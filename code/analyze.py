"""Recompute the numbers of the study from the saved inputs in data/raw. No network.

Dune results in data/raw/dune are saved aggregates of the SQL in queries/. Everything else is raw.
Output: data/results.json and a printed summary.
Usage: python3 code/analyze.py
"""
import glob
import json
import statistics as st
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
# Position rows stay outside the repo: with this few positions a row is one holder.
PRIVATE = ROOT.parent / "susde-loop-exit-cost-private" / "morpho_positions.json"
MAIN = "0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5"  # sUSDe / PYUSD
MIN_DEBT = 10_000      # USD. Positions below this are dust
CHEAP_BP = 50          # a quote is called "cheap" up to this cost
MIN_MARKET_DEBT = 1e6  # carry weeks start when the market has at least this much debt


def load(name):
    return json.loads((RAW / name).read_text())


def wmean_ltv(pos, lltv):
    return sum(lltv / p["health_factor"] * p["borrow_usd"] for p in pos) / sum(p["borrow_usd"] for p in pos)


def population(positions, lltv):
    """Aggregates of positions with debt. LTV comes from the health factor:
    health factor = LLTV x collateral value at the oracle / debt, so LTV = LLTV / health factor.
    Values are rounded so that no figure reproduces one position."""
    pos = [p for p in positions if (p["borrow_usd"] or 0) >= MIN_DEBT and p["health_factor"]]
    debt = sum(p["borrow_usd"] for p in pos)
    coll = sum(p["collateral_usd"] for p in pos)
    ltv = wmean_ltv(pos, lltv)
    top = sorted((p["borrow_usd"] for p in pos), reverse=True)
    near = sum(p["borrow_usd"] for p in pos if lltv - lltv / p["health_factor"] < 0.02)
    return {
        "positions": len(pos), "debt_musd": round(debt / 1e6, 1), "collateral_musd": round(coll / 1e6, 1),
        "ltv_debt_weighted_mean": round(ltv, 3), "leverage_at_mean_ltv": round(1 / (1 - ltv), 1),
        "feed_fall_to_liquidation_at_mean_ltv": round(1 - ltv / lltv, 3),
        "debt_share_within_2_points": round(near / debt, 2),
        "top10_debt_share": round(sum(top[:10]) / debt, 2),
        "positions_collateral_over_5m": sum(p["collateral_usd"] > 5e6 for p in pos),
        "collateral_share_over_5m": round(sum(p["collateral_usd"] for p in pos if p["collateral_usd"] > 5e6) / coll, 2),
    }


def population_block(lltv):
    """Recompute the aggregate if the private position rows are present, else use the saved aggregate."""
    saved = ROOT / "data" / "population_aggregate.json"
    if PRIVATE.exists():
        positions = json.loads(PRIVATE.read_text())["positions"]
        agg = {"positions_all_markets_over_10k": sum((p["borrow_usd"] or 0) >= MIN_DEBT for p in positions),
               "positions_all_markets_any_debt": sum((p["borrow_usd"] or 0) > 0 for p in positions),
               "population_main": population([p for p in positions if p["market"] == MAIN], lltv)}
        saved.write_text(json.dumps(agg, indent=1))
    if not saved.exists():
        raise SystemExit("data/population_aggregate.json is missing. It is a committed input: restore it from the "
                         "repository, or run code/fetch_morpho.py to fetch the position rows again.")
    return json.loads(saved.read_text())


def best_per_size(snaps, sell, buys):
    """{size: [(cost in bp, number of sources that quoted)]}, one entry per snapshot."""
    per_size = {}
    for s in snaps:
        best, sources = {}, {}
        for q in s["quotes"]:
            if q["sell"] == sell and q["buy"] in buys and q["buy_amount"]:
                size = q["size_usd"]
                best[size] = max(best.get(size, 0), q["buy_amount"])
                sources.setdefault(size, set()).add(q["source"])
        for size, got in best.items():
            per_size.setdefault(size, []).append(((1 - got / size) * 1e4, len(sources[size])))
    return per_size


