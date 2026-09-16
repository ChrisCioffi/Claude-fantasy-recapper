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

## 4. Publish it as a shareable Artifact

The recap isn't done until it's a link the user can drop in the league
group chat — don't just print it as a chat reply. Build a self-contained
HTML page and publish it with the Artifact tool.

1. Load the `artifact-design` skill before writing the page (required for
   every artifact).
2. Reuse `.claude/skills/fantasy-recap/recap-style.css` as the page's
   `<style>` block — read the file and inline its full contents. Don't
   redesign the palette/type/layout from scratch each run; the point is a
   consistent weekly look. Only deviate if the user explicitly asks for a
   different design.
3. Structure the page using that stylesheet's classes:
   - `.eyebrow` — league/week context line (e.g. "Sleeper League · Week 3"
     or "Sleeper League · Weeks 1-6").
   - `h1` — the headline, `.dek` — the 1-2 sentence lede.
   - `.scoreboard` — one `.matchup` card per game that week (for a
     multi-week/season recap, use the most recent week's games here, or
     omit if it doesn't make sense for the range).
   - `article` — the recap body as `<p>` tags, plus an `h2.section`
     ("By the Numbers") followed by a `.stats` grid of `.stat-tile`s built
     from QUICK STATS.
   - For multi-week/season recaps, add a `.standings` table built from the
     STANDINGS output.
   - `footer` — note the league ID and that it was generated by this
     skill.
4. Publish with the Artifact tool: `favicon: "🏈"`, `icon: "scoreboard"`,
   a title like "Week 3 League Recap" or "Weeks 1-6 League Recap" (name
   the artifact, don't append an explainer), and a one-sentence
   `description` summarizing the week's headline.
5. Share the resulting URL with the user as the deliverable.
