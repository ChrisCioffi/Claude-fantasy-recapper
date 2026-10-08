source("sleeper_common.R")

# ---- Config ---------------------------------------------------------------
# Usage: Rscript grade_predictions.R [week]
# Fills in results for every logged prediction from a completed week, saves
# predictions/log.csv, and prints a report for [week] (default: latest graded
# week) plus season-to-date totals.
LOG_FILE <- "predictions/log.csv"
args <- commandArgs(trailingOnly = TRUE)
REPORT_WEEK <- if (length(args) >= 1) as.integer(args[1]) else NA_integer_

if (!file.exists(LOG_FILE)) stop("No predictions logged yet (predictions/log.csv)")
log <- read.csv(LOG_FILE, stringsAsFactors = FALSE, colClasses = "character")
log[is.na(log)] <- ""
state <- sleeper_get("state/nfl")

# A week is final once Sleeper has moved on to the next one
is_final <- function(season, week) {
  as.integer(season) < as.integer(state$season) ||
    (season == state$season && as.integer(week) < as.integer(state$week))
}

cache <- new.env()
cached <- function(key, f) { if (is.null(cache[[key]])) cache[[key]] <- f(); cache[[key]] }

# A call replaced later in the week (note starts "SUPERSEDED") is kept for the record but not graded
superseded <- startsWith(log$note, "SUPERSEDED")
todo <- which(log$graded_at == "" & !superseded & mapply(is_final, log$season, log$week))
for (i in todo) {
  r <- log[i, ]
  scoring <- cached(paste0("sc", r$league_id),
                    function() unlist(sleeper_get(sprintf("league/%s", r$league_id))$scoring_settings))
  if (r$kind %in% c("h2h", "median")) {
    m <- cached(paste0("m", r$league_id, r$week),
                function() sleeper_get(sprintf("league/%s/matchups/%s", r$league_id, r$week)))
    pts <- setNames(vapply(m, function(x) as.numeric(x$points %||% 0), numeric(1)),
                    vapply(m, function(x) as.character(x$roster_id), character(1)))
    mine <- pts[[r$roster_id]]
    if (r$kind == "h2h") {
      my_mid <- Filter(function(x) as.character(x$roster_id) == r$roster_id, m)[[1]]$matchup_id
      opp <- Filter(function(x) identical(x$matchup_id, my_mid) && as.character(x$roster_id) != r$roster_id, m)[[1]]
      other <- as.numeric(opp$points)
    } else {
      other <- median(pts)
    }
    log$actual_pick[i] <- sprintf("%.2f", mine)
    log$actual_alt[i]  <- sprintf("%.2f", other)
    log$outcome[i] <- if (mine > other) "1" else if (mine < other) "0" else "0.5"
  } else {
    # Fill in whether the call was followed from that week's actual lineup/roster
    if (r$followed %in% c("", "unknown")) {
      m <- cached(paste0("m", r$league_id, r$week),
                  function() sleeper_get(sprintf("league/%s/matchups/%s", r$league_id, r$week)))
      mine <- Filter(function(x) as.character(x$roster_id) == r$roster_id, m)[[1]]
      held <- if (r$kind == "start") unlist(mine$starters) else unlist(mine$players)
      log$followed[i] <- if (r$pick_id %in% held) "yes" else "no"
    }
    st <- cached(paste0("st", r$season, r$week), function() week_stats(r$season, as.integer(r$week)))
    p_pick <- if (!is.null(st[[r$pick_id]])) score_line(st[[r$pick_id]], scoring) else 0
    p_alt  <- if (!is.null(st[[r$alt_id]]))  score_line(st[[r$alt_id]],  scoring) else 0
    log$actual_pick[i] <- sprintf("%.2f", p_pick)
    log$actual_alt[i]  <- sprintf("%.2f", p_alt)
    # outcome = points gained by the pick over the alternative
    log$outcome[i] <- sprintf("%.2f", p_pick - p_alt)
  }
  log$graded_at[i] <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
}
write.csv(log, LOG_FILE, row.names = FALSE)
cat(sprintf("Graded %d new prediction(s).\n", length(todo)))

g <- log[log$graded_at != "" & !superseded, ]
if (!nrow(g)) quit(status = 0)
g$week <- as.integer(g$week)
if (is.na(REPORT_WEEK)) REPORT_WEEK <- max(g$week)

summarise_block <- function(d, title) {
  cat(sprintf("\n========================================\n%s\n========================================\n", title))
  odds <- d[d$kind %in% c("h2h", "median"), ]
  if (nrow(odds)) {
    p <- as.numeric(odds$pred); o <- as.numeric(odds$outcome)
    cat(sprintf("Win odds: %d game(s) | won %.1f vs %.1f expected | Brier %.3f (0.250 = always saying 50%%)\n",
                nrow(odds), sum(o), sum(p), mean((p - o)^2)))
    for (j in seq_len(nrow(odds))) cat(sprintf("   wk%-2s %-6s league %s: said %3.0f%% -> %s (%s vs %s)\n",
      odds$week[j], odds$kind[j], odds$league_id[j], 100 * p[j], ifelse(o[j] == 1, "WON", ifelse(o[j] == 0, "lost", "tie")),
      odds$actual_pick[j], odds$actual_alt[j]))
    if (nrow(odds) >= 10) {
      b <- cut(p, c(0, .4, .5, .6, 1), include.lowest = TRUE)
      cat("   Calibration (predicted vs actual win rate by bucket):\n")
      print(aggregate(cbind(predicted = p, actual = o) ~ b, FUN = mean))
    }
  }
  dec <- d[d$kind %in% c("start", "add", "trade"), ]
  if (nrow(dec)) {
    delta <- as.numeric(dec$outcome)
    cat(sprintf("Decisions: %d | right %d, wrong %d, push %d | net %+.1f pts\n", nrow(dec),
                sum(delta > 0), sum(delta < 0), sum(delta == 0), sum(delta)))
    for (f in c("yes", "no")) {
      sel <- dec$followed == f
      if (any(sel)) cat(sprintf("   followed=%s: %d calls, net %+.1f pts\n", f, sum(sel), sum(delta[sel])))
    }
    for (j in order(-abs(delta))) cat(sprintf("   wk%-2s %-5s %-22s %6s over %-22s %6s  %+6.1f  [%s; followed=%s]\n",
      dec$week[j], dec$kind[j], dec$pick[j], dec$actual_pick[j], dec$alt[j], dec$actual_alt[j], delta[j],
      dec$sources[j], dec$followed[j]))
    srcs <- unique(trimws(unlist(strsplit(dec$sources, ","))))
    srcs <- srcs[nzchar(srcs)]
    if (length(srcs) > 1) {
      cat("   By source behind the call:\n")
      for (s in srcs) {
        sel <- grepl(s, dec$sources, fixed = TRUE)
        cat(sprintf("     %-10s %2d calls, right %2d, net %+.1f pts\n", s, sum(sel), sum(delta[sel] > 0), sum(delta[sel])))
      }
    }
  }
}
summarise_block(g[g$week == REPORT_WEEK, ], sprintf("WEEK %d", REPORT_WEEK))
if (length(unique(g$week)) > 1) summarise_block(g, "SEASON TO DATE")