def quote_table():
    """Quoted cost in bp of selling sUSDe (and USDe) in one transaction, per size: the best source in each
    snapshot, then median, minimum and maximum over snapshots. Cost = 1 - stablecoins received / size,
    with size = tokens x unstake rate and USDe, USDC, USDT each counted as 1 USD."""
    snaps = [json.loads(Path(f).read_text()) for f in sorted(glob.glob(str(RAW / "quotes" / "*.json")))]
    out = {"snapshots": len(snaps), "first_unix": snaps[0]["taken_at_unix"], "last_unix": snaps[-1]["taken_at_unix"],
           "snapshot_times_unix": [x["taken_at_unix"] for x in snaps],
           "snapshot_times_utc": [datetime.fromtimestamp(x["taken_at_unix"], timezone.utc).strftime("%Y-%m-%d %H:%M")
                                  for x in snaps]}
    for name, sell, buys in (("sUSDe_to_USDC", "sUSDe", ("USDC",)), ("sUSDe_to_USDC_or_USDT", "sUSDe", ("USDC", "USDT")),
                             ("USDe_to_USDC", "USDe", ("USDC",))):
        out[name] = {str(int(size)): {"median_bp": round(st.median(c for c, _ in v), 1),
                                      "min_bp": round(min(c for c, _ in v), 1), "max_bp": round(max(c for c, _ in v), 1),
                                      "snapshots": len(v), "min_sources": min(n for _, n in v)}
                     for size, v in sorted(best_per_size(snaps, sell, buys).items())}
    for name in ("sUSDe_to_USDC", "sUSDe_to_USDC_or_USDT"):
        table = out[name]
        out[name + "_largest_size_under_50bp_in_all_snapshots"] = max(
            int(k) for k, v in table.items() if v["max_bp"] <= CHEAP_BP)
        out[name + "_smallest_size_over_50bp_in_all_snapshots"] = min(
            int(k) for k, v in table.items() if v["min_bp"] > CHEAP_BP)
    # "a loss above X%" at 7.5 million: the lowest best quote of any snapshot, rounded down to a whole percent
    out["sUSDe_to_USDC_7_5m_loss_above_pct"] = int(out["sUSDe_to_USDC"]["7500000"]["min_bp"] // 100)
    return out


def series(points, scale=1.0):
    """{date: value} from Morpho [{x: unix, y: value}], one value per UTC day (the last point of the day)."""
    out = {}
    for p in sorted(points, key=lambda p: p["x"]):
        if p["y"] is not None:
            out[datetime.fromtimestamp(p["x"], timezone.utc).strftime("%Y-%m-%d")] = p["y"] * scale
    return out


def carry(yield_days, borrow_days, debt_days, leverage):
    """sUSDe yield minus borrow rate, weekly means, from the first day the market has real debt.
    The net figure is the formula yield + (leverage - 1) x (yield - borrow). It is not a realised return."""
    days = sorted(d for d in set(yield_days) & set(borrow_days) & set(debt_days) if debt_days[d] >= MIN_MARKET_DEBT)
    used = days[len(days) % 7:]
    weeks = [(used[i + 6], [st.mean(c[d] for d in used[i:i + 7]) for c in (yield_days, borrow_days, debt_days)])
             for i in range(0, len(used), 7)]
    spread = [y - b for _, (y, b, _) in weeks]
    net = [y + (leverage - 1) * (y - b) for _, (y, b, _) in weeks]
    run = longest = 0
    for s in spread:
        run = run + 1 if s < 0 else 0
        longest = max(longest, run)
    return {"weeks": len(weeks), "first_week_end": weeks[0][0], "last_week_end": weeks[-1][0],
            "negative_weeks": sum(s < 0 for s in spread), "longest_negative_run": longest,
            "days": len(days), "negative_days": sum(yield_days[d] < borrow_days[d] for d in days),
            "mean_spread_points": round(st.mean(spread), 2), "min_spread_points": round(min(spread), 2),
            # the mean above is over every week; this one is over the weeks with yield above the borrow rate
            "mean_spread_points_weeks_above": round(st.mean(s for s in spread if s >= 0), 2),
            "max_spread_points": round(max(spread), 2),
            "borrow_daily_min": round(min(borrow_days[d] for d in days), 2),
            "borrow_daily_max": round(max(borrow_days[d] for d in days), 2),
            "leverage_used": leverage, "mean_net_yield_points": round(st.mean(net), 1),
            "last_week_net_yield_points": round(net[-1], 1), "weeks_net_yield_below_zero": sum(n < 0 for n in net),
            "weekly": [{"week_end": w, "yield": round(y, 3), "borrow": round(b, 3), "debt_usd": round(d)}
                       for w, (y, b, d) in weeks]}


def week_start_counts(yield_days, borrow_days, debt_days):
    """Weeks with yield below the borrow rate for each of the seven possible first days of a week.
    Shift 1 is the one used in carry(): weeks counted back from the last day of data."""
    days = sorted(d for d in set(yield_days) & set(borrow_days) & set(debt_days) if debt_days[d] >= MIN_MARKET_DEBT)
    out = []
    for shift in range(7):
        used = days[shift:]
        weeks = [used[i:i + 7] for i in range(0, len(used) - 6, 7)]
        below = sum(st.mean(yield_days[d] for d in w) < st.mean(borrow_days[d] for d in w) for w in weeks)
        out.append({"first_day": used[0], "weeks": len(weeks), "weeks_below": below})
    return out


def debt_path(debt_days):
    """Peak of the market's debt, the low that followed, and the largest one-day fall."""
    days = sorted(debt_days)
    peak = max(days, key=lambda d: debt_days[d])
    low = min((d for d in days if d > peak), key=lambda d: debt_days[d])
    worst = min((debt_days[days[i]] - debt_days[days[i - 1]], days[i]) for i in range(1, len(days)))
    return {"peak_musd": round(debt_days[peak] / 1e6, 1), "peak_day": peak,
            "low_after_peak_musd": round(debt_days[low] / 1e6, 1), "low_day": low,
            "largest_one_day_fall_musd": round(-worst[0] / 1e6, 1), "largest_one_day_fall_day": worst[1]}


def exits(rows, big, usd_per_susde):
    """How collateral left the main market over its whole life (Dune query 08, monthly rows).
    USD values use the unstake rate of the latest quote snapshot, so they are approximate."""
    tot = lambda k: sum(r[k] for r in rows)
    susde = tot("susde_m")   # big: sUSDe in transactions above 4 million, whole life
    share = lambda k: round(tot(k) / susde, 3)
    return {"first_month": rows[0]["month"], "last_month": rows[-1]["month"],
            "withdrawal_txs": tot("withdrawal_txs"), "susde_withdrawn_m": round(susde, 1),
            "withdrawn_musd_at_todays_rate": round(susde * usd_per_susde),
            "pyusd_repaid_same_tx_m": round(tot("pyusd_repaid_same_tx_m"), 1),
            "share_with_repay_same_tx": share("with_repay_m"),
            "share_with_dex_sale_same_tx": share("with_dex_sale_m"),
            "share_with_unstake_request_same_tx": share("with_unstake_request_m"),
            "share_with_supply_to_other_morpho_market_same_tx": share("with_supply_to_other_morpho_market_m"),
            "txs_over_4m_susde": tot("txs_over_4m_susde"), "susde_in_txs_over_4m_m": round(big, 1),
            "share_in_txs_over_4m": round(big / susde, 2), "over_4m_with_dex_sale_m": tot("over_4m_with_dex_sale_m"),
            "four_million_susde_in_musd": round(4 * usd_per_susde, 1), "liquidations": tot("liquidations")}


def stress(rows):
    """Summary of the daily DEX discount file (Dune query 01) and how many days it covers."""
    s = [r for r in rows if r["susde_worst_bp"] is not None]
    u = [r for r in rows if r["usde_worst_bp"] is not None]
    worst_s, worst_u = max(s, key=lambda r: r["susde_worst_bp"]), max(u, key=lambda r: r["usde_worst_bp"])
    apr_aug = [r["susde_worst_bp"] for r in s if "2026-04-01" <= r["day"][:10] <= "2026-08-31"]
    return {"days": len(rows), "first_day": rows[0]["day"][:10], "last_day": rows[-1]["day"][:10],
            "susde_days_with_data": len(s), "susde_days_with_data_before_2026_04": sum(r["day"] < "2026-04" for r in s),
            "susde_worst_hour_bp": worst_s["susde_worst_bp"], "susde_worst_day": worst_s["day"][:10],
            "susde_hours_over_50bp": sum(r["susde_hours_over_50bp"] for r in rows),
            "susde_worst_hour_bp_apr_to_aug_2026": max(apr_aug), "susde_days_with_data_apr_to_aug_2026": len(apr_aug),
            "usde_worst_hour_bp": worst_u["usde_worst_bp"], "usde_worst_day": worst_u["day"][:10],
            "usde_hours_over_50bp": sum(r["usde_hours_over_50bp"] for r in rows),
            "usde_days_with_tail_over_100bp": sum((r["usde_worst_tail_bp"] or 0) > 100 for r in rows)}


def unstake_days(ltv, lltv, gap=0.01):
    """Model, not a measurement. Days to close a position without selling sUSDe and without other money:
    each day withdraw the collateral that keeps LTV `gap` under the LLTV, unstake it (1 day), repay with it.
    Assumes one pending unstake per address, a 1-day cooldown and USDe turned into PYUSD at par."""
    cap, coll, debt, days = lltv - gap, 1.0, ltv, 0
    while debt > 1e-9 and days < 1000:
        free = coll - debt / cap
        if free <= 0:
            return None
        coll, debt, days = coll - free, max(debt - free, 0.0), days + 1
    return days


def market_block():
    markets = {m["marketId"]: m for m in load("morpho_markets.json")["markets"]}
    state, lltv = markets[MAIN]["state"], int(markets[MAIN]["lltv"]) / 1e18
    res = {"market_main": {k: state[k] for k in ("borrowAssetsUsd", "collateralAssetsUsd", "liquidityAssetsUsd",
                                                  "borrowApy", "utilization")}}
    res["market_main"]["lltv"] = lltv
    res["markets_total_debt_usd"] = sum(m["state"]["borrowAssetsUsd"] for m in markets.values())
    res.update(population_block(lltv))
    return res, lltv


def exit_paths(r, strict):
    """Share of the withdrawn sUSDe for which the receiving address started an Ethena cooldown afterwards
    (Dune query 10). Address-level match, not coin tracing: see the SQL."""
    w = r["withdrawn_m"]
    share = lambda k: round(r[k] / w, 2)
    return {"receivers": r["receivers"], "withdrawn_m": w,
            "share_unstake_started_within_1d": share("matched_cooldown_within_1d_m"),
            "share_unstake_started_within_3d": share("matched_cooldown_within_3d_m"),
            # query 11: same match, capped at what the address received on that withdrawal day
            "share_unstake_started_within_3d_strict": round(strict["matched_within_3d_capped_per_day_m"] / w, 2),
            "share_unstake_started_within_1d_strict": round(strict["matched_within_1d_capped_per_day_m"] / w, 2),
            "share_unstake_started_within_7d": share("matched_cooldown_within_7d_m"),
            "share_unstake_started_any_later": share("matched_cooldown_any_later_m"),
            "receivers_with_unstake_within_3d": r["receivers_with_cooldown_within_3d"],
            "share_of_ten_largest_receivers": r["share_of_ten_largest_receivers"]}


def fall_weeks(weekly, peak_day, low_day, yld, borrow, debt):
    """Weekly carry between the debt peak and the low after it, the weeks with yield below the borrow rate,
    and the daily readings in the same window. Weekly means hide daily spikes, so both are reported."""
    last = max(low_day, min(x["week_end"] for x in weekly if x["week_end"] >= low_day))
    wk = [w for w in weekly if peak_day < w["week_end"] <= last]
    days = sorted(d for d in set(yld) & set(borrow) if peak_day < d <= last)
    all_days = sorted(debt)

    def debt_change(week_end):
        """Change in debt over the 7 days of the week, in million USD."""
        i = all_days.index(week_end)
        return round((debt[week_end] - debt[all_days[i - 7]]) / 1e6, 1)

    neg = [{"week_end": w["week_end"], "yield": round(w["yield"], 2), "borrow": round(w["borrow"], 2),
            "debt_change_musd": debt_change(w["week_end"])} for w in wk if w["yield"] < w["borrow"]]
    top = max(days, key=lambda d: borrow[d])
    return {"weeks": len(wk), "negative_weeks": len(neg), "negative_week_list": neg,
            "mean_yield": round(sum(w["yield"] for w in wk) / len(wk), 2),
            "mean_borrow": round(sum(w["borrow"] for w in wk) / len(wk), 2),
            "days": len(days), "days_borrow_above_yield": sum(borrow[d] > yld[d] for d in days),
            "days_borrow_above_10pct": sum(borrow[d] > 10 for d in days),
            "borrow_daily_max": round(borrow[top], 1), "borrow_daily_max_day": top}


def debt_fall(g, weekly, e):
    """Who made the fall in debt between the peak and the low (Dune queries 12, 13, 14). Debt per address is
    rebuilt from Borrow, Repay and Liquidate events, so totals differ slightly from the market series."""
    gross = g["gross_fall_m"]
    worst = min(weekly, key=lambda w: w["net_change_three_largest_fallers_m"] or 0)
    return {"debt_peak_m": g["debt_peak_m"], "debt_low_m": g["debt_low_m"],
            "addresses_with_debt_at_peak": g["addresses_with_debt_at_peak"],
            "addresses_with_debt_at_low": g["addresses_with_debt_at_low"],
            "gross_fall_m": gross, "gross_rise_m": g["gross_rise_m"],
            "share_of_fall_three_largest": round(g["fall_top3_m"] / gross, 2),
            "share_of_fall_ten_largest": round(g["fall_top10_m"] / gross, 2),
            "fall_ten_largest_m": g["fall_top10_m"], "net_fall_m": g["net_fall_m"],
            "addresses_falling_over_1m": g["addresses_falling_over_1m"],
            "of_which_closed": g["addresses_over_1m_that_closed"],
            "ten_largest_under_5pct_left": g["top10_under_5pct_left"],
            "liquidated_m": g["liquidated_in_window_m"],
            "share_of_fall_liquidated": round(g["liquidated_in_window_m"] / gross, 3),
            "largest_week_three_largest": worst["week"],
            "largest_week_three_largest_change_m": worst["net_change_three_largest_fallers_m"],
            "of_ten_with_unstake_in_window": e["with_unstake_in_window"],
            "share_of_ten_fall_matched_by_usde_unstaked": round(e["fall_matched_by_usde_unstaked_m"] / e["fall_m"], 2),
            "of_ten_with_borrow_in_another_morpho_market": e["with_borrow_in_another_morpho_market"],
            "of_ten_with_borrow_on_aave_v3": e["with_borrow_on_aave_v3"],
            "of_ten_that_came_back": e["came_back_after_low"]}


def repayment_source(cls, kinds, mints):
    """Where the PYUSD of repayments above 1 million came from (Dune queries 15, 16, 17).
    Query 15: one class per repayment, same transaction first. Query 16: PYUSD received in the 24 hours
    before, each transfer counted once, split by how it reached the payer. Query 17: the mints."""
    total, n = cls[0]["total_m"], sum(r["txs"] for r in cls)
    in_tx = sum(r["txs"] for r in cls if r["source"][0] in "123")   # flash loan, swap or borrow in the same tx
    share = lambda key: round(sum(r["share_of_repayments_over_1m"] for r in kinds if r["kind"].startswith(key)), 3)
    m = mints[0]
    return {"repayments_over_1m": n, "repaid_over_1m_m": total,
            "share_of_all_repayments": round(total / cls[0]["all_repayments_m"], 2),
            "with_flash_loan_swap_or_borrow_same_tx": in_tx,
            "share_bought_on_dex_before": share("2 "), "share_bought_on_dex_paying_usds": share("2 bought on a DEX in an earlier transaction, paying USDS"),
            "share_minted_to_payer": share("1 "), "share_received_with_a_borrow": share("3 "),
            "share_from_labelled_exchange": share("4 "), "share_from_address_active_in_market": share("5 "),
            "share_from_unlabelled_contract": share("6 "), "share_from_unlabelled_wallet": share("7 "),
            "share_not_covered_by_inflows_24h": share("8 "),
            "share_covered_by_inflows_24h": round(1 - share("8 "), 3),
            "mints_to_payers": m["mints_to_payers"], "mint_payer_addresses": m["payer_addresses"],
            "mints_by_direct_call_to_the_token": m["mints_by_direct_call_to_the_token"],
            "recipients_of_the_same_mint_senders": m["recipients_of_these_senders_all_mints"]}


def repay_timing(r):
    """Repayments against unstake requests, for positions that did both (Dune query 19). Shares by PYUSD
    repaid. Times and addresses are matched, not coins: see the SQL."""
    keep = ("positions_with_repayment_and_unstake", "positions_with_repayment", "repayments", "repaid_m",
            "share_request_within_1h_after", "share_request_within_24h_after", "share_request_within_3d_after",
            "share_usde_ready_within_24h_before", "share_usde_ready_within_3d_before",
            "share_with_request_pending_at_repayment", "share_both_3d", "share_only_usde_ready_before_3d",
            "share_only_request_after_3d", "share_neither_3d", "median_hours_to_next_request_by_value",
            "median_hours_since_usde_ready_by_value")
    out = {k: r[k] for k in keep}
    out["share_request_in_same_tx"] = r["share_request_in_same_tx"] or 0
    out["share_of_all_repayments"] = round(r["repaid_m"] / r["all_repaid_m"], 2)
    out["share_of_all_repaid_usde_ready_before_and_request_after_3d"] = round(
        r["share_both_3d"] * r["repaid_m"] / r["all_repaid_m"], 2)
    # the same share on all repayments, counting positions with no unstake request as "no request"
    out["share_of_all_repaid_with_request_within_24h_after"] = round(
        r["share_request_within_24h_after"] * r["repaid_m"] / r["all_repaid_m"], 2)
    return out


def liquidation_distance(book, feed):
    """Distance of the book from liquidation on chosen dates (Dune query 22) and the largest fall of the
    feed ratio since December 2025 (query 21). The book and the feeds are measured. "Liquidatable after a
    fall" is a counterfactual on the measured book."""
    last = book[-1]
    return {"feed_ratio_lowest": feed["lowest_ratio"], "feed_ratio_lowest_day": feed["lowest_ratio_day"],
            "feed_ratio_largest_drawdown": feed["largest_drawdown"], "feed_ratio_updates": feed["updates"],
            "feed_days_ratio_below_099": feed["days_ratio_below_099"],
            "dates_with_debt_over_lltv": sum(r["debt_share_over_lltv"] > 0 for r in book),
            "latest_day": last["day"],
            "latest_price_fall_to_liquidation": last["price_fall_to_liquidation_debt_weighted"],
            "latest_debt_share_liquidatable_after_largest_drawdown": last["debt_share_liquidatable_after_fall_0_6pct"],
            "latest_debt_share_liquidatable_after_fall_2pct": last["debt_share_liquidatable_after_fall_2pct"],
            "latest_debt_share_liquidatable_after_fall_5pct": last["debt_share_liquidatable_after_fall_5pct"],
            "smallest_price_fall_to_liquidation": min(r["price_fall_to_liquidation_debt_weighted"] for r in book),
            "smallest_price_fall_day": min(book, key=lambda r: r["price_fall_to_liquidation_debt_weighted"])["day"],
            "by_date": book}


def largest_falls(debt_days, n=3, span=7):
    """The n largest falls of the market's debt over `span` days, not overlapping."""
    days = sorted(debt_days)
    falls = sorted(((debt_days[days[i - span]] - debt_days[days[i]], days[i - span], days[i])
                    for i in range(span, len(days))), reverse=True)
    picked = []
    for fall, a, b in falls:
        if len(picked) < n and all(b < pa or a > pb for _, pa, pb in picked):
            picked.append((fall, a, b))
    return [{"from": a, "to": b, "fall_musd": round(f / 1e6, 1)} for f, a, b in picked]


def squeeze(window, yld):
    """One window of hourly Morpho data: the first hour with utilization above 99%, what supply and the
    borrow rate did in the two hours up to it, and how long until debt fell by more than 1 million."""
    hour = lambda x: datetime.fromtimestamp(x, timezone.utc).strftime("%Y-%m-%d %H:00")
    s = {f: [(hour(p["x"]), p["y"]) for p in pts if p["y"] is not None] for f, pts in window["series"].items()}
    util, supply, rate, debt = (dict(s[f]) for f in ("utilization", "supplyAssetsUsd", "borrowApy", "borrowAssetsUsd"))
    hours = sorted(util)
    out = {"first_day": window["first_day"], "utilization_peak": round(max(util.values()), 3),
           "utilization_peak_pct": round(max(util.values()) * 100, 3),
           "hours_above_90pct": sum(u > 0.9 for u in util.values()),
           "borrow_rate_hourly_max": round(max(rate.values()) * 100, 1)}
    hit = next((i for i, h in enumerate(hours) if util[h] > 0.99 and i >= 2), None)
    if hit is None:
        return out
    at, before = hours[hit], hours[hit - 2]
    drop = next((i - hit for i in range(hit + 1, len(hours)) if debt[hours[i - 1]] - debt[hours[i]] > 1e6), None)
    out.update({"first_hour_above_99pct_utc": at,
                "supply_drop_in_2h_musd": round((supply[before] - supply[at]) / 1e6, 1),
                "debt_change_in_2h_musd": round((debt[at] - debt[before]) / 1e6, 1),
                # idle liquidity is supply minus debt: what lenders could still withdraw
                "idle_before_musd": round((supply[before] - debt[before]) / 1e6, 2),
                "idle_after_musd": round((supply[at] - debt[at]) / 1e6, 2),
                "utilization_at_that_hour_pct": round(util[at] * 100, 2),
                "borrow_rate_before": round(rate[before] * 100, 2), "borrow_rate_after": round(rate[at] * 100, 2),
                "susde_yield_that_day": round(yld[at[:10]], 2),
                "hours_to_first_debt_fall_over_1m": drop})
    return out


def window_detail(window):
    """More of one hourly window: hours with the borrow rate above 10% and the interest paid in them, every
    hourly move of supply above 10 million, and the hours of the largest falls of debt and of supply."""
    hour = lambda x: datetime.fromtimestamp(x, timezone.utc).strftime("%Y-%m-%d %H:00")
    get = lambda f: [(hour(p["x"]), p["y"]) for p in window["series"][f] if p["y"] is not None]
    supply, debt, rate = get("supplyAssetsUsd"), get("borrowAssetsUsd"), get("borrowApy")
    step = lambda pts: [(pts[i][0], (pts[i][1] - pts[i - 1][1]) / 1e6) for i in range(1, len(pts))]
    moves = [(h, round(m, 1)) for h, m in step(supply) if abs(m) > 10]
    high = [r for _, r in rate if r > 0.10]
    debt_low, supply_low = min(step(debt), key=lambda x: x[1]), min(step(supply), key=lambda x: x[1])
    return {"hours": len(rate), "hours_borrow_rate_above_10pct": len(high),
            # interest of one hour at an annual rate r is r / 8760 of the debt
            "interest_in_those_hours_bp_of_debt": round(sum(high) / 8760 * 1e4, 1),
            "supply_moves_over_10m": [{"hour_utc": h, "change_musd": m} for h, m in moves],
            "supply_withdrawn_in_those_moves_musd": round(-sum(m for _, m in moves if m < 0), 1),
            "largest_hourly_debt_fall": {"hour_utc": debt_low[0], "change_musd": round(debt_low[1], 1)},
            "largest_hourly_supply_fall": {"hour_utc": supply_low[0], "change_musd": round(supply_low[1], 1)}}


def aave_rate(days, first, last):
    """Lowest and highest daily USDC borrow rate on Aave v3 between two days, with their days."""
    span = {d: v for d, v in days.items() if first <= d <= last}
    lo, hi = min(span, key=span.get), max(span, key=span.get)
    return {"first_day": first, "last_day": last, "min": round(span[lo], 1), "min_day": lo,
            "max": round(span[hi], 1), "max_day": hi}


def lender_side(data, yld, debt_days):
    """Supply, utilization and borrow rate around the largest falls in debt (hourly, Morpho API).
    A fall "has a squeeze" when utilization passed 99% between the day before it starts and its end."""
    wins = [{**squeeze(w, yld), **window_detail(w)} for w in data["windows"]]
    hit = [w["first_hour_above_99pct_utc"][:10] for w in wins if "first_hour_above_99pct_utc" in w]
    falls = largest_falls(debt_days)
    day_before = lambda d: (datetime.strptime(d, "%Y-%m-%d") - timedelta(days=1)).strftime("%Y-%m-%d")
    for f in falls:
        f["utilization_passed_99pct"] = any(day_before(f["from"]) <= h <= f["to"] for h in hit)
    sq = [w for w in wins if "supply_drop_in_2h_musd" in w]
    return {"largest_falls_7d": falls, "falls_with_squeeze": sum(f["utilization_passed_99pct"] for f in falls),
            "supply_drop_min_musd": min(w["supply_drop_in_2h_musd"] for w in sq),
            "supply_drop_max_musd": max(w["supply_drop_in_2h_musd"] for w in sq),
            "borrow_rate_before_max": max(w["borrow_rate_before"] for w in sq),
            "borrow_rate_after_min": min(w["borrow_rate_after"] for w in sq),
            "yield_min": min(w["susde_yield_that_day"] for w in sq), "yield_max": max(w["susde_yield_that_day"] for w in sq),
            "utilization_peak": max(w["utilization_peak"] for w in sq), "windows": wins}


def receivers_sales(r, paths):
    """sUSDe sold by the receiving address within 3 days of a withdrawal, on a DEX or on CoW Protocol (Dune
    query 25), by the same two counting rules as the unstake match, next to the unstake shares."""
    w = r["withdrawn_m"]
    share = lambda k: round(r[k] / w, 3)
    return {"share_sold_dex_within_3d": share("sold_dex_within_3d_m"),
            "share_sold_dex_within_3d_strict": share("sold_dex_within_3d_capped_per_day_m"),
            "share_sold_dex_or_cow_within_3d": share("sold_dex_or_cow_within_3d_m"),
            "share_sold_dex_or_cow_within_3d_strict": share("sold_dex_or_cow_within_3d_capped_per_day_m"),
            "share_sold_dex_or_cow_within_7d": share("sold_dex_or_cow_within_7d_m"),
            "share_sold_dex_or_cow_any_later": share("sold_dex_or_cow_any_later_m"),
            "receivers_selling_within_3d": r["receivers_selling_within_3d"],
            "receivers_selling_on_cow_within_3d": r["receivers_selling_on_cow_within_3d"],
            "share_unstake_started_within_3d": paths["share_unstake_started_within_3d"],
            "share_unstake_started_within_3d_strict": paths["share_unstake_started_within_3d_strict"]}


def hourly_days(points):
    """Mean of the hourly borrow rate per UTC day, in percent."""
    days = {}
    for p in points:
        days.setdefault(datetime.fromtimestamp(p["x"], timezone.utc).strftime("%Y-%m-%d"), []).append(p["y"] * 100)
    return {d: st.mean(v) for d, v in days.items() if len(v) >= 24}


def supply_withdrawers(d):
    """Who withdrew supply in the two hours when utilization first passed 99% (Dune query 26)."""
    return {"windows": d["rows"], "distinct_vaults_both_windows": d["distinct_vaults_both_windows"],
            "distinct_curators_both_windows": d["distinct_curators_both_windows"]}


def receivers_check(r):
    """Receivers of the withdrawn sUSDe: contracts, sUSDe sent on, and USDe sold after the claim (Dune
    query 24). All matches are by address and capped, and the caps overlap: see the SQL."""
    w = r["withdrawn_m"]
    return {"receivers": r["receivers"], "receivers_that_are_contracts": r["receivers_that_are_contracts"],
            "share_withdrawn_to_contracts": round(r["withdrawn_to_contracts_m"] / w, 2),
            "contracts_unstake_within_3d_m": r["contracts_unstake_within_3d_m"],
            "share_of_contract_receipts_sent_on_within_3d": round(r["contracts_forwarded_within_3d_m"] / r["withdrawn_to_contracts_m"], 2),
            "share_sent_on_within_3d_upper_bound": round(r["forwarded_within_3d_m"] / w, 2),
            "usde_claimed_m": r["usde_claimed_m"], "receivers_with_claim": r["receivers_with_claim"],
            "share_of_claimed_usde_sold_on_dex_within_3d": round(r["usde_sold_on_dex_within_3d_of_claim_m"] / r["usde_claimed_m"], 2),
            "receivers_selling_usde_within_3d": r["receivers_selling_usde_within_3d"]}


def carry_blocks(res, lev):
    """Carry and debt path from the daily series, and the same weeks on hourly borrow rates."""
    hist = load("morpho_history.json")["history"][MAIN]
    yld, debt_days, borrow_days = dict(load("susde_yield.json")), series(hist["borrowAssetsUsd"]), series(hist["borrowApy"], 100)
    res["carry_morpho"] = carry(yld, borrow_days, debt_days, lev)
    res["carry_aave_usdc"] = carry(yld, dict(load("aave_borrow.json")["USDC"]), debt_days, lev)
    res["debt_path"] = debt_path(debt_days)
    peak, low = res["debt_path"]["peak_day"], res["debt_path"]["low_day"]
    # the same weeks with the borrow rate as the mean of 24 hourly readings instead of one reading at 00:00 UTC
    hourly = hourly_days(load("morpho_borrow_hourly.json")["borrowApy"])
    res["carry_morpho_hourly"] = carry(yld, hourly, {d: v for d, v in debt_days.items() if d in hourly}, lev)
    res["carry_morpho_hourly_by_week_start"] = week_start_counts(yld, hourly, debt_days)
    res["carry_during_debt_fall"] = fall_weeks(res["carry_morpho"]["weekly"], peak, low, yld, borrow_days, debt_days)
    res["carry_during_debt_fall_hourly"] = fall_weeks(res["carry_morpho_hourly"]["weekly"], peak, low, yld, hourly, debt_days)
    return yld, debt_days


def exit_blocks(res):
    """Withdrawals: what left with a sale in the same transaction, and what the receivers did after."""
    rows = lambda name: load("dune/" + name)["rows"]
    last = json.loads(Path(sorted(glob.glob(str(RAW / "quotes" / "*.json")))[-1]).read_text())
    by_month = load("dune/08_exits_by_month.json")
    res["exits_whole_life"] = exits(by_month["rows"], by_month["susde_in_txs_over_4m_m_whole_life"], last["unstake_rate_usde_per_susde"])
    r90 = rows("07_withdrawals_with_dex_sale.json")[0]
    res["exits_90d"] = {"withdrawal_txs": r90["withdrawal_txs"],
                        "share_with_repay_same_tx": round(r90["with_repay"] / r90["collateral"], 3),
                        "share_with_dex_sale_same_tx": round(r90["with_dex_sale"] / r90["collateral"], 3)}
    res["exit_paths"] = exit_paths(rows("10_exit_paths.json")[0], rows("11_exit_paths_strict.json")[0])
    res["receivers_check"] = receivers_check(rows("24_receivers_and_usde_sold.json")[0])
    res["receivers_sales"] = receivers_sales(rows("25_receivers_susde_sold.json")[0], res["exit_paths"])


def unwind_blocks(res, yld, debt_days):
    """The fall in debt: who made it, where the repaid PYUSD came from, the lender side."""
    rows = lambda name: load("dune/" + name)["rows"]
    res["debt_fall"] = debt_fall(rows("12_debt_fall_by_group.json")[0], rows("13_debt_change_weekly_by_group.json"),
                                 rows("14_fallers_elsewhere.json")[0])
    res["repayment_source"] = repayment_source(rows("15_repayment_source.json"), rows("16_repayment_inflows_by_kind.json"),
                                               rows("17_new_pyusd_to_payers.json"))
    res["repayment_timing"] = repay_timing(rows("19_repayment_vs_unstake_timing.json")[0])
    res["liquidation_distance"] = liquidation_distance(rows("22_liquidation_distance_by_date.json"),
                                                       rows("21_oracle_ratio_drawdown.json")[0])
    res["repayments_around_2026_04_18"] = rows("20_repayments_around_2026_04_18.json")[0]
    res["repayments_around_three_dates"] = rows("23_repayments_around_three_dates.json")
    res["lender_side"] = lender_side(load("morpho_lender_side.json"), yld, debt_days)
    res["supply_withdrawers"] = supply_withdrawers(load("dune/26_supply_withdrawers.json"))
    res["incentives"] = load("morpho_incentives.json")
    aave = dict(load("aave_borrow.json")["USDC"])
    res["aave_usdc_borrow_rate"] = {"april": aave_rate(aave, "2026-04-18", "2026-04-25"),
                                    "may": aave_rate(aave, "2026-05-09", "2026-05-20")}


def quote_span(q):
    """How the texts must name the days of the quote snapshots, from the timestamp of every quote file (UTC):
    "one evening" while all fall on one day after 16:00, two days as "23 and 24 November", more as a range
    from the first to the last day."""
    times = [datetime.fromtimestamp(t, timezone.utc) for t in q["snapshot_times_unix"]]
    days = sorted({t.date() for t in times})
    name = lambda d, month=True: d.strftime("%-d %B" if month else "%-d")
    if len(days) == 1:
        return "one evening" if min(t.hour for t in times) >= 16 else name(days[0])
    same_month = days[0].month == days[-1].month
    return name(days[0], not same_month) + (" and " if len(days) == 2 else " to ") + name(days[-1])


def check_texts(q):
    """Stop with an error if post, article or README disagree with the quotes on the loss at 7.5 million or
    on the days the snapshots cover. These two wordings are updated by hand after a new snapshot.
    A text that is not in the folder is skipped and named: post.md is not part of the repository."""
    loss, span = f"a loss above {q['sUSDe_to_USDC_7_5m_loss_above_pct']}%", quote_span(q)
    # the post words the same figure as "lost under 0.5% up to 3 million USD and above X% at 7.5 million"
    in_post = loss.replace("a loss above", "above") + " at 7.5 million"
    wanted = {"post.md": [in_post, "Quotes from " + span], "article.md": [loss, "quotes come from " + span],
              "README.md": [loss, "snapshots are from " + span]}
    skipped = [name for name in wanted if not (ROOT / name).exists()]
    missing = [f'{name}: "{w}"' for name, ws in wanted.items() if name not in skipped for w in ws
               if w.lower() not in (ROOT / name).read_text().lower()]
    if missing:
        raise SystemExit("Texts do not match data/results.json. Expected wording not found:\n  " + "\n  ".join(missing))
    print("texts match the quotes:", loss + ",", span, "| skipped, not found:", ", ".join(skipped) or "none")


def main():
    res, lltv = market_block()
    pop = res["population_main"]
    res["oracle_main"] = load("oracle_main.json")
    res["feed_history"] = load("dune/09_feed_history.json")["rows"][0]
    res["quotes"] = quote_table()
    yld, debt_days = carry_blocks(res, pop["leverage_at_mean_ltv"])
    exit_blocks(res)
    unwind_blocks(res, yld, debt_days)
    res["stress"] = stress(load("dune/01_daily_discount.json")["rows"])
    res["cooldown_changes"] = load("dune/02_cooldown_changes.json")["rows"]
    res["unstake_wait"] = load("unstake_wait.json")
    res["dex_volume_90d"] = load("dune/06_susde_dex_volume.json")["rows"][0]
    res["unstake_only_exit_days_model"] = {f"ltv_{l}_gap_{g}": unstake_days(l, lltv, g)
                                           for l in (pop["ltv_debt_weighted_mean"], 0.88, 0.90) for g in (0.01, 0.02)}
    (ROOT / "data" / "results.json").write_text(json.dumps(res, indent=1))
    show = {k: ({a: b for a, b in v.items() if a != "weekly"} if isinstance(v, dict) else v) for k, v in res.items()}
    print(json.dumps(show, indent=1))
    check_texts(res["quotes"])


if __name__ == "__main__":
    main()
