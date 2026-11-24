-- Daily summary of the hourly on-chain price of sUSDe against its unstake value, and of USDe against USDC/USDT.
-- sUSDe unstake rate: USDe per sUSDe, taken from deposits and withdrawals of the staking vault.
-- Discount of sUSDe = 1 - (USDe received per sUSDe sold on a DEX) / (unstake rate).
-- Cutoff: only events before 2026-11-24 00:00:00 UTC are read, so a rerun gives the saved result.
WITH rate_events AS (
    SELECT evt_block_time AS t, CAST(assets AS double) / CAST(shares AS double) AS rate
    FROM ethena_labs_ethereum.stakedusdev2_evt_deposit
    WHERE evt_block_date >= DATE '2025-09-25' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND shares > UINT256 '1000000000000000000000'
    UNION ALL
    SELECT evt_block_time, CAST(assets AS double) / CAST(shares AS double)
    FROM ethena_labs_ethereum.stakedusdev2_evt_withdraw
    WHERE evt_block_date >= DATE '2025-09-25' AND evt_block_time < TIMESTAMP '2026-11-24 00:00:00' AND shares > UINT256 '1000000000000000000000'
),
rate_hourly AS (
    SELECT CAST(date_trunc('hour', t) AS timestamp) AS hour, max(rate) AS rate FROM rate_events GROUP BY 1
),
hours AS (
    -- sequence() is capped at 10,000 entries, so build days and cross them with 24 hours
    SELECT d + n * INTERVAL '1' hour AS hour
    FROM unnest(sequence(TIMESTAMP '2025-10-01 00:00', TIMESTAMP '2026-11-23 00:00', INTERVAL '1' day)) AS s(d)
    CROSS JOIN unnest(sequence(0, 23)) AS t(n)
),
rate_filled AS (
    -- carry the last known rate forward to hours without a deposit or withdrawal
    SELECT h.hour, max_by(r.rate, r.hour) AS rate
    FROM hours h JOIN rate_hourly r ON r.hour <= h.hour AND r.hour > h.hour - INTERVAL '7' day
    GROUP BY 1
),
susde_trades AS (
    SELECT CAST(date_trunc('hour', block_time) AS timestamp) AS hour,
           CASE WHEN token_sold_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
                THEN token_sold_amount ELSE token_bought_amount END AS susde,
           CASE WHEN token_sold_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
                THEN token_bought_amount ELSE token_sold_amount END AS usde
    FROM dex.trades
    WHERE blockchain = 'ethereum' AND block_date >= DATE '2025-10-01' AND block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND ((token_sold_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497 AND token_bought_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3)
        OR (token_bought_address = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497 AND token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3))
      AND token_sold_amount > 1000 AND token_bought_amount > 1000
),
usde_trades AS (
    SELECT CAST(date_trunc('hour', block_time) AS timestamp) AS hour,
           CASE WHEN token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3
                THEN token_sold_amount ELSE token_bought_amount END AS usde,
           CASE WHEN token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3
                THEN token_bought_amount ELSE token_sold_amount END AS stable
    FROM dex.trades
    WHERE blockchain = 'ethereum' AND block_date >= DATE '2025-10-01' AND block_time < TIMESTAMP '2026-11-24 00:00:00'
      AND ((token_sold_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 AND token_bought_address IN (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0xdAC17F958D2ee523a2206206994597C13D831ec7))
        OR (token_bought_address = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 AND token_sold_address IN (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 0xdAC17F958D2ee523a2206206994597C13D831ec7)))
      AND token_sold_amount > 1000 AND token_bought_amount > 1000
      -- Uniswap v2 pools are left out of the USDe price for the whole period. On 2026-10-30, 00:00 to 03:00 UTC,
      -- one v2 pool printed 0.64-0.69 USD on 18.5M USDe of volume while Curve and Uniswap v4 stayed near 0.998
      -- (queries/05_usde_20261030_by_venue.sql). What that pool is was not established.
      AND NOT (project = 'uniswap' AND version = '2')
),
-- Hourly price = volume-weighted MEDIAN trade price. A plain average is distorted by a few sandwich trades at 0.30 or 0.03.
s AS (SELECT hour, approx_percentile(usde / susde, usde, 0.5) AS usde_per_susde, approx_percentile(usde / susde, usde, 0.1) AS susde_p10, sum(usde) AS susde_volume_usde, count(*) AS susde_trades FROM susde_trades GROUP BY 1),
u AS (SELECT hour, approx_percentile(stable / usde, usde, 0.5) AS usd_per_usde, approx_percentile(stable / usde, usde, 0.1) AS usde_p10, sum(usde) AS usde_volume, count(*) AS usde_trades FROM usde_trades GROUP BY 1),
hourly AS (
    SELECT h.hour, s.susde_volume_usde, u.usde_volume,
           (1 - s.usde_per_susde / r.rate) * 10000 AS susde_discount_bp,
           (1 - u.usd_per_usde) * 10000 AS usde_discount_bp,
           (1 - s.susde_p10 / r.rate) * 10000 AS susde_tail_bp,   -- price of the worst 10% of volume
           (1 - u.usde_p10) * 10000 AS usde_tail_bp
    FROM hours h
    LEFT JOIN rate_filled r ON r.hour = h.hour
    LEFT JOIN s ON s.hour = h.hour AND s.susde_volume_usde >= 50000   -- ignore thin hours
    LEFT JOIN u ON u.hour = h.hour AND u.usde_volume >= 50000
)
-- One row per day: worst hourly discount and traded volume, for sUSDe (against unstake value) and USDe (against 1 USD).
SELECT CAST(date_trunc('day', hour) AS date) AS day,
       round(max(susde_discount_bp), 1) AS susde_worst_bp,
       round(sum(susde_discount_bp * susde_volume_usde) / sum(susde_volume_usde), 1) AS susde_avg_bp,
       round(sum(susde_volume_usde) / 1e6, 2) AS susde_volume_m,
       count_if(susde_discount_bp > 50) AS susde_hours_over_50bp,
       round(max(susde_tail_bp), 1) AS susde_worst_tail_bp,
       round(max(usde_discount_bp), 1) AS usde_worst_bp,
       round(max(usde_tail_bp), 1) AS usde_worst_tail_bp,
       round(sum(usde_volume) / 1e6, 2) AS usde_volume_m,
       count_if(usde_discount_bp > 50) AS usde_hours_over_50bp
FROM hourly
GROUP BY 1 ORDER BY 1
