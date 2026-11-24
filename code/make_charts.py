"""Charts for the article and the README, drawn from data/results.json and data/raw. No network.

Writes charts/*.svg and renders each to PNG with headless Chrome (set CHROME to another path if needed).
Usage: python3 code/make_charts.py   (after code/analyze.py)
"""
import json
from datetime import datetime, timezone
import math
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "charts"
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
INK, SOFT, GRID = "#1c1c1c", "#555555", "#e3e3e3"
BLUE, ORANGE, GREY = "#2a6fb0", "#d9822b", "#9aa3ad"
FONT = "Helvetica Neue, Helvetica, Arial, sans-serif"


def text(x, y, s, size=22, fill=INK, anchor="start", weight="normal"):
    return (f'<text x="{x:.0f}" y="{y:.0f}" font-size="{size}" fill="{fill}" '
            f'text-anchor="{anchor}" font-weight="{weight}">{s}</text>')


def line(pts, color, width=4, dash=""):
    d = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    return f'<polyline points="{d}" fill="none" stroke="{color}" stroke-width="{width}" stroke-dasharray="{dash}"/>'


def save(name, w, h, body):
    """Write the SVG and render it to a PNG of the same size."""
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
           f'font-family="{FONT}"><rect width="{w}" height="{h}" fill="white"/>{"".join(body)}</svg>')
    OUT.mkdir(exist_ok=True)
    (OUT / f"{name}.svg").write_text(svg)
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", f"--window-size={w},{h}",
                    f"--screenshot={OUT / (name + '.png')}", f"file://{OUT / (name + '.svg')}"],
                   check=True, capture_output=True)


def axes(box, xticks, yticks, xmap, ymap):
    """Grid lines and tick labels. xticks and yticks are lists of (value, label)."""
    x0, y0, x1, y1 = box
    out = []
    for v, lab in yticks:
        out += [f'<line x1="{x0}" x2="{x1}" y1="{ymap(v):.1f}" y2="{ymap(v):.1f}" stroke="{GRID}" stroke-width="2"/>',
                text(x0 - 12, ymap(v) + 7, lab, 20, SOFT, "end")]
    for v, lab in xticks:
        out.append(text(xmap(v), y1 + 32, lab, 20, SOFT, "middle"))
    return out


def quote_days(q):
    """The day or days of the quote snapshots, from their timestamps (UTC)."""
    first, last = (datetime.fromtimestamp(q[k], timezone.utc) for k in ("first_unix", "last_unix"))
    if first.date() == last.date():
        return first.strftime("%-d %B %Y")
    # two days in a row read "23 and 24"; a longer span reads "23 to 26"
    join = " and " if (last.date() - first.date()).days == 1 else " to "
    return first.strftime("%-d") + join + last.strftime("%-d %B %Y")


def cost_curve(res, box):
    """Quoted cost of a sale into USDC against size, log-log axes, up to 5 million USD.
    Above that only two services answered and the quote is a routing limit, so it is written, not drawn."""
    x0, y0, x1, y1 = box
    q = res["quotes"]["sUSDe_to_USDC"]
    xmap = lambda v: x0 + (math.log10(v) - 5) / 2 * (x1 - x0)                    # 100k to 10M
    ymap = lambda bp: y1 - math.log10(max(bp, 1)) / 3 * (y1 - y0)               # 1 bp to 1,000 bp
    out = axes(box, [(1e5, "100k"), (1e6, "1M"), (1e7, "10M")],
               [(1, "0.01%"), (10, "0.1%"), (100, "1%"), (1000, "10%")], xmap, ymap)
    sizes = sorted(int(k) for k in q if int(k) <= 5e6)
    for k in sizes:   # range over snapshots
        out.append(f'<line x1="{xmap(k):.1f}" x2="{xmap(k):.1f}" y1="{ymap(q[str(k)]["min_bp"]):.1f}" '
                   f'y2="{ymap(q[str(k)]["max_bp"]):.1f}" stroke="{GREY}" stroke-width="10" stroke-linecap="round"/>')
    out.append(line([(xmap(k), ymap(q[str(k)]["median_bp"])) for k in sizes], BLUE, 5))
    out += [f'<circle cx="{xmap(k):.1f}" cy="{ymap(q[str(k)]["median_bp"]):.1f}" r="7" fill="{BLUE}"/>' for k in sizes]
    above = res["quotes"]["sUSDe_to_USDC_7_5m_loss_above_pct"]
    out += [text(x1, y0 + 34, "From 5 million up only two routers answered.", 22, ORANGE, "end", "bold"),
            text(x1, y0 + 64, f"Their best quote at 7.5 million was a loss above {above}%.", 22, ORANGE, "end", "bold"),
            text(x1, y0 + 94, "A limit of one transaction, not a market price.", 22, ORANGE, "end")]
    return out, xmap, ymap


def chart_exit(res):
    w, h, box = 1400, 800, (130, 110, 1340, 690)
    body, _, _ = cost_curve(res, box)
    body += [text(40, 52, "Quoted cost of selling sUSDe for USDC in one transaction, by size", 30, weight="bold"),
             text(40, 86, "Best quote of up to three public routers, against unstake value. Median of the "
                  "snapshots that include the size, grey bar = range. Quotes, not trades.", 20, SOFT),
             text(735, 770, f"Size of the sale, USD (log scale). {quote_days(res['quotes'])}.", 20, SOFT, "middle")]
    save("chart1_exit_cost", w, h, body)


