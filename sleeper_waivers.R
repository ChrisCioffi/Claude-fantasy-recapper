library(httr2)
library(dplyr)
library(jsonlite)

# ---- Config ---------------------------------------------------------------
# Usage: Rscript sleeper_waivers.R [league_id] [team]
#   league_id - Sleeper league ID (defaults to DEFAULT_LEAGUE_ID below)
#   team      - optional: the user's team, matched against roster_id, team
#               name, or owner display name (case-insensitive substring).
#               Omit to evaluate every team in the league.
# Writes league_rosters.csv and waiver_pool.csv (full tables) next to the
# script; stdout holds the summaries the waiver-wire skill reads first.
DEFAULT_LEAGUE_ID <- "1397988384693063680"
PLAYERS_CACHE <- "players_cache.rds"  # shared with sleeper_matchups.R
POOL_PER_POSITION <- 30               # free agents printed per position

options(width = 200)
args <- commandArgs(trailingOnly = TRUE)
LEAGUE_ID  <- if (length(args) >= 1 && nzchar(args[1])) args[1] else DEFAULT_LEAGUE_ID
TEAM_QUERY <- if (length(args) >= 2 && nzchar(args[2])) args[2] else NA_character_

# ---- Fetch helpers ----------------------------------------------------------
sleeper_get <- function(path, simplify = TRUE) {
  request(paste0("https://api.sleeper.app/v1/", path)) |>
    req_perform() |>
    resp_body_json(simplifyVector = simplify)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# ---- League settings --------------------------------------------------------
cat("Fetching league settings...\n")
league   <- sleeper_get(sprintf("league/%s", LEAGUE_ID), simplify = FALSE)
nfl_state <- sleeper_get("state/nfl")

season        <- league$season
scoring       <- unlist(league$scoring_settings)
roster_slots  <- unlist(league$roster_positions)
score_of      <- function(key) if (key %in% names(scoring)) scoring[[key]] else 0
waiver_type   <- league$settings$waiver_type %||% 0
waiver_budget <- league$settings$waiver_budget %||% 0
current_week  <- nfl_state$week
last_complete <- max(0, current_week - 1)

waiver_label <- switch(as.character(waiver_type),
  "0" = "Rolling waivers",
  "1" = "Reverse-standings waivers",
  "2" = sprintf("FAAB ($%s budget)", waiver_budget),
  sprintf("Unknown waiver type (%s)", waiver_type)
)
rec_pts <- score_of("rec")
format_label <- if (rec_pts >= 1) "PPR" else if (rec_pts > 0) "Half-PPR" else "Standard"

# Positions that can fill a starting slot in this league
flex_map <- list(
  FLEX       = c("RB", "WR", "TE"),
  WRRB_FLEX  = c("RB", "WR"),
  REC_FLEX   = c("WR", "TE"),
  SUPER_FLEX = c("QB", "RB", "WR", "TE"),
  IDP_FLEX   = c("DL", "LB", "DB")
)
starting_slots <- roster_slots[!roster_slots %in% c("BN", "IR", "TAXI")]
fantasy_positions <- unique(unlist(lapply(starting_slots, function(s) flex_map[[s]] %||% s)))

cat("\n========================================\n")
cat("LEAGUE SETTINGS\n")
cat("========================================\n")
cat(sprintf("League: %s (%s) — season %s\n", league$name, LEAGUE_ID, season))
cat(sprintf("Current NFL week: %d (stats below cover weeks 1-%d)\n", current_week, last_complete))
cat(sprintf("Scoring: %s (rec = %s, pass_td = %s", format_label, rec_pts, score_of("pass_td")))
if (score_of("bonus_rec_te") != 0) {
  cat(sprintf(", TE premium +%s/rec", score_of("bonus_rec_te")))
}
cat(")\n")
cat("Starting lineup:", paste(starting_slots, collapse = ", "), "\n")
cat(sprintf("Bench: %d | IR: %d | Taxi: %d\n",
            sum(roster_slots == "BN"),
            league$settings$reserve_slots %||% 0,
            league$settings$taxi_slots %||% 0))
ir_extra <- c(Out = "reserve_allow_out", Doubtful = "reserve_allow_doubtful",
              Suspended = "reserve_allow_sus", "NA" = "reserve_allow_na",
              COV = "reserve_allow_cov", DNR = "reserve_allow_dnr")
ir_allowed <- names(ir_extra)[vapply(ir_extra, function(k) isTRUE((league$settings[[k]] %||% 0) == 1), logical(1))]
cat("IR-eligible statuses:", paste(c("IR", ir_allowed), collapse = ", "), "\n")
cat("Waivers:", waiver_label, "\n")

# ---- Rosters + users ----------------------------------------------------------
cat("\nFetching rosters and users...\n")
rosters_raw <- sleeper_get(sprintf("league/%s/rosters", LEAGUE_ID), simplify = FALSE)
users_raw   <- sleeper_get(sprintf("league/%s/users", LEAGUE_ID), simplify = FALSE)

users <- bind_rows(lapply(users_raw, function(u) {
  tn <- u$metadata$team_name %||% ""
  tibble(
    user_id      = u$user_id,
    display_name = u$display_name,
    team_name    = if (nchar(tn) > 0) tn else NA_character_
  )
}))

teams <- bind_rows(lapply(rosters_raw, function(r) {
  s <- r$settings
  tibble(
    roster_id       = r$roster_id,
    owner_id        = r$owner_id %||% NA_character_,
    wins            = s$wins %||% 0,
    losses          = s$losses %||% 0,
    ties            = s$ties %||% 0,
    points_for      = (s$fpts %||% 0) + (s$fpts_decimal %||% 0) / 100,
    waiver_position = s$waiver_position %||% NA,
    faab_remaining  = if (waiver_type == 2) waiver_budget - (s$waiver_budget_used %||% 0) else NA
  )
})) |>
  left_join(users, by = c("owner_id" = "user_id")) |>
  mutate(team_label = coalesce(team_name, display_name, paste("Roster", roster_id)))

roster_players <- bind_rows(lapply(rosters_raw, function(r) {
  players <- unlist(r$players)
  if (length(players) == 0) return(NULL)
  starters <- unlist(r$starters)
  reserve  <- unlist(r$reserve)
  taxi     <- unlist(r$taxi)
  tibble(
    roster_id = r$roster_id,
    player_id = players,
    slot = case_when(
      players %in% reserve  ~ "IR",
      players %in% taxi     ~ "TAXI",
      players %in% starters ~ "START",
      TRUE                  ~ "BENCH"
    )
  )
}))

# ---- Player metadata (cached) -------------------------------------------------
if (file.exists(PLAYERS_CACHE) &&
    difftime(Sys.time(), file.info(PLAYERS_CACHE)$mtime, units = "hours") < 12) {
  cat("Loading cached player metadata...\n")
  all_players_raw <- readRDS(PLAYERS_CACHE)
} else {
  cat("Fetching player metadata (this may take a moment)...\n")
  all_players_raw <- sleeper_get("players/nfl")
  saveRDS(all_players_raw, PLAYERS_CACHE)
}

field <- function(p, name, default = NA) {
  v <- p[[name]]
  if (is.null(v) || length(v) == 0) default else v[[1]]
}

player_meta <- tibble(
  player_id   = names(all_players_raw),
  player_name = sapply(all_players_raw, function(p) {
    nm <- field(p, "full_name", "")
    if (nchar(nm) > 0) nm else paste(field(p, "first_name", ""), field(p, "last_name", ""))
  }),
  position      = sapply(all_players_raw, field, "position", NA_character_),
  nfl_team      = sapply(all_players_raw, field, "team", NA_character_),
  status        = sapply(all_players_raw, field, "status", NA_character_),
  injury_status = sapply(all_players_raw, field, "injury_status", NA_character_),
  depth_order   = sapply(all_players_raw, field, "depth_chart_order", NA_integer_),
  years_exp     = sapply(all_players_raw, field, "years_exp", NA_integer_),
  search_rank   = sapply(all_players_raw, field, "search_rank", NA_integer_)
) |>
  mutate(across(c(depth_order, years_exp, search_rank), as.integer))

# ---- Season-to-date production, scored with this league's settings ---------
score_line <- function(stat_line) {
  keys <- intersect(names(stat_line), names(scoring))
  if (length(keys) == 0) return(0)
  sum(unlist(stat_line[keys]) * scoring[keys])
}

weekly <- list()
if (last_complete >= 1) {
  for (wk in seq_len(last_complete)) {
    cat(sprintf("Fetching week %d player stats...\n", wk))
    wk_stats <- tryCatch(
      sleeper_get(sprintf("stats/nfl/regular/%s/%d", season, wk), simplify = FALSE),
      error = function(e) { cat("  stats unavailable:", conditionMessage(e), "\n"); NULL }
    )
    if (is.null(wk_stats) || length(wk_stats) == 0) next
    played <- vapply(wk_stats, function(s) (s$gp %||% s$gms_active %||% 0) > 0, logical(1))
    wk_stats <- wk_stats[played]
    if (length(wk_stats) == 0) next
    weekly[[length(weekly) + 1]] <- tibble(
      player_id = names(wk_stats),
      week      = wk,
      pts       = round(vapply(wk_stats, score_line, numeric(1)), 2)
    )
  }
}
weekly <- bind_rows(weekly)

production <- if (nrow(weekly) > 0) {
  weekly |>
    group_by(player_id) |>
    summarise(
      games      = n(),
      season_pts = round(sum(pts), 1),
      ppg        = round(mean(pts), 1),
      last_wk    = if (any(week == last_complete)) pts[week == last_complete] else NA_real_,
      # last 2 weeks played, to surface breakouts
      recent_ppg = round(mean(tail(pts[order(week)], 2)), 1),
      .groups = "drop"
    )
} else {
  tibble(player_id = character(), games = integer(), season_pts = numeric(),
         ppg = numeric(), last_wk = numeric(), recent_ppg = numeric())
}

# ---- Trending adds (Sleeper-wide, last 48h) ----------------------------------
trending <- tryCatch(
  sleeper_get("players/nfl/trending/add?lookback_hours=48&limit=100"),
  error = function(e) data.frame(player_id = character(), count = integer())
)
trending <- tibble(player_id = as.character(trending$player_id),
                   trend_adds_48h = as.integer(trending$count))

# ---- Assemble tables ------------------------------------------------------------
enrich <- function(df) {
  df |>
    left_join(player_meta, by = "player_id") |>
    left_join(production, by = "player_id") |>
    left_join(trending, by = "player_id") |>
    mutate(
      across(c(games, season_pts), ~ coalesce(.x, 0)),
      trend_adds_48h = coalesce(trend_adds_48h, 0L)
    )
}

league_rosters <- roster_players |>
  enrich() |>
  left_join(teams |> select(roster_id, team_label), by = "roster_id") |>
  select(team_label, roster_id, slot, player_name, position, nfl_team, injury_status,
         games, season_pts, ppg, recent_ppg, last_wk, player_id) |>
  arrange(roster_id, factor(slot, levels = c("START", "BENCH", "IR", "TAXI")),
          position, desc(season_pts))

waiver_pool <- player_meta |>
  filter(!player_id %in% roster_players$player_id,
         position %in% fantasy_positions,
         !is.na(nfl_team),
         coalesce(status, "Active") != "Inactive") |>
  select(player_id) |>
  enrich() |>
  select(player_name, position, nfl_team, injury_status, depth_order, years_exp,
         games, season_pts, ppg, recent_ppg, last_wk, trend_adds_48h, search_rank, player_id) |>
  arrange(position, desc(season_pts), search_rank)

write.csv(league_rosters, "league_rosters.csv", row.names = FALSE)
write.csv(waiver_pool, "waiver_pool.csv", row.names = FALSE)

# ---- Which team(s) to evaluate ---------------------------------------------------
focus <- teams
if (!is.na(TEAM_QUERY)) {
  q <- tolower(TEAM_QUERY)
  focus <- teams |>
    filter(as.character(roster_id) == TEAM_QUERY |
             grepl(q, tolower(coalesce(team_name, "")), fixed = TRUE) |
             grepl(q, tolower(coalesce(display_name, "")), fixed = TRUE))
  if (nrow(focus) == 0) {
    cat(sprintf("\nNo team matched '%s'. Teams in this league:\n", TEAM_QUERY))
    print(teams |> select(roster_id, team_label, display_name), n = Inf)
    quit(status = 1)
  }
}

# ---- Print summaries --------------------------------------------------------------
cat("\n========================================\n")
cat("TEAMS\n")
cat("========================================\n")
print(teams |>
        mutate(record = sprintf("%d-%d-%d", wins, losses, ties)) |>
        select(roster_id, team_label, display_name, record, points_for,
               waiver_position, faab_remaining) |>
        arrange(roster_id), n = Inf)

for (rid in focus$roster_id) {
  t <- focus |> filter(roster_id == rid)
  cat("\n========================================\n")
  cat(sprintf("ROSTER — %s (roster %d, %s, %d-%d-%d",
              t$team_label, rid, t$display_name, t$wins, t$losses, t$ties))
  if (!is.na(t$faab_remaining)) cat(sprintf(", $%s FAAB left", t$faab_remaining))
  cat(")\n")
  cat("========================================\n")
  print(league_rosters |> filter(roster_id == rid) |> select(-team_label, -roster_id, -player_id),
        n = Inf)
}

cat("\n========================================\n")
cat("POSITIONAL DEPTH (rostered players per position, excluding IR/taxi)\n")
cat("========================================\n")
active <- league_rosters |>
  filter(slot %in% c("START", "BENCH"), position %in% fantasy_positions)
depth <- as.data.frame.matrix(table(active$team_label,
                                    factor(active$position, levels = fantasy_positions)))
print(depth)
cat("Starting slots:", paste(names(table(starting_slots)), table(starting_slots),
                             sep = "x", collapse = ", "), "\n")

cat("\n========================================\n")
cat(sprintf("FREE AGENT POOL — top %d per position by season points (full list: waiver_pool.csv)\n",
            POOL_PER_POSITION))
cat("========================================\n")
for (pos in fantasy_positions) {
  cat(sprintf("\n-- %s --\n", pos))
  print(waiver_pool |>
          filter(position == pos) |>
          slice_head(n = POOL_PER_POSITION) |>
          select(-position, -player_id),
        n = Inf)
}

cat("\n========================================\n")
cat("TRENDING ADDS ON SLEEPER (48h) — and whether they're available here\n")
cat("========================================\n")
print(trending |>
        left_join(player_meta |> select(player_id, player_name, position, nfl_team), by = "player_id") |>
        left_join(roster_players |> select(player_id, roster_id), by = "player_id") |>
        left_join(teams |> select(roster_id, team_label), by = "roster_id") |>
        mutate(available = case_when(!is.na(roster_id) ~ "rostered",
                                     is.na(nfl_team)    ~ "unsigned (no NFL team)",
                                     TRUE               ~ "available"),
               rostered_by = coalesce(team_label, "")) |>
        filter(position %in% fantasy_positions) |>
        select(player_name, position, nfl_team, trend_adds_48h, available, rostered_by) |>
        slice_head(n = 40),
      n = Inf)
