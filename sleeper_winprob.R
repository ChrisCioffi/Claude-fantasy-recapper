source("sleeper_common.R")

# ---- Config ---------------------------------------------------------------
# Usage: Rscript sleeper_winprob.R <league_id> <week> <team> <projections.csv> [swaps]
#   projections.csv - columns player_name, position, proj (standard PPR points;
#                     blend your sources before writing it). DEF rows can use the
#                     team abbreviation or nickname ("LAR" / "Rams").
#   swaps           - optional lineup alternative for <team>, e.g.
#                     "Darren Waller=Jacoby Brissett;Cam Skattebo=Darren Waller"
#                     (bench the left player, start the right one).
# Simulates every team's starting lineup: each starter's projection plus a weekly
# swing drawn from last season's real results at that position (scored with this
# league's settings). Players who already played count as banked points.
N_SIMS <- 20000
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4) stop("Usage: Rscript sleeper_winprob.R <league_id> <week> <team> <projections.csv> [swaps]")
LEAGUE_ID <- args[1]; WEEK <- as.integer(args[2]); TEAM <- args[3]; PROJ_CSV <- args[4]
SWAPS <- if (length(args) >= 5) args[5] else NA_character_
set.seed(WEEK)

league  <- sleeper_get(sprintf("league/%s", LEAGUE_ID))
season  <- league$season
scoring <- unlist(league$scoring_settings)
slots   <- unlist(league$roster_positions)
slots   <- slots[!slots %in% c("BN", "IR", "TAXI")]
median_game <- isTRUE((league$settings$league_average_match %||% 0) == 1)
me <- resolve_roster(LEAGUE_ID, TEAM)
teams <- resolve_roster(LEAGUE_ID, NA)
ptab <- player_table(load_players())

# ---- Weekly swing pools from last season -------------------------------------
prev <- as.character(as.integer(season) - 1)
RESID_CACHE <- sprintf("stats_cache_%s.rds", prev)
if (file.exists(RESID_CACHE)) {
  prev_stats <- readRDS(RESID_CACHE)
} else {
  cat(sprintf("Fetching %s weekly stats (one-time, cached to %s)...\n", prev, RESID_CACHE))
  prev_stats <- lapply(1:18, function(w) week_stats(prev, w))
  saveRDS(prev_stats, RESID_CACHE)
}
prev_pts <- bind_rows(lapply(seq_along(prev_stats), function(w) {
  s <- prev_stats[[w]]
  if (!length(s)) return(NULL)
  tibble(player_id = names(s), week = w,
         pts = vapply(s, score_line, numeric(1), scoring = scoring))
})) |>
  left_join(ptab |> select(player_id, position), by = "player_id") |>
  mutate(position = ifelse(is.na(position) & grepl("^[A-Z]+$", player_id), "DEF", position))
# Residual = week score minus the player's average in his *other* weeks
resid_pool <- prev_pts |>
  group_by(player_id) |>
  filter(n() >= 6) |>
  mutate(loo = (sum(pts) - pts) / (n() - 1), resid = pts - loo) |>
  ungroup() |>
  select(position, loo, resid)

swing_pool <- function(pos, mu) {
  pool <- resid_pool[resid_pool$position %in% pos, ]
  for (w in c(2, 3, 5, 8, Inf)) {
    r <- pool$resid[abs(pool$loo - mu) <= w]
    if (length(r) >= 60) return(r - mean(r))
  }
  if (nrow(pool)) pool$resid - mean(pool$resid) else 0
}

# ---- This season so far: receptions/game and fallback averages ----------------
cur <- bind_rows(lapply(seq_len(max(0, WEEK - 1)), function(w) {
  s <- week_stats(season, w)
  if (!length(s)) return(NULL)
  tibble(player_id = names(s),
         rec = vapply(s, function(x) as.numeric(x$rec %||% 0), numeric(1)),
         pts = vapply(s, score_line, numeric(1), scoring = scoring))
}))
season_avg <- if (nrow(cur)) cur |> group_by(player_id) |>
  summarise(rec_pg = mean(rec), ppg = mean(pts), .groups = "drop") else
  tibble(player_id = character(), rec_pg = numeric(), ppg = numeric())
played_now <- names(week_stats(season, WEEK))

# ---- Projections -------------------------------------------------------------------
proj <- read.csv(PROJ_CSV, stringsAsFactors = FALSE)
proj$player_id <- mapply(function(n, p) resolve_player(n, ptab, p), proj$player_name, proj$position)
unmatched <- proj$player_name[is.na(proj$player_id)]
if (length(unmatched)) cat("Unmatched projection rows (ignored):", paste(unmatched, collapse = ", "), "\n")
proj <- proj[!is.na(proj$player_id), ]
rec_value <- scoring[["rec"]] %||% 0
te_bonus  <- if ("bonus_rec_te" %in% names(scoring)) scoring[["bonus_rec_te"]] else 0

