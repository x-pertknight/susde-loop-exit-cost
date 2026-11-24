# Predictions

Written 2026-11-23, before any data pull for this study.
Prior knowledge at the time of writing: one snapshot of the largest Morpho markets taken the same day for a different question. It showed the sUSDe / PYUSD market with about 94M USD borrowed, sUSDe yield 4.80% and a borrow rate of 3.86%. Nothing else in this file had been measured.

Terms
- Loop: sUSDe (or a Pendle PT on sUSDe) posted as collateral, a stablecoin borrowed against it, the loan used to buy more of the same collateral.
- LLTV: the loan-to-value ratio at which a Morpho position can be liquidated.
- Buffer: LLTV minus the current loan-to-value of a position, in percentage points.
- Redemption value: what one sUSDe is worth if unstaked through Ethena at the contract exchange rate, with USDe counted at 1 USD.
- bp: basis point, 0.01%.

## A. Population (Morpho on Ethereum, sUSDe and PT-sUSDe collateral, aggregate only)
- A1. Total borrowed: 80M to 200M USD. Positions with more than 10k USD of debt: 100 to 400.
- A2. Debt-weighted mean leverage: 4x to 7x. The ten largest positions hold more than 60% of the debt.
- A3. Debt-weighted median buffer: 3 to 8 points. Less than 10% of the debt sits within 2 points of liquidation.
- A4. Of the collateral withdrawn from these markets in the last 90 days, more than 60% left in a transaction that also contains a flash loan or a Morpho callback.

## B. Exit cost
- B1. Selling sUSDe for USDC today, best quote against redemption value: 1M USD costs 5 to 20 bp, 10M costs 30 to 100 bp, 50M costs 150 to 500 bp or gets no quote.
- B2. The 7-day unstake costs about one week of borrow interest plus one week without yield, 15 to 25 bp of the position. So selling is cheaper below a size between 2M and 10M USD and unstaking is cheaper above it.
- B3. Largest hourly on-chain discount of sUSDe to redemption value since 2025-10-01: 50 to 300 bp. Fewer than 48 hours with a discount above 50 bp.

## C. Carry break-even
- C1. Weekly sUSDe yield minus the borrow rate of the largest sUSDe market on Morpho was negative in 25% to 45% of the last 52 weeks.
- C2. Longest run of negative weeks: 3 to 8.
- C3. In negative weeks the debt in these markets fell (median weekly change between -2% and -10%). In positive weeks it rose or stayed flat (0% to +5%).

## Kill condition
Stop and report a killed study if either holds:
- fewer than 50 positions or less than 20M USD of debt in sUSDe-type collateral on Morpho Ethereum, or
- no executable quote for 1M USD of sUSDe from at least two independent sources.
