# THE PIT v2 Perps: Chief Consolidation + Fix Plan (Perp Audit Wave 1)
Consolidated 2026-07-24 from 12 read-team attacker reports. Base: main @ 17ef437 (677 tests green, deploy-v2 merged).

Verdict headline: NO drain, NO fund-lock, NO reserve desync, reentrancy posture SOUND, the 2 prior integration seam fixes GENERALIZE (hand-derived wei-exact across every path). The payout-cap + reserve-cap invariant holds: max PRICE outflow per market <= cost-to-move/SF. Every survivor below is bounded by it. Two of the findings are STRUCTURAL ECONOMICS (Hunt's decision, section A); the rest are code fixes (section B) shipped autonomously this wave.

Convergence signal: the drawdown-circuit permissionless-latch DoS was independently found by FOUR attackers (pa-access E2, pa-margin-adl F1, pa-composition S2, pa-dos M1). The funding-credit-unclamped-on-modify-paths asymmetry by FIVE (pa-funding B, pa-composition S3, pa-dos L1, pa-accounting #1/#2). ADL starvation by THREE (pa-margin-adl F2, pa-dos M2, pa-composition S1).

================================================================
## SECTION A: STRUCTURAL / ECONOMIC (HUNT DECISION, NOT auto-fixed)
================================================================
These are not bugs (nothing is stolen; conservation holds). They are viability/edge decisions that change IMMUTABLE fee routing and the LP-yield model, so I am NOT changing them autonomously. Full analysis in pa-gametheory.md.

### A1 (HIGH) The vault has NO house edge.
Trade fees (5/10 bps) route 100% to jackpot/referral/buyback/treasury, 0% to the LP vault; liquidation penalty routes 80% IF / 20% keeper / 0% vault + residual RETURNED to the trader; GMX's price-impact fee was stripped (execution at the bare oracle mark, zero spread). Both reference models (GMX GLP, Hyperliquid HLP) pay the LP a fee/liquidation cushion; THE PIT deleted it. The vault's only real income is funding + borrow, which round to ~0 for fast event/latency flow (the toxic memecoin kind). So LP yield = thin funding+borrow + FINITE $PIT emissions; once emissions taper, rational LPs leave -> TVL falls -> 10%-TVL caps shrink -> capacity spiral. The risk-register "raise fees if negative" lever does NOT reach the vault (fees are diverted). This directly undercuts the tokenomics "real-revenue LP yield, not emission-funded" thesis.
DECISION FOR HUNT: route a share of trade fee AND/OR the liquidation penalty to the vault, and/or add a small vault-captured spread/price-impact on imbalancing trades. NOTE the fee-split recipients are currently IMMUTABLE (no setter, by prior audit design) so this requires a contract change to the split, not just a param.

### A2 (HIGH) The design sells free convexity (straddle harvest).
9x payout cap + early liquidation + residual-return = the vault is short gamma at zero premium. A delta-neutral sybil straddle has liquidation-truncated small downside and 9x upside; break-even realized move ~1/leverage + fee drag (~17% at 6x). On memecoins that move 20-50% intraday, or opened before a known catalyst, it is strongly +EV. Bounded by reserve caps (~2.5% TVL/sybil, ~40% TVL aggregate across 8 markets) but repeatable per vol event and NOT in the risk register. Funding/borrow (the only "premium") are keyed to skew/utilization, NOT realized vol, so the convexity is unpriced.
DECISION FOR HUNT: price it: a vol-linked open fee credited TO THE VAULT, tighter caps on fresh/high-vol markets, a minimum hold, or vol-scaled funding. (Some sub-levers, e.g. tighter fresh-market caps + min-hold, are param/logic and could be prototyped once you pick a direction.)

### A3 (MED-HIGH, context) cost-to-move invariant defends the WRONG threat.
It bounds MANIPULATION (sound vs Drift/Mango/JELLY) but A1/A2 pay nothing to move the price, so the invariant does not touch them. Single point of failure to watch: it rests on costToMove NOT being over-estimated (coeff x trackedLiquidity). Context for A1/A2, no separate action.

================================================================
## SECTION B: CODE FIXES (autonomous this wave, TDD, keep 677 green)
================================================================
Ownership split to avoid same-file conflicts: FIX-ENGINE owns PerpEngine.sol + PerpTypes.sol + the PitVault.sol seam call-sites (items B1,B2,B3,B4,B5,B6,B7,B9); FIX-CONFIG owns PerpRiskConfig.sol + InsuranceFund.sol (B11,B12), runs parallel; FIX-VAULT owns PitVault.sol internals (B8,B10), runs AFTER FIX-ENGINE merges; FIX-TESTS adds real-vault conservation cases (B13) last.

### B1 (HIGH) Reserve cap read LIVE from the router regresses v1 B1. [FIX-ENGINE]
pa-vaultdrain: vault.reservePayout enforces min(router.maxMarketPayoutCap1e18 read LIVE, ...). v1 baked this cap immutably at listMarket (MarketFactory B1 fix). Live-read lets a later router param/liquidity shift move the per-market cap after positions are open.
FIX: snapshot the per-market payout cap at engine.listMarket into engine market storage (marketMaxPayoutCap[token]); vault reservation uses the FROZEN snapshot (engine view or a reservePayout param), never the live router value. Preserve the min() with the %TVL and ramp bounds (those stay live/conservative-only).

### B2 (HIGH) Drawdown circuit: permissionless 2-day-weaponizable opens freeze. [FIX-ENGINE]
4 auditors. tripDrawdownCircuit permissionless + latches; only 2-day-timelocked resetDrawdownCircuit clears it; the reference NAV drops on ROUTINE LP withdrawals (25% epoch cap > 10% trip). An observer latches a 2-day protocol-wide opens freeze off any transient >=10% NAV dip.
FIX (all three): (a) reference excludes crystallized member withdraw-liability so legit LP exits do not read as a loss (add vault view drawdownReferenceAssets() = totalAssets + totalClaimLiability, engine consumes it); (b) resetDrawdownCircuit ALSO callable by the guardian (fast lever, not just the 2-day timelock); (c) AUTO-EXPIRE the latch on window roll when the live gate is clear. Keep the live self-healing gate. (Do NOT touch the trip threshold value.)

### B3 (MED) Maximally-winning long spuriously liquidatable. [FIX-ENGINE]
pa-liquidation F1: mm scales with UNCAPPED notional while equity is frozen at the payout cap, so past ~17-20x of entry a fully-winning long trips the maintenance guard and a keeper confiscates the capped payout. Violates "a non-negative-PnL position is never liquidatable."
FIX: in _computeLiquidation, skip/deny liquidation when clamped uPnL >= 0 (a position at or above break-even after the clamp is never liquidatable). Add a regression test at the onset ratio.

### B4 (MED) Non-LIVE accrual discards the whole funding+borrow interval. [FIX-ENGINE]
pa-funding A: _aggAccrue always advances lastAccrual even on the non-LIVE zero-delta branch, so one permissionless pokeFunding during any FALLBACK/BLOCKED blip wipes the ENTIRE holding-period funding+borrow (not just the degraded slice) -> funding dodge + vault-revenue erosion.
FIX: accrue-then-freeze: book the LIVE portion up to the state-transition instant before advancing lastAccrual, OR do not advance lastAccrual across a non-LIVE gap so the interval bills on the next LIVE poke. Never silently swallow a LIVE interval.

### B5 (MED) Pool-priced market listable with the spot-vs-TWAP breaker disarmed. [FIX-ENGINE, router-view side]
pa-oracle S1: openingAllowed short-circuits (true,ALLOWED) when tierConfig.spotSource==0; isListable for B_DEEP/C_MID never requires spotSource!=0. A single ops omission lists a pool-priced market whose only manipulation gate is silently nullified.
FIX: engine.listMarket (and/or router.isListable) must REJECT a pool-priced / B_DEEP / C_MID token whose router tierConfig has spotSource==0 (assert the opening breaker is armed before the market can trade).

### B6 (MED) ADL rework: wasted-haircut accounting + skip-counting bound + unranked. [FIX-ENGINE]
Merges pa-composition S1 (haircut on an at-cap funding-credit victim saves ZERO vault outflow but decrements `remaining` by the nominal haircut -> bad debt silently absorbed by LPs, early termination, adlAbsorbed overstated) + pa-margin-adl F2 / pa-dos M2 (examined++ counts same-side + break-even skips against the 32 budget, so sybil-padding or a lopsided book starves ADL of real victims).
FIX: (a) measure absorption from the ACTUAL vault delta: haircutEffective = winFromVault(0) - winFromVault(haircut); decrement `remaining` by that; a victim already at cap (raw win >= maxPayout at haircut 0) is NON-absorbing -> skip and continue to the next victim; (b) bound the loop on VICTIMS FOUND (opposite-side profitable, absorbing), not total scanned; (c) rank victims by (uPnL% x leverage) before scanning (or scan enough to cover, given (b)).

### B7 (MED) refreshTier downgrade retroactively tightens MMR on open positions. [FIX-ENGINE + PerpTypes]
pa-access E1: liquidation reads mmrBps LIVE from riskConfig; a permissionless downgrade raises maintenance on ALL open positions and can flip borderline-healthy into liquidatable. Spec 8.4 promises existing positions are grandfathered.
FIX: snapshot the tier's mmrBps (add Position.entryMmrBps to PerpTypes) at open/increase; liquidation uses the snapshot, not the live tier. New opens still get the current (downgraded) tier. NOTE: this is a Position struct field add (storage layout) so it must land before any deploy; coordinate with FIX-VAULT (vault NAV uses per-side margin, not per-position MMR, so no vault coupling).

### B9 (LOW, 5 auditors) Funding-credit unclamped / inconsistently clamped across paths. [FIX-ENGINE]
Close/liquidate clamp winFromVault to maxPayout; reduce/removeMargin route the whole-position funding credit through _settlePending with no per-position bound (only the global totalReserved), so (i) a dominant-reserve position's credit can revert modify ops (partial DoS, close still works), and (ii) a legit funding credit is confiscated on close when price PnL is below the cap.
FIX: give the funding credit its own bounded accounting so it is (i) not clamped away when price PnL is under the cap and (ii) consistently bounded on every settlement path (close, reduce, removeMargin, liquidate). Simplest coherent option: track funding credit separately from the price-PnL payout, add it to the pot on settlement rather than paying it live through the reserved-payout channel. Keep conservation wei-exact.

### B8 (MED) Aggregate loss-clamp overstates NAV during pause/gap; standing-exiter dodges bad debt. [FIX-VAULT]
pa-vaultshares S1: the loss clamp is applied at the SIDE aggregate (-totalLongMargin), not per position, so a position underwater past its own margin (unliquidated, during a pause/gap) is counted as vault equity -> NAV overstated by the uncollectable bad debt; a permissionless settleEpoch during that block locks the rich price for a standing-queued LP. Also maxMarkAge not enforced on NAV (pa-oracle S2).
FIX: gate settleEpoch AND lazy _resolve settlement pricing on "no market currently stale/paused" (navMarkStale()==false and no active deviation-breaker), so no one can crystallize a price during the exact window the overstatement exists; enforce maxMarkAge as a hard bound on the NAV mark (revert/degrade, not just an advisory flag). (Per-position loss clamping is the alternative but breaks the O(markets) NAV loop; the settlement-staleness gate is the O(1) fix and closes the exploit.)

### B10 (LOW) solvencyFloorBps MAX too high. [FIX-VAULT]
pa-access T1: MAX=30000 (3x) lets a malicious/mis-set owner freeze ALL LP withdrawals whenever utilization > 33%. Default 12000 already blocks at util > 83.3% (tight vs the 80% cap).
FIX: lower the settable MAX (e.g. to ~15000) so the owner cannot brick withdrawals across the normal utilization band.

### B11 (LOW) refreshTier cooldown blocks EMERGENCY downgrades. [FIX-CONFIG]
pa-margin-adl F3: the 24h cooldown check sits before the downgrade branch, so a token whose FDV craters keeps its higher leverage up to 24h; griefable by front-running with a queued upgrade.
FIX: exempt DOWNGRADES from the refresh cooldown (immediate, per spec 8.4); keep the cooldown on upgrades.

### B12 (LOW) InsuranceFund.governanceWithdraw unrestricted. [FIX-CONFIG]
pa-access T3: drains the entire fund to an arbitrary recipient (timelocked but the single largest owner blast radius; cover() is vault-locked by contrast).
FIX: add a per-period withdrawal cap (rate-limit) and/or constrain the recipient. Keep it timelock-gated.

### B13 (test gap) Real-vault conservation cases missing. [FIX-TESTS]
pa-accounting: the invariant harness runs against MockPitVault (mints wins freely, no cap/settle-before-release), so reducePosition, successful removeMargin, and increasePosition have NO wei-exact conservation test against the REAL vault (only fuzz-vs-mock). Hand-derived correct, but untested-against-real-vault seam.
FIX: add PerpIntegration real-vault conservation scenarios for reduce + removeMargin + increase (assert engine-in == out and reservedBy == sum-of-open-maxPayouts after each).

================================================================
## SECTION C: VERIFY (no code change, confirm at deploy)
================================================================
- C1 (pa-gametheory F4): confirm the v2 perp deployment CANNOT set PitPoints.creatorOf for listed perp tokens (PerpEngine never calls onMarketCreated; verify no retired MarketFactory/registrar path can), OR make the $PIT airdrop snapshot epoch/season points (which exclude the 5% creator share) not lifetime pointsOf.
- C2 (pa-reentrancy residual / pa-dos L3): USDG MUST stay hookless AND non-blacklist/non-freeze-capable AND non-upgradeable-to-add-either. The whole reentrancy posture + liquidation-transfer liveness rest on it. Document as a hard listing/deployment invariant; confirm the Robinhood-chain USDG's actual semantics before mainnet.

## Deferred LOW / informational (accept or revisit post-launch)
- pa-gametheory F5 keeper-floor IF subsidy (~break-even, bounded by IF balance) — accept.
- pa-accounting #3 closePosition lacks ADL escalation (self-closing bad debt is strictly better for the vault than letting it rot; IF normally covers) — accept/document.
- pa-vaultshares S2 exiter-selectable settlement block (small persistent bias, bounded by the 25% cap; largely subsumed by the B8 staleness gate) — revisit if B8 does not fully cover.
- pa-vaultshares OBS-A / pa-dos NAV-loop: totalAssets O(markets) loop is governance-paced (listMarket timelocked), a capacity ceiling not an attack — cap the market list or make NAV incremental before the market count grows large.
