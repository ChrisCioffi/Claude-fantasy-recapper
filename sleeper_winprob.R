source("sleeper_common.R")

# ---- Config ---------------------------------------------------------------
# Usage: Rscript sleeper_winprob.R <league_id> <week> <team> <projections.csv> [scenarios]
#   projections.csv - columns player_name, position, proj (standard PPR points;
#                     blend your sources before writing it). Optional columns:
#                     player_id (skips name matching) and active (1 = ignore an
#                     Out/Doubtful tag, e.g. a player cleared to return).
#                     DEF rows can use the team abbreviation or nickname.
#   scenarios       - optional lineup alternatives for <team>, separated by "|".
#                     Each is "label::Out Player=In Player;Out=In" (bench the
#                     left player, start the right one; the right one can be a
#                     free agent, to price a pickup). Label is optional.
# Simulates every team's starting lineup: each starter's projection plus a weekly
# swing drawn from last season's real results at that position (scored with this
# league's settings). Players who already played count as banked points. Other
# teams are assumed to start their best projected lineup; your team is simulated
# as currently set, as your best lineup, and under each scenario, all on the same
# random draws so the differences are real and not noise.
N_SIMS <- 20000
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4) stop("Usage: Rscript sleeper_winprob.R <league_id> <week> <team> <projections.csv> [scenarios]")
LEAGUE_ID <- args[1]; WEEK <- as.integer(args[2]); TEAM <- args[3]; PROJ_CSV <- args[4]
SCENARIOS <- if (length(args) >= 5 && nzchar(args[5])) strsplit(args[5], "|", fixed = TRUE)[[1]] else character()
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
proj <- read.csv(PROJ_CSV, stringsAsFactors = FALSE, colClasses = c(player_id = "character"))
if (!"player_id" %in% names(proj)) proj$player_id <- NA_character_
need <- is.na(proj$player_id) | !nzchar(proj$player_id)
if (any(need)) proj$player_id[need] <- unname(mapply(function(n, p) resolve_player(n, ptab, p),
                                                    proj$player_name[need], proj$position[need]))
unmatched <- proj$player_name[is.na(proj$player_id)]
if (length(unmatched)) cat("Unmatched projection rows (ignored):", paste(unmatched, collapse = ", "), "\n")
proj <- proj[!is.na(proj$player_id), ]
if (!"active" %in% names(proj)) proj$active <- 0
rec_value <- scoring[["rec"]] %||% 0
te_bonus  <- if ("bonus_rec_te" %in% names(scoring)) scoring[["bonus_rec_te"]] else 0

matchups <- sleeper_get(sprintf("league/%s/matchups/%d", LEAGUE_ID, WEEK))
live_pts <- do.call(c, lapply(matchups, function(m) m$players_points %||% list()))

# One spec per player: name, position, source, projected points, and a fixed set
# of N_SIMS simulated scores (common random numbers across every lineup).
spec_cache <- new.env()
player_spec <- function(pid) {
  if (!is.null(spec_cache[[pid]])) return(spec_cache[[pid]])
  info <- ptab[ptab$player_id == pid, ]
  pos <- if (nrow(info)) info$position else "DEF"
  name <- if (nrow(info)) info$player_name else pid
  sa <- season_avg[season_avg$player_id == pid, ]
  pr <- proj[proj$player_id == pid, ]
  forced_active <- nrow(pr) > 0 && isTRUE(as.numeric(pr$active[1]) == 1)
  if (pid %in% played_now) {
    sp <- list(name = name, pos = pos, src = "played", mu = live_pts[[pid]] %||% 0)
  } else if (!forced_active && nrow(info) && isTRUE(info$injury_status %in% c("Out", "IR", "Doubtful", "Sus"))) {
    sp <- list(name = name, pos = pos, src = "out", mu = 0)
  } else if (nrow(pr)) {
    mu <- pr$proj[1]
    # Projections are standard PPR: adjust for this league's reception scoring
    if (nrow(sa) && pos != "DEF") mu <- mu + (rec_value - 1) * sa$rec_pg +
        (if (pos == "TE") te_bonus * sa$rec_pg else 0)
    sp <- list(name = name, pos = pos, src = if (forced_active) "proj (cleared to play)" else "proj", mu = mu)
  } else if (pos %in% c("K", "DEF")) {
    # Rankings sources often skip kickers/defenses; their season average is a fair stand-in
    sp <- list(name = name, pos = pos, src = "season avg", mu = if (nrow(sa)) sa$ppg else 0)
  } else {
    # Sources list every startable player, so a missing one is likely on bye or not worth starting
    sp <- list(name = name, pos = pos, src = "NO PROJECTION - bye/unlisted?", mu = 0)
  }
  sp$draws <- if (sp$src %in% c("played", "out") || sp$mu == 0) rep(sp$mu, N_SIMS) else
    pmax(sp$mu + sample(swing_pool(pos, sp$mu), N_SIMS, replace = TRUE), -5)
  spec_cache[[pid]] <- sp
  sp
}

