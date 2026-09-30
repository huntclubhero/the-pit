# Static Analysis: Final Sweep | 2026-07-24

Fresh Slither + Aderyn run on the FULL merged v2 codebase (perp engine + economics 5-way fee split + vol-scaled borrow/EWMA + ADL rework + oracle + core + casino), plus a manual pattern sweep of the newest perp code. Cross-referenced against the wave-1 triage (docs/audit/wave1/slither-triage.md, 2026-07-23) so only NEW or still-open items are called out.

## Tooling

| Tool | Version | How run |
| --- | --- | --- |
| Slither | 0.11.5 | `slither . --config-file slither.config.json` from `contracts/` (same config CI uses: excludes lib/test/script/vendor, fail-on high) |
| Aderyn | 0.6.8 (x86_64-linux via WSL Ubuntu) | `aderyn .` from `contracts/`, all 88 detectors, 39 compiled files, solc 0.8.26 |
| solc | 0.8.26 | via forge build (clean; forge-lint typecast notes only, all annotated in-source) |

Both analyzers completed end-to-end. Raw outputs preserved in the session scratchpad (slither-fresh.json / slither-fresh.txt / aderyn-report.md).

## Totals

**Slither: 0 High, 90 Medium, 176 Low, 14 Informational** (82 contracts, 98 detectors, 280 results).
**Aderyn: 3 High, 16 Low** (88 detectors).

Wave-1 baseline was 0H / 28M / 48L / 7I on the pre-perp codebase; the growth is entirely the new perp module surface plus the casino/oracle repeats already triaged in wave 1.

## Aderyn High triage (all three: NOT vulnerabilities)

1. **H-1 "Incorrect use of caret operator" | src/oracle/vendor/FullMath.sol:89** : FALSE POSITIVE. `(3 * denominator) ^ 2` is the canonical Uniswap FullMath Newton-Raphson inverse seed; the xor IS the intent (vendored verbatim, path excluded from the Slither scope for the same reason).
2. **H-2 "State change after external call" (27 instances)** : FALSE POSITIVE class. Every instance is either (a) a constructor reading `decimals()` before setting immutables, (b) a read of a trusted protocol-owned contract (riskConfig / router / vault / pitPoints / guardian, all timelock-governed, no untrusted code path) before a state write, or (c) inside a `nonReentrant` external. Spot-checked the fund-relevant ones: PitVault.sol:591 (reservePayout reads `riskConfig.maxUtilizationBps()`, view on trusted config, nonReentrant), PerpEngine.sol:1525 (tripDrawdownCircuit reads own vault view then latches a bool; latch-only, no funds), InsuranceFund.sol:180 (governanceWithdraw snapshots own USDG balance, onlyOwner + nonReentrant). No untrusted callback exists between any aggregate read/write pair (the four-mutator discipline holds; USDG has no hooks).
3. **H-3 "Storage array edited with memory" | src/perp/PerpEngine.sol:1805** : FALSE POSITIVE. `_adlCloseVictim(token, vk, _positions[vk], ...)` passes the position as memory deliberately; the function never writes through the struct expecting persistence: deletion and aggregate updates go through the KEY (`_removePosition(key, ...)` + `_aggLiquidateFamily`) inside `_adlSettleVictim`. Verified line by line (PerpEngine.sol:1859-1910).

## Slither Medium triage (90)

New-code findings first; every class verdict below was re-checked against the actual v2 source, not carried blind.

### New (perp module) findings

- **divide-before-multiply (2)**:
  - `PerpEngine._adlScore` (PerpEngine.sol:1847-1852): true precision observation, ACCEPTED. The score is a pure RANKING heuristic (uPnL% x leverage) used only to order ADL victims; floor division can reorder near-ties by dust, never touches funds math. Overflow impossible in domain (pnl clamped to maxPayout, both uint128-bounded).
  - `MarginMathLib.liquidationPrice1e18` (MarginMathLib.sol:121): FALSE POSITIVE. `PRICE_SCALE / BPS_DENOM` is exactly 1e14; zero precision loss.
- **reentrancy-no-eth (perp: openPosition / increasePosition / liquidate / _prepareOpenFamily / _distributeFee)**: FALSE POSITIVE class, same reasoning as wave 1: Slither does not model `nonReentrant`; every flagged path is nonReentrant with strict CEI, calls only trusted immutables (vault, insuranceFund, riskConfig, router, points via try/catch, hookless USDG). The `_payFee -> this.pushFee` self-call is the intentional credit-on-failure armor.
- **uninitialized-local (perp: emptyPos / flows / ctx / fundingDelta / borrowDelta / adlAbsorbed, 13 instances)**: FALSE POSITIVE. All are deliberate zero-initialized structs/accumulators (emptyPos IS the zero sentinel for the delta applier; flows/ctx are filled field-by-field before use).
- **incorrect-equality (perp: ~15 instances in _openCore, _computeIncrease, _computeReduce, _payFee, _updateVolRef, _realizedVolBps, _adl*, _previewMark/Indices, _applyPositionDelta, PitVault.deposit/_settleEpoch, InsuranceFund.govWithdrawAvailable)**: FALSE POSITIVE class. All intentional `== 0` sentinels (empty position, zero-fee skip, unseeded EWMA reference, zero-delta skip, first-deposit detection, unopened gov window).
- **unused-return (perp: _openCore, listMarket, _recentDeviationBps, _removePosition, liquidatable)**: FALSE POSITIVE. EnumerableSet add/remove bools ignored by design (idempotent bookkeeping), and partial tuple destructuring of `router.tierConfigOf` (only `spotSource` / `tier` legs consumed).

