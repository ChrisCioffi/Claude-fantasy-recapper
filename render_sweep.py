#!/usr/bin/env python3
"""Render the daily sweep report (JSON) as the "Daily Lineup Desk" page.

Usage: python3 render_sweep.py report.json > page.html

report.json shape (every field except leagues[].name is optional):
{
  "date": "Tue Nov 24", "week": 12, "updated": "6:57 AM ET",
  "headline": "One sentence: the most important thing to do today.",
  "notes": ["ESPN superflex list still shows Week 10"],
  "leagues": [{
    "name": "Right at the Dunkin'", "team": "DKCountry-BelowAntarctica",
    "opponent": "Bunch of bums", "opp_proj": 157.9,
    "odds": {"h2h_now": 0.31, "h2h_plan": 0.42, "median_now": 0.38, "median_plan": 0.54},
    "next_waiver": "Wed 10:06 AM ET", "faab": 31,
    "actions": [{
      "kind": "claim" | "start" | "bench" | "drop" | "watch",
      "urgent": true,
      "title": "Claim Geno Smith (QB, NYJ)",
      "detail": "Drop Josh Downs · bid $3-5 · start at superflex",
      "why": "Daniels is your only QB, so a receiver is filling superflex.",
      "delta": "+7.8 H2H · +10.7 median",
      "sources": [{"label": "CBS weekly QB rankings", "url": "https://...", "quote": "optional exact quote"}]
    }],
    "flags": [{"tier": "MUST-START" | "BUST", "player": "Name", "where": "bench" | "waivers",
               "quote": "...", "label": "CBS · Eisenberg, Week 12 start/sit", "url": "https://..."}],
    "lineup": [{"slot": "QB", "player": "Jayden Daniels", "proj": 22.2, "note": "", "changed": false}]
  }],
  "sources": [{"label": "CBS weekly PPR rankings", "url": "https://...", "status": "Week 12, updated"}]
}
"""
import html
import json
import sys

KIND = {"claim": "Claim", "start": "Start", "bench": "Bench", "drop": "Drop", "watch": "Watch"}

