"""Rewrite the quote table in README.md from data/results.json, between the two quotes-table markers.
Run after python3 code/analyze.py. Usage: python3 code/readme_quotes.py
"""
import json
import re
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
START, END = "<!-- quotes-table:start -->", "<!-- quotes-table:end -->"


def cost(bp):
    """Basis points under 1%, percent above."""
    return f"{bp:.1f} bp" if abs(bp) < 100 else f"{bp / 100:.1f}%"


def size(usd):
    return f"{usd / 1e6:g}M" if usd >= 1e6 else f"{usd / 1e3:g}k"


def block(q):
    day = lambda t: datetime.fromtimestamp(t, timezone.utc)
    first, last = day(q["first_unix"]), day(q["last_unix"])
    # one day: the day and the two times; more days: each end with its own day and time
    days = f"on {first:%-d %B %Y}, {first:%H:%M} to {last:%H:%M} UTC" if first.date() == last.date() else (
        f"from {first:%-d %B %H:%M} to {last:%-d %B %Y %H:%M} UTC")
    lines = [f"Quoted cost of selling sUSDe for USDC in one transaction, best of ParaSwap, CoW Protocol and "
             f"KyberSwap, {q['snapshots']} snapshots {days} [`quotes.sUSDe_to_USDC`]:",
             "", "| Size, USD | Median cost | Lowest | Highest | Snapshots |", "|---|---|---|---|---|"]
    for usd, v in q["sUSDe_to_USDC"].items():
        lines.append(f"| {size(int(usd))} | {cost(v['median_bp'])} | {cost(v['min_bp'])} | {cost(v['max_bp'])} "
                     f"| {v['snapshots']} of {q['snapshots']} |")
    return "\n".join(lines)


def main():
    q = json.loads((ROOT / "data" / "results.json").read_text())["quotes"]
    readme = ROOT / "README.md"
    text = readme.read_text()
    new, n = re.subn(re.escape(START) + ".*?" + re.escape(END), lambda m: START + "\n" + block(q) + "\n" + END,
                     text, flags=re.S)
    if n != 1:
        raise SystemExit("README.md must hold exactly one pair of quotes-table markers")
    readme.write_text(new)
    print(block(q))


if __name__ == "__main__":
    main()
