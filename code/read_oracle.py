"""Read which price inputs the oracle of the sUSDe / PYUSD market uses. Public RPC, no key.

Output: data/raw/oracle_main.json
Usage: python3 code/read_oracle.py
"""
import json
import time
import urllib.request
from pathlib import Path

RPC = "https://ethereum-rpc.publicnode.com"
ORACLE = "0xE6212D05cB5aF3C821Fef1C1A233a678724F9E7E"
ZERO = "0x" + "0" * 40
# 4-byte selectors of the getters of Morpho's MorphoChainlinkOracleV2 and of a Chainlink feed
SLOTS = {"BASE_VAULT": "0xeaa2d7b4", "BASE_FEED_1": "0xf50a4718", "BASE_FEED_2": "0xdc53858c",
         "QUOTE_FEED_1": "0x56095e11", "QUOTE_FEED_2": "0xacfbd39e", "QUOTE_VAULT": "0x2e6f20a6"}
DESCRIPTION, LATEST, DECIMALS = "0x7284e416", "0x50d25bcd", "0x313ce567"


def call(to, data):
    body = {"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [{"to": to, "data": data}, "latest"]}
    req = urllib.request.Request(RPC, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r).get("result", "0x")


def feed(addr):
    raw = bytes.fromhex(call(addr, DESCRIPTION)[2:])
    name = raw[64:64 + int.from_bytes(raw[32:64], "big")].decode()
    return {"address": addr, "description": name,
            "answer": int(call(addr, LATEST), 16) / 10 ** int(call(addr, DECIMALS), 16)}


def main():
    out = {"oracle": ORACLE, "read_at_unix": int(time.time())}
    for slot, selector in SLOTS.items():
        addr = "0x" + call(ORACLE, selector)[-40:]
        out[slot] = None if addr == ZERO else (feed(addr) if "FEED" in slot else {"address": addr})
    path = Path(__file__).resolve().parent.parent / "data" / "raw" / "oracle_main.json"
    path.write_text(json.dumps(out, indent=1))
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
