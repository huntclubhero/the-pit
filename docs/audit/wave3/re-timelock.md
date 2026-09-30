# Wave 3 Re-Audit: W2-3 / W2-4 timelock fix
Auditor: re-timelock (Fable) | 2026-07-23 | Verdict: fix CORRECTLY closes TO-1/TO-2 core. No new permissionless drain. 4 residuals (owner/ops/liveness).

## Q1: closes TO-1/TO-2? Mostly YES
CONFIRMED CORRECT: delay is real (OZ v5.6.1 TimelockController _schedule enforces delay>=getMinDelay; execute requires isOperationReady; proposer==executor does NOT bypass the time gate; updateDelay is self-only so owner cannot instantly shrink it). Deploy wires proposers=[owner], executors=[owner], admin=address(0) (self-administered, recommended-secure). All 10 owned contracts handed to the timelock (_handOver Deploy:253-264); every enumerated price/coordinator setter is on a handed-over contract, so all timelocked. Guardian correctly separate: PauseGuardian.guardian immutable = GUARDIAN env (distinct from OWNER), never transferred, fast pause remains instant.

### Finding A (INFO/LOW, disclosed residual): IIndependentSource is owner-spoofable
ChainlinkAdapter.isIndependent returns feeds[token].feed != address(0), true for ANY feed the owner sets incl an owner-controlled mock. So _hasIndependentSource is satisfiable by an owner pointing setFeed at an owned feed, letting an owner classify a pool-only token A_MAJOR to escape the cap AND drive price. NOT over-claimed: corrected NatSpec (OracleRouter:19-40) says sources are independent of EACH OTHER not the OWNER, marker is defense-in-depth #2, timelock is #1. Correctly-scoped residual. TO-1 protection rests on the 48h delay + off-chain monitoring.

## Q2: new bug / liveness risk? YES, two
### Finding B (MEDIUM, ops): ownership-acceptance gap, fix not self-completing
_handOver calls transferOwnership(timelock) but contracts are Ownable2Step: only sets pendingOwner. The DEPLOYER EOA remains LIVE owner until the timelock executes acceptOwnership on each, which the deploy does NOT schedule/perform. So (1) until accept is scheduled+waited(48h)+executed, the deployer key holds full un-timelocked owner power (the exact TO-1/TO-2 capability the timelock removes), and a deployer-key compromise in that window has zero timelock protection; (2) if accept is forgotten, the timelock owns nothing and the fix is inert. Pre-fix a two-step gap existed but pendingOwner was the multisig (accepts in minutes); routing accept through the timelock widens it to >=48h and makes it a forgettable manual action. FIX: Deploy should schedule the acceptOwnership batch at deploy time; treat deployer key as fully privileged until accept; add a post-deploy assertion owner()==timelock on all 10.

### Finding C (LOW-MED, liveness): fast lever cannot cover the timelock window
PauseGuardian caps at MAX_PAUSE_DURATION 24h with PAUSE_COOLDOWN 72h, but every owner fix is now 48h-delayed. An emergency needing a timelocked config change (e.g. swap a rogue Chainlink feed) cannot be both contained (24h pause) AND fixed (48h timelock) in one window: a ~24h uncovered gap at hours 24-48 when settlement force-resumes but the fix has not landed, and re-pause is blocked until 72h from first pause. Self-refute: the autonomous breaker (3 fresh agreeing sources, deviation->cooldown) + expiry+24h neutral forced-unwind handle most single-feed emergencies without an owner fix, so exposure is narrow. DISCLOSE as accepted tradeoff. NOTE: the CHIEF doc says "48h continuous-pause cap" but code is 24h MAX_PAUSE_DURATION; real headroom is thinner than the doc implies (correct the doc).

## Not bugs
- Casino two-step coordinator is NOT a dead path: proposeCoordinator timelocked (48h) but acceptCoordinator is PERMISSIONLESS, so no double-timelock; rotation = 48h + COORDINATOR_CHANGE_DELAY 1d, accept by anyone. Only degradation: cancelStuckDraw onlyOwner so bricked-draw recovery is 48h-delayed (pot rolls forward; not time-critical). LOW.
- Timelock not trivially brickable (self-administered, default 2d, standard lose-keys-freeze tradeoff matching renounce-disabled philosophy).
- Bootstrap wiring (setConsumer/setRequestConfig/setReservedCommitments/setOpenBondBps/one-shot setCoordinator) runs in _wire while deployer still owns, before handover; nothing runtime-critical stranded.

### Finding D (LOW, latent ops): PythAdapter not deployed (Chainlink + 3 TWAP only). setPriceId not a live setter today; if Pyth added post-deploy it must ALSO be handed to the timelock; deploy path does not cover it.

Net: ship-safe on the timelock fix. Address Finding B in the deploy script/runbook before mainnet; disclose C; treat A's marker as non-load-bearing.
