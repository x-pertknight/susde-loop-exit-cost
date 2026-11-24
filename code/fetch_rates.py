"""Fetch the two sides of the carry: sUSDe yield and stablecoin borrow rates.

Sources (public, no key):
  DefiLlama pool history for sUSDe      -> data/raw/susde_yield.json  (daily APY, %)
  Aave API, Ethereum core market        -> data/raw/aave_borrow.json  (daily borrow APY, %, last year)
Morpho borrow rates come from code/fetch_morpho.py.
Usage: python3 code/fetch_rates.py
"""
import json
import urllib.request
from pathlib import Path

RAW = Path(__file__).resolve().parent.parent / "data" / "raw"
LLAMA_SUSDE = "https://yields.llama.fi/chart/66985a81-9c51-46ca-9977-42b4fe7bc6df"
AAVE_API = "https://api.v3.aave.com/graphql"
AAVE_MARKET = "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2"
TOKENS = {"USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
          "USDT": "0xdac17f958d2ee523a2206206994597c13d831ec7"}


def get(url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={
        "Content-Type": "application/json", "User-Agent": "rate-study"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def aave_borrow(token):
    q = """{ borrowAPYHistory(request:{chainId:1, underlyingToken:"%s", market:"%s",
      window:LAST_YEAR}){ date avgRate { formatted } } }""" % (token, AAVE_MARKET)
    rows = get(AAVE_API, {"query": q})["data"]["borrowAPYHistory"]
    return sorted((r["date"][:10], float(r["avgRate"]["formatted"])) for r in rows)


def main():
    RAW.mkdir(parents=True, exist_ok=True)
    rows = get(LLAMA_SUSDE)["data"]
    yld = [(r["timestamp"][:10], r["apy"]) for r in rows if r["apy"] is not None]
    (RAW / "susde_yield.json").write_text(json.dumps(yld))
    aave = {name: aave_borrow(addr) for name, addr in TOKENS.items()}
    (RAW / "aave_borrow.json").write_text(json.dumps(aave))
    print("sUSDe yield days", len(yld), yld[0][0], yld[-1][0])
    for k, v in aave.items():
        print("Aave", k, "borrow days", len(v), v[0], v[-1])


if __name__ == "__main__":
    main()
