-- Who withdrew PYUSD supply from the sUSDe / PYUSD market on Morpho in the two hours when utilization first
-- passed 99%: 18 April 2026 20:00 to 21:00 UTC and 11 May 2026 15:00 to 17:00 UTC. Dune query 9180633,
-- run there with one row per supplier; this version returns counts and amounts only.
-- Whether a supplier is a MetaMorpho vault was read on chain (name(), MORPHO(), curator()) and from the
-- Morpho API, because the decoded vault tables on Dune do not list every vault.
WITH win(label, a, b) AS (VALUES
    ('2026-04-18 20:00-21:00', TIMESTAMP '2026-04-18 20:00', TIMESTAMP '2026-04-18 21:00'),
    ('2026-05-11 15:00-17:00', TIMESTAMP '2026-05-11 15:00', TIMESTAMP '2026-05-11 17:00')),
ev AS (
    SELECT w.label, e.onBehalf AS addr, CAST(e.assets AS double) / 1e6 AS amt
    FROM morpho_blue_ethereum.morphoblue_evt_withdraw e JOIN win w ON e.evt_block_time >= w.a AND e.evt_block_time < w.b
    WHERE e.evt_block_date IN (DATE '2026-04-18', DATE '2026-05-11') AND e.id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
sup AS (
    SELECT w.label, sum(CAST(e.assets AS double)) / 1e6 AS amt
    FROM morpho_blue_ethereum.morphoblue_evt_supply e JOIN win w ON e.evt_block_time >= w.a AND e.evt_block_time < w.b
    WHERE e.evt_block_date IN (DATE '2026-04-18', DATE '2026-05-11') AND e.id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    GROUP BY 1
),
per AS (SELECT label, addr, sum(amt) AS amt FROM ev GROUP BY 1, 2),
contracts AS (SELECT DISTINCT address FROM ethereum.creation_traces WHERE address IN (SELECT addr FROM per))
SELECT p.label, count(*) AS withdrawing_suppliers, count(c.address) AS of_which_contracts,
       round(sum(p.amt) / 1e6, 2) AS withdrawn_m, round(max(p.amt) / 1e6, 2) AS largest_withdrawer_m,
       round(coalesce(max(s.amt), 0) / 1e6, 2) AS supplied_in_window_m
FROM per p LEFT JOIN contracts c ON c.address = p.addr LEFT JOIN sup s ON s.label = p.label
GROUP BY 1 ORDER BY 1
