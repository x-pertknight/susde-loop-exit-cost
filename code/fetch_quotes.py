"""Take one snapshot of sell quotes for sUSDe and USDe at several sizes.

Sources (public, no key): ParaSwap price API, CoW Protocol quote API, KyberSwap router API.
Also reads the sUSDe unstake rate from the token contract (convertToAssets) over a public RPC.
Each run writes one new file data/raw/quotes/quotes_<unix time>.json. Run it again to add a snapshot.
Quotes are indications. Nothing is traded.
Usage: python3 code/fetch_quotes.py
"""
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "data" / "raw" / "quotes"
RPC = "https://ethereum-rpc.publicnode.com"
SUSDE = "0x9D39A5DE30e57443BfF2A8307A4256c8797A3497"
USDE = "0x4c9EDD5852cd905f086C759E8383e09bff1E68B3"
USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7"
DECIMALS = {SUSDE: 18, USDE: 18, USDC: 6, USDT: 6}
PAIRS = [("sUSDe", SUSDE, "USDC", USDC), ("sUSDe", SUSDE, "USDT", USDT), ("USDe", USDE, "USDC", USDC)]
SIZES_USD = [1e5, 5e5, 1e6, 2e6, 2.5e6, 3e6, 3.5e6, 4e6, 5e6, 7.5e6, 10e6, 25e6, 50e6]
# CoW needs a sender address to build a quote. This one holds nothing and signs nothing.
PLACEHOLDER = "0x0000000000000000000000000000000000000001"


def http(url, body=None, headers=None):
    """Return parsed JSON, or {'error': text} so one failed source does not stop the run."""
    h = {"Content-Type": "application/json", "User-Agent": "quote-study"}
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h), timeout=40) as r:
            return json.load(r)
    except Exception as e:
        detail = e.read().decode(errors="replace")[:300] if hasattr(e, "read") else str(e)
        return {"error": detail}


def unstake_rate():
    """USDe received per sUSDe at the contract rate: convertToAssets(1e18)."""
    call = {"jsonrpc": "2.0", "id": 1, "method": "eth_call",
            "params": [{"to": SUSDE, "data": "0x07a2d13a" + hex(10**18)[2:].zfill(64)}, "latest"]}
    return int(http(RPC, call)["result"], 16) / 1e18


def paraswap(src, dst, amount):
    q = urllib.parse.urlencode({"srcToken": src, "destToken": dst, "amount": amount,
                                "srcDecimals": DECIMALS[src], "destDecimals": DECIMALS[dst],
                                "side": "SELL", "network": 1, "version": "6.2"})
    r = http(f"https://api.paraswap.io/prices?{q}")
    return int(r["priceRoute"]["destAmount"]) if "priceRoute" in r else None, r.get("error")


def cow(src, dst, amount):
    body = {"sellToken": src, "buyToken": dst, "from": PLACEHOLDER, "receiver": PLACEHOLDER,
            "sellAmountBeforeFee": str(amount), "kind": "sell", "priceQuality": "optimal",
            "signingScheme": "eip712", "onchainOrder": False, "partiallyFillable": False}
    r = http("https://api.cow.fi/mainnet/api/v1/quote", body)
    # buyAmount is already net of the network fee taken from the sell amount
    return int(r["quote"]["buyAmount"]) if "quote" in r else None, r.get("error") or r.get("description")


def kyber(src, dst, amount):
    q = urllib.parse.urlencode({"tokenIn": src, "tokenOut": dst, "amountIn": amount})
    r = http(f"https://aggregator-api.kyberswap.com/ethereum/api/v1/routes?{q}",
             headers={"x-client-id": "quote-study"})
    ok = r.get("data") and r["data"].get("routeSummary")
    return int(r["data"]["routeSummary"]["amountOut"]) if ok else None, r.get("error") or r.get("message")


SOURCES = {"paraswap": paraswap, "cow": cow, "kyber": kyber}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    now, rate = int(time.time()), unstake_rate()
    rows = []
    for sell_name, src, buy_name, dst in PAIRS:
        per_token_usd = rate if src == SUSDE else 1.0  # USDe counted at 1 USD
        for usd in SIZES_USD:
            amount = int(usd / per_token_usd * 10 ** DECIMALS[src])
            for name, fn in SOURCES.items():
                out, err = fn(src, dst, amount)
                rows.append({"sell": sell_name, "buy": buy_name, "size_usd": usd, "source": name,
                             "sell_amount": str(amount),
                             "buy_amount": None if out is None else out / 10 ** DECIMALS[dst],
                             "error": None if out is not None else (err or "no quote")[:200]})
                time.sleep(1.2)  # stay well under public rate limits
    snap = {"taken_at_unix": now, "unstake_rate_usde_per_susde": rate, "quotes": rows}
    (OUT / f"quotes_{now}.json").write_text(json.dumps(snap, indent=1))
    ok = sum(r["buy_amount"] is not None for r in rows)
    print("rate", rate, "| quotes ok", ok, "of", len(rows))


if __name__ == "__main__":
    main()
