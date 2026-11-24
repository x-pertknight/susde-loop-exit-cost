-- The ten addresses with the largest fall in debt (15 April to 15 August 2026): what else they did between
-- 9 April and 23 August 2026, in aggregate. Public Dune query: https://dune.com/queries/9186423
-- Limits: a borrow elsewhere is counted, not sized, and its collateral is not checked, so it is not proof of
-- a refinance. The unstake match is by address: least(fall in PYUSD, USDe unstaked), summed.
-- Debt per address is rebuilt from Borrow, Repay and Liquidate events (PYUSD, interest not included).
-- "Fall" of an address = its debt on 15 April 2026 minus its debt on 15 August 2026.
-- Addresses are ranked by fall and reported in groups of three and ten. No address is in the output.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH ev AS (
    SELECT onBehalf AS addr, evt_block_time AS t, CAST(assets AS double) / 1e6 AS d
    FROM morpho_blue_ethereum.morphoblue_evt_borrow
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION ALL
    SELECT onBehalf, evt_block_time, -CAST(assets AS double) / 1e6
    FROM morpho_blue_ethereum.morphoblue_evt_repay
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION ALL
    SELECT borrower, evt_block_time, -CAST(repaidAssets AS double) / 1e6
    FROM morpho_blue_ethereum.morphoblue_evt_liquidate
    WHERE id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5 AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
),
f AS (
    SELECT addr,
           coalesce(sum(CASE WHEN t < TIMESTAMP '2026-04-16' THEN d END), 0) - coalesce(sum(CASE WHEN t < TIMESTAMP '2026-08-16' THEN d END), 0) AS fall,
           coalesce(sum(CASE WHEN t >= TIMESTAMP '2026-08-16' AND d > 0 THEN d END), 0) AS borrowed_here_after_low
    FROM ev GROUP BY 1
),
top AS (SELECT * FROM (SELECT *, row_number() OVER (ORDER BY fall DESC) AS rk FROM f) WHERE rk <= 10),
other_morpho AS (
    SELECT b.onBehalf AS addr, count(*) AS n
    FROM morpho_blue_ethereum.morphoblue_evt_borrow b JOIN top ON top.addr = b.onBehalf
    WHERE b.evt_block_date BETWEEN DATE '2026-04-09' AND DATE '2026-08-23'
      AND b.id <> 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    GROUP BY 1
),
aave AS (
    SELECT b.onBehalfOf AS addr, count(*) AS n
    FROM aave_v3_ethereum.pool_evt_borrow b JOIN top ON top.addr = b.onBehalfOf
    WHERE b.evt_block_date BETWEEN DATE '2026-04-09' AND DATE '2026-08-23'
    GROUP BY 1
),
unst AS (
    SELECT e.owner AS addr, sum(CAST(e.assets AS double)) / 1e18 AS usde
    FROM ethena_labs_ethereum.stakedusdev2_evt_withdraw e JOIN top ON top.addr = e.owner
    WHERE e.evt_block_date BETWEEN DATE '2026-04-09' AND DATE '2026-08-23'
    GROUP BY 1
)
SELECT count(*) AS addresses,
       round(sum(top.fall) / 1e6, 1) AS fall_m,
       count_if(m.n > 0) AS with_borrow_in_another_morpho_market,
       round(sum(CASE WHEN m.n > 0 THEN top.fall END) / 1e6, 1) AS their_fall_m,
       count_if(a.n > 0) AS with_borrow_on_aave_v3,
       round(sum(CASE WHEN a.n > 0 THEN top.fall END) / 1e6, 1) AS their_fall_aave_m,
       count_if(u.usde > 0) AS with_unstake_in_window,
       round(sum(CASE WHEN u.usde > 0 THEN top.fall END) / 1e6, 1) AS their_fall_unstake_m,
       round(sum(least(top.fall, coalesce(u.usde, 0))) / 1e6, 1) AS fall_matched_by_usde_unstaked_m,
       count_if(top.borrowed_here_after_low > 1e6) AS came_back_after_low,
       round(sum(top.borrowed_here_after_low) / 1e6, 1) AS borrowed_here_after_low_m,
       count_if(m.n IS NULL AND a.n IS NULL AND u.usde IS NULL) AS with_none_of_these
FROM top LEFT JOIN other_morpho m ON m.addr = top.addr LEFT JOIN aave a ON a.addr = top.addr LEFT JOIN unst u ON u.addr = top.addr
