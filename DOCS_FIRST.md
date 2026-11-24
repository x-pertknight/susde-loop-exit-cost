# Docs first

What the documentation states, and what had to be measured. Read 2026-11-23. Each line gives its source.

## Ethena (USDe, sUSDe)

Documented
- Unstaking is a two-step process. The holder requests the unstake, the USDe is moved to a silo contract, and it can be withdrawn after a cooldown. Source: docs.ethena.fi/solution-design/staking-usde
- The length of the unstake wait (the contract calls it the cooldown) is set by the contract admin, up to a maximum of 90 days. Source: docs.ethena.fi/solution-design/staking-usde/staking-key-functions
- Rewards are paid into sUSDe every 8 hours and vest linearly over 8 hours. Rewards are positive or zero. Same page.
- Redeeming USDe for collateral is limited to whitelisted addresses that passed KYC. Source: docs.ethena.fi/resources/faq
- A reserve fund covers periods of negative protocol revenue. Source: docs.ethena.fi/solution-design/reserve-fund

Read from the chain, not from the docs
- `cooldownDuration()` on the sUSDe contract returned 86400 seconds (1 day) on 2026-11-23. Older write-ups, and the DefiLlama pool label, still say 7 days.

Not documented
- The rule that decides when the unstake wait is lengthened. A risk note on the Aave forum warns that an extension during stress would widen discounts, and that requests already made keep their end time. Source: governance.aave.com/t/llamarisk-insights-ethena-susde-dynamic-cooldown/24305
- Whether yield accrues during the unstake wait. The mechanism (a fixed USDe amount parked in the silo) implies it does not. Inference.
- Minimum redemption size and explicit redemption fee.

## Morpho

Documented
- A position can be liquidated when its loan-to-value passes the market LLTV. The liquidator bonus is min(1.15, 1 / (0.3 x LLTV + 0.7)). At an LLTV of 91.5% that is about 2.6%. Liquidators may repay up to 100% of the debt. Source: docs.morpho.org/learn/concepts/liquidation
- Bad debt is taken from lenders when a position has no collateral left. Source: Morpho.sol
- Interest rate model: target utilization 90%. Above target the rate at target rises, doubling in 5 days at 100% utilization. Maximum rate 800%. Source: morpho-blue-irm ConstantsLib.sol and docs.morpho.org/learn/concepts/irm
- Flash loans cost nothing. Callbacks let a position be opened or closed in one transaction. Source: docs.morpho.org/get-started/resources/contracts/morpho
- A market's oracle cannot be changed after deployment. Source: docs.morpho.org/learn/concepts/oracle

Read from the API, not from the docs
- The sUSDe / PYUSD market (LLTV 91.5%) uses an oracle built from three inputs, read from the oracle contract on 2026-11-23 (code/read_oracle.py): the sUSDe vault rate, the Chainlink USDe / USD feed and the Chainlink PYUSD / USD feed. So the market price of sUSDe does not enter. A fall of the USDe / USD feed does, and moves every position toward liquidation.
- The two sUSDe / DAI markets use the vault rate only, which treats 1 USDe as 1 DAI. Inference from the oracle configuration.

## Aave v3 (Ethereum)

Documented or read from the Aave API
- sUSDe in the "sUSDe Stablecoins" efficiency mode: maximum loan-to-value 90%, liquidation threshold 92%, liquidation penalty 4%. Supply cap 230M sUSDe.
- Aave prices USDe with the USDT price feed and sUSDe with the sUSDe exchange rate, capped by an adapter, times USDT. Source: governance.aave.com/t/arfc-susde-and-usde-price-feed-update/20495
- Every PT-sUSDe reserve listed on Aave is frozen. No live PT-sUSDe reserve was found.
- Flash loan fee 0.05% at deployment, changeable by governance. Current value not checked.

## Must be measured
1. Who holds sUSDe loops on Morpho, how levered, how far from liquidation.
2. What it costs to sell sUSDe for a dollar stablecoin at each size.
3. How often the sUSDe yield was below the borrow rate.
4. What happened to sUSDe pricing on-chain in past stress.

## Outside this study
- Loop positions on Aave. They need a per-account balance reconstruction that was not done.
- Sales through private quotes or market makers. Only public on-chain routes are quoted.
