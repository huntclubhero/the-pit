# Perp Audit Wave 1: Reentrancy / Cross-Contract / Callback
Attacker: pa-reentrancy (Fable) | 2026-07-24 | VERDICT: no exploitable survivor. Reentrancy architecture sound.

## Inventory
Zero low-level calls, zero delegatecall in src/perp (grep-confirmed). Every external target: usdg (hookless ERC20), router (trusted, reads price sources), vault (onlyEngine + nonReentrant), insuranceFund (onlyEngine + nonReentrant), points (immutable trusted PitPoints), riskConfig/guardian (trusted views), this.pushFee (onlySelf). ONLY attacker-reachable calls = USDG transfers to trader/keeper/fee-recipient (PerpEngine 605,687,851,894,896,1034,1494). Every defense reduces to "USDG has no transfer hook" + "points is trusted".

## Refuted
(a) vault reads engine.marketState WITHOUT a lock during reservePayout: REFUTED. The read is always POST-write (open: _aggOpenFamily :465 before reservePayout :468; same in increase :540/542, addMargin :778/780). marketState returns _agg[token] whole; _applyPositionDelta :1569 updates all fields with no external call between reads/writes, so no half-updated snapshot observable. Unrealized funding excluded from BOTH vault balance AND NAV (PitVault:30-33), so reservePayout cannot be tricked. Decisive: NO attacker callback anywhere in an engine flow, so read-only-reentrancy on NAV/share-price is unreachable.
(b) GMX-desync: REFUTED. The 4 mutators make no external calls. In increase/addMargin/removeMargin a safeTransferFrom sits between the `before` memory snapshot and the write, but _positions[key] cannot change across it (nonReentrant + hookless USDG) and the code re-reads storage into a fresh `pos` to avoid aliasing (comments :516-517, 662-663, 815-816). Delta exact.
(c) settleTraderLoss transferFrom pull + max-approve: REFUTED. onlyEngine + nonReentrant; pulls exactly the engine-supplied amount, capped at position margin (payToVault = owed>margin?margin:owed :1394); the vault never chooses the amount. Over-pull impossible unless the vault CODE is malicious (immutable/timelock-owned). Trust assumption, not a bug.
(d) best-effort points try/catch: REFUTED. points immutable, real PitPoints (non-proxy Ownable2Step); onSettle makes NO external call; onFill's only call is spin.requestSpin (itself try/catch + code-length guard). Engine calls onFill/onSettle LAST after all effects, whole external nonReentrant. Never-block holds (all try/catch targets trusted, bounded gas; 63/64 not weaponizable by a trusted callee).
(e) checkPrice state-mutating mid-trade: REFUTED. Advances breaker state on the ROUTER only, called once early before any engine effect; internal reads hit price sources that never transfer control. CEI intact.
(f) USDG no-callback: CONFIRMED load-bearing. Attempted a drain ASSUMING USDG had an outbound hook: still fails (engine guard blocks re-entry; all attacker-reachable transfers AFTER finalized effects, strict CEI; vault public fns each nonReentrant reading consistent post-effect NAV). Could NOT build a drain even with the hook assumed.

## Residual (deployment invariants, INFO)
1. USDG MUST stay hookless / non-callback and non-upgradeable-to-add-a-hook. The single assumption the whole reentrancy posture rests on. Document as a hard listing/deployment invariant.
2. points, vault, insuranceFund MUST stay the trusted immutable contracts wired at construction.
No code change for this angle. Confidence HIGH (whole call graph + every try/catch target traced).
