-- Chainlink USDe / USD divided by PYUSD / USD since December 2025: the part of the market's oracle that can
-- fall. Lowest value and largest drawdown from a running high. Dune query 9186173.
-- At every update of either feed the ratio uses the two latest answers, as the oracle contract would.
-- Feed addresses as in query 09. The sUSDe contract rate, the third input, is not in this ratio.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH a AS (
    SELECT block_date, block_time,
           CASE WHEN contract_address IN (0xB735cC58d71dEAc4cfC46dE68d3b04988F7D7b2d, 0xcC16f670129f965b396f2e81312F6e339FFDB18e) THEN 'USDe' ELSE 'PYUSD' END AS feed,
           CAST(varbinary_to_int256(topic1) AS double) / 1e8 AS answer
    FROM ethereum.logs
    WHERE block_date >= DATE '2025-11-25' AND block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND topic0 = 0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f
      AND contract_address IN (0xB735cC58d71dEAc4cfC46dE68d3b04988F7D7b2d, 0xcC16f670129f965b396f2e81312F6e339FFDB18e,
                               0x60128Ad1eC1A26e338054c7C763b170351355FBD, 0x39E31761911b9aaBAEF5fb81B18Fd1C24a60E884)
),
s AS (
    SELECT block_time, block_date,
           last_value(CASE WHEN feed = 'USDe' THEN answer END) IGNORE NULLS OVER (ORDER BY block_time) AS usde,
           last_value(CASE WHEN feed = 'PYUSD' THEN answer END) IGNORE NULLS OVER (ORDER BY block_time) AS pyusd
    FROM a
),
r AS (SELECT block_time, block_date, usde, pyusd, usde / pyusd AS ratio FROM s WHERE usde IS NOT NULL AND pyusd IS NOT NULL AND block_date >= DATE '2025-12-01' AND block_time < TIMESTAMP '2026-11-24 00:00:00'),
dd AS (SELECT *, max(ratio) OVER (ORDER BY block_time) AS run_max FROM r)
SELECT count(*) AS updates, CAST(min(block_date) AS varchar) AS first_day, CAST(max(block_date) AS varchar) AS last_day,
       round(min(ratio), 5) AS lowest_ratio, CAST(min_by(block_date, ratio) AS varchar) AS lowest_ratio_day,
       round(min_by(usde, ratio), 5) AS usde_at_lowest, round(min_by(pyusd, ratio), 5) AS pyusd_at_lowest,
       round(max(ratio), 5) AS highest_ratio,
       round(max(1 - ratio / run_max), 5) AS largest_drawdown, CAST(max_by(block_date, 1 - ratio / run_max) AS varchar) AS largest_drawdown_day,
       round(approx_percentile(ratio, 0.01), 5) AS ratio_p01, round(approx_percentile(ratio, 0.5), 5) AS ratio_median,
       count(DISTINCT CASE WHEN ratio < 0.995 THEN block_date END) AS days_ratio_below_0995,
       count(DISTINCT CASE WHEN ratio < 0.99 THEN block_date END) AS days_ratio_below_099
FROM dd
