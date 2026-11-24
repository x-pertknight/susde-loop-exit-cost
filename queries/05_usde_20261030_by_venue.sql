-- USDe against USDC and USDT on 2026-10-30, by hour and venue. Dune query 9179318.
-- p10_px is the price below which the worst 10% of the hour's volume traded.
WITH t AS (
    SELECT block_time, project, version, project_contract_address AS pool, tx_hash,
           CASE WHEN token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 THEN token_sold_amount ELSE token_bought_amount END AS usde,
           CASE WHEN token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 THEN token_bought_amount ELSE token_sold_amount END AS stable
    FROM dex.trades
    WHERE blockchain = 'ethereum' AND block_date = DATE '2026-10-30'
      AND ((token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 AND token_bought_address IN (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0xdAC17F958D2ee523a2206206994597C13D831ec7))
        OR (token_bought_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 AND token_sold_address IN (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0xdAC17F958D2ee523a2206206994597C13D831ec7)))
      AND token_sold_amount > 1000 AND token_bought_amount > 1000
)
SELECT hour(block_time) AS h, project, version,
       count(*) AS trades, count(DISTINCT tx_hash) AS txs, count(DISTINCT pool) AS pools,
       round(sum(usde) / 1e6, 2) AS usde_m,
       round(approx_percentile(stable / usde, usde, 0.5), 4) AS median_px,
       round(approx_percentile(stable / usde, usde, 0.1), 4) AS p10_px,
       round(min(stable / usde), 4) AS min_px, round(max(stable / usde), 4) AS max_px
FROM t GROUP BY 1, 2, 3 HAVING sum(usde) > 200000 ORDER BY 1, usde_m DESC
