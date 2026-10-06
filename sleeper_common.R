library(httr2)
library(dplyr)
library(jsonlite)

# Shared helpers for sleeper_winprob.R, log_prediction.R and grade_predictions.R.

PLAYERS_CACHE <- "players_cache.rds"  # shared with sleeper_matchups.R / sleeper_waivers.R

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

sleeper_get <- function(path, simplify = FALSE) {
  request(paste0("https://api.sleeper.app/v1/", path)) |>
    req_perform() |>
    resp_body_json(simplifyVector = simplify)
}

load_players <- function() {
  if (file.exists(PLAYERS_CACHE) &&
      difftime(Sys.time(), file.info(PLAYERS_CACHE)$mtime, units = "hours") < 12) {
    readRDS(PLAYERS_CACHE)
  } else {
    p <- sleeper_get("players/nfl", simplify = TRUE)
    saveRDS(p, PLAYERS_CACHE)
    p
  }
}

field <- function(p, name, default = NA) {
  v <- p[[name]]
  if (is.null(v) || length(v) == 0) default else v[[1]]
}

player_table <- function(players) {
  tibble(
    player_id = names(players),
    player_name = vapply(players, function(p) {
      nm <- field(p, "full_name", "")
      if (nchar(nm) > 0) nm else paste(field(p, "first_name", ""), field(p, "last_name", ""))
    }, character(1)),
    position      = vapply(players, field, character(1), "position", NA_character_),
    nfl_team      = vapply(players, field, character(1), "team", NA_character_),
    injury_status = vapply(players, field, character(1), "injury_status", NA_character_)
  )
}

# Lowercase, strip punctuation and suffixes so "Deebo Samuel Sr." == "deebo samuel"
norm_name <- function(x) {
  x <- tolower(gsub("[.']", "", x))
  x <- gsub("\\b(jr|sr|ii|iii|iv|v)\\b", "", x)
  trimws(gsub("\\s+", " ", x))
}

# Resolve a player name (or a DEF team abbreviation/nickname) to a Sleeper player_id.
# Prefers players currently on an NFL team, then the given position.
resolve_player <- function(name, ptab, position = NA) {
  if (is.na(name) || !nzchar(name)) return(NA_character_)
  if (toupper(name) %in% ptab$player_id[ptab$position %in% "DEF"]) return(toupper(name))
  key <- norm_name(name)
  cand <- ptab[norm_name(ptab$player_name) == key, ]
  if (nrow(cand) == 0) {
    # DEF by nickname, e.g. "Rams" or "Rams D/ST"
    nick <- norm_name(sub("\\s*(d/st|dst|def|defense)$", "", name, ignore.case = TRUE))
    cand <- ptab[ptab$position %in% "DEF" &
                   norm_name(sub("^.* ", "", ptab$player_name)) == nick, ]
  }
  if (!is.na(position)) {
    pos_match <- cand[cand$position %in% position, ]
    if (nrow(pos_match) > 0) cand <- pos_match
  }
  cand <- cand[order(is.na(cand$nfl_team)), ]
  if (nrow(cand) == 0) NA_character_ else cand$player_id[1]
}

# League team by roster_id, team name or owner display name (case-insensitive substring)
resolve_roster <- function(league_id, query) {
  rosters <- sleeper_get(sprintf("league/%s/rosters", league_id))
  users <- sleeper_get(sprintf("league/%s/users", league_id))
  teams <- bind_rows(lapply(rosters, function(r) {
    u <- Filter(function(x) identical(x$user_id, r$owner_id), users)
    u <- if (length(u)) u[[1]] else list()
    tibble(roster_id = r$roster_id,
           display_name = u$display_name %||% NA_character_,
           team_name = u$metadata$team_name %||% NA_character_)
  })) |>
    mutate(team_label = coalesce(team_name, display_name, paste("Roster", roster_id)))
  if (is.na(query) || !nzchar(query)) return(teams)
  q <- tolower(query)
  hit <- teams |> filter(as.character(roster_id) == query |
                           grepl(q, tolower(coalesce(team_name, "")), fixed = TRUE) |
                           grepl(q, tolower(coalesce(display_name, "")), fixed = TRUE))
  if (nrow(hit) != 1) stop(sprintf("Team '%s' matched %d teams in league %s", query, nrow(hit), league_id))
  hit
}

# Fantasy points for one stat line under a league's scoring settings
score_line <- function(stat_line, scoring) {
  keys <- intersect(names(stat_line), names(scoring))
  if (length(keys) == 0) return(0)
  vals <- unlist(stat_line[keys])
  sum(as.numeric(vals) * scoring[names(vals)])
}

week_stats <- function(season, week) {
  s <- tryCatch(sleeper_get(sprintf("stats/nfl/regular/%s/%d", season, week)),
                error = function(e) list())
  Filter(function(x) (x$gp %||% 0) > 0, s)
}
