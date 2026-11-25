#!/usr/bin/env python3
"""Fetch this week's CBS and ESPN fantasy football rankings and articles.

Usage: python3 fetch_sources.py [--out DIR] [--hours N]

Writes to DIR (default ~/fantasy_sources; keep it out of the repo, the
articles are third-party content):
  cbs_rankings.json     CBS weekly PPR rankings: flex (RB/WR/TE) and QB pages
  espn_rankings.json    ESPN analysts' weekly PPR ranks (QB/RB/WR/TE): each analyst's
                        positional rank averaged, then re-ranked within the position
  espn_superflex.json   Karabell's weekly superflex list (ESPN), if found
  articles/*.txt        plain text of each CBS/ESPN fantasy football article
  manifest.json         one entry per article: source, title, url, published,
                        path, and is_new (published within the last N hours)

Network: www.cbssports.com, site.api.espn.com (article index),
content.core.api.espn.com (article text), lm-api-reads.fantasy.espn.com (weekly
ranks) and api.sleeper.app (current week). www.espn.com refuses automated
requests, so ESPN text comes from its content API. The Athletic is not fetched.
"""
import argparse
import datetime as dt
import hashlib
import html
import json
import os
import re
import subprocess
import sys

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
CBS = "https://www.cbssports.com"
# Article index pages on CBS that link to the week's rankings, start/sit,
# waiver, cheat-sheet and trade-chart columns
CBS_INDEXES = ["/fantasy/football/", "/fantasy/football/news/", "/fantasy/football/rankings/"]
# ESPN columns that reuse one article id all season (updated weekly)
ESPN_FIXED = {"49803708": "Karabell flex and superflex rankings"}
ESPN_NEWS = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/news?limit=100"
ESPN_CONTENT = "https://content.core.api.espn.com/v1/sports/news/{}"
ESPN_PLAYERS = ("https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/{season}/segments/0/"
                "leaguedefaults/3?scoringPeriodId={week}&view=kona_player_info")
ESPN_POS = {1: "QB", 2: "RB", 3: "WR", 4: "TE"}


def get(url, timeout=30):
    """Fetch through curl so the session's proxy and CA bundle apply."""
    r = subprocess.run(["curl", "-s", "-L", "-m", str(timeout), "--compressed", "-A", UA,
                        "-H", "Accept-Language: en-US,en;q=0.9", "-w", "\n%{http_code}", url],
                       capture_output=True)
    body, _, code = r.stdout.rpartition(b"\n")
    return int(code or 0), body.decode("utf-8", "ignore")


def html_to_text(s):
    s = re.sub(r"(?is)<(script|style|noscript|svg|figure|aside)\b.*?</\1>", " ", s)
    s = re.sub(r"(?i)<br\s*/?>|</p>|</li>|</h[1-6]>|</tr>", "\n", s)
    s = re.sub(r"<[^>]+>", " ", s)
    s = html.unescape(s)
    s = re.sub(r"[ \t\xa0]+", " ", s)
    return re.sub(r"\n\s*\n+", "\n\n", s).strip()


def slug_path(out, source, key):
    return os.path.join(out, "articles", f"{source}_{hashlib.md5(key.encode()).hexdigest()[:10]}.txt")


# ---- CBS ---------------------------------------------------------------------
def cbs_rankings(page):
    """Parse a CBS FantasyRankingsTable page into rows."""
    code, s = get(f"{CBS}/fantasy/football/rankings/{page}/")
    if code != 200:
        return None, code
    week = re.search(r"Week (\d+)", s)
    rows = []
    for tr in re.findall(r'<tr class="FightTable-row FantasyRankingsTable-row">(.*?)</tr>', s, re.S):
        rank = re.search(r"td--rank\">\s*(\d+)", tr)
        first = re.search(r"FantasyRankingsTable-firstName\">([^<]+)<", tr)
        last = re.search(r"FantasyRankingsTable-firstInitial\">[^<]*</span>([^<]+)</span>", tr)
        team = re.search(r"FantasyRankingsTable-teamPosition\">([^<]+)<", tr)
        pos = re.search(r"td--pos\">\s*([A-Z]+)(\d+)", tr)
        opp = re.search(r"FantasyRankingsTable-opponent[^\"]*\">([^<]+)<", tr)
        experts = re.findall(r"td--expert\">\s*([^<]+?)\s*<", tr)
        if not (rank and first and last):
            continue
        rows.append(dict(rank=int(rank.group(1)), name=html.unescape(f"{first.group(1).strip()} {last.group(1).strip()}"),
                         team=html.unescape(team.group(1).strip()) if team else None,
                         pos=pos.group(1) if pos else None, pos_rank=int(pos.group(2)) if pos else None,
                         opp=opp.group(1).strip() if opp else None,
                         experts=[None if e.strip("-") == "" else int(e) for e in experts if re.fullmatch(r"\d+|-+", e)]))
    if page.split("/")[1].upper() in ("QB", "RB", "WR", "TE", "K", "DST"):   # position pages: the rank is the positional rank
        p = page.split("/")[1].upper()
        for r in rows:
            r["pos"], r["pos_rank"] = r["pos"] or p, r["pos_rank"] or r["rank"]
    return dict(week=int(week.group(1)) if week else None, rows=rows), code