CSS = """
:root {
  /* Layout: one phone-width column; per league a verdict strip, ranked action cards with their sources, flags, then the lineup. */
  --bg: #eef2e6; --surface: #ffffff; --surface-2: #e3ead9; --ink: #162118; --ink-soft: #4b5b4d;
  --line: #cdd8c4; --accent: #c97a0f; --accent-ink: #4a3005; --win: #2f7d4f; --loss: #a83f3f;
  --win-bg: #e3f0e6; --loss-bg: #f5e6e1;
  --display: "Big Shoulders Display", "Arial Narrow", sans-serif;
  --body: "Source Serif 4", Georgia, serif;
  --mono: "IBM Plex Mono", ui-monospace, Menlo, monospace;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #10160f; --surface: #182018; --surface-2: #1f2a1e; --ink: #eef1e6; --ink-soft: #b7c2ae;
    --line: #33402f; --accent: #f2b134; --accent-ink: #241a02; --win: #5fc78c; --loss: #e2837c;
    --win-bg: #1c2c21; --loss-bg: #2c2020; color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --bg: #10160f; --surface: #182018; --surface-2: #1f2a1e; --ink: #eef1e6; --ink-soft: #b7c2ae;
  --line: #33402f; --accent: #f2b134; --accent-ink: #241a02; --win: #5fc78c; --loss: #e2837c;
  --win-bg: #1c2c21; --loss-bg: #2c2020; color-scheme: dark;
}
* { box-sizing: border-box; }
body { background: var(--bg); color: var(--ink); font-family: var(--body); margin: 0;
  padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px));
  padding-block: 24px 40px; display: flex; justify-content: center; }
main { width: 100%; max-width: 720px; min-width: 0; display: grid; gap: 26px; }
a { color: inherit; }
a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.eyebrow { font-family: var(--mono); font-size: 0.72rem; letter-spacing: 0.14em; text-transform: uppercase; color: var(--accent); font-weight: 600; }
h1 { font-family: var(--display); font-weight: 800; font-size: clamp(2rem, 8vw, 2.8rem); line-height: 1; margin: 6px 0 10px; text-wrap: balance; }
.headline { font-size: 1.05rem; line-height: 1.5; margin: 0; }
.notes { margin: 10px 0 0; padding: 0; list-style: none; font-family: var(--mono); font-size: 0.72rem; color: var(--ink-soft); display: grid; gap: 4px; }
.league { display: grid; gap: 12px; }
.lhead { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: 14px 16px; display: grid; gap: 10px; }
.lhead h2 { font-family: var(--display); font-weight: 800; font-size: 1.7rem; line-height: 1; margin: 0; }
.facts { display: flex; flex-wrap: wrap; gap: 4px 14px; font-family: var(--mono); font-size: 0.72rem; color: var(--ink-soft); }
.facts b { color: var(--ink); font-weight: 600; }
.odds { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 8px; }
.odd { background: var(--surface-2); border-radius: 6px; padding: 10px 12px; }
.odd .k { font-family: var(--mono); font-size: 0.62rem; letter-spacing: 0.1em; text-transform: uppercase; color: var(--ink-soft); }
.odd .v { font-family: var(--display); font-weight: 800; font-size: 1.7rem; line-height: 1.1; font-variant-numeric: tabular-nums; }
.odd .v .to { color: var(--win); } .odd .v .ar { color: var(--ink-soft); font-size: 1.1rem; padding-inline: 3px; }
h3 { font-family: var(--mono); font-size: 0.72rem; font-weight: 700; letter-spacing: 0.12em; text-transform: uppercase; color: var(--ink-soft); margin: 6px 0 0; }
.cards { display: grid; gap: 8px; }
.card { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: 12px 14px; display: grid; gap: 6px; min-width: 0; }
.card.urgent { border-color: var(--accent); box-shadow: inset 3px 0 0 var(--accent); }
.row { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px 10px; }
.chip { font-family: var(--mono); font-size: 0.62rem; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; padding: 2px 7px; border-radius: 3px; background: var(--surface-2); color: var(--ink-soft); }
.chip.claim { background: var(--accent); color: var(--accent-ink); }
.chip.start { background: var(--win-bg); color: var(--win); }
.chip.bench, .chip.drop { background: var(--loss-bg); color: var(--loss); }
.chip.must { background: var(--win-bg); color: var(--win); } .chip.bust { background: var(--loss-bg); color: var(--loss); }
.title { font-weight: 600; font-size: 1.02rem; }
.delta { margin-left: auto; font-family: var(--mono); font-size: 0.78rem; font-weight: 700; color: var(--win); white-space: nowrap; font-variant-numeric: tabular-nums; }
.detail { font-family: var(--mono); font-size: 0.76rem; color: var(--ink-soft); }
.why { margin: 0; font-size: 0.92rem; line-height: 1.45; }
.src { display: grid; gap: 6px; margin: 2px 0 0; padding: 0; list-style: none; }
.src li { border-left: 3px solid var(--accent); background: var(--surface-2); border-radius: 0 4px 4px 0; padding: 6px 10px; font-size: 0.86rem; line-height: 1.4; }
.src q { font-style: italic; quotes: "\\201C" "\\201D"; display: block; margin-bottom: 3px; }
.src a { font-family: var(--mono); font-size: 0.72rem; color: var(--ink-soft); text-decoration: underline; text-underline-offset: 2px; }
.table-wrap { overflow-x: auto; border: 1px solid var(--line); border-radius: 8px; background: var(--surface); }
table { width: 100%; border-collapse: collapse; font-size: 0.88rem; }
td { padding: 8px 12px; border-bottom: 1px solid var(--line); vertical-align: top; }
tr:last-child td { border-bottom: 0; }
td.slot { font-family: var(--mono); font-size: 0.7rem; font-weight: 700; white-space: nowrap; color: var(--ink-soft); }
td.num { text-align: right; font-family: var(--mono); font-variant-numeric: tabular-nums; white-space: nowrap; }
tr.changed td { background: var(--win-bg); }
.note { color: var(--ink-soft); font-size: 0.8rem; }
.empty { font-size: 0.9rem; color: var(--ink-soft); margin: 0; }
footer { font-family: var(--mono); font-size: 0.7rem; color: var(--ink-soft); line-height: 1.6; border-top: 1px solid var(--line); padding-top: 12px; }
footer ul { margin: 6px 0 0; padding-left: 16px; }
"""


def e(x):
    return html.escape(str(x), quote=True)


def pct(x):
    return f"{round(100 * x)}%" if isinstance(x, (int, float)) else "–"


def source_list(srcs):
    if not srcs:
        return ""
    items = []
    for s in srcs:
        q = f"<q>{e(s['quote'])}</q>" if s.get("quote") else ""
        link = f'<a href="{e(s["url"])}" target="_blank" rel="noopener">{e(s.get("label") or s["url"])}</a>' if s.get("url") else e(s.get("label", ""))
        items.append(f"<li>{q}{link}</li>")
    return f'<ul class="src">{"".join(items)}</ul>'


def odds_tile(label, now, plan):
    if now is None and plan is None:
        return ""
    v = pct(now) if plan is None or plan == now else f'{pct(now)}<span class="ar">→</span><span class="to">{pct(plan)}</span>'
    return f'<div class="odd"><div class="k">{e(label)}</div><div class="v">{v}</div></div>'


