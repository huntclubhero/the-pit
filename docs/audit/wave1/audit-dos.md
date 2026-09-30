# Wave 1 Audit Report: DoS / Griefing / Fund Lockup / Liveness
Auditor: audit-dos (internal specialist) | Date: 2026-07-23 | Scope: all contracts/src/

## Summary
Liveness design is unusually robust. Offer collateral is unconditionally maker-cancellable; positions always reach terminal payout via permissionless forced-unwind strictly after expiry + 24h when oracle is broken; PauseGuardian cannot exceed 48h continuous pause; oracle breaker is data/time driven so cannot be steered by repeated calls; every casino hook is non-reverting; draws have a 24h permissionless fallback. Could not permanently strand escrow under standard-USDG assumption. Findings: one MEDIUM economic-DoS, two LOW push-payment lockups (bite only if USDG can block transfers), one LOW liquidity-floor griefing, four INFO indexer notes.

## MEDIUM

### M1. OI cap monopolized by risk-free self-trades, denying all new positions up to 30 days at near-zero cost
Location: Market.sol:381 (fillOffer), 624-633 (_checkedNewOpenInterest), 488-490 (pre-expiry settle restriction), 59 (MAX_DURATION).
Self-fill guard (Market.sol:387) only blocks maker==taker, so an attacker with two addresses posts from A, fills from B with duration=30 days, owns both legs (market-neutral), and repeats until _openInterest hits the cap. At the default floor (25_000e18, 10% cap) that is ~2.5k USDG of their own refundable risk-free collateral plus a one-time ~5 USDG entry fee. No third party can settle a pre-expiry position, so honest fillOffer reverts OiCapExceeded for up to 30 days, repeatable. Markets immutable, pausing blocks settlement too and is capped at 48h. Denies new-position liveness, not funds. Cheap on niche/new markets near the floor; expensive on deep markets.
Fix: per-address OI sub-cap (cleanest, no price risk to honest traders), or reserved headroom, or entry fee rising with fraction of cap consumed.
Refutation: survives. Invariant suite proves cap never exceeded, not that a filled cap cannot exclude others.

## LOW

### L2. Jackpot payout not isolated from pending-flag clear; one unpayable winner bricks the draw kind and locks the pot (only if USDG can deny a transfer)
Location: Jackpot.sol:402-410 (flags cleared then safeTransfer). Standard USDG always succeeds. If USDG is blocklist-capable (like USDC/USDT) and the VRF-selected winner is blocklisted, safeTransfer reverts, fulfillment reverts (including fulfillTimeout), no admin path resets the flag: draw kind never restarts, pot locked forever. Impact would be HIGH if the assumption is relaxed.
Fix: clear flag + record winner unconditionally, pay via pull-payment claim, or roll pot forward on failed transfer.

### L3. Settlement and forced-unwind use push payments; unpayable counterparty locks both sides' escrow (only if USDG can deny a transfer)
Location: Market.sol:551, 538-539 (settle), 518-519 (_forcedUnwind). If USDG can block a recipient, settle reverts AND the forced-unwind escape hatch also reverts (pays both parties), stranding the counterparty's collateral with no exit. Zero-value edges already safe.
Fix: settle to internal credit balances with withdraw; at minimum make _forcedUnwind credit-on-failure since it is the last-resort liveness path.

### L4. Liquidity floor / OI cap read live pool balance a large swap can transiently deflate, blocking new fills
Location: OracleRouter.sol:542-553 (balanceOf(pool)), consumed Market.sol:626-632. A swap dropping a tracked pool's USDG below 40% of the creation snapshot reverts every fillOffer (LiquidityFloorBreached). Denies new fills only, never settlement/cancellation. Bounded and costly (huge high-slippage swap, arbitrage-reversed, must be continually re-drained).
Fix: short TWAP of tracked balance so a single-block swap cannot trip the floor. Low priority.

## INFO
- I5: Cheap unbounded id inflation degrades frontends enumerating offers/positions by id (off-chain only; on-chain O(1)). Use event-based indexing.
- I6: PitPoints checkpoints and Jackpot entrants append per activity but stay O(log n)/O(1) on-chain; off-chain enumeration degrades.
- I7: Shared commit-reveal FIFO queue can be drained by a fill burst, starving draw requests; degrades gracefully (SpinSkipped, retryable startDraw, no period skipped). Keep queue depth ahead of fill volume.
- I8: Post-expiry permissionless settlement uses spot-at-settle-time, granting a settlement-timing option to any keeper. Mitigated (either party can self-settle from MIN_HOLD). Cross-referenced to oracle/economics lens (matches oracle M2).

## SOLID (liveness bounds verified with arithmetic)
1. Pause provably bounded at 48h continuous: two keys x 24h max, 72h start-to-start cooldown, guaranteed 24h+ unpaused window every 72h; unpause does not reset lastPauseStart. Forced unwind reachable by expiry + 24h + 48h worst case.
2. Offer collateral always maker-cancellable, ungated.
3. Every position reaches terminal payout (OK settle or neutral unwind strictly after expiry + MAX_SETTLE_DELAY); strictly-after boundary test-confirmed.
4. Stuck-in-COOLDOWN does not strand funds (COOLDOWN != OK triggers forced unwind).
5. Breaker cannot be steered by repeated checkPrice calls (time-gated, reset only on genuine agreeing print, bad source dropped).
6. Casino never blocks trading (onFill try/catch, requestSpin non-reverting, extcodesize guard).
7. Draws cannot be held hostage (empty queue retryable, withheld reveal rescued by permissionless fulfillTimeout after 24h).
8. No attacker-inflatable unbounded on-chain loop.
9. No zero-value transfer path; _openInterest conserves exactly, no underflow.

## Counts
CRITICAL: 0 | HIGH: 0 | MEDIUM: 1 | LOW: 3 | INFO: 4

## Triage priority
M1 (cheap risk-free OI-cap monopolization on low-liquidity markets). L2/L3 worth fixing preemptively: they convert to HIGH the moment USDG is anything other than a plain non-blocking ERC20.
