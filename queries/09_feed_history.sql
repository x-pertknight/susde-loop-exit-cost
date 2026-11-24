-- Answers written by the Chainlink USDe / USD and PYUSD / USD feeds on Ethereum since 2025-10-01.
-- These two feeds, with the sUSDe contract rate, are the inputs of the oracle of the sUSDe / PYUSD market.
-- Event AnswerUpdated(int256 current, uint256 roundId, uint256 updatedAt): topic1 is the answer, 8 decimals.
-- The four addresses are the aggregators behind the two feed proxies (phaseAggregators 1 and 2 of each).
-- Dune query 9179488 returned one row per day; this version, run as 9186164, returns the summary row that is saved.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH a AS (
    SELECT block_date,
           CASE WHEN contract_address IN (0xB735cC58d71dEAc4cfC46dE68d3b04988F7D7b2d, 0xcC16f670129f965b396f2e81312F6e339FFDB18e) THEN 'USDe' ELSE 'PYUSD' END AS feed,
           CAST(varbinary_to_int256(topic1) AS double) / 1e8 AS answer
    FROM ethereum.logs
    WHERE block_date >= DATE '2025-10-01' AND block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND topic0 = 0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f
      AND contract_address IN (0xB735cC58d71dEAc4cfC46dE68d3b04988F7D7b2d, 0xcC16f670129f965b396f2e81312F6e339FFDB18e,
                               0x60128Ad1eC1A26e338054c7C763b170351355FBD, 0x39E31761911b9aaBAEF5fb81B18Fd1C24a60E884)
),
d AS (
    SELECT block_date,
           min(CASE WHEN feed = 'USDe' THEN answer END) AS usde_min, max(CASE WHEN feed = 'PYUSD' THEN answer END) AS pyusd_max,
           count_if(feed = 'USDe') AS usde_updates, count_if(feed = 'PYUSD') AS pyusd_updates
    FROM a GROUP BY 1
)
-- one summary row: lowest USDe answer and highest PYUSD answer with their days, and the second lowest USDe day
SELECT CAST(min(block_date) AS varchar) AS first_day, count(*) AS days,
       sum(usde_updates) AS usde_updates, sum(pyusd_updates) AS pyusd_updates,
       min(usde_min) AS usde_min, CAST(min_by(block_date, usde_min) AS varchar) AS usde_min_day,
       max(pyusd_max) AS pyusd_max, CAST(max_by(block_date, pyusd_max) AS varchar) AS pyusd_max_day,
       count_if(usde_min < 0.995) AS days_usde_below_0995, count_if(usde_min < 0.99) AS days_usde_below_099,
       element_at(array_sort(array_agg(usde_min) FILTER (WHERE usde_min IS NOT NULL)), 2) AS second_lowest_usde,
       CAST(element_at(min_by(block_date, usde_min, 2), 2) AS varchar) AS second_lowest_day
FROM d
