-- Of the sUSDe collateral withdrawn from the sUSDe / PYUSD market on Morpho in the last 90 days,
-- how much left in a transaction that also sold sUSDe on a DEX. Public Dune query: https://dune.com/queries/9186416
-- A sale filled outside the venues in Dune's dex.trades table (a private quote, for example) is not seen here.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH w AS (
    SELECT evt_tx_hash, sum(CAST(assets AS double)) / 1e18 AS collateral
    FROM morpho_blue_ethereum.morphoblue_evt_withdrawcollateral
    WHERE evt_block_date >= DATE '2026-11-24' - INTERVAL '90' day AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    GROUP BY 1
),
rep AS (
    SELECT DISTINCT evt_tx_hash FROM morpho_blue_ethereum.morphoblue_evt_repay
    WHERE evt_block_date >= DATE '2026-11-24' - INTERVAL '90' day AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
sold AS (
    SELECT tx_hash, sum(token_sold_amount) AS susde_sold
    FROM dex.trades
    WHERE blockchain = 'ethereum' AND block_date >= DATE '2026-11-24' - INTERVAL '90' day AND block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND token_sold_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
    GROUP BY 1
)
SELECT count(*) AS withdrawal_txs,
       sum(w.collateral) AS collateral,
       sum(CASE WHEN rep.evt_tx_hash IS NOT NULL THEN w.collateral END) AS with_repay,
       sum(CASE WHEN sold.tx_hash IS NOT NULL THEN w.collateral END) AS with_dex_sale,
       count_if(sold.tx_hash IS NOT NULL) AS txs_with_dex_sale
FROM w LEFT JOIN rep ON rep.evt_tx_hash = w.evt_tx_hash LEFT JOIN sold ON sold.tx_hash = w.evt_tx_hash
