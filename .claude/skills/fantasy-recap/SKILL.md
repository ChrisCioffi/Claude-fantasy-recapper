---
name: fantasy-recap
description: Fetch this week's Sleeper fantasy football matchup results and player scores, then write a punchy ~400-word news-style weekly recap with a headline summary and fun, stat-driven observations. Use when the user asks for a weekly recap, league update, matchup summary, or "what happened this week" for the Sleeper league.
---

# Fantasy League Weekly Recap

Turn raw Sleeper matchup data into a recap article the league's players would
actually enjoy reading.

## 1. Determine the week

If the user specified a week number, use it. Otherwise ask which week to
recap (don't guess the NFL week from the calendar — league weeks and NFL
weeks can drift).

## 2. Fetch the data

From the repo root, run:

```
Rscript sleeper_matchups.R <week>
```

This hits the Sleeper API for the configured league and prints three
sections to stdout:

- **MATCHUP RESULTS** — one row per team: opponent, points scored, W/L/T,
  margin.
- **PLAYER SCORES** — every rostered player's points for the week, flagged
  `starter = TRUE/FALSE`.
- **QUICK STATS** — highest/lowest scoring team, biggest blowout, top
  individual starter, and the "biggest bust" (lowest-scoring starter,
  excluding K/DEF).

Read the entire output before writing anything — the recap should only use
numbers that actually appear there. Player metadata is cached locally
(`players_cache.rds`, refreshed every 12h), so re-runs for the same session
are fast.

## 3. Write the recap

Target length: **350–450 words**. Structure:

1. **Headline + lede (1–2 sentences).** Open with the single biggest
   storyline of the week — the blowout, the nailbiter, the upset, whoever
   is now running the league. This is the hook, not a summary of every
   game.
2. **Matchup rundown.** Go through the week's matchups (group throwaway
   ones together if the league is large) with sharp, specific
   observations — not just "Team A beat Team B, 120–110." Call out close
   margins, lopsided wins, a team winning despite a weak bench, or a
   result that swings the standings narrative.
3. **By the numbers / fun facts.** Pull from QUICK STATS and the player
   score table: top individual scorer, the week's biggest bust, the
   closest game, the largest blowout, or any other detail worth a
   fantasy-nerd chuckle (e.g. a kicker outscoring a team's whole WR room).

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