# ---- Lineups ---------------------------------------------------------------------------
flex_map <- list(FLEX = c("RB", "WR", "TE"), WRRB_FLEX = c("RB", "WR"), REC_FLEX = c("WR", "TE"),
                 SUPER_FLEX = c("QB", "RB", "WR", "TE"), IDP_FLEX = c("DL", "LB", "DB"))
eligible <- function(slot) flex_map[[slot]] %||% slot
# Best projected lineup: fill the narrowest slots first, then flex, then superflex
best_lineup <- function(pids) {
  pool <- unique(pids[!is.na(pids)])
  mus <- vapply(pool, function(p) player_spec(p)$mu, numeric(1))
  poss <- vapply(pool, function(p) player_spec(p)$pos, character(1))
  order_slots <- order(vapply(slots, function(s) length(eligible(s)), integer(1)))
  chosen <- rep(NA_character_, length(slots))
  for (i in order_slots) {
    ok <- which(poss %in% eligible(slots[i]) & !pool %in% chosen)
    if (length(ok)) chosen[i] <- pool[ok[which.max(mus[ok])]]
  }
  chosen
}
lineup_sim <- function(starters) {
  starters <- starters[!is.na(starters) & starters != "0"]
  if (!length(starters)) return(numeric(N_SIMS))
  Reduce(`+`, lapply(starters, function(p) player_spec(p)$draws))
}
lineup_mu <- function(starters) sum(vapply(starters[!is.na(starters) & starters != "0"],
                                           function(p) player_spec(p)$mu, numeric(1)))

label <- function(rid) teams$team_label[teams$roster_id == rid]
my_m  <- Filter(function(m) m$roster_id == me$roster_id, matchups)[[1]]
opp_m <- Filter(function(m) m$matchup_id == my_m$matchup_id && m$roster_id != me$roster_id, matchups)[[1]]
# A team with a slot it can't fill (bye, injury) will pick up the best free agent
rostered <- unlist(lapply(matchups, function(m) unlist(m$players)))
free_agents <- setdiff(proj$player_id, rostered)
fill_holes <- function(starters) {
  for (i in seq_along(slots)) {
    p <- starters[i]
    if (is.na(p) || p == "0" || player_spec(p)$mu == 0) {
      fa <- free_agents[vapply(free_agents, function(f) player_spec(f)$pos %in% eligible(slots[i]), logical(1))]
      if (length(fa)) starters[i] <- fa[which.max(vapply(fa, function(f) player_spec(f)$mu, numeric(1)))]
    }
  }
  starters
}
other_lineups <- lapply(Filter(function(m) m$roster_id != me$roster_id, matchups),
                        function(m) list(rid = m$roster_id, starters = fill_holes(best_lineup(unlist(m$players)))))
other_sims <- lapply(other_lineups, function(x) lineup_sim(x$starters))
names(other_sims) <- vapply(other_lineups, function(x) as.character(x$rid), character(1))
opp_lineup <- Filter(function(x) x$rid == opp_m$roster_id, other_lineups)[[1]]$starters
opp_sim <- other_sims[[as.character(opp_m$roster_id)]]
others_mat <- do.call(cbind, other_sims)

