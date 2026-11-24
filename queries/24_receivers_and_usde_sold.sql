-- Two checks on the receivers of sUSDe withdrawn from the sUSDe / PYUSD market on Morpho. Dune query 9186195.
-- Aggregate only.
-- 1. Receivers that are contracts, what they received, and sUSDe sent on by any receiver within 3 days of a
--    withdrawal (transfers out, leaving aside burns, the sUSDe contract and the Morpho contract).
-- 2. USDe the receivers claimed from Ethena's unstake silo, and USDe they sold on a DEX within 3 days of a claim.
-- Every match is by address and capped at what the address received or claimed. The caps overlap: the same
-- address can unstake and send on sUSDe it got elsewhere, so the shares do not add up and none is coin tracing.
-- A DEX sale is matched on the transaction sender, so a sale sent by another address is not seen.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH w_ev AS (
    SELECT receiver AS addr, evt_block_time AS t, CAST(assets AS double) / 1e18 AS amt
    FROM morpho_blue_ethereum.morphoblue_evt_withdrawcollateral
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
w AS (SELECT addr, sum(amt) AS w FROM w_ev GROUP BY 1),
contracts AS (SELECT DISTINCT address FROM ethereum.creation_traces WHERE block_time < TIMESTAMP '2026-11-24 00:00:00' AND address IN (SELECT addr FROM w)),
-- unstake requests by the receivers within 3 days of a withdrawal (same rule as query 10)
c_ev AS (
    SELECT e.owner AS addr, e.evt_block_time AS t, CAST(e.shares AS double) / 1e18 AS amt
    FROM ethena_labs_ethereum.stakedusdev2_evt_withdraw e JOIN w ON w.addr = e.owner
    WHERE e.evt_block_date >= DATE '2025-12-01' AND e.evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
),
c3 AS (
    SELECT c.addr, sum(c.amt) AS c3 FROM (
        SELECT c.addr, c.t, c.amt, date_diff('second', max(x.t), c.t) / 86400.0 AS gap
        FROM c_ev c JOIN w_ev x ON x.addr = c.addr AND x.t <= c.t GROUP BY 1, 2, 3) c
    WHERE gap <= 3 GROUP BY 1
),
-- sUSDe sent on by the receiver within 3 days of a withdrawal, not to the sUSDe contract or the zero address
fwd AS (
    SELECT t.addr, sum(t.amt) AS f3 FROM (
        SELECT tr."from" AS addr, tr.evt_block_time AS t, CAST(tr.value AS double) / 1e18 AS amt,
               date_diff('second', max(x.t), tr.evt_block_time) / 86400.0 AS gap
        FROM erc20_ethereum.evt_transfer tr JOIN w_ev x ON x.addr = tr."from" AND x.t <= tr.evt_block_time
        WHERE tr.contract_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497 AND tr.evt_block_date >= DATE '2025-12-01' AND tr.evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
          AND tr."to" NOT IN (0x0000000000000000000000000000000000000000, 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497,
                              0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb)
        GROUP BY 1, 2, 3) t
    WHERE gap <= 3 GROUP BY 1
),
-- USDe claimed from the unstake silo by the receivers, and USDe they sold on a DEX within 3 days after a claim
claim AS (
    SELECT "to" AS addr, evt_block_time AS t, CAST(value AS double) / 1e18 AS amt
    FROM erc20_ethereum.evt_transfer
    WHERE contract_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 AND evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND "from" = 0x7fc7c91d556b400afa565013e3f32055a0713425 AND "to" IN (SELECT addr FROM w)
),
cl AS (SELECT addr, sum(amt) AS claimed FROM claim GROUP BY 1),
sold AS (
    SELECT s.addr, sum(s.amt) AS sold3 FROM (
        SELECT d.tx_from AS addr, d.block_time, d.tx_hash, d.evt_index, d.token_sold_amount AS amt,
               date_diff('second', max(k.t), d.block_time) / 86400.0 AS gap
        FROM dex.trades d JOIN claim k ON k.addr = d.tx_from AND k.t <= d.block_time
        WHERE d.blockchain = 'ethereum' AND d.block_date >= DATE '2025-12-01' AND d.block_time < TIMESTAMP '2026-11-24 00:00:00'
          AND d.token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3
        GROUP BY 1, 2, 3, 4, 5) s
    WHERE gap <= 3 GROUP BY 1
)
SELECT count(*) AS receivers,
       count(k.address) AS receivers_that_are_contracts,
       round(sum(w.w) / 1e6, 1) AS withdrawn_m,
       round(sum(CASE WHEN k.address IS NOT NULL THEN w.w END) / 1e6, 1) AS withdrawn_to_contracts_m,
       round(sum(CASE WHEN k.address IS NOT NULL THEN least(w.w, coalesce(c3.c3, 0)) END) / 1e6, 1) AS contracts_unstake_within_3d_m,
       round(sum(CASE WHEN k.address IS NULL THEN least(w.w, coalesce(c3.c3, 0)) END) / 1e6, 1) AS wallets_unstake_within_3d_m,
       round(sum(least(w.w, coalesce(fwd.f3, 0))) / 1e6, 1) AS forwarded_within_3d_m,
       round(sum(CASE WHEN k.address IS NOT NULL THEN least(w.w, coalesce(fwd.f3, 0)) END) / 1e6, 1) AS contracts_forwarded_within_3d_m,
       round(sum(coalesce(cl.claimed, 0)) / 1e6, 1) AS usde_claimed_m,
       count(cl.addr) AS receivers_with_claim,
       round(sum(least(coalesce(cl.claimed, 0), coalesce(sold.sold3, 0))) / 1e6, 1) AS usde_sold_on_dex_within_3d_of_claim_m,
       count(sold.addr) AS receivers_selling_usde_within_3d
FROM w LEFT JOIN contracts k ON k.address = w.addr LEFT JOIN c3 ON c3.addr = w.addr LEFT JOIN fwd ON fwd.addr = w.addr
LEFT JOIN cl ON cl.addr = w.addr LEFT JOIN sold ON sold.addr = w.addr
