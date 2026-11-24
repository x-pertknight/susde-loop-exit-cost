-- sUSDe / PYUSD market on Morpho: who made the fall in debt from 15 April to 15 August 2026, in groups.
-- Dune query 9186043, run on 24 November 2026 with the column top10_under_5pct_left. An earlier run, 9179879,
-- had one more column, the largest single address, which is not kept here.
-- Debt per address is rebuilt from Borrow, Repay and Liquidate events (PYUSD, interest not included).
-- "Fall" of an address = its debt on 15 April 2026 minus its debt on 15 August 2026.
-- Addresses are ranked by fall and reported in groups of three and ten. No address is in the output.
WITH ev AS (
    SELECT onBehalf AS addr, evt_block_time AS t, CAST(assets AS double) / 1e6 AS d, 'borrow' AS k
    FROM morpho_blue_ethereum.morphoblue_evt_borrow
    WHERE evt_block_date >= DATE '2025-12-01' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION ALL
    SELECT onBehalf, evt_block_time, -CAST(assets AS double) / 1e6, 'repay'
    FROM morpho_blue_ethereum.morphoblue_evt_repay
    WHERE evt_block_date >= DATE '2025-12-01' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION ALL
    SELECT borrower, evt_block_time, -CAST(repaidAssets AS double) / 1e6, 'liquidation'
    FROM morpho_blue_ethereum.morphoblue_evt_liquidate
    WHERE id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
pos AS (
    SELECT addr,
           sum(CASE WHEN t < TIMESTAMP '2026-04-16' THEN d END) AS debt_peak,
           sum(CASE WHEN t < TIMESTAMP '2026-08-16' THEN d END) AS debt_low,
           sum(CASE WHEN t >= TIMESTAMP '2026-04-16' AND t < TIMESTAMP '2026-08-16' AND k = 'repay' THEN -d END) AS repaid_in_window,
           sum(CASE WHEN t >= TIMESTAMP '2026-04-16' AND t < TIMESTAMP '2026-08-16' AND k = 'borrow' THEN d END) AS borrowed_in_window,
           sum(CASE WHEN t >= TIMESTAMP '2026-04-16' AND t < TIMESTAMP '2026-08-16' AND k = 'liquidation' THEN -d END) AS liquidated_in_window
    FROM ev GROUP BY 1
),
f AS (
    SELECT *, coalesce(debt_peak, 0) - coalesce(debt_low, 0) AS fall,
           row_number() OVER (ORDER BY coalesce(debt_peak, 0) - coalesce(debt_low, 0) DESC) AS rk
    FROM pos
)
SELECT round(sum(greatest(coalesce(debt_peak, 0), 0)) / 1e6, 1) AS debt_peak_m,
       round(sum(greatest(coalesce(debt_low, 0), 0)) / 1e6, 1) AS debt_low_m,
       count_if(debt_peak > 10000) AS addresses_with_debt_at_peak,
       count_if(debt_low > 10000) AS addresses_with_debt_at_low,
       round(sum(fall) / 1e6, 1) AS net_fall_m,
       round(sum(CASE WHEN fall > 0 THEN fall END) / 1e6, 1) AS gross_fall_m,
       round(sum(CASE WHEN fall < 0 THEN -fall END) / 1e6, 1) AS gross_rise_m,
       round(sum(CASE WHEN rk <= 3 THEN fall END) / 1e6, 1) AS fall_top3_m,
       round(sum(CASE WHEN rk <= 10 THEN fall END) / 1e6, 1) AS fall_top10_m,
       count_if(fall > 1e6) AS addresses_falling_over_1m,
       count_if(debt_peak > 1e6 AND coalesce(debt_low, 0) < 0.05 * debt_peak) AS addresses_over_1m_that_closed,
       -- the same 5% rule, counted inside the ten largest falls only, so the two sets of ten are joined
       count_if(rk <= 10 AND coalesce(debt_low, 0) < 0.05 * debt_peak) AS top10_under_5pct_left,
       round(sum(repaid_in_window) / 1e6, 1) AS repaid_in_window_m,
       round(sum(borrowed_in_window) / 1e6, 1) AS borrowed_in_window_m,
       round(sum(liquidated_in_window) / 1e6, 3) AS liquidated_in_window_m
FROM f
