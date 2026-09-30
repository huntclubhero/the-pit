# Wave 3 Re-Audit: regression check
Auditor: re-regression (Fable) | 2026-07-23 | Verdict: NO REGRESSIONS. Every wave-1 fix + every wave-2 SOLID property holds after wave-2. Both suites green on re-run (438 non-fork + 16 fork).

## 1. Wave-1 fixes ALL HOLD
- B1 (no live-read in fill path): INTACT + STRENGTHENED. _checkedNewOpenInterest still reads only immutable liquiditySnapshot1e18 + maxPayoutCap1e18; W2-1 mean-liquidity change lives ONLY in OracleRouter._trackedLiquidity, consumed at creation, baked immutable. No router liquidity read reintroduced into fillOffer. The creation snapshot is now the time-averaged in-range reserve, not JIT-inflatable balanceOf. A_MAJOR keeps balanceOf by design (feed-priced, capped-payout bounds it).
- B2 (per-address sub-cap): INTACT. W2-9 bond is ADDITIVE, NOT part of escrow/OI (openInterest()==totalStake with bond active), leaves to treasury, never touches settlement/cap.
- D1 (party pull-payment): INTACT. settle/_forcedUnwind/_settleAtPrice credit both parties via _creditPayout before any fee-push. W2-12 reuses the SAME _credit/_totalCredit ledger; no collision (shared-address co-accumulates, withdraw zeroes atomically). CEI preserved.
- D2 (jackpot pull-payment): INTACT. fulfilled=true early, pending cleared unconditionally, winner/amount recorded, claimable credited no push. Drip/outflow only shrink amount; 0-payout draw still terminalizes; pot no underflow.
- C1/C4/C5: INTACT (both draws points-weighted; L3 throttle only rate-limits the multiplier climb, not minting/weighting; cancelStuckDraw moves no funds, never touches drip state; drip mutates only on genuine payout).

## 2. Wave-2 SOLID properties ALL HOLD
Reentrancy+CEI (pushFee correctly NOT nonReentrant, only usdg.safeTransfer to immutable addresses, catch is pure state effect; primeFallback best-effort mutates only the breaker ring; no new untrusted-callback). Access on new setters (setPoolGeometry/setOpenBondBps/proposeCoordinator/cancelProposedCoordinator/setReservedCommitments onlyOwner; acceptCoordinator permissionless-but-only-applies-published-proposal; primeFallback/seed/syncInflow permissionless by design; pushFee self-gated). Capped-payout INTACT. Liveness INTACT (timelock/drip/outflow do not break terminalization; W2-12 credit-on-failure is what MAKES terminal-payout hold under a frozen fee recipient).

## 3. UNTESTED-NEW-CODE GAP (the one real finding)
Market.pushFee's `if (msg.sender != address(this)) revert OnlySelf()` is SECURITY-CRITICAL (pushFee transfers arbitrary amount to arbitrary `to` from market balance; a broken guard drains ALL escrow). Correctly implemented but NO direct unit test that an external caller reverts OnlySelf; invariant fuzz does not target it. RECOMMEND: add vm.prank(attacker); vm.expectRevert(Market.OnlySelf.selector); market.pushFee(attacker, x). Test-coverage gap on new security-critical code, not a regression.
Everything else new is genuinely exercised + asserted (W2-12 frozen-treasury fill+settle survive; W2-9 bond nonzero + MAX boundary; W2-2 budget exhaustion + seed protected + shared budget; W2-4 coordinator-independent clamp + two-step; W2-10 primeFallback+seed; W2-15 rearm+reserved; W2-14 peekPrice; W2-13 NEGATIVE not-listable case; TO-1 gate + timelock delay; Deploy timelock handover via fork test).

## 4. Flipped PoCs genuinely assert defeat
JitSnapshotInflation: baked snapshot/cap == HONEST depth, balanceOf spike does NOT move trackedLiquidity/cap, both JIT + honest twin REVERT the identical oversized fill. Real defeat through the actual _trackedLiquidity -> consultMeanQuoteReserve path. TrustedOwnerPrice: honestly does not claim impossibility (median still returns owner's number), asserts the two ENFORCED mitigations (all-owner non-independent A_MAJOR not listable until an independent source added; setSources via timelock cannot execute before MIN_DELAY). Matches corrected NatSpec.

## 5. Hardening notes (not regressions; for chief/fix-casino)
- W2-2 drip attribution precision (LOW): rawFulfillRandomWords _syncInflow(draw.epoch) sweeps all deposits since last sync into the defended epoch; for WEEKLY (previous completed epoch) current-epoch fees in the fulfillment window get misattributed, modestly inflating a cheaply-dominated past epoch's budget. Bounded by outflow guard (50% pot/day) + self-funding cost, short window. Consider snapshotting epochInflow at startDraw or attributing fulfillment-window inflow to currentEpoch. Does NOT resurrect the unbounded wash-farm (hard-capped by the coordinator-independent outflow guard). (Corroborates re-jackpotdrip, bounds it.)
- W2-9 integration (INFO): when openBondBps>0 the taker must approve takerGross + bond or fillOffer reverts on the bond transferFrom. Default 0 so latent; flag for the frontend when armed.

Bottom line: wave-2 clean on regressions. Only actionable: the pushFee OnlySelf unit test; two optional hardening notes.
