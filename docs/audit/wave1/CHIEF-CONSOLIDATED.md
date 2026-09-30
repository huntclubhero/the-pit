# THE PIT: Wave 1 Consolidated Findings and Fix Plan (Chief Auditor)

Consolidator: chief (internal) | Date: 2026-07-23 | Basis: five specialist reports (access, oracle, casino, dos, math) plus independent source re-verification and on-chain checks against Robinhood Chain (id 4663).

Method note: every CRITICAL and HIGH below was re-verified by reading the actual source (OracleRouter.sol, Market.sol, Jackpot.sol, SpinVRF.sol, PitPoints.sol, CommitRevealCoordinator.sol, the three TWAP adapters, MarketFactory.sol) and by confirming chain reality against docs/ops-runbook.md and direct RPC calls to USDG. Where I differ from a specialist's severity I say so and why.

---

## 1. Executive summary

**Is the engineering sound? YES.** The contract engineering is genuinely strong and I concur with the SOLID consensus across all five reports. Settlement conservation is exact by construction (winner + loser + fee == 2 x collateralEach, algebraic and fuzz-confirmed). Reentrancy posture is airtight: funds live in only two places (Market escrow, Jackpot pot), every fund-moving entry point is nonReentrant with strict checks-effects-interactions, and no untrusted actor ever receives control during a Market operation (USDG has no transfer callback, fees and payouts go to trusted immutable addresses, oracle adapters are consulted read-only). Access control is clean (Ownable2Step, VRF authority pinned per request, hook trust chain onlyMarket). Liveness bounds are unusually robust and I verified the arithmetic: pause is provably capped at 48h continuous, every position reaches terminal payout via permissionless forced-unwind after expiry + 24h, breaker transitions are data-and-time driven so cannot be steered. The numerical layer is correct to the wei. None of that needs to change, and the fix wave must be careful not to disturb it.

**Is the economic model for thin memecoins viable as-built? NO.** This is the honest verdict Hunt has to sit with. THE PIT is a well-built engine wrapped around an oracle whose security premise is achievable for majors and unachievable for memecoins on this chain. The router's stated invariant is "median of at least three fresh, independent, mutually agreeing sources." I confirmed against the runbook and on-chain that Robinhood Chain has NO Pyth and NO per-memecoin Chainlink feed: only ETH/USD and USDG/USD exist. A memecoin therefore has exactly one price primitive, the TWAP of its single TOKEN/WETH Uniswap v3 pool, read three ways (all three adapters, TwapAdapter / CrossPoolTwapAdapter / TwoHopTwapAdapter, ultimately observe() the same pool). Moving that one pool moves all three sources in lockstep, the deviation guard never trips, and the attacker sets the settlement price. The OI cap meant to bound the damage is computed from a pool balance the attacker can inflate just-in-time in the same block. The capped-payout design is the only real backstop, and it bounds the theft to roughly the OI-cap fraction of tracked liquidity per cycle, but that is still a repeatable, positive-EV transfer from honest counterparties to the attacker with economics of roughly 40:1 or better (and unbounded in the sole-LP limit).

**The central question for Hunt:** THE PIT is shippable and sound as a capped long/short venue for assets that have a genuinely independent price feed (majors: ETH and anything with a real Chainlink feed). It is NOT safe as a memecoin venue with today's adapters, because on this chain a memecoin's settlement price is definitionally attacker-controllable. The decision is not "fix a bug." It is "choose the asset class the protocol is allowed to settle." Everything else in this register is ordinary hardening on top of a good codebase.

---

## 2. Authoritative severity register (deduplicated, root-cause grouped)

Severity is my final call. "Fix type" is CODE (a code change closes it) or DESIGN/POLICY (the decision is a listing or mechanism decision, code only enforces it).

### Group A: Thin-asset oracle (settlement price premise)

| ID | Final sev | Root cause | One-line | Location | Fix type |
| --- | --- | --- | --- | --- | --- |
| A1 (was Oracle C1) | CRITICAL | Memecoins have no price source independent of their settlement pool on this chain; "3 sources" are one pool read 3 ways | Tier B settlement price is directly attacker-controllable | OracleRouter `_evaluate` :465, `setSources` :215 (count-only check); consumed Market `settle` :493, entry :605; TwoHopTwapAdapter/CrossPoolTwapAdapter/TwapAdapter all observe() one pool | DESIGN/POLICY (code enforces the gate) |
| A2 (was Oracle M1) | MEDIUM | Every memecoin source is multiplied by the SAME ETH/USD feed leg | Shared feed leg is a common-mode the deviation guard cannot see; 90000s staleness widens window | TwoHopTwapAdapter :120-127; router staleness config | CODE (config + tighten staleness) |
| A3 (was Oracle L1/L2) | LOW | setSources enforces count, not distinct venues; Tier B 2500 bps band swallows same-pool drift | No independence/distinct-pool check; wide band reinforces A1 | OracleRouter :215-225, :50 | CODE (defense in depth) + POLICY |

