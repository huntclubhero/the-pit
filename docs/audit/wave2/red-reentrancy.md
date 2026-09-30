# Wave 2 Red-Team: Reentrancy / External-Call / Callback Drain
Attacker: red-reentrancy | 2026-07-23 | Verdict: NO SURVIVORS.

Mapped every external call across the full graph (Market, MarketFactory, Jackpot, SpinVRF, PitPoints, CommitRevealCoordinator, OracleRouter + adapters). Could not construct a re-entry that drains or corrupts.

Core finding: the ONLY attacker-controllable addresses that ever receive anything are plain USDG transfers, and every one lands in a nonReentrant function with strict CEI:
- withdraw() (Market:963), Jackpot.claim() (:455), cancelOffer() (:462): zero balance/flag BEFORE transfer, nonReentrant.
- fillOffer safeTransferFrom pulls from taker (no from-callback in std ERC20); fees push only to the 4 governance-set recipients.
- Every non-USDG external call in a mutating path targets a governance-configured trusted contract; createMarket takes only `token` (creator injects nothing); router adapters are owner-set, consulted read-only (checkPrice mutates only router breaker state; _evaluate/openingAllowed are view staticcalls).

Vectors refuted: (a) cross-function re-entry blocked by shared nonReentrant; (b) cross-contract re-entry has no attacker callback to trigger, and other markets have independent state; (c) pull-payment CEI exact, proven by shipping test test_withdraw_reentrancyBlocked with a genuinely reentrant USDG; (d) try/catch points hook + code-length guards hold, address is governance-only; (e) VRF fulfilled-flag-before-callback, one-consumer-one-delivery, no double-fulfill; (f) no CEI violation found line-by-line.

Load-bearing assumption (honest, not a finding): posture rests on USDG having no transfer callback (on-chain confirmed: Diamond stablecoin, not ERC777) AND the guards hold even if it did (reentrant-token test + nonReentrant + CEI everywhere).

INFO (defense-in-depth, not a vuln): SpinVRF and CommitRevealCoordinator are not ReentrancyGuard (unlike Jackpot); safe today (move no funds, flag before the one trusted call); a belt-and-suspenders nonReentrant would add uniformity but closes nothing open.
