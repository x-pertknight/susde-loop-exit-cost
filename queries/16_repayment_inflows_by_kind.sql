-- The PYUSD received in the 24 hours before each repayment above 1 million, by how it reached the payer.
-- Dune query 9186211. Aggregate only.
-- Each transfer is counted once: it goes to the first repayment its receiver made in the 24 hours after it.
-- A repayment is covered up to its own size, and the covered part is split across the kinds of transfer in
-- proportion to their amounts. What is left is "not covered".
-- A transfer gets the first kind that fits: minted to the payer, sent in a transaction that bought PYUSD on a
-- DEX, sent in a transaction with a borrow on Morpho or Aave v3, from a labelled exchange, from another
-- address active in this market, from an unlabelled contract, from an unlabelled wallet.
-- Limits: this goes one step back and no further, so the origin of the token paid on the DEX is not traced.
-- Kind 3 counts any borrow in the transaction, this market included, and does not check the borrowed asset.
-- The payer is the transaction sender and the position owner. A share is a share of money received, not
-- proof that those coins were the ones repaid. Exchange labels (Dune cex.addresses) are incomplete.
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
payer_set AS (SELECT DISTINCT a FROM payers),
market_addr AS (
    SELECT DISTINCT onBehalf AS a FROM morpho_blue_ethereum.morphoblue_evt_borrow
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
    UNION
    SELECT DISTINCT receiver FROM morpho_blue_ethereum.morphoblue_evt_withdrawcollateral
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id = 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
),
tr AS (
    SELECT evt_tx_hash AS h, evt_index AS ix, evt_block_time AS bt, "from" AS src, "to" AS dst, CAST(value AS double) / 1e6 AS amount
    FROM erc20_ethereum.evt_transfer
    WHERE contract_address = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8 AND evt_block_date >= DATE '2025-11-30' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND "to" IN (SELECT a FROM payer_set)
),
-- transactions that bought PYUSD on a DEX, with the token paid
buys AS (
    SELECT tx_hash AS h, max_by(token_sold_symbol, amount_usd) AS sold_symbol
    FROM dex.trades
    WHERE blockchain = 'ethereum' AND block_date >= DATE '2025-11-30' AND block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND token_bought_address = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8
    GROUP BY 1
),
-- transactions with any borrow on Morpho (any market, this one included) or on Aave v3 (any asset)
loans AS (
    SELECT evt_tx_hash AS h FROM morpho_blue_ethereum.morphoblue_evt_borrow WHERE evt_block_date >= DATE '2025-11-30' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
    UNION SELECT evt_tx_hash FROM aave_v3_ethereum.pool_evt_borrow WHERE evt_block_date >= DATE '2025-11-30' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
),
contracts AS (SELECT DISTINCT address FROM ethereum.creation_traces WHERE block_time < TIMESTAMP '2026-11-24 00:00:00' AND address IN (SELECT DISTINCT src FROM tr)),
-- each transfer goes to one repayment only: the first one by that payer in the 24 hours after it
cand AS (
    SELECT tr.h, tr.ix, tr.src, tr.amount, p.tx,
           row_number() OVER (PARTITION BY tr.h, tr.ix ORDER BY p.t, p.tx) AS rn
    FROM tr JOIN payers p ON tr.dst = p.a AND tr.bt < p.t AND tr.bt >= p.t - INTERVAL '24' hour
    WHERE tr.src NOT IN (SELECT a FROM payers p2 WHERE p2.tx = p.tx)
),
inflow AS (
    SELECT x.tx,
           CASE WHEN x.src = 0x0000000000000000000000000000000000000000 THEN '1 newly issued PYUSD (mint to the payer)'
                WHEN b.h IS NOT NULL THEN '2 bought on a DEX in an earlier transaction, paying ' || coalesce(b.sold_symbol, 'unknown')
                WHEN l.h IS NOT NULL THEN '3 received in a transaction with a borrow on Morpho or Aave'
                WHEN c.address IS NOT NULL THEN '4 from a labelled exchange'
                WHEN m.a IS NOT NULL THEN '5 from another address active in this market'
                WHEN k.address IS NOT NULL THEN '6 from an unlabelled contract'
                ELSE '7 from an unlabelled wallet' END AS kind,
           sum(x.amount) AS amount
    FROM cand x
    LEFT JOIN buys b ON b.h = x.h
    LEFT JOIN (SELECT DISTINCT h FROM loans) l ON l.h = x.h
    LEFT JOIN (SELECT DISTINCT address FROM cex.addresses WHERE blockchain = 'ethereum') c ON c.address = x.src
    LEFT JOIN market_addr m ON m.a = x.src
    LEFT JOIN contracts k ON k.address = x.src
    WHERE x.rn = 1
    GROUP BY 1, 2
),
tot AS (SELECT tx, sum(amount) AS total FROM inflow GROUP BY 1),
-- a repayment is covered up to its own size; the covered part is split by kind of inflow
parts AS (
    SELECT i.kind, i.tx, least(b.pyusd, t.total) * i.amount / t.total AS covered
    FROM inflow i JOIN tot t ON t.tx = i.tx JOIN big b ON b.tx = i.tx
    UNION ALL
    SELECT '8 not covered by PYUSD received in the 24 hours before' AS kind, b.tx, b.pyusd - least(b.pyusd, coalesce(t.total, 0))
    FROM big b LEFT JOIN tot t ON t.tx = b.tx
    WHERE b.pyusd - least(b.pyusd, coalesce(t.total, 0)) > 0
)
SELECT kind, count(DISTINCT tx) AS repayments_touched,
       round(sum(covered) / 1e6, 1) AS repaid_pyusd_m,
       round(sum(covered) / (SELECT sum(pyusd) FROM big), 3) AS share_of_repayments_over_1m,
       (SELECT count(*) FROM big) AS repayments_over_1m,
       (SELECT round(sum(pyusd) / 1e6, 1) FROM big) AS repaid_over_1m_m
FROM parts GROUP BY 1 ORDER BY 1
