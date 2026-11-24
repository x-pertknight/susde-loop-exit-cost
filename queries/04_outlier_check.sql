-- Reading the outliers by hand. A first version of query 01 used a plain volume-weighted average price
-- and showed USDe "discounts" of 8% to 20% on five days. This query lists those days by venue and side.
-- Result: on four of the five days the cause is one or two Uniswap trades at 0.03 to 0.30 USD with equal
-- volume on the buy and the sell side. Query 01 now uses the volume-weighted median. Dune query 9179314.
WITH t AS (
    SELECT block_time, project, tx_hash,
           CASE WHEN token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 THEN 'sell_usde' ELSE 'buy_usde' END AS side,
           CASE WHEN token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 THEN token_sold_amount ELSE token_bought_amount END AS usde,
           CASE WHEN token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 THEN token_bought_amount ELSE token_sold_amount END AS stable
    FROM dex.trades
    WHERE blockchain = 'ethereum' AND block_date IN (DATE '2025-11-26', DATE '2026-10-30', DATE '2026-10-31', DATE '2026-03-20', DATE '2026-01-09')
      AND ((token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 AND token_bought_address IN (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0xdAC17F958D2ee523a2206206994597C13D831ec7))
        OR (token_bought_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 AND token_sold_address IN (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0xdAC17F958D2ee523a2206206994597C13D831ec7)))
      AND token_sold_amount > 1000 AND token_bought_amount > 1000
)
SELECT CAST(block_time AS date) AS day, project, side,
       count(*) AS trades, count(DISTINCT tx_hash) AS txs,
       count_if(abs(stable / usde - 1) > 0.02) AS trades_off_2pct,
       round(sum(usde) / 1e6, 2) AS usde_m,
       round(sum(CASE WHEN abs(stable / usde - 1) > 0.02 THEN usde END) / 1e6, 3) AS usde_m_off_2pct,
       round(min(stable / usde), 4) AS min_px, round(max(stable / usde), 4) AS max_px
FROM t GROUP BY 1, 2, 3 ORDER BY 1, usde_m DESC
