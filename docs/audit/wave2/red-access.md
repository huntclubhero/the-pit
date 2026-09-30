# Wave 2 Red-Team: Access Control / Privilege Escalation / Admin Abuse
Attacker: red-access | 2026-07-23 | Scope: all contracts/src

## Part A: EXTERNAL ATTACKER (non-owner). Verdict: CLEAN, no finding.
Full external-mutating-fn matrix built; every guard adversarially tested and held:
- Every setter onlyOwner (factory, router, 5 adapters, PitPoints, SpinVRF, Jackpot, coordinator) or onlyGuardian (PauseGuardian).
- Points hooks pinned: onFill/onSettle onlyMarket; requestSpin OnlyPitPoints; mintSpinBonus NotSpinVRF; onMarketCreated registrar/registered only.
- VRF fulfillment authority pinned per request/draw (SpinVRF:259, Jackpot:410); non-coordinator cannot fulfill; swap cannot touch in-flight.
- registrar/creator-share unspoofable; creator-share first-writer-wins AND excluded from epoch weighting (C4 fix). Market has NO owner; withdraw pulls only msg.sender credit. Ownable2Step everywhere; renounce disabled (F1) confirmed.
Tried and FAILED: reach any setter as non-owner, spoof isMarket, call requestSpin/mintSpinBonus/rawFulfillRandomWords unpinned, hijack creator share, renounce. Wave1 "access clean" holds for external attacker.

## Part B: TRUSTED-OWNER ABUSE (compromised/malicious multisig). Findings.
Load-bearing distinction: Market bakes router/guardian/feeSplit/settlementFeeBps/oiCap/maxPayoutCap/liquiditySnapshot as IMMUTABLES, so most owner power hits FUTURE markets only. Exceptions below reach EXISTING markets/funds.

### TO-1 | HIGH (trusted-owner) | reaches user funds | EXISTING markets
Owner can set the effective SETTLEMENT PRICE of a live market and drain a counterparty. OracleRouter NatSpec (:16-22) claims "no admin function can ever set/override/nudge a price": effectively FALSE. Owner owns setSources (:328) AND every adapter (ChainlinkAdapter.setFeed:47, Twap/CrossPool/TwoHop setConfig, PythAdapter). For an existing token the owner points all >=3 sources at owner-controlled feeds/pools; all read the same P, deviation 0, median = P returned OK by checkPrice (:474). Live Market holds an immutable ref to this router and calls checkPrice at settle (Market.sol:681). Sources are independent of each OTHER, not of the OWNER. Owner (holding/colluding on one side) sets P to win and takes the counterparty's full stake (bounded by capped payout). FIX: enforce a TIMELOCK on setSources/setFeed (window to settle at honest price first); require >=1 genuinely owner-independent source for any value-bearing token; correct the router invariant NatSpec.

### TO-2 | HIGH (trusted-owner) | reaches user funds | future draws
Owner drains the JACKPOT by swapping the coordinator for future draws. Per-request pinning (Jackpot:410) only protects in-flight. setCoordinator (Jackpot:253, SpinVRF:159) sets the coordinator the NEXT startDraw pins. Owner points it at an owner-controlled randomness contract calling rawFulfillRandomWords with a chosen word; winner = selectByWeight(epoch, word % total) (Jackpot:419-421). Owner steers the winner to any address with >=1 epoch point, claims 10% (daily) / 50% (weekly) of the pot, repeatable. Commit-reveal honesty bypassed by the swap. FIX: timelock setCoordinator; two-key split between coordinator-setter and draw-starter; max-per-period pot-outflow guard.

### TO-3 | MEDIUM (trusted-owner) | griefing not theft | EXISTING markets
Owner nullifies in-flight PnL by breaking the oracle. setSources(token,[]) or failing feeds make checkPrice return UNAVAILABLE/STALE (never reverts). settle reverts OracleNotOk until expiry + MAX_SETTLE_DELAY (24h), then permissionless _forcedUnwind refunds both sides their own stake, zero fee. Owner forces a neutral unwind on demand: a deep-ITM winner is denied winnings, gets stake back. Bounded: cannot steal, cannot exceed escrow, cannot permanently lock principal (forced-unwind is the guaranteed exit, consults no owner breaker). Positive: owner cannot brick withdrawals.

### TO-4 | MEDIUM (trusted-owner) | FUTURE markets only
setFeeSplit (factory:249) only zero-checked: owner routes future markets' 4-way fees to owner addresses (bounded to 10bps entry + <=1% settle). setOiCapBps/setPerAddressOiCapBps/setTierConfig/setTrackedPools let owner size future caps (incl. inflating creation snapshot via owner JIT pools) so max_payout<=costToMove/SF stops binding on new markets. Existing immutable.

### TO-5 | LOW (trusted-owner)
PauseGuardian.guardian is IMMUTABLE, no rotation (:34); existing markets bind it immutably, so a compromised guardian key cannot be rotated for their life. Powers cannot touch funds/prices/params (24h max pause, 72h cooldown, >=48h open per key, withdrawals never paused). Residual = bounded griefing. FIX: make guardian rotatable (for future markets at least).

## Positives recorded
- settlementFeeBps hard-capped 1% in BOTH Market constructor (:388) and factory (:299), independently, immutable per market, further capped at winnings (:765): cannot zero-out/exceed principal.
- No owner power drains an existing Market's escrow, changes its recipients/fee/caps/guardian. Complete existing-market owner surface = (a) shared mutable OracleRouter (TO-1/TO-3), (b) immutable guardian (TO-5).

## Net new vs wave1
Wave1 concluded "owner cannot touch funds" WITHOUT the compromised-multisig enumeration, so it missed TO-1 (owner price control of existing markets via owned adapters, contradicting the router invariant) and TO-2 (future-draw randomness control draining the jackpot despite per-request pinning). These are the load-bearing new findings.

## Chief fix priorities (this lens)
Timelock setSources/setFeed/setCoordinator; require >=1 owner-independent source per value-bearing token; pot-outflow guard; rotatable guardian; correct OracleRouter price-invariant NatSpec. All centralization-hardening: real for a funds-holding protocol even though they need owner compromise.
