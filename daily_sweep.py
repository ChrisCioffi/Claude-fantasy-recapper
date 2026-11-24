#!/usr/bin/env python3
"""Daily sweep: rank every player in both leagues from CBS + ESPN, then flag
what to start, sit, add or drop.

Usage: python3 daily_sweep.py --sources DIR --week N LEAGUE_ID:TEAM [LEAGUE_ID:TEAM ...]

Run after:
  Rscript sleeper_waivers.R <league_id>     (writes league_rosters_<id>.csv and waiver_pool_<id>.csv)
  python3 fetch_sources.py --out DIR

Writes to DIR:
  proj_week<N>.csv   projections for sleeper_winprob.R. Each player's CBS
                     weekly and ESPN superflex positional ranks are averaged,
                     turned into points with the ln(rank) fit from the skill,
                     and averaged with Sleeper's own projection.
  sweep.json         everything below, for the session to read
and prints, per league: lineup holes, bench players ranked above starters,
free agents ranked above your weakest player at their position, and every
"must start" / "lineup lock" / "start" / "sleeper" / "sit" / "bust" / "drop"
mention of a benched or available player in this week's articles.
"""
import argparse
import csv
import json
import math
import os
import re
import subprocess

# points = a + b * ln(positional rank), fitted on ESPN weekly projections (see SKILL.md)
FIT = {"QB": (23.44, -2.72), "RB": (27.87, -5.15), "WR": (24.48, -3.81), "TE": (17.39, -3.11)}
SLOTS = {"QB": {"QB"}, "RB": {"RB"}, "WR": {"WR"}, "TE": {"TE"}, "K": {"K"}, "DEF": {"DEF"},
         "FLEX": {"RB", "WR", "TE"}, "SUPER_FLEX": {"QB", "RB", "WR", "TE"}, "REC_FLEX": {"WR", "TE"},
         "WRRB_FLEX": {"WR", "RB"}}
TIERS = [  # strongest first; the first tier found in a sentence wins
    ("MUST-START", r"must[- ]start|lineup lock|locked into lineups|start (?:him )?in all leagues|top-(?:3|5|10|12) (?:fantasy )?(?:qb|quarterback|rb|running back|wr|receiver|te|tight end)"),
    ("BUST", r"\bbust\b|bust alert|fade\b|avoid\b"),
    ("SIT", r"\bsit\b|sit 'em|bench (?:him|them)|tough to trust|hard to trust"),
    ("DROP", r"drop candidate|\bdrop\b|cut\b|safe to drop"),
    ("ADD", r"should be added|worth adding|must[- ]add|add (?:him|in all leagues)|pick(?:ed)? up|stash"),
    ("START", r"\bstart\b|flex (?:option|play)|sleeper|starter in"),
]


def norm(s):
    s = re.sub(r"\b(jr|sr|ii|iii|iv)\b\.?", "", s.lower())
    return re.sub(r"[^a-z0-9 ]", "", s).strip()