starter_spec <- function(pid, live_pts) {
  info <- ptab[ptab$player_id == pid, ]
  pos <- if (nrow(info)) info$position else "DEF"
  name <- if (nrow(info)) info$player_name else pid
  sa <- season_avg[season_avg$player_id == pid, ]
  if (pid %in% played_now) return(list(name, pos, "played", live_pts[[pid]] %||% 0, NULL))
  if (nrow(info) && isTRUE(info$injury_status %in% c("Out", "IR", "Doubtful", "Sus")))
    return(list(name, pos, "out", 0, NULL))
  pr <- proj$proj[proj$player_id == pid]
  if (length(pr)) {
    mu <- pr[1]; src <- "proj"
    # Projections are standard PPR: adjust for this league's reception scoring
    if (nrow(sa) && pos != "DEF") mu <- mu + (rec_value - 1) * sa$rec_pg +
        (if (pos == "TE") te_bonus * sa$rec_pg else 0)
  } else if (pos %in% c("K", "DEF")) {
    # Rankings sources often skip kickers/defenses; their season average is a fair stand-in
    mu <- if (nrow(sa)) sa$ppg else 0; src <- "season avg"
  } else {
    # Sources list every startable player, so a missing one is likely on bye or not worth starting
    mu <- 0; src <- "NO PROJECTION - bye/unlisted? add a row to the CSV"
  }
  list(name, pos, src, mu, swing_pool(pos, mu))
}

matchups <- sleeper_get(sprintf("league/%s/matchups/%d", LEAGUE_ID, WEEK))
build_team <- function(m, starters = unlist(m$starters)) {
  lapply(starters, starter_spec, live_pts = m$players_points %||% list())
}
simulate <- function(spec) {
  tot <- numeric(N_SIMS)
  for (s in spec) {
    tot <- tot + if (is.null(s[[5]])) s[[4]] else pmax(s[[4]] + sample(s[[5]], N_SIMS, replace = TRUE), -5)
  }
  tot
}

specs <- lapply(matchups, build_team)
names(specs) <- vapply(matchups, function(m) as.character(m$roster_id), character(1))
sims <- lapply(specs, simulate)
my_m <- Filter(function(m) m$roster_id == me$roster_id, matchups)[[1]]
opp_m <- Filter(function(m) m$matchup_id == my_m$matchup_id && m$roster_id != me$roster_id, matchups)[[1]]
label <- function(rid) teams$team_label[teams$roster_id == rid]

report <- function(title, my_spec, my_sim) {
  opp_sim <- sims[[as.character(opp_m$roster_id)]]
  cat(sprintf("\n== %s ==\n", title))
  for (who in list(list(label(me$roster_id), my_spec, my_sim),
                   list(label(opp_m$roster_id), specs[[as.character(opp_m$roster_id)]], opp_sim))) {
    cat(sprintf("%s: projected %.1f (10-90%% range %.0f-%.0f)\n", who[[1]],
                sum(vapply(who[[2]], `[[`, numeric(1), 4)),
                quantile(who[[3]], .1), quantile(who[[3]], .9)))
    for (s in who[[2]]) cat(sprintf("   %-4s %-24s %5.1f (%s)\n", s[[2]], s[[1]], s[[4]], s[[3]]))
  }
  h2h <- mean(my_sim > opp_sim)
  cat(sprintf("P(win head-to-head) = %.0f%%\n", 100 * h2h))
  med <- NA
  if (median_game) {
    others <- do.call(cbind, sims[names(sims) != as.character(me$roster_id)])
    beaten_by <- rowSums(others > my_sim)
    med <- mean(beaten_by < length(sims) / 2)
    cat(sprintf("P(beat league median) = %.0f%%\n", 100 * med))
  }
  cat(sprintf("RESULT h2h=%.3f median=%s\n", h2h, ifelse(is.na(med), "NA", sprintf("%.3f", med))))
}

my_spec <- specs[[as.character(me$roster_id)]]
report("Current lineup", my_spec, sims[[as.character(me$roster_id)]])

if (!is.na(SWAPS)) {
  starters <- unlist(my_m$starters)
  for (sw in strsplit(SWAPS, ";")[[1]]) {
    pair <- trimws(strsplit(sw, "=")[[1]])
    out_id <- resolve_player(pair[1], ptab); in_id <- resolve_player(pair[2], ptab)
    if (!out_id %in% starters) stop(sprintf("%s is not in the starting lineup", pair[1]))
    starters[starters == out_id] <- in_id
  }
  alt_spec <- build_team(my_m, starters)
  report(sprintf("With swaps: %s", SWAPS), alt_spec, simulate(alt_spec))
}

cat("\nAll teams (projected):\n")
for (rid in names(specs)) cat(sprintf("  %-30s %6.1f\n", label(as.integer(rid)),
                                      sum(vapply(specs[[rid]], `[[`, numeric(1), 4))))
