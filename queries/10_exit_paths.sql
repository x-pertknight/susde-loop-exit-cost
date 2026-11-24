-- sUSDe withdrawn from the sUSDe / PYUSD market on Morpho: did the receiving address then start an Ethena
-- cooldown (an unstake request)? Whole life of the market, in aggregate. Public Dune query: https://dune.com/queries/9186419
-- Every Withdraw event of the sUSDe contract in these months has the cooldown silo as receiver (a separate check
-- found 14,089 events, one receiver), so each one is an unstake request.
-- Each cooldown request is counted once, with the time since the latest withdrawal to the same address.
-- Per address the matched amount is capped at what the address received from the market.
-- Limits: this matches addresses, not coins. An address can unstake sUSDe it got elsewhere, and sUSDe
-- forwarded to another address is not followed. No address is in the output.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH w_ev AS (
    SELECT receiver AS addr, evt_block_time AS t, CAST(assets AS double) / 1e18 AS amt
    FROM morpho_blue_ethereum.morphoblue_evt_withdrawcollateral
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
w AS (SELECT addr, sum(amt) AS w FROM w_ev GROUP BY 1),
c_ev AS (
    SELECT e.owner AS addr, e.evt_block_time AS t, CAST(e.shares AS double) / 1e18 AS amt
    FROM ethena_labs_ethereum.stakedusdev2_evt_withdraw e JOIN w ON w.addr = e.owner
    WHERE e.evt_block_date >= DATE '2025-12-01' AND e.evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
),
c_gap AS (
    SELECT c.addr, c.t, c.amt, date_diff('second', max(x.t), c.t) / 86400.0 AS days_since_withdrawal
    FROM c_ev c JOIN w_ev x ON x.addr = c.addr AND x.t <= c.t
    GROUP BY 1, 2, 3
),
c AS (
    SELECT addr,
           sum(CASE WHEN days_since_withdrawal <= 1 THEN amt END) AS c1,
           sum(CASE WHEN days_since_withdrawal <= 3 THEN amt END) AS c3,
           sum(CASE WHEN days_since_withdrawal <= 7 THEN amt END) AS c7,
           sum(amt) AS c_any_later
    FROM c_gap GROUP BY 1
),
ranked AS (SELECT w.*, row_number() OVER (ORDER BY w.w DESC) AS rk FROM w)
SELECT count(*) AS receivers,
       round(sum(r.w) / 1e6, 2) AS withdrawn_m,
       round(sum(least(r.w, coalesce(c.c1, 0))) / 1e6, 2) AS matched_cooldown_within_1d_m,
       round(sum(least(r.w, coalesce(c.c3, 0))) / 1e6, 2) AS matched_cooldown_within_3d_m,
       round(sum(least(r.w, coalesce(c.c7, 0))) / 1e6, 2) AS matched_cooldown_within_7d_m,
       round(sum(least(r.w, coalesce(c.c_any_later, 0))) / 1e6, 2) AS matched_cooldown_any_later_m,
       count_if(coalesce(c.c3, 0) > 0) AS receivers_with_cooldown_within_3d,
       count_if(coalesce(c.c_any_later, 0) > 0) AS receivers_with_cooldown_later,
       round(sum(CASE WHEN r.rk <= 10 THEN r.w END) / sum(r.w), 2) AS share_of_ten_largest_receivers
FROM ranked r LEFT JOIN c ON c.addr = r.addr