### Group B: OI-cap and liquidity-floor integrity (live-state manipulation)

| ID | Final sev | Root cause | One-line | Location | Fix type |
| --- | --- | --- | --- | --- | --- |
| B1 (was Oracle H1) | HIGH | Cap basis reads raw pool balanceOf, JIT-inflatable with single-sided WETH; cap checked at fill only, never re-checked at settle | trackedLiquidity inflation defeats OI cap and floor; NatSpec falsely claims capital must be parked | OracleRouter `_trackedLiquidity` :542, `_quotePoolUsd` :557; Market `_checkedNewOpenInterest` :624-632; misleading NatSpec :392-401 | CODE |
| B2 (was DoS M1) | MEDIUM | Self-fill guard only blocks maker==taker; no per-address OI sub-cap | OI cap monopolized by risk-free two-address self-trades, denying all new positions up to 30 days for cents | Market `fillOffer` :387, `_checkedNewOpenInterest` :624, MAX_DURATION :59 | CODE |
| B3 (was Oracle M3) | MEDIUM (moot single-pool) | Cross-pool weight uses instantaneous pool.liquidity() | JIT-manipulable in-range-liquidity weighting; real only for multi-pool tokens | CrossPoolTwapAdapter :85-107 | CODE |
| B4 (was DoS L4) | LOW | Floor reads live balance a large swap can transiently deflate | Single-block swap can trip LiquidityFloorBreached, blocking new fills | OracleRouter :542; Market :626-632 | CODE (same fix as B1) |

### Group C: Jackpot capture and randomness

| ID | Final sev | Root cause | One-line | Location | Fix type |
| --- | --- | --- | --- | --- | --- |
| C1 (was Casino H1) | HIGH | Daily ENTRANTS draw is uniform over slots; a slot is minted per FILL EVENT (100x spin), not per notional | Daily 10%-of-pot mini-drop capturable for cents by per-event entrant flooding | Jackpot `startDraw` ENTRANTS :298-301, winner :384-386, `registerEntrant` :271-276; SpinVRF 100x :296-303; PitPoints spin per fill :265-275; Market dust floor :398-403 | CODE |
| C2 (was Casino M1) | MEDIUM | Timeout fallback word derives from requestId + parent blockhash, both known at call time | Fallback word is a freely grindable chosen sample; upgrades C1 from probabilistic to deterministic for a stuck draw/spin | CommitRevealCoordinator `fulfillTimeout` :280-289 | CODE |
| C3 (was Casino M2) | MEDIUM | Global FIFO commitment queue, no per-consumer fairness | Fill-flooder drains commitments, starving honest spins and biasing entrant fairness; amplifies C1 | CommitRevealCoordinator :226-250; SpinVRF empty-queue :214-218 | CODE |
| C4 (was Casino L1) | LOW | Creator share bound to first market creator, not to stake | Front-run SourcesSet to farm a perpetual 5% creator jackpot weight | MarketFactory :144; PitPoints :305-311, :513-521 | CODE |
| C5 (was Casino L2) | LOW | Jackpot lacks SpinVRF's requestId de-dup; pending flag never clears on collision | Coordinator swap mid-draw can orphan a draw and brick that draw kind permanently | Jackpot :361 (vs SpinVRF :230-235) | CODE |

### Group D: Push-payment fund lockup (blocking-token dependency) -- ESCALATED

| ID | Final sev | Root cause | One-line | Location | Fix type |
| --- | --- | --- | --- | --- | --- |
| D1 (was DoS L3) | MEDIUM (escalated from LOW) | settle and forced-unwind push USDG; USDG is freeze-capable (confirmed on-chain) | A frozen counterparty makes settle AND the last-resort forced-unwind both revert, stranding the innocent party's escrow forever; breaks the stated "every position reaches terminal payout" invariant | Market `settle`/`_settleAtPrice` :551, :538-539; `_forcedUnwind` :518-519 | CODE |
| D2 (was DoS L2) | MEDIUM (escalated from LOW) | Jackpot clears pending flag then pushes; flag clear reverts with the transfer | A frozen VRF-selected winner reverts fulfillment (incl. fulfillTimeout), pending flag never clears, draw kind bricked and pot locked forever | Jackpot :402-410 | CODE |