def cbs_articles(out, hours, now):
    links = set()
    for idx in CBS_INDEXES:
        code, s = get(CBS + idx)
        if code == 200:
            links |= set(re.findall(r'href="(?:https://www\.cbssports\.com)?(/fantasy/football/news/[a-z0-9\-]+/)"', s))
    items = []
    for path in sorted(links):
        code, s = get(CBS + path)
        if code != 200:
            continue
        title = re.search(r"<title>([^<]+)</title>", s)
        pub = re.search(r'"datePublished"\s*:\s*"([^"]+)"', s) or re.search(r'article:published_time"\s*content="([^"]+)"', s)
        mod = re.search(r'"dateModified"\s*:\s*"([^"]+)"', s)
        body = re.search(r'(?is)<div[^>]+class="[^"]*Article-bodyContent[^"]*"[^>]*>(.*)', s)
        text = html_to_text(body.group(1) if body else s)
        items.append(save(out, "cbs", CBS + path, html.unescape(title.group(1)).strip() if title else path,
                          pub.group(1) if pub else None, mod.group(1) if mod else None, text, hours, now))
    return items


# ---- ESPN --------------------------------------------------------------------
def espn_articles(out, hours, now):
    ids = dict(ESPN_FIXED)
    code, s = get(ESPN_NEWS)
    if code == 200:
        for a in json.loads(s).get("articles", []):
            web = (a.get("links", {}).get("web", {}) or {}).get("href", "")
            m = re.search(r"/fantasy/football/story/_/(?:page/[^/]+/)?id/(\d+)", web) or \
                (re.search(r"/story/_/id/(\d+)", web) if "fantasy" in (a.get("headline", "") + web).lower() else None)
            if m:
                ids.setdefault(m.group(1), a.get("headline"))
    items = []
    for aid in ids:
        code, s = get(ESPN_CONTENT.format(aid))
        if code != 200:
            continue
        a = (json.loads(s).get("headlines") or [{}])[0]
        text = html_to_text(a.get("story") or "")
        web = (a.get("links", {}).get("web", {}) or {}).get("href", ESPN_CONTENT.format(aid))
        items.append(save(out, "espn", web, a.get("headline") or ids[aid], a.get("published"),
                          a.get("lastModified"), text, hours, now))
    return items


def espn_weekly_ranks(season, week):
    """ESPN's weekly PPR rankings from its fantasy API: every analyst's positional rank for
    the week (rankSourceId 0 is a placeholder with rank 0, skipped), averaged per player,
    then re-ranked within the position. Same lists as ESPN's weekly rankings pages."""
    filt = json.dumps({"players": {
        "filterStatus": {"value": ["FREEAGENT", "WAIVERS", "ONTEAM"]},
        "filterSlotIds": {"value": [0, 2, 4, 6]},
        "filterRanksForScoringPeriodIds": {"value": [week]},
        "filterRanksForRankTypes": {"value": ["PPR"]},
        "sortDraftRanks": {"sortPriority": 100, "sortAsc": True, "value": "PPR"},
        "limit": 600}})
    r = subprocess.run(["curl", "-s", "-m", "90", "--compressed", "-A", UA, "-H", f"X-Fantasy-Filter: {filt}",
                        "-w", "\n%{http_code}", ESPN_PLAYERS.format(season=season, week=week)], capture_output=True)
    body, _, code = r.stdout.rpartition(b"\n")
    if code != b"200":
        return None, int(code or 0)
    data = json.loads(body)
    data = data.get("players", []) if isinstance(data, dict) else data
    by_pos = {}
    for p in data:
        pl = p.get("player", {})
        pos = ESPN_POS.get(pl.get("defaultPositionId"))
        ranks = [x["rank"] for x in (pl.get("rankings") or {}).get(str(week), [])
                 if x.get("rankType") == "PPR" and x.get("rank", 0) > 0]
        if pos and ranks:
            by_pos.setdefault(pos, []).append(dict(name=pl.get("fullName"), pos=pos, avg=round(sum(ranks) / len(ranks), 1),
                                                   analysts=len(ranks), best=min(ranks), worst=max(ranks)))
    rows = []
    for pos, lst in by_pos.items():
        for i, x in enumerate(sorted(lst, key=lambda x: x["avg"]), 1):
            rows.append(dict(x, pos_rank=i))
    return (dict(week=week, rows=rows) if rows else None), 200