def league(L):
    o = L.get("odds", {})
    facts = [f"vs <b>{e(L['opponent'])}</b>" + (f" ({L['opp_proj']} proj)" if L.get("opp_proj") else "") if L.get("opponent") else "",
             f"Next waivers <b>{e(L['next_waiver'])}</b>" if L.get("next_waiver") else "",
             f"FAAB <b>${e(L['faab'])}</b>" if L.get("faab") is not None else ""]
    tiles = odds_tile("Head-to-head", o.get("h2h_now"), o.get("h2h_plan")) + odds_tile("Median game", o.get("median_now"), o.get("median_plan"))
    cards = []
    for a in sorted(L.get("actions", []), key=lambda a: not a.get("urgent")):
        k = a.get("kind", "watch")
        cards.append(
            f'<div class="card{" urgent" if a.get("urgent") else ""}"><div class="row"><span class="chip {e(k)}">{e(KIND.get(k, k))}</span>'
            f'<span class="title">{e(a.get("title", ""))}</span>' + (f'<span class="delta">{e(a["delta"])}</span>' if a.get("delta") else "") + "</div>"
            + (f'<div class="detail">{e(a["detail"])}</div>' if a.get("detail") else "")
            + (f'<p class="why">{e(a["why"])}</p>' if a.get("why") else "") + source_list(a.get("sources")) + "</div>")
    flags = []
    for f in L.get("flags", []):
        cls = "must" if f.get("tier") == "MUST-START" else "bust"
        flags.append(f'<div class="card"><div class="row"><span class="chip {cls}">{e(f.get("tier", ""))}</span>'
                     f'<span class="title">{e(f.get("player", ""))}</span><span class="detail">on your {e(f.get("where", ""))}</span></div>'
                     + source_list([dict(quote=f.get("quote"), url=f.get("url"), label=f.get("label"))]) + "</div>")
    rows = "".join(f'<tr class="{"changed" if r.get("changed") else ""}"><td class="slot">{e(r.get("slot", ""))}</td>'
                   f'<td>{e(r.get("player", ""))}' + (f'<div class="note">{e(r["note"])}</div>' if r.get("note") else "") + "</td>"
                   f'<td class="num">{e(r.get("proj", ""))}</td></tr>' for r in L.get("lineup", []))
    return (f'<section class="league"><div class="lhead"><h2>{e(L["name"])}</h2>'
            f'<div class="facts">{"".join(f"<span>{x}</span>" for x in facts if x)}</div>'
            + (f'<div class="odds">{tiles}</div>' if tiles else "") + "</div>"
            + "<h3>Do this</h3>" + (f'<div class="cards">{"".join(cards)}</div>' if cards else '<p class="empty">No changes needed.</p>')
            + (f'<h3>Flags on your bench or the wire</h3><div class="cards">{"".join(flags)}</div>' if flags else "")
            + (f'<h3>Lineup to set</h3><div class="table-wrap"><table><tbody>{rows}</tbody></table></div>' if rows else "")
            + "</section>")


def main():
    R = json.load(open(sys.argv[1]))
    notes = "".join(f"<li>{e(n)}</li>" for n in R.get("notes", []))
    srcs = "".join(f'<li><a href="{e(s["url"])}" target="_blank" rel="noopener">{e(s["label"])}</a>' + (f" · {e(s['status'])}" if s.get("status") else "") + "</li>"
                   if s.get("url") else f"<li>{e(s['label'])}" + (f" · {e(s['status'])}" if s.get("status") else "") + "</li>" for s in R.get("sources", []))
    print(f"""<title>Daily Lineup Desk</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Big+Shoulders+Display:wght@800&family=IBM+Plex+Mono:wght@400;600;700&family=Source+Serif+4:ital,wght@0,400;0,600;1,400&display=swap">
<style>{CSS}</style>
<main>
  <header>
    <div class="eyebrow">Sleeper · Week {e(R.get('week', ''))} · {e(R.get('date', ''))}{(' · updated ' + e(R['updated'])) if R.get('updated') else ''}</div>
    <h1>Daily Lineup Desk</h1>
    <p class="headline">{e(R.get('headline', ''))}</p>
    {f'<ul class="notes">{notes}</ul>' if notes else ''}
  </header>
  {''.join(league(L) for L in R.get('leagues', []))}
  <footer>Rankings: CBS weekly PPR and ESPN superflex lists, blended with Sleeper's projections. Win odds come from 20,000 simulated games. Nothing is entered on Sleeper for you.
    {f'<ul>{srcs}</ul>' if srcs else ''}</footer>
</main>""")


if __name__ == "__main__":
    main()
