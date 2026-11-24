-- Timing of repayments against Ethena unstake requests, for positions that did both. Public Dune query: https://dune.com/queries/9186427
-- Aggregate only, shares by PYUSD repaid.
-- A position's addresses are its owner, the senders of its repayments and the receivers of its collateral.
-- An unstake request is a Withdraw event of the sUSDe contract (see query 10). Its USDe is counted as ready
-- 7 days after the request before 16 March 2026 and 1 day after from that date. The claim itself is not read.
-- For each repayment the query looks 10 days back and 7 days forward.
-- Limits: this matches addresses and times, not coins. USDe that was ready before a repayment is not shown
-- to have paid for it. A request after a repayment is not shown to be for the collateral that repayment freed.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH rep AS (
    SELECT evt_tx_hash AS tx, min(evt_block_time) AS t, min(evt_tx_from) AS sender, min(onBehalf) AS owner,
           sum(CAST(assets AS double)) / 1e6 AS pyusd
    FROM morpho_blue_ethereum.morphoblue_evt_repay
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    GROUP BY 1
),
-- addresses tied to a position: its owner, the senders of its repayments, the receivers of its collateral
grp AS (
    SELECT owner, owner AS a FROM rep
    UNION SELECT owner, sender FROM rep
    UNION SELECT onBehalf, receiver FROM morpho_blue_ethereum.morphoblue_evt_withdrawcollateral
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
-- unstake requests (cooldown starts) by those addresses. The wait was 7 days until 16 March 2026, 1 day after.
cd AS (
    SELECT DISTINCT g.owner, e.evt_tx_hash AS h, e.evt_block_time AS t,
           e.evt_block_time + CASE WHEN e.evt_block_time < TIMESTAMP '2026-03-16' THEN INTERVAL '7' day ELSE INTERVAL '1' day END AS ready
    FROM ethena_labs_ethereum.stakedusdev2_evt_withdraw e JOIN grp g ON g.a = e.owner
    WHERE e.evt_block_date >= DATE '2025-11-20' AND e.evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
),
both AS (SELECT DISTINCT owner FROM cd),
r AS (
    SELECT rep.tx, rep.pyusd,
           min(CASE WHEN cd.t >= rep.t THEN date_diff('second', rep.t, cd.t) END) / 3600.0 AS h_to_next_request,
           min(CASE WHEN cd.ready <= rep.t THEN date_diff('second', cd.ready, rep.t) END) / 3600.0 AS h_since_usde_ready,
           count_if(cd.h = rep.tx) AS same_tx,
           count_if(cd.t < rep.t AND cd.ready > rep.t) AS pending
    FROM rep JOIN both b ON b.owner = rep.owner
    LEFT JOIN cd ON cd.owner = rep.owner AND cd.t BETWEEN rep.t - INTERVAL '10' day AND rep.t + INTERVAL '7' day
    GROUP BY 1, 2
),
f AS (
    SELECT *, coalesce(h_since_usde_ready <= 72, false) AS ready_before,
           coalesce(h_to_next_request <= 72, false) AS request_after,
           CAST(greatest(pyusd, 1) AS bigint) AS wt
    FROM r
)
SELECT (SELECT count(*) FROM both) AS positions_with_repayment_and_unstake,
       (SELECT count(DISTINCT owner) FROM rep) AS positions_with_repayment,
       count(*) AS repayments,
       round(sum(pyusd) / 1e6, 1) AS repaid_m,
       round((SELECT sum(pyusd) FROM rep) / 1e6, 1) AS all_repaid_m,
       round(sum(CASE WHEN same_tx > 0 THEN pyusd END) / sum(pyusd), 3) AS share_request_in_same_tx,
       round(sum(CASE WHEN h_to_next_request <= 1 THEN pyusd END) / sum(pyusd), 3) AS share_request_within_1h_after,
       round(sum(CASE WHEN h_to_next_request <= 24 THEN pyusd END) / sum(pyusd), 3) AS share_request_within_24h_after,
       round(sum(CASE WHEN h_to_next_request <= 72 THEN pyusd END) / sum(pyusd), 3) AS share_request_within_3d_after,
       round(sum(CASE WHEN h_since_usde_ready <= 24 THEN pyusd END) / sum(pyusd), 3) AS share_usde_ready_within_24h_before,
       round(sum(CASE WHEN h_since_usde_ready <= 72 THEN pyusd END) / sum(pyusd), 3) AS share_usde_ready_within_3d_before,
       round(sum(CASE WHEN pending > 0 THEN pyusd END) / sum(pyusd), 3) AS share_with_request_pending_at_repayment,
       round(sum(CASE WHEN ready_before AND request_after THEN pyusd END) / sum(pyusd), 3) AS share_both_3d,
       round(sum(CASE WHEN ready_before AND NOT request_after THEN pyusd END) / sum(pyusd), 3) AS share_only_usde_ready_before_3d,
       round(sum(CASE WHEN NOT ready_before AND request_after THEN pyusd END) / sum(pyusd), 3) AS share_only_request_after_3d,
       round(sum(CASE WHEN NOT ready_before AND NOT request_after THEN pyusd END) / sum(pyusd), 3) AS share_neither_3d,
       round(approx_percentile(h_to_next_request, wt, 0.5), 2) AS median_hours_to_next_request_by_value,
       round(approx_percentile(h_since_usde_ready, wt, 0.5), 2) AS median_hours_since_usde_ready_by_value
FROM f
