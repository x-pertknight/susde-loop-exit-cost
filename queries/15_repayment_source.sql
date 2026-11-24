-- Where the PYUSD in repayments above 1 million came from, in aggregate. Dune query 9186210.
-- Each repayment transaction above 1M PYUSD gets one class, tested in this order:
--   1 a flash loan in the same transaction (Morpho, Aave v3, Balancer v2)
--   2 a swap into PYUSD in the same transaction, for at least half of the repaid amount
--   3 a borrow on another Morpho market or on Aave v3 in the same transaction
--   4 PYUSD received by the transaction sender or the position owner in the 24 hours before,
--     for at least 90% of the repaid amount, named by the largest kind of sender
--   5 none of these: held for more than 24 hours, or not seen
-- Limits: one class per transaction, by the largest source. PYUSD received in the 24 hours before two close
-- repayments counts for both. The payer is approximated by the transaction sender and the position owner.
-- "Unlabelled" is not traced further. Exchange labels come from Dune's cex.addresses and are incomplete.
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
flash AS (
    SELECT evt_tx_hash AS tx FROM morpho_blue_ethereum.morphoblue_evt_flashloan WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND evt_tx_hash IN (SELECT tx FROM big)
    UNION
    SELECT evt_tx_hash FROM aave_v3_ethereum.pool_evt_flashloan WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND evt_tx_hash IN (SELECT tx FROM big)
    UNION
    SELECT evt_tx_hash FROM balancer_v2_ethereum.vault_evt_flashloan WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND evt_tx_hash IN (SELECT tx FROM big)
),
swap AS (
    SELECT tx_hash AS tx, sum(token_bought_amount) AS pyusd_bought, max_by(token_sold_symbol, amount_usd) AS sold_symbol
    FROM dex.trades
    WHERE blockchain = 'ethereum' AND block_date >= DATE '2025-12-01' AND block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND token_bought_address = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8 AND tx_hash IN (SELECT tx FROM big)
    GROUP BY 1
),
borrow_same_tx AS (
    SELECT evt_tx_hash AS tx FROM morpho_blue_ethereum.morphoblue_evt_borrow
    WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND id <> 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5 AND evt_tx_hash IN (SELECT tx FROM big)
    UNION
    SELECT evt_tx_hash FROM aave_v3_ethereum.pool_evt_borrow WHERE evt_block_date >= DATE '2025-12-01' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND evt_tx_hash IN (SELECT tx FROM big)
),
tr AS (
    SELECT evt_block_time AS bt, "from" AS src, "to" AS dst, CAST(value AS double) / 1e6 AS amount
    FROM erc20_ethereum.evt_transfer
    WHERE contract_address = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8 AND evt_block_date >= DATE '2025-11-30' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND "to" IN (SELECT a FROM payer_set)
),
-- PYUSD that reached the payer in the 24 hours before the repayment, by kind of sender
inflow AS (
    SELECT p.tx,
           sum(CASE WHEN tr.src = 0x0000000000000000000000000000000000000000 THEN tr.amount END) AS from_mint,
           sum(CASE WHEN c.address IS NOT NULL THEN tr.amount END) AS from_cex,
           sum(CASE WHEN c.address IS NULL AND m.a IS NOT NULL THEN tr.amount END) AS from_market_address,
           sum(CASE WHEN c.address IS NULL AND m.a IS NULL AND tr.src <> 0x0000000000000000000000000000000000000000 THEN tr.amount END) AS from_other
    FROM payers p
    JOIN tr ON tr.dst = p.a AND tr.bt < p.t AND tr.bt >= p.t - INTERVAL '24' hour
    LEFT JOIN (SELECT DISTINCT address FROM cex.addresses WHERE blockchain = 'ethereum') c ON c.address = tr.src
    LEFT JOIN market_addr m ON m.a = tr.src
    WHERE tr.src NOT IN (SELECT a FROM payers p2 WHERE p2.tx = p.tx)
    GROUP BY 1
),
cls AS (
    SELECT b.tx, b.pyusd,
           CASE WHEN f.tx IS NOT NULL THEN '1 flash loan in the same transaction'
                WHEN s.tx IS NOT NULL AND s.pyusd_bought >= 0.5 * b.pyusd THEN '2 swap into PYUSD in the same transaction, from ' || coalesce(s.sold_symbol, 'unknown')
                WHEN bs.tx IS NOT NULL THEN '3 borrow on another market in the same transaction'
                WHEN coalesce(i.from_mint, 0) + coalesce(i.from_cex, 0) + coalesce(i.from_market_address, 0) + coalesce(i.from_other, 0) >= 0.9 * b.pyusd THEN
                     CASE greatest(coalesce(i.from_mint, 0), coalesce(i.from_cex, 0), coalesce(i.from_market_address, 0), coalesce(i.from_other, 0))
                          WHEN coalesce(i.from_mint, 0) THEN '4a received within 24h, newly issued PYUSD'
                          WHEN coalesce(i.from_cex, 0) THEN '4b received within 24h, from a labelled exchange'
                          WHEN coalesce(i.from_market_address, 0) THEN '4c received within 24h, from another address active in this market'
                          ELSE '4d received within 24h, from an unlabelled address' END
                ELSE '5 held for more than 24h, or not seen' END AS source
    FROM big b
    LEFT JOIN (SELECT DISTINCT tx FROM flash) f ON f.tx = b.tx LEFT JOIN swap s ON s.tx = b.tx
    LEFT JOIN (SELECT DISTINCT tx FROM borrow_same_tx) bs ON bs.tx = b.tx LEFT JOIN inflow i ON i.tx = b.tx
)
SELECT source, count(*) AS txs, round(sum(pyusd) / 1e6, 1) AS pyusd_m,
       round(sum(pyusd) / sum(sum(pyusd)) OVER (), 3) AS share,
       round(sum(sum(pyusd)) OVER () / 1e6, 1) AS total_m,
       (SELECT round(sum(pyusd) / 1e6, 1) FROM rep) AS all_repayments_m
FROM cls GROUP BY 1 ORDER BY 1