### Carried from wave 1 (unchanged verdicts)

- **pyth-unchecked-confidence + pyth-unchecked-publishtime (2, PythAdapter.read)**: GENUINE hardening item, still DORMANT (Pyth not deployed on Robinhood Chain; adapter unwired). Remains the standing pre-condition: add confidence + publishTime checks before any Pyth wiring. Carried forward again.
- **incorrect-equality / timestamp-family / uninitialized-local / unused-return in casino + oracle + core**: identical instances to wave 1, verdicts unchanged (benign by design).
- **reentrancy-no-eth (Market.fillOffer/settle, MarketFactory.createMarket, Jackpot.collectFees)**: wave-1 false positives, unchanged.

### Low + Informational

- **calls-loop (78)**: dominated by `PitVault.aggTraderUnrealizedPnl` / `navMarkStale` (per-market engine + router view reads) and OracleRouter adapter fan-out. ACCEPTED: market count grows only via owner-timelocked `listMarket`; loop is view-only trusted calls; the fund-moving loops are hard-bounded (below).
- **timestamp (74)**: intentional time logic (epochs, ramps, EWMA dt, drawdown window, cooldowns). Benign.
- **missing-zero-check (1, PitPoints.setRegistrar)**: wave-1 by-design (zero disables registrar).
- **missing-inheritance (8, Informational)**: cosmetic, wave-1 carry.
- Aderyn Lows: all style-level (nonReentrant modifier ordering: no other modifier on those functions can reenter, onlyEngine/onlyOwner are pure checks; PUSH0 in vendor pragma; literals; internal-fn-once). No action.

## Manual pattern sweep (newest code focus)

- **Unchecked external calls / raw call/delegatecall/transfer/send**: NONE in perp/core/oracle (grep clean; SafeERC20 everywhere; the only try/catch wrappers are the intentional best-effort surfaces: points hooks, insuranceFund.cover/payKeeperFloor, spot read, pushFee).
- **Zero-address checks**: PerpEngine constructor checks all 11 addresses and asserts `feeSplit_.vault == vault_` (the A1 misroute guard); PitVault.setEngine / InsuranceFund.setEngine/setVault are set-once with zero checks; no unchecked address setters found.
- **Unbounded loops**: ADL is hard-bounded (MAX_ADL_SCAN 256 keys, MAX_ADL_VICTIMS 32, selection loop <= 256x32 memory scans; PerpEngine.sol:79-81, 1787-1814). PitVault `_resolve` roll-chain walk terminates (every roll targets a strictly later epoch, progress persisted). NAV market loop bounded by owner-gated listings (accepted, documented above).
- **Reentrancy guards on fund-touching externals**: verified complete. PerpEngine: all 8 trading/keeper externals + withdrawCredit are nonReentrant (12 total). PitVault: deposit, requestWithdraw, claim, settleEpoch and the entire 7-function engine-only counterparty surface are nonReentrant (12 total). InsuranceFund: all 4 fund-moving externals. `pushFee` is external-unguarded but OnlySelf.
- **Integer truncation in the new economics math**: re-derived. Fee split is wei-exact (treasury absorbs dust: `fee - jackpot - referral - vaultBase - buyback`, PerpEngine.sol:1254-1266); liquidation split is wei-exact (`fundCut = penalty - keeperCut - vaultCut`, residual to trader, setters enforce keeper + vault shares <= 100%); vol-borrow multiplier `base * multX100 / 100` on x100 fixed point is correct and double-capped (config MAX 5,000,000 x100 + FundingLib 2%/h absolute ceiling); EWMA step `diff * dt / tau` floors toward the old reference (conservative) with SafeCast toUint128 on store; all mulDiv, no raw a*b/c on unbounded operands.
- **Struct fields (Position.entryMmrBps, VolParams, FeeSplit.vault)**: no storage-layout risk (no proxies/delegatecall anywhere in src). entryMmrBps round-trip is safe: written only from `TierParams.mmrBps` (uint16) widened to uint32, so the `uint16(pos.entryMmrBps)` narrowing in liquidationPrice/_isUnderwater cannot truncate. VolParams field types match the FundingLib signature exactly (uint16/uint16/uint32). setVolParams hard-caps every knob and forbids arming kBorrowVol without a tau.
- **TODO / FIXME / unsafe**: zero TODO/FIXME/HACK markers in src; the only `unsafe-typecast` lint annotations are three documented ones in core/Market.sol (wave-1 code); zero `unchecked` blocks in the perp module.

## Verdict

**CLEAN: 0 real vulnerabilities.** Slither reports 0 High (the CI gate condition) and every Medium is a triaged false positive, intentional-by-design sentinel, or an accepted precision/ranking observation. Aderyn's 3 Highs are all false positives (vendored Uniswap xor, non-modeled nonReentrant/trusted-callee patterns, key-based ADL deletion). The manual sweep of the newest economics / vol-borrow / ADL code found no unchecked calls, no missing guards, no truncation bugs, and no unbounded work on fund paths.

Standing carry item (unchanged since wave 1, dormant): add Pyth confidence-interval + publishTime staleness checks in PythAdapter.read before Pyth is ever wired on Robinhood Chain.
