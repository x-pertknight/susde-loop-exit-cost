# Scorecard

Predictions are in `PREDICTIONS.md`. Values are in `data/results.json`. "Quoted" marks a figure that is a quote, not a trade.

| # | Prediction | Found | Result |
|---|---|---|---|
| A1 | Total borrowed 80M to 200M USD | 100M across four markets | held |
| A1 | 100 to 400 positions with more than 10k USD of debt | 29 | missed |
| A2 | Debt-weighted leverage 4x to 7x | 7.4x at the mean loan-to-value of the largest market | missed |
| A2 | Ten largest positions hold more than 60% of the debt | 94% | held |
| A3 | Debt-weighted median buffer 3 to 8 points | about 5 points (debt-weighted mean 5.0; the median comes from the unpublished rows and rounds to the same) | held |
| A3 | Less than 10% of the debt within 2 points of liquidation | about 2% | held |
| A4 | More than 60% of withdrawn collateral leaves with a flash loan or callback | Not testable. Callbacks leave no event. A Morpho flash loan event appears with 2% of the collateral, in the same transactions that hold a DEX sale. | not scored |
| B1 | 1M USD of sUSDe into USDC costs 5 to 20 bp | quoted 6 bp | held |
| B1 | 10M costs 30 to 100 bp | quoted 49% | missed |
| B1 | 50M costs 150 to 500 bp or gets no quote | quoted, at a loss of about 91% | missed |
| B2 | Unstaking takes 7 days and costs 15 to 25 bp | The unstake wait is 1 day since 16 March 2026 | missed |
| B3 | Largest hourly sUSDe discount on DEXs 50 to 300 bp | 72 bp | held |
| B3 | Fewer than 48 hours above 50 bp | 1 hour | held |
| C1 | Yield below the Morpho borrow rate in 25% to 45% of weeks | 4 of 45 weeks on hourly borrow rates (41 above). On one reading a day at 00:00 UTC, 2 of 45 | missed |
| C2 | Longest run of negative weeks 3 to 8 | 1, on either reading | missed |
| C3 | Debt falls 2% to 10% in negative weeks, flat or up to +5% in positive weeks | Four negative weeks on hourly rates, two on the daily reading. Not enough to compare. | not scored |

7 of 14 scored parts held. Two could not be scored.

What the misses say:

- A4 and B1 rested on one assumption: that a loop is closed by selling the collateral inside one transaction. Since January, 1.8% of the withdrawn collateral left with a DEX sale in the same transaction. A sale in a later transaction is not seen.
- B2 used a 7-day unstake wait from older write-ups. The contract says 1 day.
- C3 assumed that debt follows the carry. The debt fell from 163M to 21M between April and August 2026. On hourly rates three of the four negative weeks fall in that period: debt fell by 56 million in the one ending 18 May and rose in the other two. The other 15 weeks of the fall were positive.

The kill condition fired. `PREDICTIONS.md` says to stop below 50 positions, and A1 counts positions above 10k USD of debt. There are 29. The study continued because the debt condition held (100M USD against a floor of 20M) and because the question does not depend on the number of holders. No distribution of positions is reported, only counts and shares.
