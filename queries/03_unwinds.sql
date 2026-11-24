-- Public Dune query: https://dune.com/queries/9186412
-- How collateral leaves the sUSDe-type Morpho markets, last 90 days, in aggregate.
-- A withdrawal is "atomic" when the same transaction also repays debt in the same market.
-- It "uses a Morpho flash loan" when the transaction also contains a Morpho FlashLoan event.
-- Morpho callbacks emit no event, so atomic closes done with a callback show as atomic without flash loan.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH ids(id, market) AS (VALUES
    (0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5, 'sUSDe / PYUSD'),
    (0x5613b170ded221c588b6e9637b910f49e5508680ceede207f44aa72e5c46cb05, 'PT-sUSDe 26NOV2026 / USDC'),
    (0x39d11026eae1c6ec02aa4c0910778664089cdd97c3fd23f68f7cd05e2e95af48, 'sUSDe / DAI 86'),
    (0x1247f1c237eceae0602eab1470a5061a6dd8f734ba88c7cdc5d6109fb0026b28, 'sUSDe / DAI 91.5')
),
w AS (
    SELECT i.market, e.evt_tx_hash, e.id, CAST(e.assets AS double) / 1e18 AS collateral
    FROM morpho_blue_ethereum.morphoblue_evt_withdrawcollateral e JOIN ids i ON i.id = e.id
    WHERE e.evt_block_date >= DATE '2026-11-24' - INTERVAL '90' day AND e.evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
),
rep AS (
    SELECT DISTINCT evt_tx_hash, id FROM morpho_blue_ethereum.morphoblue_evt_repay
    WHERE evt_block_date >= DATE '2026-11-24' - INTERVAL '90' day AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
),
fl AS (
    SELECT DISTINCT evt_tx_hash FROM morpho_blue_ethereum.morphoblue_evt_flashloan
    WHERE evt_block_date >= DATE '2026-11-24' - INTERVAL '90' day AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
),
liq AS (
    SELECT i.market, count(*) AS liquidations_all_time,
           sum(CAST(badDebtAssets AS double)) AS bad_debt_raw_all_time
    FROM morpho_blue_ethereum.morphoblue_evt_liquidate e JOIN ids i ON i.id = e.id
    WHERE e.evt_block_time < TIMESTAMP '2026-11-24 00:00:00' GROUP BY 1
)
SELECT w.market,
       count(*) AS withdrawals,
       sum(w.collateral) AS collateral_withdrawn,
       sum(CASE WHEN rep.evt_tx_hash IS NOT NULL THEN w.collateral ELSE 0 END) AS atomic_collateral,
       sum(CASE WHEN fl.evt_tx_hash IS NOT NULL THEN w.collateral ELSE 0 END) AS flashloan_collateral,
       max(liq.liquidations_all_time) AS liquidations_all_time,
       max(liq.bad_debt_raw_all_time) AS bad_debt_raw_all_time
FROM w
LEFT JOIN rep ON rep.evt_tx_hash = w.evt_tx_hash AND rep.id = w.id
LEFT JOIN fl ON fl.evt_tx_hash = w.evt_tx_hash
LEFT JOIN liq ON liq.market = w.market
GROUP BY 1 HAVING count(*) >= 5 ORDER BY 3 DESC   -- a market with a handful of withdrawals would show single holders