def sleeper_projections(week, season):
    url = (f"https://api.sleeper.app/projections/nfl/{season}/{week}?season_type=regular"
           "&position%5B%5D=QB&position%5B%5D=RB&position%5B%5D=WR&position%5B%5D=TE"
           "&position%5B%5D=K&position%5B%5D=DEF&order_by=pts_ppr")
    r = subprocess.run(["curl", "-s", "-m", "30", url], capture_output=True)
    try:
        data = json.loads(r.stdout)
    except ValueError:
        return {}
    out = {}
    for p in data:
        st = p.get("stats") or {}
        if p.get("player_id") and st.get("pts_ppr") is not None:
            out[p["player_id"]] = dict(proj=st["pts_ppr"], opp=p.get("opponent"), date=p.get("date"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", required=True)
    ap.add_argument("--week", type=int, required=True)
    ap.add_argument("--season", default="2026")
    ap.add_argument("--repo", default=".", help="folder holding league_rosters_<id>.csv / waiver_pool_<id>.csv")
    ap.add_argument("leagues", nargs="+", help="LEAGUE_ID:TEAM_LABEL")
    a = ap.parse_args()
    S = a.sources

    # ---- rankings ------------------------------------------------------------
    cbs = json.load(open(os.path.join(S, "cbs_rankings.json"))) if os.path.exists(os.path.join(S, "cbs_rankings.json")) else {}
    sf_path = os.path.join(S, "espn_superflex.json")
    espn = json.load(open(sf_path)) if os.path.exists(sf_path) else None
    notes = []
    cbs_rank = {}
    for key in ("flex", "QB"):
        part = cbs.get(key)
        if not part:
            notes.append(f"CBS {key} rankings missing")
            continue
        if part.get("week") != a.week:
            notes.append(f"CBS {key} rankings are week {part.get('week')}, not week {a.week}: ignored")
            continue
        for r in part["rows"]:
            cbs_rank[(norm(r["name"]), r["pos"])] = r
    espn_rank = {}
    if espn and espn.get("week") == a.week:
        for r in espn["rows"]:
            espn_rank[(norm(r["name"]), r["pos"])] = r
    else:
        notes.append(f"ESPN superflex rankings are week {espn.get('week') if espn else None}, not week {a.week}: ignored until Karabell updates them")
    slp = sleeper_projections(a.week, a.season)
    if not slp:
        notes.append("Sleeper projections unavailable")

    # ---- articles ------------------------------------------------------------
    manifest = json.load(open(os.path.join(S, "manifest.json"))) if os.path.exists(os.path.join(S, "manifest.json")) else []
    sentences = []
    for m in manifest:
        # Skip last week's columns (CBS index pages keep linking them); keep undated pieces
        weeks = {int(w) for w in re.findall(r"Week (\d+)", m["title"])}
        if weeks and a.week not in weeks:
            continue
        try:
            text = open(m["path"]).read()
        except OSError:
            continue
        for s in re.split(r"(?<=[.!?])\s+|\n+", text):
            if 25 < len(s) < 600:
                sentences.append((m, s.strip()))

    def mentions(name):
        # Full name, or "F. Last" as CBS tables write it; a bare last name matches too many players
        parts = name.split()
        short = f"{parts[0][0]}. {' '.join(parts[1:])}" if len(parts) > 1 else name
        pat = re.compile(r"\b(?:" + re.escape(name) + "|" + re.escape(short) + r")\b")
        hits = []
        for m, s in sentences:
            nm = pat.search(s)
            if nm:
                tier = None
                for t, rx in TIERS:
                    for tm in re.finditer(rx, s, re.I):
                        # the call has to be about this player: close to the name, and not negated
                        near = abs(tm.start() - nm.start()) <= 90 or s.lstrip().upper().startswith(t)
                        negated = re.search(r"(no longer|not|isn't|never|wouldn't)\s+(?:be\s+)?(?:a\s+|an\s+)?$", s[max(0, tm.start() - 25):tm.start()], re.I)
                        other = re.search(r"\b[A-Z][a-z]+ (?:is|as) (?:a |an )?$", s[max(0, tm.start() - 30):tm.start()]) and \
                            not re.search(re.escape(name.split()[-1]) + r" (?:is|as) (?:a |an )?$", s[max(0, tm.start() - 40):tm.start()])
                        if near and not negated and not other:
                            tier = t
                            break
                    if tier:
                        break
                if tier:
                    hits.append(dict(tier=tier, quote=s, source=m["source"], title=m["title"], url=m["url"], new=m["is_new"]))
        order = {t: i for i, (t, _) in enumerate(TIERS)}
        return sorted(hits, key=lambda h: (not h["new"], order[h["tier"]]))

    # ---- players -------------------------------------------------------------
    proj_rows, report = {}, {"week": a.week, "notes": notes, "leagues": []}

    def value(r):
        pos, pid = r["position"], r["player_id"]
        c = cbs_rank.get((norm(r["player_name"]), pos)); e = espn_rank.get((norm(r["player_name"]), pos))
        ranks = [x["pos_rank"] for x in (c, e) if x]
        pts = []
        if ranks and pos in FIT:
            fa, fb = FIT[pos]
            pts.append(fa + fb * math.log(sum(ranks) / len(ranks)))
        if pid in slp:
            pts.append(slp[pid]["proj"])
        proj = round(sum(pts) / len(pts), 1) if pts else 0.0
        proj_rows[pid] = dict(player_id=pid, player_name=r["player_name"], position=pos, proj=proj)
        return dict(name=r["player_name"], pos=pos, team=r.get("nfl_team"), injury=r.get("injury_status"),
                    slot=r.get("slot"), proj=proj, cbs=c["pos_rank"] if c else None, espn=e["pos_rank"] if e else None,
                    cbs_overall=c["rank"] if c else None, sleeper=round(slp[pid]["proj"], 1) if pid in slp else None,
                    date=slp.get(pid, {}).get("date"))

    for spec in a.leagues:
        lid, team = spec.split(":", 1)
        rosters = list(csv.DictReader(open(os.path.join(a.repo, f"league_rosters_{lid}.csv"))))
        pool = list(csv.DictReader(open(os.path.join(a.repo, f"waiver_pool_{lid}.csv"))))
        mine = [value(r) for r in rosters if r["team_label"] == team]
        for r in rosters:
            if r["team_label"] != team:
                value(r)
        fas = [value(r) for r in pool if r["position"] in ("QB", "RB", "WR", "TE", "K", "DEF")]
        out = dict(league=lid, team=team, holes=[], bench_over_starter=[], fa_upgrades=[], flags=[], roster=mine)
        starters = [p for p in mine if p["slot"] == "START"]
        bench = [p for p in mine if p["slot"] == "BENCH"]
        for p in starters:
            if p["injury"] in ("Out", "IR", "Doubtful", "Sus") or p["proj"] == 0:
                out["holes"].append(p)
        weakest = {}
        for p in mine:
            if p["slot"] in ("START", "BENCH") and p["injury"] not in ("Out", "IR"):
                if p["pos"] not in weakest or p["proj"] < weakest[p["pos"]]["proj"]:
                    weakest[p["pos"]] = p
        for b in bench:
            # Same position only; sleeper_winprob.R's best lineup handles FLEX/SUPER_FLEX shuffles
            worse = [s for s in starters if s["proj"] < b["proj"] and s["pos"] == b["pos"]]
            if worse and b["injury"] not in ("Out", "IR", "Doubtful"):
                out["bench_over_starter"].append(dict(bench=b, starter=min(worse, key=lambda s: s["proj"])))
        for f in sorted(fas, key=lambda f: -f["proj"]):
            w = weakest.get(f["pos"])
            if f["proj"] > 0 and f["injury"] not in ("Out", "IR") and (w is None or f["proj"] > w["proj"] + 1.0):
                out["fa_upgrades"].append(dict(fa=f, over=w))
        out["fa_upgrades"] = out["fa_upgrades"][:12]
        watch = bench + [f for f in fas if f["proj"] >= 5 or f["cbs"] or f["espn"]]
        for p in watch:
            hits = mentions(p["name"])
            strong = [h for h in hits if h["tier"] in ("MUST-START", "BUST")]
            if strong:
                out["flags"].append(dict(player=p, where="bench" if p in bench else "waivers", hits=strong[:3]))
        report["leagues"].append(out)

    with open(os.path.join(S, f"proj_week{a.week}.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["player_id", "player_name", "position", "proj"])
        w.writeheader()
        w.writerows(proj_rows.values())
    json.dump(report, open(os.path.join(S, "sweep.json"), "w"), indent=1)

    # ---- print -----------------------------------------------------------------
    def fmt(p):
        r = "/".join(x for x in (f"CBS {p['pos']}{p['cbs']}" if p["cbs"] else "", f"ESPN {p['pos']}{p['espn']}" if p["espn"] else "") if x)
        return f"{p['name']} ({p['pos']}, {p['proj']} proj{', ' + r if r else ''}{', ' + p['injury'] if p['injury'] not in (None, 'NA') else ''})"
    for n in notes:
        print("NOTE:", n)
    for L in report["leagues"]:
        print(f"\n===== {L['team']} ({L['league']})")
        for p in L["holes"]:
            print("  HOLE:", fmt(p), "is starting")
        for x in L["bench_over_starter"]:
            print("  BENCH>START:", fmt(x["bench"]), "over", fmt(x["starter"]))
        for x in L["fa_upgrades"]:
            print("  FA:", fmt(x["fa"]), "| your weakest", fmt(x["over"]) if x["over"] else "none rostered")
        for f in L["flags"]:
            for h in f["hits"]:
                print(f"  FLAG {h['tier']} ({f['where']}): {f['player']['name']} — \"{h['quote'][:220]}\" [{h['source'].upper()}: {h['title'][:60]}{', NEW' if h['new'] else ''}]")
    print(f"\nProjections: {os.path.join(S, f'proj_week{a.week}.csv')}")


if __name__ == "__main__":
    main()