def espn_superflex(out):
    """Parse Karabell's superflex list ("12. Name, QB5 vs OPP") from its article text."""
    p = slug_path(out, "espn", next((u for u in [m["url"] for m in MANIFEST if "49803708" in m["url"]]), "x"))
    if not os.path.exists(p):
        return None
    t = open(p).read()
    week = re.search(r"Week (\d+)", t)
    rows, seen = [], set()
    for m in re.finditer(r"(?m)^\s*(\d+)\. (.+?), (QB|RB|WR|TE)(\d+) (vs|@) ([A-Z]{2,3})", t):
        if m.group(2) in seen:   # the superflex list comes first; skip the flex-only repeat
            continue
        seen.add(m.group(2))
        rows.append(dict(rank=int(m.group(1)), name=m.group(2).strip(), pos=m.group(3),
                         pos_rank=int(m.group(4)), opp=f"{m.group(5)} {m.group(6)}"))
    return dict(week=int(week.group(1)) if week else None, rows=rows)


# ---- shared ------------------------------------------------------------------
def parse_time(s):
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def save(out, source, url, title, published, modified, text, hours, now):
    path = slug_path(out, source, url)
    with open(path, "w") as f:
        f.write(f"{title}\n{url}\npublished {published} modified {modified}\n\n{text}\n")
    stamp = parse_time(modified) or parse_time(published)
    return dict(source=source, title=title, url=url, published=published, modified=modified, path=path,
                chars=len(text), is_new=bool(stamp and (now - stamp).total_seconds() <= hours * 3600))


MANIFEST = []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.expanduser("~/fantasy_sources"))
    ap.add_argument("--hours", type=float, default=36, help="articles newer than this are flagged is_new")
    a = ap.parse_args()
    os.makedirs(os.path.join(a.out, "articles"), exist_ok=True)
    now = dt.datetime.now(dt.timezone.utc)

    ranks, status = {}, {}
    for key, page in (("flex", "ppr/flex/weekly"), ("QB", "ppr/QB/weekly")):
        r, code = cbs_rankings(page)
        status[f"cbs_rankings_{key}"] = code
        if r:
            ranks[key] = r
    json.dump(ranks, open(os.path.join(a.out, "cbs_rankings.json"), "w"), indent=0)

    MANIFEST.extend(cbs_articles(a.out, a.hours, now))
    MANIFEST.extend(espn_articles(a.out, a.hours, now))
    json.dump(MANIFEST, open(os.path.join(a.out, "manifest.json"), "w"), indent=1)

    try:
        _, st = get("https://api.sleeper.app/v1/state/nfl")
        st = json.loads(st)
        ew, code = espn_weekly_ranks(st["season"], int(st["week"]))
    except Exception as ex:   # never let one source stop the rest
        ew, code = None, str(ex)
    if ew:
        json.dump(ew, open(os.path.join(a.out, "espn_rankings.json"), "w"), indent=0)
    print("ESPN weekly ranks: " + (f"week {ew['week']} ({len(ew['rows'])} players)" if ew else f"not fetched ({code})"))

    sf = espn_superflex(a.out)
    if sf:
        json.dump(sf, open(os.path.join(a.out, "espn_superflex.json"), "w"), indent=0)

    print(f"CBS rankings: " + ", ".join(f"{k} week {v['week']} ({len(v['rows'])} rows)" for k, v in ranks.items())
          + (f" | fetch status {status}" if not ranks else ""))
    print(f"ESPN superflex: " + (f"week {sf['week']} ({len(sf['rows'])} players)" if sf else "not found"))
    for src in ("cbs", "espn"):
        items = [m for m in MANIFEST if m["source"] == src]
        print(f"{src.upper()} articles: {len(items)} fetched, {sum(m['is_new'] for m in items)} new in {a.hours:g}h")
        for m in sorted(items, key=lambda m: m["modified"] or m["published"] or "", reverse=True):
            if m["is_new"]:
                print(f"   NEW {m['modified'] or m['published']}  {m['title'][:90]}")
    print(f"Saved to {a.out}")
    return 0 if ranks or MANIFEST else 1


if __name__ == "__main__":
    sys.exit(main())
