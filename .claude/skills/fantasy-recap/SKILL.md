---
name: fantasy-recap
description: Fetch Sleeper fantasy football matchup results and player scores for a chosen league and time range (single week, week range, or full season-to-date), then write a punchy news-style recap with a headline summary and fun, stat-driven observations. Use when the user asks for a weekly recap, league update, matchup summary, standings check, or "what happened this week/season" for a Sleeper league.
---

# Fantasy League Recap

Turn raw Sleeper matchup data into a recap article the league's players would
actually enjoy reading.

## 1. Determine the league and scope

Ask for anything not already given:

- **League ID.** If the user doesn't have it handy, tell them it's the
  numeric ID in their Sleeper league URL
  (`sleeper.com/leagues/<league_id>/...`). If they have no preference and
  just want "the" league, it's fine to fall back to the script's built-in
  default league.
- **Scope.** A single week, a range of weeks, or the full season so far.
  Don't guess the current NFL week from the calendar — league weeks and
  NFL weeks can drift, so confirm with the user instead.

## 2. Fetch the data

From the repo root, run:

```
Rscript sleeper_matchups.R <league_id> <week_start> [week_end]
```

- Single week: omit `week_end` (or pass the same value as `week_start`).
- Week range: pass both, e.g. `Rscript sleeper_matchups.R 123456789 3 6`.
- Full season-to-date: pass `season` (or `current`) as `week_end`, e.g.
  `Rscript sleeper_matchups.R 123456789 1 season` — this resolves to the
  last completed NFL week automatically. Weeks that haven't been played
  yet are skipped with a note, so this is safe to run any time in-season.

This prints, once per requested week: **MATCHUP RESULTS** (one row per
team — opponent, points, W/L/T, margin) and **PLAYER SCORES** (every
rostered player's points, flagged `starter = TRUE/FALSE`). After all
weeks, it prints:

- **QUICK STATS** across the whole requested range — highest/lowest
  single-week team performance, biggest blowout, top individual starter,
  and the "biggest bust" (lowest-scoring starter, excluding K/DEF).
- **STANDINGS** (only when more than one week was requested) — cumulative
  W-L-T, points for/against, and average points per team.

Read the entire output before writing anything — the recap should only use
numbers that actually appear there. Player metadata is cached locally
(`players_cache.rds`, refreshed every 12h), so re-runs for the same session
are fast.

## 3. Write the recap

Target length: **350–450 words** for a single week; a multi-week or
season-to-date recap can run a bit longer (up to ~600 words) to cover the
standings properly. Structure:

1. **Headline + lede (1–2 sentences).** Open with the single biggest
   storyline — for a single week, the blowout, nailbiter, or upset; for a
   range/season, who's running the league and who's cratering. This is
   the hook, not a summary of every game.
2. **Rundown.** For a single week, go through the matchups (group
   throwaway ones together if the league is large) with sharp, specific
   observations — not just "Team A beat Team B, 120–110." For a
   multi-week or season recap, lead with the standings narrative (who's
   hot, who's cold, who's overperforming their record) and call out the
   notable individual weeks along the way.
3. **By the numbers / fun facts.** Pull from QUICK STATS (and STANDINGS,
   when present): top individual scorer, the biggest bust, the closest
   game, the largest blowout, or any other detail worth a fantasy-nerd
   chuckle (e.g. a kicker outscoring a team's whole WR room).

## Voice and constraints

- Write like a pithy sports-column recap: witty, confident, a little
  cheeky. Every sentence should carry information or a joke — no generic
  filler ("It was an exciting week of football").
- Use team names (`team_label`) and full player names, never Sleeper IDs
  or roster numbers.
- Only reference numbers and outcomes that appear in the script's output —
  never invent a stat, injury, or storyline that isn't in the data.
- Output the recap as the reply itself (plain prose, no headers/bullets
  unless the user asks for a specific format) — don't write it to a file
  unless asked.
