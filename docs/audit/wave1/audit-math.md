# Wave 1 Audit Report: Numerical Correctness
Auditor: audit-math (internal specialist) | Date: 2026-07-23 | Scope: all settlement/fee/oracle/casino math

## Summary
Every settlement, fee, oracle, and casino formula re-derived from first principles and traced line by line for rounding direction and overflow headroom across Market.sol, the full oracle layer (OracleRouter, all five adapters, vendored TickMath/FullMath, UniV3TwapLib), and casino (PitPoints, SpinVRF, Jackpot). NO correctness defects at CRITICAL/HIGH/MEDIUM/LOW. Settlement conservation is exact by construction (algebraic, independent of rounding); entry-fee NET convention balances escrow to the wei; every cross-scale conversion dimensionally consistent; every dangerous multiplication is 512-bit (FullMath.mulDiv) or provably within uint256 given MAX_SOURCE_PRICE=1e36 and NOTIONAL_CAP=1e38. Verified against live suite (settlement fuzz 4 properties x 2000 runs, 108 oracle tests, 100 casino tests, green).

## Findings (all INFO)

### INFO-1: Settlement fuzz collateral domain stops at 1e30, uint128-max corner unexercised
Location: test/core/SettlementFuzz.t.sol:18 (MAX_COLLATERAL=1e30); exercises Market.sol:398-402, 523-561, 640-647.
Brief asked for "collateral near uint128 max"; fuzz stops ~8 orders below type(uint128).max. Verified safe by hand at 2^128-1: feePerSide~3.40e36 (fits uint128), notional~3.37e39 (uint256), mulDiv peaks ~3.37e75 (<uint256 max, 512-bit anyway), OI check ~6.7e50. Region economically unreachable (~3.4e32 USDG). Fix: raise MAX_COLLATERAL toward uint128 max or document the ceiling as deliberate.

### INFO-2 (refuted for reachable paths): PythAdapter can return ok=true with price1e18=0
Location: oracle/adapters/PythAdapter.sol:58-65. With expo near -30, small mantissa floors to 0 while ok=true. Neutralized: OracleRouter._evaluate drops `p==0 || p>MAX_SOURCE_PRICE` (OracleRouter.sol:479), test-confirmed; no path reads an adapter directly. Optional hardening: return ok=false when scaled==0.

### INFO-3 (theoretical): unbounded totalPoints / per-epoch cumulative use checked arithmetic
Location: casino/PitPoints.sol:503, 507-508. No clamp, so astronomical accrual would revert on overflow, nominally breaking never-revert. Needs ~7.7e18 max-size mints, unreachable; every mint needs a real entry fee upstream; per-epoch cumulative resets every 7 days. Not exploitable.

## SOLID (re-derived and confirmed)
- Entry fee capped at 1% of fill, uint128 cast in range, dust gate reverts, escrow balances to 2*effectiveCollateral.
- PnL mulDiv floors (favors loser, conservation-neutral), clamp correct, absMove>=entry early branch correct.
- fee = min(notional*70/10000, pnl) floors and bounded by pnl; winnerPayout>=collateralEach, loserPayout>=0.
- Conservation winner+loser+fee == 2*collateralEach exact, independent of rounding (algebraic + 2000-run fuzz).
- Fee split 40/40/20 round-down, dust to treasury, sums exactly; two independent flooring events modeled.
- OI accounting cannot underflow; unit-consistent native-to-1e18; overflow-free.
- UniV3TwapLib mean-tick rounds toward negative infinity like Uniswap; quoteAtTick matches getQuoteAtTick both branches/orientations; TickMath/FullMath canonical unchanged.
- Adapter normalization to 1e18 correct (Chainlink 0..30 dec, Pyth shift bounded); two-hop product renormalizes correctly; extreme-tick overflow reverts inside router per-source try/catch (source dropped).
- Router median, deviation guard, fallback all correct; 1e36 cap keeps entryPrice1e18 in uint128.
- Casino: base points peak 1e49, multiplier stacking peak ~7.5e57, spin bonus peak ~7.4e51, threshold table 60/25/10/4/1, modulo bias ~1e-73, loss rebate 25%, creator 5% depth-1, weighted selection binary search correct; jackpot 10%/50% floored with dust retained.
- Fuzz-domain adequacy: multiple/price domains full; one gap = collateral ceiling 1e30 (INFO-1, hand-verified safe).

## Counts
CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 0 | INFO: 3