### Group E: Settlement timing / stale-fallback option

| ID | Final sev | Root cause | One-line | Location | Fix type |
| --- | --- | --- | --- | --- | --- |
| E1 (was Oracle M2 + DoS I8) | MEDIUM | Post-expiry settlement uses spot-at-settle-time; fallback serves stale ring-median as OK with no freshness stamp or settle delay | Keeper settlement-timing free option; stale-print arb whenever fallback is active | OracleRouter fallback :323-358; Market :488-520; post-expiry permissionless settle :488-490 | CODE |

### Group F: Ownership / ops hardening

| ID | Final sev | Root cause | One-line | Location | Fix type |
| --- | --- | --- | --- | --- | --- |
| F1 (was Access L1) | LOW | renounceOwnership() one-step callable on every admin contract | Erroneous/compromised renounce freezes router sources, coordinator rotation, future-market params forever | All Ownable2Step contracts (router :32, PitPoints :29, SpinVRF :35, Jackpot :32, coordinator :48, MarketFactory :24, adapters) | CODE |
| F2 (was Access INFO 2/3) | INFO | Market points hooks not code-length-guarded; owner setters not contract-checked | Pattern inconsistency; unreachable in production (immutable, zero-checked, no selfdestruct) | Market :441, :557; MarketFactory :184-215 | CODE (symmetry) |
| F3 (was Math INFO-1/2/3) | INFO | Fuzz collateral ceiling 1e30 (hand-verified safe to uint128); PythAdapter zero-price neutralized by router; unbounded totalPoints checked-arith | Test-domain and defensive-hardening notes, none exploitable | test/core/SettlementFuzz.t.sol:18; PythAdapter :58-65; PitPoints :503 | CODE (optional) |
| F4 (indexer notes I5/I6/I7) | INFO | Cheap id inflation degrades off-chain enumeration; on-chain stays O(1)/O(log n) | Use event-based indexing; keep commitment queue ahead of fill volume | n/a | POLICY/ops |

Deduplication summary: 22 distinct specialist findings collapse to 6 root-cause groups. The JIT-liquidity theme (Oracle H1 + Oracle M3 + DoS L4) is one root (live pool state as a cap basis) and is grouped as B1/B3/B4. The entrant-flood theme (Casino H1 + Casino M2) is grouped C1/C3. The timing/settle-option theme (Oracle M2 + DoS I8) is one item E1. The push-payment theme (DoS L2 + L3) is one root, group D. The OI-cap-monopolization item (DoS M1) shares the "the OI cap is a weak bound" umbrella with B1 and is placed as B2.

---

## 3. The three decisions this audit forces

### Decision A: the oracle / thin-asset problem (A1)

This is a design/policy decision, not a bug fix. The oracle math is correct; the premise (three independent sources) is simply unachievable for a memecoin on a chain with no independent memecoin feed. Options:

- (i) Strict listing policy: only list tokens that have a source independent of their settlement pool. On this chain that means only assets with a real Chainlink feed, which is majors, not memecoins.
- (ii) Redesign to a matched-price / funding model where counterparties agree the entry and only direction/settlement is oracle-driven. Large redesign, and settlement still needs a price, so it does not by itself remove the manipulated-settlement-read problem.
- (iii) Accept memecoins only when the pool is deep and externally arbitraged, with reduced max-multiple and OI cap. Insufficient alone: manipulation cost and prize both scale with liquidity, so depth does not change the ratio; the real bound is external arbitrage, which a fresh memecoin does not have.
- (iv) Hybrid: keep memecoins tradeable but make settlement mechanics that do not let one read pay out (time-averaged multi-read settlement, randomized settlement instant within a window, dispute windows, hard per-market and per-address payout caps).

**My recommendation: ship (i) as a hard technical gate for launch, and treat memecoins as a gated R&D track behind (iv) + (iii) combined, with an explicit, capped, accepted-residual-risk posture.** Concretely:

