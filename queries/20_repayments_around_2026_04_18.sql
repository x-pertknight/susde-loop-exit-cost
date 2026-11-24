-- sUSDe / PYUSD market on Morpho: repayments by the ten addresses with the largest fall in debt, before and
-- after 18 April 2026 17:35 UTC. Public Dune query: https://dune.com/queries/9186428. Aggregate only.
-- The reference time is the start of the Kelp DAO rsETH bridge exploit as reported in public write-ups
-- (17:35 UTC; one write-up gives 18:52 UTC). This query measures timing. It does not show a cause.
-- The ten addresses are ranked as in query 13 (fall in debt between 15 April and 15 August 2026).
-- Debt changes come from Borrow, Repay and Liquidate events (PYUSD, interest not included).
WITH ev AS (
    SELECT onBehalf AS addr, evt_block_time AS t, CAST(assets AS double) / 1e6 AS d
    FROM morpho_blue_ethereum.morphoblue_evt_borrow
    WHERE evt_block_date >= DATE '2025-12-01' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION ALL
    SELECT onBehalf, evt_block_time, -CAST(assets AS double) / 1e6
    FROM morpho_blue_ethereum.morphoblue_evt_repay
    WHERE evt_block_date >= DATE '2025-12-01' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION ALL
    SELECT borrower, evt_block_time, -CAST(repaidAssets AS double) / 1e6
    FROM morpho_blue_ethereum.morphoblue_evt_liquidate
    WHERE id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
f AS (
    SELECT addr, row_number() OVER (ORDER BY coalesce(sum(CASE WHEN t < TIMESTAMP '2026-04-16' THEN d END), 0)
                                           - coalesce(sum(CASE WHEN t < TIMESTAMP '2026-08-16' THEN d END), 0) DESC) AS rk
    FROM ev GROUP BY 1
),
-- hours from the reference time; negative = before
x AS (
    SELECT e.addr, e.d, f.rk, date_diff('second', TIMESTAMP '2026-04-18 17:35:00', e.t) / 3600.0 AS h
    FROM ev e JOIN f ON f.addr = e.addr
)
SELECT round(sum(CASE WHEN rk <= 10 AND d < 0 AND h >= -720 AND h < 0 THEN -d END) / 1e6, 1) AS ten_repaid_30d_before_m,
       round(coalesce(sum(CASE WHEN rk <= 10 AND d < 0 AND h >= -144 AND h < 0 THEN -d END), 0) / 1e6, 1) AS ten_repaid_6d_before_m,
       round(coalesce(sum(CASE WHEN rk <= 10 AND d < 0 AND h >= 0 AND h < 24 THEN -d END), 0) / 1e6, 1) AS ten_repaid_24h_after_m,
       round(sum(CASE WHEN rk <= 10 AND d < 0 AND h >= 0 AND h < 72 THEN -d END) / 1e6, 1) AS ten_repaid_3d_after_m,
       round(sum(CASE WHEN rk <= 10 AND d < 0 AND h >= 0 AND h < 144 THEN -d END) / 1e6, 1) AS ten_repaid_6d_after_m,
       round(coalesce(sum(CASE WHEN rk <= 10 AND d > 0 AND h >= -144 AND h < 0 THEN d END), 0) / 1e6, 1) AS ten_borrowed_6d_before_m,
       round(coalesce(sum(CASE WHEN rk <= 10 AND d > 0 AND h >= 0 AND h < 144 THEN d END), 0) / 1e6, 1) AS ten_borrowed_6d_after_m,
       round(min(CASE WHEN rk <= 10 AND d < -1e6 AND h >= 0 THEN h END), 1) AS hours_to_first_repayment_over_1m_by_the_ten,
       count(DISTINCT CASE WHEN rk <= 10 AND d < -1e6 AND h >= 0 AND h < 72 THEN addr END) AS of_the_ten_repaying_over_1m_within_3d,
       count(DISTINCT CASE WHEN rk <= 10 AND d < -1e6 AND h >= 0 AND h < 144 THEN addr END) AS of_the_ten_repaying_over_1m_within_6d,
       round(coalesce(sum(CASE WHEN rk > 10 AND h >= -144 AND h < 0 THEN d END), 0) / 1e6, 1) AS others_net_change_6d_before_m,
       round(coalesce(sum(CASE WHEN rk > 10 AND h >= 0 AND h < 144 THEN d END), 0) / 1e6, 1) AS others_net_change_6d_after_m,
       round(sum(CASE WHEN h >= -144 AND h < 0 THEN d END) / 1e6, 1) AS market_net_change_6d_before_m,
       round(sum(CASE WHEN h >= 0 AND h < 144 THEN d END) / 1e6, 1) AS market_net_change_6d_after_m,
       -- how unusual: the largest repayment total of the ten in any earlier 6-day block (48 days back)
       (SELECT round(max(s) / 1e6, 1) FROM (
            SELECT floor(h / 144) AS blk, sum(-d) AS s FROM x WHERE rk <= 10 AND d < 0 AND h < 0 AND h >= -1152 GROUP BY 1)) AS ten_largest_6d_block_repaid_before_m
FROM x