def chart_carry(res):
    w, h, (x0, y0, x1, y1) = 1400, 800, (110, 110, 1340, 690)
    wk, av = res["carry_morpho_hourly"]["weekly"], res["carry_aave_usdc"]["weekly"]
    top = 12.0
    xmap = lambda i: x0 + i / (len(wk) - 1) * (x1 - x0)
    ymap = lambda v: y1 - min(v, top) / top * (y1 - y0)
    step = max(1, len(wk) // 6)
    body = axes((x0, y0, x1, y1), [(i, wk[i]["week_end"][:7]) for i in range(0, len(wk), step)],
                [(v, f"{v}%") for v in (0, 3, 6, 9, 12)], xmap, ymap)
    body += [line([(xmap(i), ymap(r["borrow"])) for i, r in enumerate(av)], GREY, 3),
             line([(xmap(i), ymap(r["borrow"])) for i, r in enumerate(wk)], ORANGE, 4),
             line([(xmap(i), ymap(r["yield"])) for i, r in enumerate(wk)], BLUE, 5),
             text(40, 52, "sUSDe yield against the cost of borrowing, weekly", 30, weight="bold"),
             text(40, 86, "Blue: sUSDe yield. Orange: borrow rate, sUSDe / PYUSD market on Morpho (hourly readings). "
                  "Grey: USDC borrow rate on Aave (cut at 12%).", 20, SOFT)]
    save("chart2_carry", w, h, body)


def chart_discount():
    w, h, (x0, y0, x1, y1) = 1400, 800, (110, 110, 1340, 690)
    rows = json.loads((ROOT / "data" / "raw" / "dune" / "01_daily_discount.json").read_text())["rows"]
    top = 80.0
    xmap = lambda i: x0 + i / (len(rows) - 1) * (x1 - x0)
    ymap = lambda v: y1 - max(min(v, top), 0) / top * (y1 - y0)
    step = len(rows) // 6
    body = axes((x0, y0, x1, y1), [(i, rows[i]["day"][:7]) for i in range(0, len(rows), step)],
                [(v, f"{v / 100:.1f}%") for v in (0, 20, 40, 60, 80)], xmap, ymap)
    for key, color in (("usde_worst_bp", GREY), ("susde_worst_bp", BLUE)):
        body += [f'<circle cx="{xmap(i):.1f}" cy="{ymap(r[key]):.1f}" r="4" fill="{color}"/>'
                 for i, r in enumerate(rows) if r[key] is not None]
    body += [text(40, 52, "Worst hourly median discount on DEXs, per day", 30, weight="bold"),
             text(40, 86, "Blue: sUSDe below its unstake value. Grey: USDe below 1 USD. "
                  "Hours with under 50k USD traded are left out.", 20, SOFT)]
    save("chart3_discount", w, h, body)


def summary(res):
    """Summary image, 1080 x 1350."""
    w, h, box = 1080, 1350, (130, 600, 1030, 1180)
    q, ex, path, sold = res["quotes"], res["exits_whole_life"], res["exit_paths"], res["receivers_sales"]
    pct = lambda v: f"{v * 100:.0f}%"
    body, _, _ = cost_curve(res, box)
    body += [text(50, 120, f"{pct(path['share_unstake_started_within_3d_strict'])} or {pct(path['share_unstake_started_within_3d'])}", 110, weight="bold"),
             text(50, 190, "of the sUSDe withdrawn from the largest sUSDe lending", 34),
             text(50, 234, "market on Morpho (Ethereum) was matched by an Ethena", 34),
             text(50, 278, "unstake the receiving address started within three days.", 34),
             text(50, 340, f"Receivers sold {pct(sold['share_sold_dex_or_cow_within_3d_strict'])} or {pct(sold['share_sold_dex_or_cow_within_3d'])} on a DEX or through CoW in the same three days.", 27, ORANGE, weight="bold"),
             text(50, 378, f"Two counting rules. {ex['susde_withdrawn_m']:.0f} million sUSDe withdrawn since January 2026.", 28, SOFT),
             text(50, 416, "Matched by address, not by coin.", 28, SOFT),
             text(50, 480, "Quoted cost of selling sUSDe for USDC in one transaction", 26, weight="bold"),
             text(50, 516, f"Best quote of up to three public routers, {q['snapshots']} snapshots, {quote_days(q)}.", 22, SOFT),
             text(50, 548, "Against unstake value. Log scales. Dots are the median, bars the range.", 22, SOFT),
             text(580, 1250, "Size of the sale, USD", 22, SOFT, "middle"),
             text(50, 1310, "Quotes, not trades. Onchain data and the Morpho API.", 22, SOFT)]
    save("summary", w, h, body)


def main():
    res = json.loads((ROOT / "data" / "results.json").read_text())
    chart_exit(res)
    chart_carry(res)
    chart_discount()
    summary(res)
    print("wrote", sorted(p.name for p in OUT.glob("*.png")))


if __name__ == "__main__":
    main()
