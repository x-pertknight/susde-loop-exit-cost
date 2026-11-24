-- Every PYUSD mint on Ethereum since December 2025, grouped by the contract the transaction called.
-- Dune query 9186182. Context for query 17: it separates mints made by a direct call to the token (the issuer)
-- from mints made through other contracts. The addresses here are contracts, not holders.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
SELECT evt_tx_to AS called, count(*) AS mints, count(DISTINCT "to") AS recipients,
       count(DISTINCT evt_tx_from) AS tx_senders, round(sum(CAST(value AS double)) / 1e12, 1) AS minted_m,
       round(approx_percentile(CAST(value AS double) / 1e6, 0.5)) AS median_mint
FROM erc20_ethereum.evt_transfer
WHERE contract_address = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8 AND evt_block_date >= DATE '2025-11-30' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
  AND "from" = 0x0000000000000000000000000000000000000000
GROUP BY 1 ORDER BY minted_m DESC LIMIT 10
