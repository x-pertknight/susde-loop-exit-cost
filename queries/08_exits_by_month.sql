-- sUSDe / PYUSD market on Morpho, whole life, by month: collateral withdrawn and what else happened
-- in the same transaction. Public Dune query: https://dune.com/queries/9186417
-- Limits: a repayment in the same transaction says nothing about where the PYUSD came from. A sale filled
-- outside the venues in dex.trades, or in another transaction, is not seen. A withdrawal is counted whether
-- or not the position was closed.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH w AS (
    SELECT evt_tx_hash, min(evt_block_date) AS d, sum(CAST(assets AS double)) / 1e18 AS susde
    FROM morpho_blue_ethereum.morphoblue_evt_withdrawcollateral
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    GROUP BY 1
),
rep AS (
    SELECT evt_tx_hash, sum(CAST(assets AS double)) / 1e6 AS pyusd
    FROM morpho_blue_ethereum.morphoblue_evt_repay
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    GROUP BY 1
),
sold AS (
    SELECT tx_hash, sum(token_sold_amount) AS susde_sold
    FROM dex.trades
    WHERE blockchain = 'ethereum' AND block_date >= DATE '2025-12-01' AND block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND token_sold_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
    GROUP BY 1
),
unstake AS (
    SELECT DISTINCT evt_tx_hash FROM ethena_labs_ethereum.stakedusdev2_evt_withdraw WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
),
moved AS (
    SELECT DISTINCT evt_tx_hash FROM morpho_blue_ethereum.morphoblue_evt_supplycollateral
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id <> 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
fl AS (
    SELECT DISTINCT evt_tx_hash FROM morpho_blue_ethereum.morphoblue_evt_flashloan WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
),
liq AS (
    SELECT date_trunc('month', evt_block_date) AS m, count(*) AS liquidations
    FROM morpho_blue_ethereum.morphoblue_evt_liquidate
    WHERE id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5 AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' GROUP BY 1
)
SELECT CAST(date_trunc('month', w.d) AS date) AS month,
       count(*) AS withdrawal_txs,
       round(sum(w.susde) / 1e6, 2) AS susde_m,
       round(sum(CASE WHEN rep.evt_tx_hash IS NOT NULL THEN w.susde END) / 1e6, 2) AS with_repay_m,
       round(sum(rep.pyusd) / 1e6, 2) AS pyusd_repaid_same_tx_m,
       round(sum(CASE WHEN sold.tx_hash IS NOT NULL THEN w.susde END) / 1e6, 2) AS with_dex_sale_m,
       round(sum(CASE WHEN unstake.evt_tx_hash IS NOT NULL THEN w.susde END) / 1e6, 2) AS with_unstake_request_m,
       round(sum(CASE WHEN moved.evt_tx_hash IS NOT NULL THEN w.susde END) / 1e6, 2) AS with_supply_to_other_morpho_market_m,
       round(sum(CASE WHEN fl.evt_tx_hash IS NOT NULL THEN w.susde END) / 1e6, 2) AS with_morpho_flashloan_m,
       count_if(w.susde > 4000000) AS txs_over_4m_susde,
       -- same value on every row: the whole-life total, so that no month shows the size of one transaction
       round(sum(sum(CASE WHEN w.susde > 4000000 THEN w.susde END)) OVER () / 1e6, 2) AS susde_in_txs_over_4m_m_whole_life,
       round(sum(CASE WHEN w.susde > 4000000 AND sold.tx_hash IS NOT NULL THEN w.susde END) / 1e6, 2) AS over_4m_with_dex_sale_m,
       max(liq.liquidations) AS liquidations
FROM w
LEFT JOIN rep ON rep.evt_tx_hash = w.evt_tx_hash
LEFT JOIN sold ON sold.tx_hash = w.evt_tx_hash
LEFT JOIN unstake ON unstake.evt_tx_hash = w.evt_tx_hash
LEFT JOIN moved ON moved.evt_tx_hash = w.evt_tx_hash
LEFT JOIN fl ON fl.evt_tx_hash = w.evt_tx_hash
LEFT JOIN liq ON liq.m = date_trunc('month', w.d)
GROUP BY 1 ORDER BY 1