- For any market carrying real value at mainnet: enforce in code that a token is listable only if at least one configured source is NOT a function of the settlement pool. Today that resolves to a majors allowlist. THE PIT on majors is a real, sound, shippable product, and the engine already supports it (ChainlinkAdapter exists).
- Do not pretend memecoins are securable by an oracle tweak. State plainly to the team: on a single-pool memecoin, "manipulate the only price source" costs only external-arbitrage friction, which is near zero for a fresh token, so no TWAP length, deviation band, or liquidity floor closes A1. The capped payout is the sole backstop and it caps the bleed, it does not stop it.
- If memecoins must launch, they launch degen-tier: multiple near 1 to 2, OI cap well below 1000 bps, per-market and per-address payout caps, settlement price averaged over multiple reads at a randomized instant, and a hard requirement of demonstrable independent external arbitrage (real volume on a second venue). Accept and disclose that a well-capitalized sole-LP attacker can still extract up to the capped amount. That is a business decision about an accepted, bounded loss, and it must be made with eyes open, not discovered in production.

Rejected: (iii) alone (does not change the ratio) and "just widen liquidity floors" (A1 is invariant to L).

### Decision B: the JIT-liquidity + OI-cap cluster (B1, B2, and by extension B3/B4)

All code-fixable. Recommended fixes, in order:

- **Change the OI-cap basis from live trackedLiquidity to the creation snapshot.** The market already stores liquiditySnapshot1e18 and already uses it for the floor; use it for the cap too, or use a time-averaged in-range liquidity read (pool.liquidity() averaged over the TWAP observation window) instead of raw balanceOf. This removes the single-block JIT-inflation lever entirely and closes B1, B3, and B4 in one change. If the cap should track genuine liquidity growth, allow an owner re-snapshot with a delay, never a live read.
- **Add a per-address OI sub-cap.** Cap the open interest attributable to any single address (or offer maker + taker pair) to a fraction of the market cap, so two colluding addresses cannot monopolize the whole cap with market-neutral self-trades. This closes B2 with no price risk to honest traders and is cleaner than raising the entry fee.
- **Fix the trackedLiquidity NatSpec** (OracleRouter :392-401): it wrongly claims inflation "requires parking real quote capital." The capital is parked for one block and fully recoverable, so it is not at risk. Correct the comment so future readers do not trust the false guarantee.

Do not restructure _openInterest accounting or the escrow flow while doing this: it conserves exactly today. Add gates, do not touch the conservation math.

### Decision C: jackpot daily-drop capture (C1) and randomness fallback grinding (C2)

Both code-fixable.

- **C1: drop the uniform ENTRANTS mode; always run the daily draw points-weighted, exactly like the weekly draw.** Points scale with notional (money at risk) and the 60% treasury/referral burn makes the points-to-jackpot loop negative-sum, which is precisely why the weighted paths are safe and the uniform path is not. This single change removes the one non-proportional payout path and also strips most of the value out of C2 and C3 against the jackpot (there is no longer a cheap uniform entrant draw to grind or starve into). If the "Pit Drop entrants" flavor must survive, weight entrants by their epoch points and gate entrant eligibility on a minimum per-fill notional, but the simplest correct answer is to delete the uniform mode.
- **C2: derive the fallback word from data fixed at request time and unknown at timeout.** Today fulfillTimeout uses keccak256(requestId, blockhash(block.number - 1)), both caller-known, so a wrapper can grind block by block until the word selects the attacker. Mix in the stored blockhash(assignedBlock) captured at request, or require the timeout path to itself commit to a fresh future block (a two-step timeout), so the fallback is one unknown sample rather than a chosen one. At minimum do not derive it solely from the current parent blockhash.

---

## 4. Prioritized fix plan for the fix wave

### P0: blocks ANY launch

- **A1 listing gate.** Implement and enforce, in MarketFactory/OracleRouter listing logic, that a token is listable only if at least one configured source is independent of its settlement pool (for launch: a majors allowlist / real-Chainlink-feed requirement). Without this, any listed token settling against its own single pool is drainable from block one. This is the gate that makes the launch honest. Type: CODE + POLICY.

If the launch is explicitly majors-only from day one, A1 is mitigated by this gate and the remaining P1 items become the mainnet blockers.

### P1: blocks mainnet with real value

- **C1**: daily drop to points-weighted (delete uniform ENTRANTS mode). Direct skim of community funds. Type: CODE.
- **B1 + B3 + B4**: OI-cap/floor basis to creation-snapshot or time-averaged in-range liquidity; stop reading raw live balanceOf; fix NatSpec. Type: CODE.
- **B2**: per-address OI sub-cap. Type: CODE.
- **D1 + D2**: convert settlement, forced-unwind, and jackpot payout to pull-payment or credit-on-failure, and clear Jackpot pending flags + record the winner unconditionally before the transfer. Escalated to P1 because USDG is confirmed freeze-capable and pause-capable on-chain (Diamond proxy, isFrozen(address) live, paused() live), so a frozen party permanently strands an innocent counterparty's escrow and can brick a draw kind. This is the one fix directly protecting core fund safety and the stated liveness invariant. Type: CODE.

