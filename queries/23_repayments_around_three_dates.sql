-- Query 20 repeated for three reference times, as a comparison. Dune query 9180248. Aggregate only.
-- 18 April 2026 17:35 UTC is the reported start of the Kelp DAO exploit. 11 March and 12 May 2026 (00:00 UTC)
-- are the first days of the other two largest 7-day falls in the market's debt. The ten addresses are the
-- same in all three rows: the ten with the largest fall in debt between 15 April and 15 August 2026.
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
refs(label, t0) AS (VALUES ('2026-03-11 00:00', TIMESTAMP '2026-03-11 00:00:00'),
                           ('2026-04-18 17:35', TIMESTAMP '2026-04-18 17:35:00'),
                           ('2026-05-12 00:00', TIMESTAMP '2026-05-12 00:00:00')),
x AS (
    SELECT r.label, e.addr, e.d, f.rk, date_diff('second', r.t0, e.t) / 3600.0 AS h
    FROM refs r CROSS JOIN ev e JOIN f ON f.addr = e.addr
)
SELECT label AS reference_time_utc,
       round(coalesce(sum(CASE WHEN rk <= 10 AND d < 0 AND h >= -144 AND h < 0 THEN -d END), 0) / 1e6, 1) AS ten_repaid_6d_before_m,
       round(coalesce(sum(CASE WHEN rk <= 10 AND d < 0 AND h >= 0 AND h < 24 THEN -d END), 0) / 1e6, 1) AS ten_repaid_24h_after_m,
       round(coalesce(sum(CASE WHEN rk <= 10 AND d < 0 AND h >= 0 AND h < 72 THEN -d END), 0) / 1e6, 1) AS ten_repaid_3d_after_m,
       round(coalesce(sum(CASE WHEN rk <= 10 AND d < 0 AND h >= 0 AND h < 144 THEN -d END), 0) / 1e6, 1) AS ten_repaid_6d_after_m,
       round(coalesce(sum(CASE WHEN rk <= 10 AND d > 0 AND h >= -144 AND h < 0 THEN d END), 0) / 1e6, 1) AS ten_borrowed_6d_before_m,
       round(coalesce(sum(CASE WHEN rk <= 10 AND d > 0 AND h >= 0 AND h < 144 THEN d END), 0) / 1e6, 1) AS ten_borrowed_6d_after_m,
       count(DISTINCT CASE WHEN rk <= 10 AND d < -1e6 AND h >= 0 AND h < 144 THEN addr END) AS of_the_ten_repaying_over_1m_within_6d,
       round(coalesce(sum(CASE WHEN rk > 10 AND d < 0 AND h >= 0 AND h < 144 THEN -d END), 0) / 1e6, 1) AS others_repaid_6d_after_m,
       round(sum(CASE WHEN h >= -144 AND h < 0 THEN d END) / 1e6, 1) AS market_net_change_6d_before_m,
       round(sum(CASE WHEN h >= 0 AND h < 144 THEN d END) / 1e6, 1) AS market_net_change_6d_after_m
FROM x GROUP BY 1 ORDER BY 1
