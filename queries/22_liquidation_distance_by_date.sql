-- sUSDe / PYUSD market on Morpho: how far the book was from liquidation on seven dates. Public Dune query: https://dune.com/queries/9186430
-- Measured from events, in aggregate. No address is in the output.
-- Per address: collateral = SupplyCollateral - WithdrawCollateral - seized in Liquidate. Debt = its borrow
-- shares x market borrow assets / market borrow shares, where market borrow assets include AccrueInterest.
-- Collateral value = sUSDe x contract rate x USDe / USD feed / PYUSD / USD feed, as the market's oracle does.
-- The book is the one at the end of the day. The feeds are the worst of that day for a borrower (lowest USDe
-- answer, highest PYUSD answer), or the latest earlier answer when a feed did not update that day.
-- "Liquidatable after a fall of x" = debt of positions whose loan-to-value would reach 91.5% if the oracle
-- price fell by x more. That part is a counterfactual on a measured book. 0.598% is the largest drawdown of
-- the feed ratio since December 2025 (query 21).
-- Limits: positions under 10,000 PYUSD of debt are left out. The sUSDe rate is read from the latest large
-- unstake request within two days, so it can lag by up to two days of yield.
WITH dates(d) AS (VALUES (DATE '2026-03-15'), (DATE '2026-04-15'), (DATE '2026-04-18'), (DATE '2026-04-21'),
                           (DATE '2026-08-15'), (DATE '2026-10-30'), (DATE '2026-11-22')),
