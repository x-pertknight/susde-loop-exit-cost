-- How newly issued PYUSD reached the payers of repayments above 1 million. Public Dune query: https://dune.com/queries/9186426. Aggregate only.
-- A mint is a PYUSD transfer from the zero address. The query takes the mints that reached a payer in the
-- 24 hours before one of its repayments, counts who sent those transactions and which contract they called,
-- and then counts how many addresses the same transaction senders minted PYUSD to since December 2025.
-- Reading: a sender that mints to thousands of addresses is an issuance channel open to many users.
-- Limits: this does not name the channel and does not show what was paid for the PYUSD.
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH rep AS (
    SELECT evt_tx_hash AS tx, min(evt_block_time) AS t, min(evt_tx_from) AS sender, min(onBehalf) AS owner,
           sum(CAST(assets AS double)) / 1e6 AS pyusd
    FROM morpho_blue_ethereum.morphoblue_evt_repay
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    GROUP BY 1
),
big AS (SELECT * FROM rep WHERE pyusd > 1e6),
payers AS (SELECT tx, t, sender AS a FROM big UNION SELECT tx, t, owner FROM big),
-- every PYUSD mint since December 2025
mints AS (
    SELECT evt_tx_hash AS h, evt_index AS ix, evt_block_time AS bt, "to" AS dst, evt_tx_from AS minter, evt_tx_to AS called,
           CAST(value AS double) / 1e6 AS amount
    FROM erc20_ethereum.evt_transfer
    WHERE contract_address = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8 AND evt_block_date >= DATE '2025-11-30' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND "from" = 0x0000000000000000000000000000000000000000
),
-- mints that reached a payer in the 24 hours before one of its repayments above 1M, each counted once
ours AS (
    SELECT DISTINCT m.h, m.ix, m.dst, m.minter, m.called, m.amount
    FROM mints m JOIN payers p ON p.a = m.dst AND m.bt < p.t AND m.bt >= p.t - INTERVAL '24' hour
),
our_minters AS (SELECT DISTINCT minter FROM ours),
minter_all AS (
    SELECT count(DISTINCT dst) AS recipients_all, sum(amount) AS minted_all
    FROM mints WHERE minter IN (SELECT minter FROM our_minters)
),
contracts AS (SELECT DISTINCT address FROM ethereum.creation_traces WHERE block_time < TIMESTAMP '2026-11-24 00:00:00' AND address IN (SELECT dst FROM ours UNION SELECT minter FROM ours))
SELECT count(*) AS mints_to_payers,
       round(sum(o.amount) / 1e6, 1) AS minted_to_payers_m,
       count(DISTINCT o.dst) AS payer_addresses,
       count(DISTINCT CASE WHEN kd.address IS NOT NULL THEN o.dst END) AS payer_addresses_that_are_contracts,
       count(DISTINCT o.minter) AS distinct_tx_senders,
       count(DISTINCT CASE WHEN km.address IS NOT NULL THEN o.minter END) AS tx_senders_that_are_contracts,
       count(DISTINCT CASE WHEN o.minter = o.dst THEN o.h END) AS mints_sent_by_the_payer_itself,
       count(CASE WHEN o.called = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8 THEN 1 END) AS mints_by_direct_call_to_the_token,
       count(DISTINCT o.called) AS distinct_contracts_called,
       (SELECT recipients_all FROM minter_all) AS recipients_of_these_senders_all_mints,
       (SELECT round(minted_all / 1e6, 1) FROM minter_all) AS minted_by_these_senders_all_m,
       (SELECT round(sum(amount) / 1e6, 1) FROM mints) AS all_pyusd_minted_m,
       (SELECT count(DISTINCT minter) FROM mints) AS all_mint_tx_senders
FROM ours o
LEFT JOIN contracts kd ON kd.address = o.dst
LEFT JOIN contracts km ON km.address = o.minter
