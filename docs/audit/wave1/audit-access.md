# Wave 1 Audit Report: Reentrancy / Access Control / External-Call Safety / Ownership
Auditor: audit-access (internal specialist) | Date: 2026-07-23 | Scope: all contracts/src/

## Summary
Full external-call map of every state-mutating function across core, casino, and oracle; access-control matrix; full cross-contract call-graph trace (Market to PitPoints to SpinVRF to CommitRevealCoordinator plus VRF fulfillment paths back through SpinVRF and Jackpot). Codebase judged genuinely strong in this lens. Funds live in exactly two places (Market escrow, Jackpot pot); both nonReentrant on every fund-moving entry point with strict checks-effects-interactions. Decisive structural property: no untrusted actor ever receives control during a Market operation (USDG is a standard non-callback token; payouts/fees go to trusted immutable addresses; oracle adapters consulted via staticcall). VRF fulfillment authority pinned per request. No CRITICAL, HIGH, or MEDIUM findings.

## Findings

### 1. LOW: renounceOwnership() callable on every Ownable2Step admin contract
Locations: MarketFactory (core/MarketFactory.sol:24), PitPoints (casino/PitPoints.sol:29), SpinVRF (casino/SpinVRF.sol:35), Jackpot (casino/Jackpot.sol:32), CommitRevealCoordinator (casino/CommitRevealCoordinator.sol:48), OracleRouter (oracle/OracleRouter.sol:32), all six adapters.
Path: one erroneous or compromised multisig tx sets owner to address(0); router sources, coordinator rotation, and future-market parameters become frozen forever. Bypasses the two-step safety since renounce is one-step.
Fix: override renounceOwnership() to revert, or forbid via multisig runbook.
Refutation note: survives at LOW: deliberate owner action required; never risks existing funds (markets immutable, in-flight draws pinned, Jackpot pays permissionlessly). Operational-brick risk only.

### 2. INFO: Market points hooks not code-length-guarded (pattern inconsistency)
Locations: core/Market.sol:441 (onFill), core/Market.sol:557 (onSettle); contrast casino/PitPoints.sol:269 which guards its SpinVRF call.
A code-less points address would revert in Market's frame despite try/catch (extcodesize assertion). Unreachable in production: points is immutable, constructor zero-checks, no selfdestruct anywhere (grep-confirmed). Real inconsistency, not exploitable.
Fix: add code-length guard for symmetry or document.

### 3. INFO: Owner setters do not verify contract-ness of future-market dependencies
Locations: core/MarketFactory.sol:184-215 (_setGuardian/_setRouter/_setPoints), router/adapter config setters.
Zero-checked but not code-checked; a code-less target would brick FUTURE markets only (existing immutable). Trusted-owner misconfiguration class.
Fix: optional extcodesize check or rely on timelocked-multisig review.

## Checked and found SOLID
- Market core reentrancy: postOffer/cancelOffer/fillOffer/settle/_forcedUnwind/_settleAtPrice all nonReentrant, effects before transfers; proven by reentrancy test and escrow/overpay/resettle invariants.
- Cross-contract fill chain terminates with no attacker-code callback; onSettle makes no SpinVRF call; cross-market reentrancy structurally ruled out.
- VRF fulfillment: fulfilled=true set before external calls in SpinVRF, Jackpot (also nonReentrant), and coordinator _deliver; authority pinned to accepting coordinator.
- Access matrix verified for all externals; permissionless functions intentionally open; no over-restriction.
- Ownable2Step everywhere transferable; PauseGuardian immutable guardian, cannot touch funds/prices/params; 72h cooldown vs 24h max-pause leaves guaranteed unpaused window per key.
- try/catch semantics correct; failing oracle source degrades to skipped.
- No proxy, initializer, delegatecall, or selfdestruct anywhere in scope (assembly only in vendored Uniswap math).
- Fee routing: round-down split, dust to treasury, exact sums; fee accumulator invariant holds.

## Counts
CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 1 | INFO: 2
