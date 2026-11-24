"""Fetch Morpho data for sUSDe-type collateral on Ethereum: markets, positions, rate history.

Network: Morpho public API (no key). Output in data/raw/:
  morpho_markets.json    one row per market
  morpho_positions.json  one row per position, addresses replaced by sequential ids. Written OUTSIDE the
                         repo, in ../susde-loop-exit-cost-private/, because a row is one holder
  morpho_history.json    daily borrow rate and borrowed amount per market
Usage: python3 code/fetch_morpho.py
"""
import json
import time
import urllib.request
from pathlib import Path

RAW = Path(__file__).resolve().parent.parent / "data" / "raw"
API = "https://blue-api.morpho.org/graphql"
PRIVATE = RAW.parent.parent.parent / "susde-loop-exit-cost-private"
MIN_BORROW_USD = 100_000   # markets below this are ignored
HISTORY_DAYS = 420


def gql(query):
    body = json.dumps({"query": query}).encode()
    for attempt in range(5):
        try:
            req = urllib.request.Request(API, data=body, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                out = json.load(r)
            if "errors" in out:
                raise RuntimeError(out["errors"])
            return out["data"]
        except Exception as e:  # rate limit or network error: wait and retry
            print("retry", attempt, str(e)[:120])
            time.sleep(3 + 3 * attempt)
    raise RuntimeError("Morpho API failed")


def fetch_markets():
    q = """{ markets(first: 100, orderBy: BorrowAssetsUsd, orderDirection: Desc,
      where:{chainId_in:[1], search:"sUSDe"}) { items { marketId lltv creationTimestamp
      collateralAsset { symbol address decimals } loanAsset { symbol address decimals }
      oracle { address type }
      state { borrowApy borrowAssetsUsd supplyAssetsUsd liquidityAssetsUsd
              collateralAssetsUsd utilization price } } } }"""
    items = gql(q)["markets"]["items"]
    keep = [m for m in items if m["state"] and m["collateralAsset"]
            and "susde" in m["collateralAsset"]["symbol"].lower()
            and (m["state"]["borrowAssetsUsd"] or 0) >= MIN_BORROW_USD]
    return keep


def fetch_positions(market_id):
    """All positions of one market. The API pages by 1000."""
    out, skip = [], 0
    while True:
        q = """{ marketPositions(first: 1000, skip: %d, where:{chainId_in:[1],
          marketUniqueKey_in:["%s"]}) { items { user { address } healthFactor
          state { collateralUsd borrowAssetsUsd collateral borrowAssets } } } }""" % (skip, market_id)
        page = gql(q)["marketPositions"]["items"]
        out += page
        if len(page) < 1000:
            return out
        skip += 1000


def anonymise(positions_by_market):
    """Replace addresses by ids. The same address keeps one id across markets."""
    ids, rows = {}, []
    for market_id, positions in positions_by_market.items():
        for p in positions:
            addr = p["user"]["address"].lower()
            ids.setdefault(addr, len(ids) + 1)
            s = p["state"] or {}
            rows.append({"market": market_id, "holder_id": ids[addr],
                         "health_factor": p["healthFactor"],
                         "collateral_usd": s.get("collateralUsd"),
                         "borrow_usd": s.get("borrowAssetsUsd"),
                         "collateral_raw": s.get("collateral"),
                         "borrow_raw": s.get("borrowAssets")})
    return rows


def fetch_history(market_id, now):
    q = """{ markets(first: 1, where:{chainId_in:[1], uniqueKey_in:["%s"]}) { items {
      historicalState {
        borrowApy(options:{interval:DAY, startTimestamp:%d, endTimestamp:%d}) { x y }
        borrowAssetsUsd(options:{interval:DAY, startTimestamp:%d, endTimestamp:%d}) { x y }
        collateralAssetsUsd(options:{interval:DAY, startTimestamp:%d, endTimestamp:%d}) { x y }
      } } } }""" % ((market_id,) + (now - HISTORY_DAYS * 86400, now) * 3)
    return gql(q)["markets"]["items"][0]["historicalState"]


def main():
    RAW.mkdir(parents=True, exist_ok=True)
    now = int(time.time())
    markets = fetch_markets()
    (RAW / "morpho_markets.json").write_text(json.dumps(
        {"fetched_at_unix": now, "markets": markets}, indent=1))
    positions = {m["marketId"]: fetch_positions(m["marketId"]) for m in markets}
    PRIVATE.mkdir(exist_ok=True)
    (PRIVATE / "morpho_positions.json").write_text(json.dumps(
        {"fetched_at_unix": now, "positions": anonymise(positions)}, indent=1))
    history = {m["marketId"]: fetch_history(m["marketId"], now) for m in markets}
    (RAW / "morpho_history.json").write_text(json.dumps(
        {"fetched_at_unix": now, "history": history}))
    for m in markets:
        print(m["collateralAsset"]["symbol"], m["loanAsset"]["symbol"],
              round(m["state"]["borrowAssetsUsd"] / 1e6, 2), "M borrowed,",
              len(positions[m["marketId"]]), "positions,",
              len(history[m["marketId"]]["borrowApy"]), "days of history")


if __name__ == "__main__":
    main()
