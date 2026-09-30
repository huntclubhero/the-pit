# Wave 1 Audit Report: Casino / Incentive-Layer Gaming
Auditor: audit-casino (internal specialist) | Date: 2026-07-23 | Scope: casino/* + hook-calling paths in core/

## Summary
Trading-escrow and points-minting trust chain is tight: hooks onlyMarket, markets registrable only by owner/factory (registers only its own deployments), creation gated by owner-configured sources + 25,000 USDG floor, weighted-draw binary search correct. The headline farming worry (monopolize cheap points, drain weighted jackpot) does NOT survive: points scale with fees, weighted draws pay proportional to point share, and the 60% treasury/referral cut makes the points-to-jackpot loop negative-sum for everyone including the attacker. That is correct design. The real hole is the ONE non-proportional path: the daily mini-drop ENTRANTS mode is a uniform lottery over 100x-spin entrants, and a slot is earned per FILL EVENT (1% per taker fill), not per notional. On a gas-free chain an attacker floods sub-cent fills, dominates entrant slots for cents, and captures 10% of the honest-funded pot daily. Two randomness weaknesses amplify it.

## HIGH

### H1. Daily mini-drop ENTRANTS draw capturable for near-zero cost by per-event entrant flooding
Location: Jackpot.sol:298-301 (ENTRANTS branch), 384-386 (winner = list[word % length]), 271-276 (registerEntrant one push per 100x, multiple entries), SpinVRF.sol:278-284, 296-303 (100x = 1%), PitPoints.sol:265-275 (spin per taker fill), Market.sol:398-403 (dust floor).
Daily draw pays 10% of pot to a UNIFORM pick weighted only by slot count. A slot is minted on a 100x taker-fill spin (1% per fill), so slot cost tracks NUMBER of fills, not size. Min taker fill fillCollateral*multiple >= 1000 native units; at multiple 10 that is 0.0001 USDG, ~2 native units fee/fill, escrow recovered on flat settle. ~100 fills (~0.0002 USDG fees) buys one slot. Honest 100x entrants scarce (~10/day at 1,000 fills). Attacker buying 100 slots (~10,000 fills, ~0.02 USDG) wins ~91%. Against a 10,000 USDG pot that is ~910 USDG/day for ~0.02 USDG/day, repeatable, permissionless startDraw. Direct skim of community funds (pot fed by 40% of all fees), not redistribution. Win probability set by entrant COUNT, slot supply bounded by fill count not capital, so strongly positive-EV unlike the weighted paths.
Fix: make daily eligibility proportional to money at risk. Simplest: drop uniform ENTRANTS mode, always run points-weighted draw (points scale with notional). Alternatives: min-notional gate per qualifying fill, per-address slot cap, weight entrants by epoch points.
Refutation: survives. Self-funding refuted (attacker fee sub-cent, pot fed by everyone, 60% burn on negligible fees). Queue throttle bounds rate not dominance. Not covered by tests (only uniform selection + payout tested, not floodability).

## MEDIUM

### M1. Timeout fallback word is grindable, letting anyone select the winner of a stuck draw or spin
Location: CommitRevealCoordinator.sol:280-289 (fulfillTimeout, base = keccak256(requestId, blockhash(block.number-1))), 294-301 (_deliver).
Normal reveal word is unforgeable (secret pre-committed before assigned block). Fallback depends only on requestId (fixed) and parent blockhash (KNOWN at call time). Gas free, so attacker deploys a wrapper that computes the fallback word and reverts unless it selects their address, spams every block until it lands. Stuck draw: picks arbitrary winner. Stuck spin: forces 100x (H1 slot + 99x bonus). NatSpec undersells this: after timeout the fallback is a freely grindable CHOSEN sample, not one unknown sample.
Why MEDIUM: requires 24h non-reveal (operator absence/malice/collusion), liveness+trust gated, but it upgrades H1 from probabilistic to deterministic.
Fix: derive fallback word from data fixed at request time and unknown at timeout (mix in stored blockhash(assignedBlock), or a future-block commitment for the fallback too); at minimum not caller-selected block.number-1.
Refutation: survives. 256-block window governs only reveal path; fulfilled flag rollback is exactly what lets the grinder retry.

### M2. Shared FIFO commitment queue lets a fill-flooder starve honest spins and bias entrant fairness
Location: CommitRevealCoordinator.sol:226-250 (one commitment per request), SpinVRF.sol:214-218 (empty queue -> SpinSkipped).
Every fill's spin consumes one commitment from a global FIFO. Attacker flooding fills drains commitments as fast as the operator posts, denying honest users the spin bonus and their entrant slots while attacker fills accrue slots. Graceful for liveness but an adversarial fairness lever.
Fix: fair-queue or rate-limit per consumer/address, or decouple entrant eligibility from the shared-queue race.
Refutation: survives. Rate self-limits but attacker only needs majority of throttled supply; starving honest users is a feature of the attack.

## LOW
- L1: createMarket creator-share land-grab yields free perpetual 5% jackpot weight (MarketFactory.sol:144, PitPoints.sol:305-311, 513-521). Front-run SourcesSet events to farm creator shares. Fix: bind creator share to seed liquidity/bond, or exclude creator points from jackpot weighting, or owner-set creator. Small magnitude (5% of one market, 60% burned), hence LOW.
- L2: Jackpot lacks the requestId de-dup guard SpinVRF has (Jackpot.sol:361 vs SpinVRF.sol:230-235). A coordinator swap while a draw is pending can collide/orphan the draw, and the pending flag then blocks all future draws of that kind permanently. Fix: require _drawIdByRequestId[requestId]==0 before writing; add owner escape hatch to clear a stuck pending flag. Owner-action + timing gated, LOW.

## INFO
- I1: Points farming for WEIGHTED draws is NOT profitable (intended, correct): ~5.4x base points per fill for a fixed entry fee, points scale with fees, 60% burned, negative-sum for all payers. Keep this property.
- I2: Spin EV accrues only to taker (~340 pts/USDG vs maker ~200); takers get entrant slots (interacts with H1).
- I3: Weekly draws not per-epoch guaranteed (startDraw(WEEKLY) draws only currentEpoch-1, jumps forward); skipped epoch forfeits its mega-drop. By-design, document.
- I4: mintSpinBonus = basePoints*(multiplier-1) on the tiny fill's tiny earn, so fill-flooding does not inflate weekly weight (only entrant slots): H1 attacks count not weight.

## SOLID
- Hook caller trust chain (onlyMarket, owner/registrar-only registration, single factory registers only its own deployments): no arbitrary contract can spam points.
- Creation gating (>= 3 owner sources + 25,000 USDG floor): fake-token/fake-pool free-points markets not creatable by outsiders.
- Weighted selection: strictly-increasing cumulatives (zero-amount mint returns early), boundary target correct, all participant-count cases proportional, empty/over-target returns address(0) and callers skip.
- VRF authority pinning: both modules pin coordinator per request, check msg.sender at fulfillment, fulfilled/double-fulfill/empty-words guards; admin swap cannot influence in-flight/past (only L2 bricking edge remains).
- Reveal-path unpredictability + 256-block window: word binds pre-committed secret to future blockhash, expired reveal reverts (not silent blockhash==0); requester cannot know assigned block hash at request. Only the fallback (M1) is weak.
- Never-revert hooks: NOTIONAL_CAP clamp, depth-1 creator recursion, codelength-guarded requestSpin all hold.
- Jackpot payout nonReentrant CEI; standard USDG no hook; hostile future fee token cannot reenter (guards).

## Counts
CRITICAL: 0 | HIGH: 1 | MEDIUM: 2 | LOW: 2 | INFO: 4

## Load-bearing fix
H1: make the daily drop proportional to notional (drop uniform ENTRANTS mode, or weight entrants by points). That one change also removes most of M1/M2's value against the jackpot.
