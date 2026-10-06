source("sleeper_common.R")

# ---- Config ---------------------------------------------------------------
# Usage: Rscript log_prediction.R key=value ...
#   league=<id> week=<n> team=<roster_id|name>   (required)
#   kind=<h2h|median|start|add|trade>              (required)
#     h2h / median : pred = win probability (0-1)
#     start        : pick = player started, alt = player benched for him
#     add          : pick = player added,  alt = player dropped (or the add passed over)
#     trade        : pick = player received, alt = the player he'd replace in the lineup
#   pick="Name" alt="Name" pick_pos=WR alt_pos=RB   (decisions; DEF can be "LAR"/"Rams")
#   pred=<number> alt_pred=<number>                 (projection or probability)
#   sources="CBS,ESPN"  followed=<yes|no|unknown>  note="free text"
# Appends one row to predictions/log.csv; grade_predictions.R fills in results.
LOG_FILE <- "predictions/log.csv"
LOG_COLS <- c("logged_at", "season", "week", "league_id", "roster_id", "kind",
              "pick", "pick_id", "alt", "alt_id", "pred", "alt_pred", "sources",
              "followed", "note", "actual_pick", "actual_alt", "outcome", "graded_at")

kv <- commandArgs(trailingOnly = TRUE)
opts <- setNames(sub("^[^=]*=", "", kv), sub("=.*$", "", kv))
get_opt <- function(k, default = NA) if (k %in% names(opts) && nzchar(opts[[k]])) opts[[k]] else default
for (k in c("league", "week", "team", "kind")) if (is.na(get_opt(k))) stop(sprintf("Missing %s=", k))
kind <- get_opt("kind")
if (!kind %in% c("h2h", "median", "start", "add", "trade")) stop("kind must be h2h, median, start, add or trade")

league <- sleeper_get(sprintf("league/%s", get_opt("league")))
team <- resolve_roster(get_opt("league"), get_opt("team"))
ptab <- player_table(load_players())

pick_id <- alt_id <- NA_character_
if (kind %in% c("start", "add", "trade")) {
  pick_id <- resolve_player(get_opt("pick"), ptab, get_opt("pick_pos"))
  alt_id  <- resolve_player(get_opt("alt"), ptab, get_opt("alt_pos"))
  if (is.na(pick_id) || is.na(alt_id)) stop("Could not resolve pick/alt to Sleeper player IDs")
}

row <- data.frame(
  logged_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
  season = league$season, week = as.integer(get_opt("week")),
  league_id = get_opt("league"), roster_id = team$roster_id, kind = kind,
  pick = get_opt("pick", ""), pick_id = ifelse(is.na(pick_id), "", pick_id),
  alt = get_opt("alt", ""), alt_id = ifelse(is.na(alt_id), "", alt_id),
  pred = get_opt("pred", ""), alt_pred = get_opt("alt_pred", ""), sources = get_opt("sources", ""),
  followed = get_opt("followed", "unknown"), note = get_opt("note", ""),
  actual_pick = "", actual_alt = "", outcome = "", graded_at = "",
  stringsAsFactors = FALSE
)
dir.create(dirname(LOG_FILE), showWarnings = FALSE)
write.table(row[LOG_COLS], LOG_FILE, sep = ",", row.names = FALSE, qmethod = "double",
            append = file.exists(LOG_FILE), col.names = !file.exists(LOG_FILE))
cat(sprintf("Logged %s for %s, week %s: %s\n", kind, team$team_label, row$week,
            if (kind %in% c("h2h", "median")) sprintf("p=%s", row$pred)
            else sprintf("%s over %s", row$pick, row$alt)))
