-- Public Dune query: https://dune.com/queries/9186411
-- Every change of the sUSDe unstake cooldown since the contract was deployed.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
SELECT evt_block_time, previousDuration / 86400.0 AS previous_days, newDuration / 86400.0 AS new_days
FROM ethena_labs_ethereum.stakedusdev2_evt_cooldowndurationupdated
WHERE evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
ORDER BY 1
