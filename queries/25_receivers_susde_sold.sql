-- sUSDe withdrawn from the sUSDe / PYUSD market on Morpho: did the receiving address then sell sUSDe?
-- Whole life of the market, in aggregate. Dune query 9186181.
-- Same denominator and the same two counting rules as the unstake match (queries 10 and 11):
-- each sale is counted once, with the time since the latest withdrawal to the same address. Rule one caps
-- the matched amount at what the address received over its whole life, rule two at what it received on the
-- day of that withdrawal.
-- A sale is a row of dex.trades where the receiver is the transaction sender or the taker, or a CoW Protocol
-- fill where the receiver is the trader. A sale inside the withdrawal transaction counts if the receiver
-- sent it or took it.
-- Limits: this matches addresses, not coins. A sale by another address the same holder controls, a private
-- quote, or a sale on a venue outside these two tables is not seen. No address is in the output.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH w_ev AS (
    SELECT receiver AS addr, evt_block_time AS t, CAST(assets AS double) / 1e18 AS amt
    FROM morpho_blue_ethereum.morphoblue_evt_withdrawcollateral
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
w AS (SELECT addr, sum(amt) AS w FROM w_ev GROUP BY 1),
w_day AS (SELECT addr, date_trunc('day', t) AS d, sum(amt) AS w FROM w_ev GROUP BY 1, 2),
-- sUSDe sales by a receiver: DEX trades it sent or took, and CoW Protocol fills where it is the trader
s_ev AS (
    SELECT 'dex' AS venue, w.addr, d.block_time AS t, d.tx_hash AS h, d.evt_index AS i, d.token_sold_amount AS amt
    FROM dex.trades d JOIN w ON w.addr = d.tx_from OR w.addr = d.taker
    WHERE d.blockchain = 'ethereum' AND d.block_date >= DATE '2025-12-01' AND d.block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND d.token_sold_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
    UNION ALL
    SELECT 'cow', w.addr, c.block_time, c.tx_hash, c.evt_index, c.units_sold
    FROM cow_protocol_ethereum.trades c JOIN w ON w.addr = c.trader
    WHERE c.block_date >= DATE '2025-12-01' AND c.block_time < TIMESTAMP '2026-11-24 00:00:00' AND c.sell_token_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
),
s_one AS (SELECT venue, addr, t, h, i, max(amt) AS amt FROM s_ev GROUP BY 1, 2, 3, 4, 5),
s_gap AS (
    SELECT s.venue, s.addr, s.t, s.h, s.i, s.amt, max(x.t) AS last_w
    FROM s_one s JOIN w_ev x ON x.addr = s.addr AND x.t <= s.t
    GROUP BY 1, 2, 3, 4, 5, 6
),
loose AS (
    SELECT addr,
           sum(CASE WHEN venue = 'dex' AND date_diff('second', last_w, t) <= 86400 THEN amt END) AS dex1,
           sum(CASE WHEN venue = 'dex' AND date_diff('second', last_w, t) <= 3 * 86400 THEN amt END) AS dex3,
           sum(CASE WHEN venue = 'cow' AND date_diff('second', last_w, t) <= 3 * 86400 THEN amt END) AS cow3,
           sum(CASE WHEN date_diff('second', last_w, t) <= 3 * 86400 THEN amt END) AS all3,
           sum(CASE WHEN date_diff('second', last_w, t) <= 7 * 86400 THEN amt END) AS all7,
           sum(amt) AS all_later
    FROM s_gap GROUP BY 1
),
strict AS (
    SELECT addr, date_trunc('day', last_w) AS d,
           sum(CASE WHEN venue = 'dex' AND date_diff('second', last_w, t) <= 3 * 86400 THEN amt END) AS dex3,
           sum(CASE WHEN date_diff('second', last_w, t) <= 3 * 86400 THEN amt END) AS all3
    FROM s_gap GROUP BY 1, 2
),
a AS (
    SELECT count(*) AS receivers, sum(w.w) AS withdrawn,
           sum(least(w.w, coalesce(l.dex1, 0))) AS dex1, sum(least(w.w, coalesce(l.dex3, 0))) AS dex3,
           sum(least(w.w, coalesce(l.cow3, 0))) AS cow3, sum(least(w.w, coalesce(l.all3, 0))) AS all3,
           sum(least(w.w, coalesce(l.all7, 0))) AS all7, sum(least(w.w, coalesce(l.all_later, 0))) AS all_later,
           count_if(coalesce(l.dex3, 0) > 0) AS n_dex3, count_if(coalesce(l.cow3, 0) > 0) AS n_cow3,
           count_if(coalesce(l.all3, 0) > 0) AS n_all3
    FROM w LEFT JOIN loose l ON l.addr = w.addr
),
b AS (
    SELECT sum(least(d.w, coalesce(s.dex3, 0))) AS dex3_strict, sum(least(d.w, coalesce(s.all3, 0))) AS all3_strict
    FROM w_day d LEFT JOIN strict s ON s.addr = d.addr AND s.d = d.d
)
SELECT a.receivers, round(a.withdrawn / 1e6, 2) AS withdrawn_m,
       round(a.dex1 / 1e6, 2) AS sold_dex_within_1d_m, round(a.dex3 / 1e6, 2) AS sold_dex_within_3d_m,
       round(a.cow3 / 1e6, 2) AS sold_cow_within_3d_m, round(a.all3 / 1e6, 2) AS sold_dex_or_cow_within_3d_m,
       round(a.all7 / 1e6, 2) AS sold_dex_or_cow_within_7d_m, round(a.all_later / 1e6, 2) AS sold_dex_or_cow_any_later_m,
       round(b.dex3_strict / 1e6, 2) AS sold_dex_within_3d_capped_per_day_m,
       round(b.all3_strict / 1e6, 2) AS sold_dex_or_cow_within_3d_capped_per_day_m,
       a.n_dex3 AS receivers_selling_on_dex_within_3d, a.n_cow3 AS receivers_selling_on_cow_within_3d,
       a.n_all3 AS receivers_selling_within_3d
FROM a CROSS JOIN b