### P2: pre-scale

- **C2**: fallback word derivation (remove grindability). Type: CODE.
- **C3**: fair-queue or per-consumer/per-address rate limit on the commitment queue, or decouple entrant eligibility from the shared-queue race. Largely defanged if C1 lands, but fix before scaling spin volume. Type: CODE.
- **C5**: Jackpot requestId de-dup guard plus an owner escape hatch to clear a stuck pending flag. Compounds with D2. Type: CODE.
- **A2**: require at least one USD source not routed through the ETH/USD feed where feasible; tighten feedMaxStaleness (90000s vs 86400s heartbeat is loose). Type: CODE.
- **E1**: give the fallback price a distinct non-tradeable/freshness status and require a delay or both-party settle at the fallback price; reduce the post-expiry keeper timing option. Type: CODE.

### P3: hardening

- **F1**: override renounceOwnership() to revert on all admin contracts (or forbid by runbook). Type: CODE.
- **C4**: bind creator share to seed liquidity/bond or exclude creator points from jackpot weighting or make creator owner-set. Type: CODE.
- **A3**: distinct-source/distinct-pool checks in setSources as defense in depth; document independence as listing policy. Type: CODE + POLICY.
- **F2, F3, F4**: code-length-guard symmetry on Market hooks; raise or document the fuzz collateral ceiling; PythAdapter return ok=false when scaled==0; event-based indexing guidance. Type: CODE (optional) / ops.

---

## 5. What NOT to change (proven-correct, do not disturb)

The following are the SOLID consensus across all five reports and my re-verification. The fix wave must treat these as invariants and must not refactor through them while implementing sections 3 and 4:

- **Settlement conservation.** winnerPayout + loserPayout + fee == 2 x collateralEach, exact by algebra and independent of rounding, fuzz-confirmed. The entry-fee NET convention balances escrow to the wei. Do not touch _settleAtPrice, _outcome, _absPnl, or _openInterest accounting; add gates around them, not inside them.
- **Reentrancy posture.** nonReentrant + strict checks-effects-interactions on every fund-moving path; no untrusted callback during a Market operation. The D1/D2 pull-payment change must preserve this (pull is strictly safer, but keep the guards and CEI ordering).
- **Access control and authority pinning.** Ownable2Step everywhere, hook onlyMarket trust chain, single factory registering only its own deployments, VRF fulfillment authority pinned per request. Do not widen any gate; F1 only removes the one-step renounce.
- **Liveness bounds.** 48h continuous-pause cap (two keys x 24h, 72h cooldown), forced-unwind reachable at expiry + 24h + at most 48h, permissionless data-and-time-driven breaker transitions, never-revert casino hooks, retryable empty-queue and timeout fallback. Preserve all of it; note that D1 is what makes the forced-unwind path actually honor this guarantee under a blocking token.
- **Numerical and oracle math.** Median selection, the exact division-free deviation guard, TWAP mean-tick rounding matching Uniswap, quoteAtTick X192/X128 handling, decimal normalization to 1e18, the 1e36 source-price ceiling, FullMath/TickMath vendored unchanged. No correctness defects at any severity; leave it alone.
- **The capped-payout invariant itself.** Neither side can lose more than escrowed. This is the backstop that bounds A1's damage; do not weaken it while adding per-address caps.

---

## Counts (consolidated, final severity)

CRITICAL: 1 (A1) | HIGH: 2 (B1, C1) | MEDIUM: 7 (A2, B2, B3, C2, C3, D1, D2, E1) | LOW: 4 (A3, B4, C4, C5, F1 -- 5 counting F1) | INFO: 3 groups (F2, F3, F4).

Two severities raised from the specialists: DoS L2 and L3 (to MEDIUM, group D) on the confirmed on-chain finding that USDG can freeze and pause. Everything else I concur with. A1 is confirmed CRITICAL and correctly reframed as a design/policy decision rather than a code bug: the code does exactly what it claims, and the flaw is that its security premise cannot hold for the target asset class on this chain.

## Bottom line for Hunt

Build quality is high and the engine is sound. Ship on majors with the A1 listing gate (P0) plus the P1 fixes and THE PIT is a defensible product. Ship memecoins as-built and the settlement price is attacker-controlled and the jackpot daily drop is farmable for cents, both from day one. The memecoin question is not an engineering gap to close, it is a product-risk decision to make deliberately, with the capped payout as the only, and only partial, safety net.
