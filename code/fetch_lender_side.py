"""Hourly supply, borrow, utilization and borrow rate of the sUSDe / PYUSD market on Morpho for three windows
around the largest falls in debt, and the hourly borrow rate for the whole life of the market.
Source: the public Morpho API. Writes data/raw/morpho_lender_side.json and data/raw/morpho_borrow_hourly.json.
Needs curl. Usage: python3 code/fetch_lender_side.py
"""
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

API = "https://blue-api.morpho.org/graphql"
OUT = Path(__file__).resolve().parent.parent / "data" / "raw" / "morpho_lender_side.json"
MAIN = "0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5"
WINDOWS = [("2026-03-09", "2026-03-19"), ("2026-04-16", "2026-04-27"), ("2026-05-09", "2026-05-20")]
FIELDS = ["supplyAssetsUsd", "borrowAssetsUsd", "utilization", "borrowApy"]
# the API returns at most 5,000 points per request, so the whole period is fetched in parts
WHOLE = ["2026-01-12", "2026-05-01", "2026-09-01", "2026-11-24"]


def unix(day):
    return int(datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp())


def fetch(field, start, end):
    """One field per request: the API rejects the four hourly series in one query."""
    opts = "(options:{interval:HOUR, startTimestamp:%d, endTimestamp:%d}) { x y }" % (start, end)
    q = '{ markets(first:1, where:{chainId_in:[1], uniqueKey_in:["%s"]}) { items { historicalState { %s } } } }' % (
        MAIN, field + opts)
    # the API refuses Python's HTTP client, so the request goes through curl
    raw = subprocess.run(["curl", "-s", "-m", "60", API, "-H", "Content-Type: application/json",
                          "-d", json.dumps({"query": q})], capture_output=True, text=True, check=True).stdout
    return json.loads(raw)["data"]["markets"]["items"][0]["historicalState"][field]


def main():
    out = {"market": MAIN, "interval": "hour", "windows": []}
    for a, b in WINDOWS:
        state = {f: fetch(f, unix(a), unix(b)) for f in FIELDS}
        out["windows"].append({"first_day": a, "last_day_excluded": b,
                               "series": {f: sorted(state[f], key=lambda p: p["x"]) for f in FIELDS}})
        print(a, b, {f: len(state[f]) for f in FIELDS})
    OUT.write_text(json.dumps(out, indent=1))
    rate = {}
    for a, b in zip(WHOLE, WHOLE[1:]):
        rate.update({p["x"]: p["y"] for p in fetch("borrowApy", unix(a), unix(b))})
    hourly = {"market": MAIN, "interval": "hour", "first_day": WHOLE[0], "last_day_excluded": WHOLE[-1],
              "borrowApy": [{"x": x, "y": rate[x]} for x in sorted(rate)]}
    (OUT.parent / "morpho_borrow_hourly.json").write_text(json.dumps(hourly))
    print("hourly borrow rate", len(rate))


if __name__ == "__main__":
    main()
