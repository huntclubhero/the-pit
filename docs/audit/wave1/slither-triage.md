# Slither Static Analysis Triage | 2026-07-23
Tool: slither-analyzer 0.11.5 on main post-fix-wave (378 tests green). Config: contracts/slither.config.json (excludes lib/test/script/vendor).

## Result: 0 High, 28 Medium, 48 Low, 7 Informational
No High findings. Every Medium falls into a known-benign or dormant class below; none is a genuine vulnerability. The manual 5-specialist audit (docs/audit/wave1/) already covered reentrancy, fee/settlement math, and streak logic rigorously; Slither confirms no new High-severity surface.

## Medium triage
- **reentrancy-no-eth (4: settle, fillOffer, createMarket)**: FALSE POSITIVE. Slither does not model the nonReentrant modifier; every flagged function is nonReentrant with strict CEI and only calls trusted immutable contracts (USDG, points, oracle) or credits (post-D1 pull-payment). The access-control specialist verified no untrusted callback exists during any fund move. Benign.
- **incorrect-equality (12: _winMultiplier, dailyMultiplierOf, _touchDaily, _mint, drawIdForRequest, rawFulfillRandomWords, _quotePoolUsd)**: intentional `== 0` sentinel checks (never-active day sentinel, empty-slot checks, zero-amount early return). By design. Benign.
- **timestamp (23)**: intentional time-based logic (pause windows, cooldown/fallback state machine, staleness gates). The DoS specialist verified all time arithmetic (48h pause cap, breaker transitions) is correct and cannot be steered. Benign.
- **uninitialized-local (4: tickCumulatives, ethUsd1e18, secondsPerLiquidity, winner)**: locals declared then assigned via tuple-destructuring or in-branch before any read. Slither flags the declaration site. Assigned-before-use confirmed. Benign.
- **unused-return (5: latestRoundData, observe in adapters/UniV3TwapLib)**: intentional partial tuple destructuring (we consume answer+updatedAt from feeds and check updatedAt staleness ourselves; we consume the tickCumulatives / secondsPerLiquidity leg we need from observe). Benign.
- **divide-before-multiply (1: fillOffer)**: math specialist re-derived all fee/OI math from first principles and proved it exact with conservation preserved; the flagged ordering does not lose precision in the domain. Benign (re-verify after settlement layer changes fillOffer).
- **missing-zero-check (1: setRegistrar)**: zero is an intentional value (disables registrar registration per NatSpec). By design.
- **pyth-unchecked-confidence + pyth-unchecked-publishtime (2: PythAdapter.read)**: GENUINE hardening item, but DORMANT: Pyth is not deployed on Robinhood Chain, so PythAdapter is unused. CARRY TO AUDIT WAVE 2: if Pyth is ever wired, add confidence-interval and publishTime staleness checks (Pyth best practice) plus the scaled==0 return-ok=false from math INFO-2.

## Carry to audit wave 2
1. Pyth confidence + publishTime checks in PythAdapter (before any Pyth use).
2. Re-run Slither on the settlement-layer diff (fillOffer, OracleRouter, adapters all change in increment 1); re-verify the divide-before-multiply and uninitialized-local flags on the new code.
3. missing-inheritance (Info, 6): optionally have PitPoints/SpinVRF/Jackpot formally `is` the small consumer interfaces they implement (cosmetic).

## Verdict
Clean for a pre-external-audit internal gate: no High, and every Medium is a documented false-positive, intentional-by-design, or dormant-code item. CI (.github/workflows/security.yml) runs Slither fail-on-high on every push.
