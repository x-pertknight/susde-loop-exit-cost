-- Daily DEX volume of sUSDe on Ethereum against any token, last 90 full days. Dune query 9186175.
-- "sold" counts trades where sUSDe is the token sold. amount_usd is Dune's own USD value of the trade.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH t AS (
    SELECT block_date,
           CASE WHEN token_sold_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497 THEN 'sell' ELSE 'buy' END AS side,
           amount_usd
    FROM dex.trades
    WHERE blockchain = 'ethereum' AND block_date >= DATE '2026-11-24' - INTERVAL '90' day AND block_time < TIMESTAMP '2026-11-24 00:00:00' AND block_date < DATE '2026-11-24'
      AND (token_sold_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497 OR token_bought_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497)
      AND amount_usd > 0
),
daily AS (SELECT block_date, sum(amount_usd) AS v, sum(CASE WHEN side = 'sell' THEN amount_usd END) AS sold FROM t GROUP BY 1)
SELECT count(*) AS days, round(approx_percentile(v, 0.5) / 1e6, 2) AS median_daily_m,
       round(avg(v) / 1e6, 2) AS mean_daily_m, round(max(v) / 1e6, 2) AS max_daily_m,
       round(approx_percentile(sold, 0.5) / 1e6, 2) AS median_daily_sold_m, round(max(sold) / 1e6, 2) AS max_daily_sold_m,
       round(sum(v) / 1e6, 1) AS total_m
FROM daily
