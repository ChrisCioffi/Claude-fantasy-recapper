library(httr2)
library(dplyr)
library(jsonlite)

# ---- Config ---------------------------------------------------------------
LEAGUE_ID <- "1397988384693063680"
WEEK      <- 1
PLAYERS_CACHE <- "players_cache.rds"  # 2026-09-15: avoid re-hitting /players/nfl every run

# ---- Fetch helpers ----------------------------------------------------------
sleeper_get <- function(path) {
  request(paste0("https://api.sleeper.app/v1/", path)) |>
    req_perform() |>
    resp_body_json(simplifyVector = TRUE)
}

# ---- Fetch raw data ---------------------------------------------------------
cat("Fetching rosters...\n")
rosters_raw <- sleeper_get(sprintf("league/%s/rosters", LEAGUE_ID))

cat("Fetching users...\n")
users_raw <- sleeper_get(sprintf("league/%s/users", LEAGUE_ID))

cat("Fetching matchups...\n")
matchups_raw <- sleeper_get(sprintf("league/%s/matchups/%d", LEAGUE_ID, WEEK))

# ---- Build rosters table ----------------------------------------------------
rosters <- tibble(
  roster_id = rosters_raw$roster_id,
  owner_id  = rosters_raw$owner_id
)

# ---- Build users table ------------------------------------------------------
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

# ---- Build matchups table ---------------------------------------------------
matchups <- tibble(
  roster_id  = matchups_raw$roster_id,
  matchup_id = matchups_raw$matchup_id,
  points     = matchups_raw$points,
  starters   = matchups_raw$starters
)

# ---- Extract per-player points ----------------------------------------------
# Sleeper returns players_points as a data frame where:
#   - column names = player IDs
#   - row i = scores for roster i
# We need to transpose this into a long format: roster_id | player_id | pts

pp_df <- matchups_raw$players_points

player_points <- lapply(seq_len(nrow(matchups)), function(i) {
  # Each row of pp_df is one roster's player scores
  row_vals <- as.numeric(pp_df[i, ])
  col_names <- names(pp_df)

  # Keep only non-NA scores (NA = player not on this roster)
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

cat("\nDiagnostic — player_points head:\n")
print(head(player_points, 10))
cat("Rows:", nrow(player_points), "\n")

# ---- Join teams -------------------------------------------------------------
teams <- matchups |>
  left_join(rosters, by = "roster_id") |>
  left_join(users, by = c("owner_id" = "user_id")) |>
  mutate(team_label = coalesce(team_name, display_name))

# ---- Pair opponents ---------------------------------------------------------
# Self-join then keep opponent_roster to drop the self-matched row
# 2026-09-15: fixed tie-handling — previous version dropped one team from
# tied matchups entirely; this is a one-row-per-team table, so no dedup
# is needed at all, ties included.
results <- teams |>
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
    result = case_when(
      points > opponent_points ~ "W",
      points < opponent_points ~ "L",
      TRUE ~ "T"
    ),
    margin = round(points - opponent_points, 2)
  ) |>
  select(
    matchup_id, roster_id, team_label,
    points, result, margin,
    opponent_label, opponent_points
  ) |>
  arrange(matchup_id, desc(points))

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

# ---- Attach player names to scoring data ------------------------------------
player_scores <- player_points |>
  left_join(player_meta, by = "player_id") |>
  left_join(rosters, by = "roster_id") |>
  left_join(users, by = c("owner_id" = "user_id")) |>
  mutate(
    team_label = coalesce(team_name, display_name),
    starter    = mapply(function(rid, pid) {
      idx <- which(matchups$roster_id == rid)
      if (length(idx) == 0) return(FALSE)
      pid %in% unlist(matchups$starters[idx])
    }, roster_id, player_id)
  ) |>
  select(team_label, roster_id, player_id, player_name, position, nfl_team, pts, starter) |>
  arrange(team_label, desc(pts))

# ---- Print output for recap -------------------------------------------------
cat("\n\n========================================\n")
cat("WEEK", WEEK, "MATCHUP RESULTS\n")
cat("========================================\n")
print(results)

cat("\n\n========================================\n")
cat("WEEK", WEEK, "PLAYER SCORES (STARTERS FLAGGED)\n")
cat("========================================\n")
print(player_scores, n = Inf)

# ---- Summary stats ----------------------------------------------------------
cat("\n\n========================================\n")
cat("QUICK STATS\n")
cat("========================================\n")

cat("\nHighest scoring team:\n")
print(results |> arrange(desc(points)) |> slice(1) |> select(team_label, points))

cat("\nLowest scoring team:\n")
print(results |> arrange(points) |> slice(1) |> select(team_label, points))

cat("\nBiggest blowout (by margin):\n")
print(results |> filter(result == "W") |> arrange(desc(margin)) |> slice(1) |>
        select(team_label, points, opponent_label, opponent_points, margin))

cat("\nTop individual scorer (starters only):\n")
print(player_scores |> filter(starter) |> arrange(desc(pts)) |> slice(1))

cat("\nBiggest bust — starter with lowest pts (excludes K/DEF):\n")
print(player_scores |>
        filter(starter, !position %in% c("K", "DEF", "DST")) |>
        arrange(pts) |>
        slice(1))
