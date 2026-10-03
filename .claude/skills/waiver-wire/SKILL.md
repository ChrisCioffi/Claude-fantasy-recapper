---
name: waiver-wire
description: Evaluate a Sleeper fantasy football league's rosters against player rankings from user-provided websites (FantasyPros, ESPN, Yahoo, a podcast's rankings page, etc.) and recommend the best waiver-wire / free-agent pickups, each paired with a drop and, in FAAB leagues, a bid. Use when the user asks who to pick up, who's on the waiver wire, who to add/drop, how much FAAB to bid, or which free agents are worth claiming for a Sleeper league — for their own team or for every team in the league.
---

# Waiver Wire Advisor

Cross-reference what's actually available in the league with rankings the
user trusts, then recommend specific add/drop moves that make rosters
better. Pair every recommendation with a reason grounded in the rankings
and the league data.

## 1. Gather inputs

Ask for anything not already given:

- **League ID.** It's the number in the Sleeper league URL
  (`sleeper.com/leagues/<league_id>/...`). If the user has no preference,
  fall back to the script's built-in default league.
- **Whose team.** The user's own team (team name, Sleeper username, or
  roster ID), or "all teams" for a league-wide waiver report.
- **Ranking sources.** One or more URLs whose rankings the user wants
  to use. Ask which **horizon** they care about if it's unclear:
  *rest-of-season* rankings for stash/long-term adds, or *this week's*
  rankings for streamers (QB/TE/K/DEF). Don't pick ranking sites yourself
  unless the user tells you to. These are the user's sources.

## 2. Pull the league data

From the repo root, run:

```
Rscript sleeper_waivers.R <league_id> [team]
```

Omit `team` to get every roster. The script prints:

- **LEAGUE SETTINGS**: scoring format (PPR/half/standard, TE premium),
  starting lineup slots, bench/IR size, which injury statuses can go on
  IR, and waiver type (FAAB budget, rolling, or reverse standings).
- **TEAMS**: record, points for, waiver position, FAAB remaining.
- **ROSTER**: one block per evaluated team. Every player has a slot
  (START/BENCH/IR/TAXI), injury status, and season-to-date production
  scored with *this league's* settings: `season_pts`, `ppg`,
  `recent_ppg` (average of the last 2 games played), and `last_wk`.
- **POSITIONAL DEPTH**: healthy rostered players per position for every
  team, plus the starting slots, to show who is thin where.
- **FREE AGENT POOL**: the top unrostered players at each startable
  position, with the same production columns plus `depth_order` (NFL depth
  chart), `trend_adds_48h` (Sleeper-wide adds in the last 48 hours), and
  Sleeper's `search_rank`.
- **TRENDING ADDS**: Sleeper's hottest adds, each flagged available,
  rostered (and by whom), or unsigned (no NFL team, so not worth a claim
  yet).

It also writes the full tables to `league_rosters.csv` and
`waiver_pool.csv`. Search `waiver_pool.csv` when a ranked player isn't in
the printed top-N. The pool excludes everyone on a roster, so anyone in it
is claimable. Player metadata is shared with the recap skill's 12-hour
cache (`players_cache.rds`).

## 3. Read the rankings

Fetch every URL the user gave you (WebFetch). For each, extract
`player name → position → rank` (positional rank if listed; otherwise
derive it from overall order within each position). Note the ranking's
scoring format and horizon (weekly vs ROS) if the page states it.

- **Match names carefully.** Normalize case, punctuation, and suffixes
  (`Jr.`, `II`, `III`), common nicknames (e.g. "Hollywood Brown" /
  "Marquise Brown"), and team defenses ("Chiefs D/ST", "KC DST", and
  "Kansas City Chiefs" are all the same DEF). Use position + NFL team to
  break ties between same-name players.
- **Multiple sources → consensus.** Average each player's positional rank
  across the sources that rank him. Note when sources disagree sharply.
  That's often a useful point for the write-up.
- **If a page won't load or has no readable rankings** (JS-rendered
  tables, paywalls, login walls), tell the user which source failed and
  ask them to paste the rankings or give another URL. **Never invent or
  "remember" rankings.** If no source works, stop and ask; don't fall
  back to Sleeper's `search_rank` as a substitute without saying so.

## 4. Find the best moves

For each evaluated team:

1. **Identify the weak spots.** Compare the team's rostered players
   against the consensus rankings, position by position, given the
   starting slots: e.g. a team that starts 2 RB + 2 FLEX needs at least
   4–5 startable RB/WR/TE. Flag starters who are injured (`Out`, `IR`,
   `Doubtful`), positions where the team is thinner than its lineup
   requires, and bench spots held by players the rankings don't rate.
2. **Pick drop candidates.** Choose the lowest-ranked bench players. Never
   suggest dropping an IR/taxi player to "make room" unless roster rules
   require it. Be careful dropping a stud who's merely hurt short-term.
   Before suggesting any drop, check whether an injured player could
   move to an open IR slot instead (see "IR-eligible statuses"). That's a
   free roster spot.
3. **Match pickups to holes.** A free agent is a recommended add when his
   consensus rank beats the drop candidate's at a position the team can
   actually start him. Prioritize by the size of that gap, then by need.
   Use production (`ppg`, `recent_ppg`), `depth_order`, and
   `trend_adds_48h` as supporting evidence, not as the main signal. The
   user's rankings are the main signal.
4. **Streamers.** For single-slot positions (QB, TE, K, DEF), only
   recommend a weekly streamer when it's a clear upgrade in this week's
   rankings over the current starter.
5. **Bids and priority.**
   - *FAAB:* suggest a bid in dollars. Scale it by the tier of the
     player (league-winner / every-week starter / bye-week fill-in /
     speculative stash), the team's remaining budget, and how many weeks
     are left. Note competition: other teams with real need at that
     position (from POSITIONAL DEPTH) and enough FAAB to outbid.
   - *Rolling / reverse-standings:* say whether the player is worth
     burning waiver priority for, given the team's `waiver_position`.

Rank the moves. Recommend 3–5 for a single team, or the top 1–3 for each
team in a league-wide report. Also list the top available players overall
by consensus, so the user can see who else is out there.

## 5. Report

For a **single team**, reply in chat:

- A one-line verdict (e.g. "Your RB2 is a hole; Player X is the fix").
- A ranked list of moves: **Add X (POS, TEAM) / Drop Y**, plus the FAAB
  bid or priority call, and 1–2 sentences of reasoning that cite the
  consensus rank vs the dropped player's rank and any supporting stat.
- "Best of the rest": the next handful of available players by consensus
  rank, with position.
- Sources used, any that failed, and the name matches you weren't sure
  about.

For an **all-teams** report, or whenever the user asks for something
shareable, also publish it as an Artifact so it can go in the league
chat. Load the `artifact-design` skill first. Reuse
`.claude/skills/fantasy-recap/recap-style.css` (inline its contents) so it
matches the weekly recaps: `.eyebrow` for "Sleeper League · Week N Waivers",
`h1`/`.dek` for the headline, one section per team, and a `.stats` grid
for the top available players. Use `icon: "clipboard"` and a title like
"Week 5 Waiver Wire".

## Constraints

- Every rank you cite must come from a source the user provided, and every
  stat must come from the script's output. Don't invent injuries, news,
  roles, or rankings.
- Only recommend players who are in the free agent pool. Check that they're
  not rostered before suggesting them.
- Use full player names and team names, never Sleeper IDs.
- If the sources' scoring format differs from the league's (e.g. standard
  rankings for a PPR league), say so and weigh pass-catchers accordingly.
