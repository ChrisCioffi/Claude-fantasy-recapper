---
name: waiver-wire
description: Evaluate a Sleeper fantasy football league's rosters against player rankings from user-provided websites (FantasyPros, ESPN, Yahoo, a podcast's rankings page, etc.) and recommend the best waiver-wire / free-agent pickups, each paired with a drop and, in FAAB leagues, a bid. Use when the user asks who to pick up, who's on the waiver wire, who to add/drop, how much FAAB to bid, or which free agents are worth claiming for a Sleeper league — for their own team or for every team in the league. Also estimates weekly win odds, compares lineup choices, and keeps a graded record of every call ("how did your predictions do?").
---

# Waiver Wire Advisor

Cross-reference what's actually available in the league with rankings the
user trusts, then recommend specific add/drop moves that make rosters
better. Pair every recommendation with a reason grounded in the rankings
and the league data.

## 0. Grade last week first

If `predictions/log.csv` exists, run `Rscript grade_predictions.R` before
anything else. It fills in results for every logged call from completed
weeks. Lead with a two-line recap: how the win odds did and the net
points from the calls. Use its "By source" lines to weigh the sources this
week. If one source has been right more often on close calls, lean on it.

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

It also writes the full tables to `league_rosters_<league_id>.csv` and
`waiver_pool_<league_id>.csv`. Search the pool CSV when a ranked player
isn't in the printed top-N, and always read the files for the league
you're evaluating. The pool excludes everyone on a roster, so anyone in it
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
- **Waiver columns are ranked lists.** Within each position, a waiver
  column lists players in priority order: the first one named is the
  writer's top add, the last is the lowest (e.g. in a CBS column, the first
  TE listed outranks the last). Record each player's place in every
  column, not just that he was mentioned, and quote the order when you
  cite it ("his No. 3 TE add, behind Gesicki and Higbee"). Keep this
  column priority separate from the weekly rankings. Columns lean toward
  rest-of-season value and lightly rostered players; weekly rankings
  decide this week's starts. When they disagree, show both and price the
  column favorite with the win-odds script before recommending against
  it.
- **Start/sit and matchup articles.** Read the numbers on each player card
  before using them. On CBS's Start 'Em & Sit 'Em cards, `PROJ PTS` is
  SportsLine's projection, but `RNK` is the writer's own rank (it tracks
  his text, e.g. "a low-end starter" = TE10). Don't count `RNK` again on
  top of the CBS rankings. Average `PROJ PTS` in as its own projection,
  after removing its average offset from yours at each position. In
  ESPN's matchup tables, `Opp.` is the team that defense faces, so a
  player on team T reads the row whose `Opp.` is T or @T (1 = toughest,
  32 = easiest). The writer says matchups are already part of the
  rankings, so use them as a tiebreaker on close calls, not as a points
  adjustment. When an article says a player is "expected to be out," set
  his projection to 0, whatever Sleeper's tag says.
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
   Think twice before dropping a backup RB on the same NFL team as one of
   the team's starters, even when he ranks lowest. He's the one who
   benefits if the starter gets hurt or loses work.
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

## 6. Win odds and lineup comparisons

Use this when the user asks for odds, or to settle a close start/sit call.

1. Write this week's projections to a CSV **in your scratchpad, not the
   repo** (they're third-party data). Columns: `player_name,position,proj`,
   plus optional `player_id` (skips name matching) and `active` (1 = ignore
   an Out tag for a player the news says is returning). Use standard-PPR
   points; the script adjusts for half-PPR and TE premiums itself. With
   more than one source, average them. When sources give only ranks or
   ratings, convert them to points. Fit a points source's projections
   against its positional ranks (`points = a + b*ln(rank)` fits ESPN's
   tables to within about 1 point), then apply the fit to the consensus
   rank. Give every rostered starter a row (unranked ones get a floor just
   below the last ranked player), and leave bye-week players out.
2. Run:
   ```
   Rscript sleeper_winprob.R <league_id> <week> <team> <projections.csv> ["label::Out=In;Out=In|label::..."]
   ```
   It simulates 20,000 weeks. The swings come from last season's real
   weekly results at each position, scored with this league's settings
   and cached in `stats_cache_<season>.rds`. Points already scored count
   as banked; Out/IR/Doubtful players score 0 unless marked `active`.
   Every other team starts its best projected lineup and fills a bye or
   injury hole with the best free agent. Your team is priced three ways,
   all on the same random draws: as currently set, as its best lineup
   from the roster, and under each scenario. Each scenario starts from
   the best lineup, and the player swapped in can be a free agent, to
   price a pickup. The output table shows head-to-head and median-game
   odds for each scenario, with the change versus the best lineup.
3. Report odds as rough numbers ("about 55%"), not false precision. The
   model treats players as independent, which understates swings when
   teammates (QB + his WR) boom or bust together. Say so when it matters.

## 7. Log every call

After you give recommendations, record each one so it can be graded later:

```
Rscript log_prediction.R league=<id> week=<n> team=<team> kind=<kind> pick="Player" alt="Player" pred=<n> alt_pred=<n> sources="ESPN,CBS"
```

- `kind=h2h` / `kind=median`: `pred` is the win probability you reported.
- `kind=start`: started `pick` over `alt` (same lineup slot).
- `kind=add`: added `pick`; `alt` is the player dropped, or the free agent
  passed over. Log both when both matter.
- `kind=trade`: received `pick`; `alt` is the player he'd replace in the
  lineup.
- `sources`: only the sources that backed the call. Note in `note=` when a
  source disagreed (e.g. `note="Richard preferred Stevenson"`).
- Leave `followed` out. The grader fills it in from that week's actual
  lineup and roster.
- If new information changes a call later in the week, don't delete the
  old row. Start its `note` with `SUPERSEDED` and say why, then log the
  new call. The grader skips superseded rows.

The log lives at `predictions/log.csv` and is committed to the repo. That's
how the record survives between sessions, so commit and push it after
logging. `grade_predictions.R` scores `start`/`add`/`trade` calls by the
points the pick scored minus the alternative's. An `add` is graded on raw
points even if both players sat on the bench, so it measures pickup value,
not lineup impact.

## Constraints

- Every rank you cite must come from a source the user provided, and every
  stat must come from the script's output. Don't invent injuries, news,
  roles, or rankings.
- Only recommend players who are in the free agent pool. Check that they're
  not rostered before suggesting them.
- Use full player names and team names, never Sleeper IDs.
- If the sources' scoring format differs from the league's (e.g. standard
  rankings for a PPR league), say so and weigh pass-catchers accordingly.
