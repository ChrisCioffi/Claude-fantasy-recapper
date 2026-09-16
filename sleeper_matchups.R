library(httr2)
library(dplyr)
library(jsonlite)

# ---- Config ---------------------------------------------------------------
# Usage: Rscript sleeper_matchups.R [league_id] [week_start] [week_end]
#   league_id  - Sleeper league ID (defaults to DEFAULT_LEAGUE_ID below)
#   week_start - first week to include (defaults to 1)
#   week_end   - last week to include; omit for a single-week run, or pass
#                "season"/"current" to run through the last completed NFL week
DEFAULT_LEAGUE_ID <- "1397988384693063680"
PLAYERS_CACHE <- "players_cache.rds"  # 2026-09-15: avoid re-hitting /players/nfl every run

args <- commandArgs(trailingOnly = TRUE)
LEAGUE_ID    <- if (length(args) >= 1 && nzchar(args[1])) args[1] else DEFAULT_LEAGUE_ID
WEEK_START   <- if (length(args) >= 2) as.integer(args[2]) else 1
WEEK_END_ARG <- if (length(args) >= 3) args[3] else as.character(WEEK_START)

# ---- Fetch helpers ----------------------------------------------------------
sleeper_get <- function(path) {
  request(paste0("https://api.sleeper.app/v1/", path)) |>
    req_perform() |>
    resp_body_json(simplifyVector = TRUE)
}

# "season"/"current" resolves to the last completed NFL week
if (identical(WEEK_END_ARG, "season") || identical(WEEK_END_ARG, "current")) {
  nfl_state <- sleeper_get("state/nfl")
  WEEK_END  <- max(WEEK_START, nfl_state$week - 1)
} else {
  WEEK_END <- as.integer(WEEK_END_ARG)
}

cat(sprintf("League %s — weeks %d to %d\n", LEAGUE_ID, WEEK_START, WEEK_END))

# ---- League-level data (fetched once, shared across weeks) ------------------
cat("Fetching rosters...\n")
rosters_raw <- sleeper_get(sprintf("league/%s/rosters", LEAGUE_ID))
rosters <- tibble(
  roster_id = rosters_raw$roster_id,
  owner_id  = rosters_raw$owner_id
)

cat("Fetching users...\n")
users_raw <- sleeper_get(sprintf("league/%s/users", LEAGUE_ID))
users <- tibble(
  user_id      = users_raw$user_id,
  display_name = users_raw$display_name
) |>
  mutate(
    team_name = sapply(seq_along(users_raw$user_id), function(i) {
      m <- users_raw$metadata[[i]]
      if (is.list(m) && !is.null(m$team_name) && nchar(m$team_name) > 0) {
        m$team_name
      } else {
        NA_character_
      }
    })
  )

# ---- Fetch player metadata (cached) -----------------------------------------
if (file.exists(PLAYERS_CACHE) &&
    difftime(Sys.time(), file.info(PLAYERS_CACHE)$mtime, units = "hours") < 12) {
  cat("Loading cached player metadata...\n")
  all_players_raw <- readRDS(PLAYERS_CACHE)
} else {
  cat("Fetching player metadata (this may take a moment)...\n")
  all_players_raw <- sleeper_get("players/nfl")
  saveRDS(all_players_raw, PLAYERS_CACHE)
}

player_meta <- tibble(
  player_id   = names(all_players_raw),
  player_name = sapply(all_players_raw, function(p) {
    nm <- p$full_name
    if (!is.null(nm) && nchar(nm) > 0) nm else paste(p$first_name, p$last_name)
  }),
  position = sapply(all_players_raw, function(p) {
    if (!is.null(p$position)) p$position else NA_character_
  }),
  nfl_team = sapply(all_players_raw, function(p) {
    if (!is.null(p$team)) p$team else NA_character_
  })
)

