-- Stricter version of query 10. Public Dune query: https://dune.com/queries/9186420
-- Each cooldown request (an unstake) is assigned to the day of the latest withdrawal to the same address
-- before it. The matched amount is capped at what the address received on that day, not over its whole life.
-- Same limits as query 10: addresses are matched, not coins.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH w_ev AS (
    SELECT receiver AS addr, evt_block_time AS t, CAST(assets AS double) / 1e18 AS amt
    FROM morpho_blue_ethereum.morphoblue_evt_withdrawcollateral
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
w_day AS (SELECT addr, date_trunc('day', t) AS d, sum(amt) AS w FROM w_ev GROUP BY 1, 2),
c_ev AS (
    SELECT e.owner AS addr, e.evt_block_time AS t, CAST(e.shares AS double) / 1e18 AS amt
    FROM ethena_labs_ethereum.stakedusdev2_evt_withdraw e
    WHERE e.evt_block_date >= DATE '2025-12-01' AND e.evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND e.owner IN (SELECT addr FROM w_ev)
),
c_gap AS (
    SELECT c.addr, c.t, c.amt, max(x.t) AS last_w
    FROM c_ev c JOIN w_ev x ON x.addr = c.addr AND x.t <= c.t
    GROUP BY 1, 2, 3
),
c_day AS (
    SELECT addr, date_trunc('day', last_w) AS d,
           sum(CASE WHEN date_diff('second', last_w, t) <= 86400 THEN amt END) AS c1,
           sum(CASE WHEN date_diff('second', last_w, t) <= 3 * 86400 THEN amt END) AS c3
    FROM c_gap GROUP BY 1, 2
)
SELECT round(sum(w.w) / 1e6, 2) AS withdrawn_m,
       round(sum(least(w.w, coalesce(c.c1, 0))) / 1e6, 2) AS matched_within_1d_capped_per_day_m,
       round(sum(least(w.w, coalesce(c.c3, 0))) / 1e6, 2) AS matched_within_3d_capped_per_day_m
FROM w_day w LEFT JOIN c_day c ON c.addr = w.addr AND c.d = w.d