-- signed events per address: sUSDe collateral, borrow shares, and market totals of borrow assets and shares
ev AS (
    SELECT onBehalf AS addr, evt_block_time AS t, CAST(assets AS double) / 1e18 AS coll, 0e0 AS sh, 0e0 AS a
    FROM morpho_blue_ethereum.morphoblue_evt_supplycollateral
    WHERE evt_block_date >= DATE '2025-12-01' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION ALL
    SELECT onBehalf, evt_block_time, -CAST(assets AS double) / 1e18, 0e0, 0e0
    FROM morpho_blue_ethereum.morphoblue_evt_withdrawcollateral
    WHERE evt_block_date >= DATE '2025-12-01' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION ALL
    SELECT onBehalf, evt_block_time, 0e0, CAST(shares AS double), CAST(assets AS double) / 1e6
    FROM morpho_blue_ethereum.morphoblue_evt_borrow
    WHERE evt_block_date >= DATE '2025-12-01' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION ALL
    SELECT onBehalf, evt_block_time, 0e0, -CAST(shares AS double), -CAST(assets AS double) / 1e6
    FROM morpho_blue_ethereum.morphoblue_evt_repay
    WHERE evt_block_date >= DATE '2025-12-01' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION ALL
    SELECT borrower, evt_block_time, -CAST(seizedAssets AS double) / 1e18,
           -CAST(repaidShares AS double) - CAST(badDebtShares AS double), -CAST(repaidAssets AS double) / 1e6 - CAST(badDebtAssets AS double) / 1e6
    FROM morpho_blue_ethereum.morphoblue_evt_liquidate
    WHERE id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION ALL
    -- interest raises the market's borrow assets, not the shares
    SELECT 0x0000000000000000000000000000000000000000, evt_block_time, 0e0, 0e0, CAST(interest AS double) / 1e6
    FROM morpho_blue_ethereum.morphoblue_evt_accrueinterest
    WHERE evt_block_date >= DATE '2025-12-01' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
tot AS (
    SELECT dt.d, sum(ev.a) AS assets, sum(ev.sh) AS shares
    FROM dates dt JOIN ev ON ev.t < CAST(dt.d AS timestamp) + INTERVAL '1' day GROUP BY 1
),
pos AS (
    SELECT dt.d, ev.addr, sum(ev.coll) AS coll, sum(ev.sh) AS sh
    FROM dates dt JOIN ev ON ev.t < CAST(dt.d AS timestamp) + INTERVAL '1' day
    WHERE ev.addr <> 0x0000000000000000000000000000000000000000
    GROUP BY 1, 2
),
-- sUSDe contract rate from the latest unstake request of the day or the two days before (assets per share)
rate AS (
    SELECT dt.d, max_by(CAST(e.assets AS double) / CAST(e.shares AS double), e.evt_block_time) AS rate
    FROM dates dt JOIN ethena_labs_ethereum.stakedusdev2_evt_withdraw e
      ON e.evt_block_date BETWEEN dt.d - INTERVAL '2' day AND dt.d AND CAST(e.shares AS double) > 1e21
    WHERE e.evt_block_date >= DATE '2026-03-01'
    GROUP BY 1
),
feed AS (
    SELECT block_date, block_time,
           CASE WHEN contract_address IN (0xB735cC58d71dEAc4cfC46dE68d3b04988F7D7b2d, 0xcC16f670129f965b396f2e81312F6e339FFDB18e) THEN 'USDe' ELSE 'PYUSD' END AS feed,
           CAST(varbinary_to_int256(topic1) AS double) / 1e8 AS answer
    FROM ethereum.logs
    WHERE block_date >= DATE '2026-03-01'
      AND topic0 = 0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f
      AND contract_address IN (0xB735cC58d71dEAc4cfC46dE68d3b04988F7D7b2d, 0xcC16f670129f965b396f2e81312F6e339FFDB18e,
                               0x60128Ad1eC1A26e338054c7C763b170351355FBD, 0x39E31761911b9aaBAEF5fb81B18Fd1C24a60E884)
),
-- worst feed values of the day for a borrower: lowest USDe answer, highest PYUSD answer; else the latest before
px AS (
    SELECT dt.d,
           coalesce(min(CASE WHEN f.feed = 'USDe' AND f.block_date = dt.d THEN f.answer END),
                    max_by(CASE WHEN f.feed = 'USDe' THEN f.answer END, CASE WHEN f.feed = 'USDe' THEN f.block_time END)) AS usde,
           coalesce(max(CASE WHEN f.feed = 'PYUSD' AND f.block_date = dt.d THEN f.answer END),
                    max_by(CASE WHEN f.feed = 'PYUSD' THEN f.answer END, CASE WHEN f.feed = 'PYUSD' THEN f.block_time END)) AS pyusd
    FROM dates dt JOIN feed f ON f.block_date <= dt.d GROUP BY 1
),
book AS (
    SELECT p.d, p.sh / t.shares * t.assets AS debt, p.coll * r.rate * x.usde / x.pyusd AS coll_value,
           r.rate, x.usde, x.pyusd, t.assets AS market_debt
    FROM pos p JOIN tot t ON t.d = p.d JOIN rate r ON r.d = p.d JOIN px x ON x.d = p.d
    WHERE p.sh / t.shares * t.assets >= 10000
),
l AS (SELECT *, debt / coll_value AS ltv FROM book)
SELECT CAST(d AS varchar) AS day, count(*) AS positions_over_10k, round(sum(debt) / 1e6, 1) AS debt_m,
       round(max(market_debt) / 1e6, 1) AS market_debt_m,
       round(sum(coll_value) / 1e6, 1) AS collateral_value_m,
       round(max(rate), 4) AS susde_rate, round(max(usde), 5) AS usde_feed, round(max(pyusd), 5) AS pyusd_feed,
       round(sum(ltv * debt) / sum(debt), 3) AS ltv_debt_weighted,
       round(sum((1 - ltv / 0.915) * debt) / sum(debt), 3) AS price_fall_to_liquidation_debt_weighted,
       round(sum(CASE WHEN 0.915 - ltv < 0.02 THEN debt END) / sum(debt), 3) AS debt_share_within_2_points,
       round(sum(CASE WHEN 0.915 - ltv < 0.05 THEN debt END) / sum(debt), 3) AS debt_share_within_5_points,
       round(coalesce(sum(CASE WHEN ltv / (1 - 0.00598) >= 0.915 THEN debt END), 0) / sum(debt), 3) AS debt_share_liquidatable_after_fall_0_6pct,
       round(coalesce(sum(CASE WHEN ltv / (1 - 0.01) >= 0.915 THEN debt END), 0) / sum(debt), 3) AS debt_share_liquidatable_after_fall_1pct,
       round(coalesce(sum(CASE WHEN ltv / (1 - 0.02) >= 0.915 THEN debt END), 0) / sum(debt), 3) AS debt_share_liquidatable_after_fall_2pct,
       round(coalesce(sum(CASE WHEN ltv / (1 - 0.03) >= 0.915 THEN debt END), 0) / sum(debt), 3) AS debt_share_liquidatable_after_fall_3pct,
       round(coalesce(sum(CASE WHEN ltv / (1 - 0.05) >= 0.915 THEN debt END), 0) / sum(debt), 3) AS debt_share_liquidatable_after_fall_5pct,
       round(coalesce(sum(CASE WHEN ltv >= 0.915 THEN debt END), 0) / sum(debt), 3) AS debt_share_over_lltv
FROM l GROUP BY 1 ORDER BY 1