# ---- Per-week fetch + transform ----------------------------------------------
# Returns NULL if the week hasn't been played yet (Sleeper returns no rosters).
fetch_week <- function(week) {
  matchups_raw <- sleeper_get(sprintf("league/%s/matchups/%d", LEAGUE_ID, week))

  if (length(matchups_raw) == 0 || is.null(matchups_raw$roster_id)) {
    return(NULL)
  }

  matchups <- tibble(
    roster_id  = matchups_raw$roster_id,
    matchup_id = matchups_raw$matchup_id,
    points     = matchups_raw$points,
    starters   = matchups_raw$starters
  )

  # Sleeper returns players_points as a data frame where column names are
  # player IDs and row i holds roster i's scores; transpose to long format.
  pp_df <- matchups_raw$players_points

  player_points <- lapply(seq_len(nrow(matchups)), function(i) {
    row_vals <- as.numeric(pp_df[i, ])
    col_names <- names(pp_df)
    keep <- !is.na(row_vals)

    if (!any(keep)) {
      return(tibble(roster_id = integer(), player_id = character(), pts = numeric()))
    }

    tibble(
      roster_id = matchups$roster_id[i],
      player_id = col_names[keep],
      pts       = row_vals[keep]
    )
  }) |>
    bind_rows()

  teams <- matchups |>
    left_join(rosters, by = "roster_id") |>
    left_join(users, by = c("owner_id" = "user_id")) |>
    mutate(team_label = coalesce(team_name, display_name))

  # Self-join to pair each team with its opponent; ties keep both rows
  # since this is one-row-per-team, not deduped by matchup.
  week_results <- teams |>
    inner_join(
      teams |> select(
        matchup_id,
        opponent_label  = team_label,
        opponent_points = points,
        opponent_roster = roster_id
      ),
      by = "matchup_id",
      relationship = "many-to-many"
    ) |>
    filter(roster_id != opponent_roster) |>
    mutate(
      week   = week,
      result = case_when(
        points > opponent_points ~ "W",
        points < opponent_points ~ "L",
        TRUE ~ "T"
      ),
      margin = round(points - opponent_points, 2)
    ) |>
    select(
      week, matchup_id, roster_id, team_label,
      points, result, margin,
      opponent_label, opponent_points
    ) |>
    arrange(matchup_id, desc(points))

  week_player_scores <- player_points |>
    left_join(player_meta, by = "player_id") |>
    left_join(rosters, by = "roster_id") |>
    left_join(users, by = c("owner_id" = "user_id")) |>
    mutate(
      week       = week,
      team_label = coalesce(team_name, display_name),
      starter    = mapply(function(rid, pid) {
        idx <- which(matchups$roster_id == rid)
        if (length(idx) == 0) return(FALSE)
        pid %in% unlist(matchups$starters[idx])
      }, roster_id, player_id)
    ) |>
    select(week, team_label, roster_id, player_id, player_name, position, nfl_team, pts, starter) |>
    arrange(desc(pts))

  list(results = week_results, player_scores = week_player_scores)
}

# ---- Loop over the requested weeks, printing each week's recap data ---------
all_results <- list()
all_player_scores <- list()

for (wk in WEEK_START:WEEK_END) {
  cat(sprintf("\nFetching matchups for week %d...\n", wk))
  wk_data <- fetch_week(wk)

  if (is.null(wk_data)) {
    cat(sprintf("  No matchup data for week %d (not played yet) — skipping.\n", wk))
    next
  }

  all_results[[length(all_results) + 1]] <- wk_data$results
  all_player_scores[[length(all_player_scores) + 1]] <- wk_data$player_scores

  cat("\n========================================\n")
  cat("WEEK", wk, "MATCHUP RESULTS\n")
  cat("========================================\n")
  print(wk_data$results)

  cat("\n========================================\n")
  cat("WEEK", wk, "PLAYER SCORES (STARTERS FLAGGED)\n")
  cat("========================================\n")
  print(wk_data$player_scores, n = Inf)
}

results <- bind_rows(all_results)
player_scores <- bind_rows(all_player_scores)

if (nrow(results) == 0) {
  cat("\nNo matchup data found for the requested week(s).\n")
  quit(status = 0)
}

n_weeks <- length(unique(results$week))

# ---- Quick stats across the requested range ----------------------------------
cat("\n\n========================================\n")
cat("QUICK STATS —",
    if (n_weeks > 1) sprintf("weeks %d-%d", WEEK_START, WEEK_END) else sprintf("week %d", WEEK_START),
    "\n")
cat("========================================\n")

cat("\nHighest scoring team performance:\n")
print(results |> arrange(desc(points)) |> slice(1) |> select(week, team_label, points))

cat("\nLowest scoring team performance:\n")
print(results |> arrange(points) |> slice(1) |> select(week, team_label, points))

cat("\nBiggest blowout (by margin):\n")
print(results |> filter(result == "W") |> arrange(desc(margin)) |> slice(1) |>
        select(week, team_label, points, opponent_label, opponent_points, margin))

cat("\nTop individual scorer (starters only):\n")
print(player_scores |> filter(starter) |> arrange(desc(pts)) |> slice(1))

cat("\nBiggest bust — starter with lowest pts (excludes K/DEF):\n")
print(player_scores |>
        filter(starter, !position %in% c("K", "DEF", "DST")) |>
        arrange(pts) |>
        slice(1))

# ---- Standings across the requested range (multi-week runs only) ------------
if (n_weeks > 1) {
  cat("\n\n========================================\n")
  cat("STANDINGS — weeks", WEEK_START, "to", WEEK_END, "\n")
  cat("========================================\n")

  standings <- results |>
    group_by(team_label) |>
    summarise(
      wins           = sum(result == "W"),
      losses         = sum(result == "L"),
      ties           = sum(result == "T"),
      points_for     = round(sum(points), 2),
      points_against = round(sum(opponent_points), 2),
      avg_points     = round(mean(points), 2),
      .groups = "drop"
    ) |>
    arrange(desc(wins), desc(points_for))

  print(standings, n = Inf)
}
