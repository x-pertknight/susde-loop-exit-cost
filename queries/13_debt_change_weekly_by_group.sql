-- sUSDe / PYUSD market on Morpho: weekly net change in debt, March to mid September 2026, for the three
-- addresses with the largest fall, the next seven, and all others. Dune query 9179887.
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
f AS (
    SELECT addr, row_number() OVER (ORDER BY coalesce(sum(CASE WHEN t < TIMESTAMP '2026-04-16' THEN d END), 0)
                                           - coalesce(sum(CASE WHEN t < TIMESTAMP '2026-08-16' THEN d END), 0) DESC) AS rk
    FROM ev GROUP BY 1
)
SELECT CAST(date_trunc('week', e.t) AS date) AS week,
       round(sum(CASE WHEN f.rk <= 3 THEN e.d END) / 1e6, 1) AS net_change_three_largest_fallers_m,
       round(sum(CASE WHEN f.rk BETWEEN 4 AND 10 THEN e.d END) / 1e6, 1) AS net_change_next_seven_m,
       round(sum(CASE WHEN f.rk > 10 THEN e.d END) / 1e6, 1) AS net_change_all_others_m,
       count(DISTINCT CASE WHEN f.rk <= 10 AND e.d < -1e6 THEN e.addr END) AS of_the_ten_repaying_over_1m
FROM ev e JOIN f ON f.addr = e.addr
WHERE e.t >= TIMESTAMP '2026-03-01' AND e.t < TIMESTAMP '2026-09-15'
GROUP BY 1 ORDER BY 1
