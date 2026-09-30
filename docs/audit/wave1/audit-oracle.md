# Wave 1 Audit Report: Oracle Manipulation Economics and Price-Path Correctness
Auditor: audit-oracle (internal specialist) | Date: 2026-07-23 | Scope: oracle/* + consuming paths in core/

## Summary
Oracle math is correct and well fuzzed (median, deviation guard, TWAP rounding, decimal normalization, 1e36 discipline) and there is no admin price-injection path. The problem is the economic premise, not the math. The router's stated invariant is "median of >= 3 fresh, independent, mutually agreeing sources." For Tier B memecoins on Robinhood Chain, independence is a fiction: no Chainlink/Pyth feed exists for any memecoin (only ETH/USD and USDG/USD; Pyth not deployed), so all three sources are TWAPs read from the token's single Uniswap v3 pool. Moving that one pool moves all three sources in lockstep; the deviation guard stays near zero; the attacker sets the settlement price. The OI cap meant to bound damage is computed from a pool balance the attacker can inflate just-in-time. Attack clears cost ~40x under the single-arb assumption; bound is honest-counterparty collateral (~4.6% of tracked liquidity per cycle); no liquidity level fixes it since prize and manipulation both scale with L.

## CRITICAL

### C1. Tier B settlement price is directly attacker-controlled (3 same-pool TWAP sources = 1 source read 3 ways)
Location: OracleRouter.sol:465-505 (_evaluate), :215-225 (setSources enforces count>=3 only, nothing about independence/distinct pools); consumed Market.sol:493 (settle), :605 (entry). Adapters: TwoHopTwapAdapter, CrossPoolTwapAdapter, TwapAdapter over UniV3TwapLib.
- setSources checks count only, not pool/venue independence. On this chain the only non-pool primitives are ETH/USD and USDG/USD; no per-memecoin feed, no Pyth. A listable memecoin's 3 sources are necessarily TWAPs of the same TOKEN/WETH pool (FWA has exactly one pool).
- Deviation guard (highest-lowest)*10000 > devBps*lowest never trips under common-mode movement; median, 3-source min, fallback ring all defeated. Tier B band 2500 bps swallows drift.
- Economics: to clamp a winner at multiple 10 needs a 10% TWAP move. Prize = OI cap: _openInterest <= 0.10*L so sum(collateralEach) <= 0.05*L; max extraction ~0.046*L/cycle net of fees (~1,150 USD at 25K floor, ~11,500 at L=250K, linear, repeatable). Cost to move+hold TWAP under single-arb + attacker-LP assumption: <0.001*L (LP fees, returned if attacker is the LP). Ratio ~40:1, improving with L.
- The only real cost is external arbitrage draining the mispriced side: exactly the "attacker is the only arb" assumption a new-chain memecoin removes. Safe bound is a listing policy, not a code parameter.
Fixes: (1) do not list tokens whose price derives from a single non-externally-arbitraged pool; (2) require >= 1 source NOT a function of the settlement pool (no memecoin qualifies today, so no memecoin is listable safely with current adapters); (3) if pool-only listing must happen, cut MAX_MULTIPLE toward 1 and oiCapBps well below 1000 (raises bar, does not close it).
Refutation: survives as CRITICAL. Every mitigation premise (3-source min, expensive TWAP, deviation guard, OI cap) fails as shown.

## HIGH

### H1. trackedLiquidity reads pool ERC20 balance, inflatable with JIT single-sided liquidity, defeating OI cap and floor
Location: OracleRouter.sol:542-553 (_trackedLiquidity sums balanceOf(pool)*scale*2), :557-569; consumed at fill Market.sol:624-632. NatSpec at :392-401 wrongly claims inflation "requires parking real quote capital."
- Attacker mints a v3 position ranged entirely on one side, depositing only WETH (no token inventory). That WETH enters balanceOf(pool), doubling trackedLiquidity. Fully withdrawable next block, not capital at risk. OI cap and 40% floor are fill-time only (never re-checked at settle), so: create market with low real liquidity, same-block JIT-inflate 10x, open 10x intended OI, withdraw next block. Force multiplier on C1: prize rises toward 0.046*L_inflated.
Fix: use time-averaged in-range liquidity (pool.liquidity() over the TWAP window) or snapshot the OI-cap basis at creation; refuse live inflation. At minimum correct the NatSpec.
Refutation: survives as HIGH. Floor/cap fill-time only; removal unpunished; floor is 40% of the LOW creation snapshot.

## MEDIUM
- M1: Shared ETH/USD feed leg is a common-mode multiplier the deviation guard cannot see (TwoHopTwapAdapter.sol:110-133). A bad-but-positive in-window ETH/USD answer scales all sources identically; spread stays ~0; settles OK. 90000s staleness (>24h) vs 86400s heartbeat widens the window. Fix: >= 1 USD source not routed through ETH/USD; tighten feedMaxStaleness.
- M2: Fallback serves stale ring-median as OK; either-party settle timing makes it a free arb; forced-neutral-unwind is a bounded free option (OracleRouter.sol:323-358, Market.sol:488-520). Inducing fallback needs 90 min of >25% genuine disagreement (impossible for same-window same-pool sources, so moot exactly where C1 is strongest), but stale-print settle-timing arb is real whenever fallback is active for any reason. Fix: fallback carries distinct non-tradeable status or freshness stamp; require delay/both-party settle at fallback price.
- M3: CrossPoolTwapAdapter weights by instantaneous in-range liquidity, JIT-manipulable (CrossPoolTwapAdapter.sol:85-107). Moot with one pool; real for multi-pool tokens. Fix: time-average in-range liquidity over the window.

## LOW / INFO
- L1: setSources does not enforce/inspect source independence or distinct pools (:215-225); accepts duplicates and opaque adapters. Add distinct-address checks; document independence as listing policy.
- L2: Tier B deviation band 2500 bps so wide same-underlying TWAPs never trip it; reinforces C1.
- L3: snapshotLiquidity permissionless overwrite (:410-414) but each Market stores floor basis as immutable at creation, so re-snapshots cannot move an existing market's floor; snapshot gaming self-harms. Live-liquidity JIT (H1) is the real path.

## SOLID
No price-injection path; median math (odd middle, even average round-down, fuzzed n in [3,7]); deviation formula exact and overflow-free for bps[1,10000] prices[1,1e36]; TWAP mean-tick rounding matches Uniswap OracleLibrary, quoteAtTick X192/X128 split correct, TickMath/FullMath vendored unchanged; decimal normalization to 1e18 for USDG(1e12), 8-dec feeds(1e10), Pyth expo[-30,12]; OI cap scaling dimensionally correct; trackedLiquidity doubles QUOTE side only (token-leg skew blocked; broken feed zeroes contribution); single rogue source cannot escape honest band GIVEN two honest independent sources (premise fails for memecoins per C1); state machine integrity (permissionless, data+time driven, cooldown/failed-round/fallback/reset all correct, peekPrice non-mutating and predictive); adapters never revert on read, verified on live FWA/WETH pool and ETH/USD feed in fork suite.

## Counts
CRITICAL: 1 | HIGH: 1 | MEDIUM: 3 | LOW/INFO: 3

## Launch bottom line
C1 + H1 mean a Tier B memecoin listed with today's adapters has an attacker-set settlement price and an inflatable damage cap. The correct gate is a listing policy, not a parameter tweak: do not list any token lacking a price source independent of its settlement pool; treat "three TWAP sources over one pool" as one source for risk purposes.