odds <- function(sim) {
  h2h <- mean(sim > opp_sim)
  med <- if (median_game) mean(rowSums(others_mat > sim) < (ncol(others_mat) + 1) / 2) else NA
  c(h2h = h2h, median = med)
}
print_lineup <- function(title, starters) {
  cat(sprintf("%s: projected %.1f\n", title, lineup_mu(starters)))
  for (i in seq_along(slots)) {
    p <- starters[i]
    if (is.na(p) || p == "0") { cat(sprintf("   %-10s (empty)\n", slots[i])); next }
    sp <- player_spec(p)
    cat(sprintf("   %-10s %-24s %5.1f (%s)\n", slots[i], sp$name, sp$mu, sp$src))
  }
}

current <- unlist(my_m$starters)
best <- best_lineup(unlist(my_m$players))
cat(sprintf("\nOpponent: %s (assumed to start their best projected lineup)\n", label(opp_m$roster_id)))
print_lineup(label(opp_m$roster_id), opp_lineup)
cat("\n"); print_lineup(sprintf("%s, lineup as currently set", label(me$roster_id)), current)
cat("\n"); print_lineup(sprintf("%s, best lineup from current roster", label(me$roster_id)), best)

apply_swaps <- function(starters, swaps) {
  for (sw in strsplit(swaps, ";", fixed = TRUE)[[1]]) {
    pair <- trimws(strsplit(sw, "=", fixed = TRUE)[[1]])
    out_id <- resolve_player(pair[1], ptab); in_id <- resolve_player(pair[2], ptab)
    if (is.na(out_id) || !out_id %in% starters) stop(sprintf("%s is not in the lineup being changed", pair[1]))
    if (is.na(in_id)) stop(sprintf("Could not find %s", pair[2]))
    starters[starters == out_id] <- in_id
  }
  starters
}

base <- odds(lineup_sim(current))
rows <- list(list("Lineup as currently set", lineup_mu(current), base))
b <- odds(lineup_sim(best)); rows[[2]] <- list("Best lineup from current roster", lineup_mu(best), b)
for (sc in SCENARIOS) {
  parts <- strsplit(sc, "::", fixed = TRUE)[[1]]
  lab <- if (length(parts) == 2) parts[1] else sc
  sw  <- parts[length(parts)]
  # Scenarios start from the best lineup, so each one is priced on top of the obvious fixes
  st <- apply_swaps(best, sw)
  rows[[length(rows) + 1]] <- list(lab, lineup_mu(st), odds(lineup_sim(st)))
}
cat(sprintf("\n== Win odds vs %s%s ==\n", label(opp_m$roster_id),
            if (median_game) " (and vs the league median)" else ""))
cat(sprintf("%-48s %7s %8s %8s %8s %8s\n", "Scenario", "Proj", "H2H", "dH2H", "Median", "dMedian"))
for (r in rows) {
  o <- r[[3]]
  cat(sprintf("%-48s %7.1f %7.1f%% %+7.1f%% %8s %8s\n", substr(r[[1]], 1, 48), r[[2]], 100 * o["h2h"],
              100 * (o["h2h"] - b["h2h"]),
              if (median_game) sprintf("%.1f%%", 100 * o["median"]) else "-",
              if (median_game) sprintf("%+.1f%%", 100 * (o["median"] - b["median"])) else "-"))
}
cat("(dH2H / dMedian are relative to your best lineup from the current roster)\n")
cat(sprintf("RESULT h2h=%.3f median=%s best_h2h=%.3f best_median=%s\n", base["h2h"],
            ifelse(is.na(base["median"]), "NA", sprintf("%.3f", base["median"])), b["h2h"],
            ifelse(is.na(b["median"]), "NA", sprintf("%.3f", b["median"]))))

cat("\nAll teams (best projected lineup):\n")
for (x in other_lineups) cat(sprintf("  %-30s %6.1f\n", label(x$rid), lineup_mu(x$starters)))
cat(sprintf("  %-30s %6.1f (your best lineup)\n", label(me$roster_id), lineup_mu(best)))
