# THE PIT: Wave 3 Re-Audit Consolidated Verdict + Wave-2b Follow-Up Plan
Consolidator: integrator | 2026-07-23 | Basis: 10 wave-3 re-auditor reports (Fable, own contexts) + wave-2 CHIEF-CONSOLIDATED + strategy research. All fixes verified at main dd18870 (438 non-fork + 16 fork green).

## 1. Executive verdict
The wave-2 fixes are MECHANICALLY SOUND and introduced NO regressions and NO new external drain. re-conservation (all 4 invariants wei-exact), re-regression (every wave-1 + wave-2 SOLID property holds, both suites green), and re-composition (no cross-fix drain, 3 seams SOLID) all came back clean. The riskiest changes (fee credit-on-failure, open bond, jackpot drip, timelock) are individually correct.

BUT two fixes did NOT fully close their HIGH, and there are launch-config + hardening items. Combined with the strategy research (Drift Protocol drained ~$285M in April 2026 by our exact A1+W2-1+W2-3 attack chain), the honest launch-readiness call is:
- **MAJORS (Tier A): launch-safe** with the wave-2 fixes + the P1 launch-config items below. No external drain; the capped-payout p2p core is genuinely differentiated and structurally immune to the mechanisms that drained the field.
- **MEMECOINS (Tier B/C): NOT launch-safe.** W2-1 still leaves a concentrated-liquidity cap-inflation (~200x) and A1 keeps the settlement price attacker-controllable. Gate them behind W2-1b + the increment-2 optimistic bonded backstop.
- **JACKPOT: needs W2-2b** (weekly backward-attribution) before a large seeded pot.

## 2. Wave-3 findings register (deduplicated)
### Material (partially re-open a HIGH; fix before the relevant feature carries value)
- **R-1 (W2-1 concentration) [re-jit, corroborated re-composition F5]**: the mean-liquidity fix kills the PoC but the new in-range VIRTUAL reserve is ~1000x inflatable by concentrating ~$10k of real quote in a +/-0.1% band; defeats the memecoin cap ~200x. Latent for majors-only, LIVE for any pool-priced market. FIX (W2-1b): use MIN(virtual in-range reserve, balanceOf) OR measure depth across the +/-2% band the settlement move actually spans, not the single in-range tick; re-tune aggregateDepthFloor + costToMoveCoeff for the new basis; add a regression assert cap<=costToMove/SF.
- **R-2 (W2-2 weekly attribution) [re-jackpotdrip, corroborated re-potguard, re-composition F6, re-regression]**: DAILY drip closed (non-positive-EV confirmed), but WEEKLY startDraw names the PREVIOUS epoch and _syncInflow sweeps unattributed current-epoch inflow backward into it, reconstituting ~$21.5k wash-farm if the attacker controls draw timing. Bounded by the outflow guard (does NOT resurrect the UNbounded farm) + defused by a keeper syncing at rollover, so conditional. FIX (W2-2b): snapshot epochInflow at the epoch boundary / attribute fulfillment-window inflow to currentEpoch.

### Launch-config (fix before ANY launch, mostly Deploy/ops)
- **R-3 (W2-9 bond ships disabled + front-runnable) [re-bond F1, re-composition F2]**: openBondBps default 0, immutable per market, createMarket permissionless, so a monopolizer front-runs createMarket before global arming (itself timelocked) and bakes bond=0. FIX: arm OPEN_BOND_BPS>0 at DEPLOY (factory), value above the tiny-fill rounding floor (~>=50 bps).
- **R-4 (ownership handover not self-completing) [re-timelock B]**: Deploy transferOwnership sets pendingOwner only; the deployer EOA holds full un-timelocked power until acceptOwnership executes (manual, >=48h). FIX: Deploy schedules the acceptOwnership batch at deploy; post-deploy assert owner()==timelock on all 10; treat the deployer key as fully privileged until then.
- **R-5 (timelock vs feed-migration liveness) [re-composition F1]**: a routine Chainlink feed deprecation drops a major to 2 sources -> STALE -> settlement blocked, and the setFeed repoint is 2-day-timelocked, freezing a major ~2 days. FIX: run > MIN_SOURCES (i.e. 4+) feeds per major so losing one keeps quorum, and/or a shorter break-glass delay for setFeed specifically.
- **R-6 (jackpot fee-share black-hole) [re-fee S1]**: if USDG freezes the jackpot CONTRACT address, its 25% fee credits to Market but Jackpot has no function to call Market.withdraw(). FIX: add an owner/keeper collector (market.withdraw() passthrough) on Jackpot, or a deploy rule that every fee recipient is withdraw-capable (also covers the future Buyback executor).

### Hardening (P2, before scale)
- **R-7 primeFallback [re-listing F1/F2, re-composition F3]**: permissionless anytime, fills all 3 ring slots with ONE instant read (no temporal diversity), can be used to preserve the free-option it was meant to close. FIX: cap to one print per call (distinct blocks), or gate to factory/first-listing only; make createMarket require ringCount reach AGREED_PRINTS on fallback-serving tiers.
- **R-8 pushFee OnlySelf test [re-regression]**: security-critical guard (broken => drains all escrow) has no direct unit test. FIX: add the one-liner expectRevert test.
- **R-9 geometry window floor [re-jit S2]**: poolGeometry.window decoupled from the TWAP/seasoning window with no floor; a short window re-weakens W2-1. FIX: enforce a MIN window >= seasoning horizon.
- **R-10 docs**: correct 24h-vs-48h pause (re-timelock C); NatSpec weekly-clamp wording (re-potguard a); economics/fee-model doc drift 40/40/20+70bps -> 25/10/39/26+50bps (re-composition/red-composition); bond-on-forced-unwind fairness note (re-composition F4); W2-9 frontend approval note.

### Confirmed SOLID (do not touch)
Conservation wei-exact, no regressions, reentrancy/CEI, capped-payout, pull-payment accounting, fee-split, all wave-1 fixes (B1/B2/D1/D2/C1/C4/C5), the 3 composition seams (bond x credit-on-failure, drip x outflow-guard x seed, mean-liquidity x seasoning). W2-3/W2-4 timelock + pot-outflow guard + W2-12 credit-on-failure all close their finding.

## 3. Wave-2b fix plan (prioritized)
- P1-material (gate the feature until done): R-1 W2-1b concentration-aware cap; R-2 W2-2b epoch-inflow snapshot.
- P1-launch-config (before any launch): R-3 arm bond at deploy; R-4 acceptOwnership + assert; R-5 feed quorum >=4 / break-glass; R-6 jackpot collector.
- P2-hardening: R-7 primeFallback; R-8 pushFee test; R-9 geometry floor; R-10 docs.
- DESIGN (E3): W2-8 house-vault odds pricing (do NOT ship a mechanical symmetric quoter; the odds are +EV for takers).

## 4. Strategy alignment (from the-pit-strategy-research-2026-07-23.md)
The re-audit's technical verdict and the market evidence agree: ship the SAFE CORE (majors, capped-payout, odds) first, gate the memecoin dream behind W2-1b + the optimistic backstop, right-size the token so buyback is meaningful, lead marketing with the no-liquidation structural truth, and copy the survivor offshore+geofence+dual-counsel structure. Drift/Mango/JELLY make this non-negotiable, not cautious.
