# THE PIT: Wave 2 Consolidated Findings and Fix Plan (Chief Red-Team Lead)

Consolidator: chief (internal, wave 2) | Date: 2026-07-23 | Basis: twelve wave-2 attacker reports (red-oracle, red-jit, red-composition, red-access, red-casino, red-dos, red-breaker, red-gametheory, red-feebuyback, red-pullpay, red-reentrancy, red-settlement), the wave-1 consolidated register, the settlement / economics / tokenomics design docs, plus independent source re-verification and real Foundry PoCs written under contracts/test/redteam/.

Method note: every HIGH below was re-verified by reading the actual source (OracleRouter.sol, MarketFactory.sol, Market.sol, Jackpot.sol, ChainlinkAdapter.sol) and, for the flagship JIT finding and the trusted-owner price finding, by writing and running PoC tests that compile and pass against the real contracts. Where I differ from an attacker's severity I say so and why.

PoC files committed in this worktree:
- contracts/test/redteam/JitSnapshotInflation.t.sol (2 tests, PASS) : the flagship JIT snapshot-inflation HIGH.
- contracts/test/redteam/TrustedOwnerPrice.t.sol (1 test, PASS) : the TO-1 owner-price HIGH.

---

## 1. Executive summary

### Is there an EXTERNAL (no-privileged-role) drain? YES, two, both conditional and code/design-fixable.

1. Memecoin settlement drain (wave-1 A1 CRITICAL, now amplified by wave-2 W2-1). On a Tier B_DEEP / C_MID single-pool memecoin the settlement price is attacker-controllable (A1, unchanged from wave 1: the "three independent sources" are one pool read three ways on this chain). Wave 2 proves the one quantitative backstop the gated memecoin track relies on, max_payout <= costToMove / safetyFactor, is itself defeated: an attacker inflates the tracked-pool balanceOf just-in-time inside the same permissionless createMarket transaction and freezes an OI / payout cap orders of magnitude above the honest value. My PoC bakes a cap 167x the honest cap while the pool sits at its true depth, and shows the resulting market accepts 33x the open interest an honest market would. So the memecoin bleed is neither small nor bounded to honest liquidity. This drain does NOT exist for Tier A majors (independent feed, no pool-derived cap).

2. Jackpot wash-farm (W2-2, red-casino H-J1). An external attacker drains a seeded or donated standing jackpot pot for positive EV whenever the pot exceeds ~1.31x the weighting epoch's honest fees. That inequality is the DEFAULT at a seeded launch and during any draw lull. I re-derived the threshold algebraically and it reproduces red-casino's worked case exactly (seed 50k, honest epoch fees 2k: spend ~6.7k on epoch points, capture ~29k across the 7 daily + 1 weekly draws, net +22.6k, repeatable until the seed is drained).

### Honest state of each risk class

- EXTERNAL real-value: NOT SAFE on memecoins as-built (A1 + W2-1). NOT SAFE for a seeded jackpot above the threshold (W2-2). SAFE on majors, and the core engine (settlement, escrow accounting, reentrancy, external access) has NO external drain.
- TRUSTED-OWNER centralization: two HIGH exposures needing owner-key compromise. TO-1 lets a compromised owner set a LIVE market's settlement price (refuting the OracleRouter NatSpec invariant, PoC-confirmed). TO-2 lets the owner steer jackpot draws by swapping the VRF coordinator. Real for a funds-holding protocol, but hardening, not a permissionless drain.
- ECONOMIC-DESIGN (not a bug): the "be the house, earn the edge" capital thesis is inverted. With a shared multiple, every high-odds offer is +EV for the TAKER, so a mechanical symmetric house vault (E3) is a taker money-pump. Conservation and the capped payout are intact; this is a product / pricing decision, not a security defect.
- LOW / hardening: bounded griefing and liveness items (OI-cap Sybil monopolization, fee-push liveness, forced-unwind free option on a fresh multi-source market, opening-breaker fallback mismatch, tracked-pool/settlement-source decoupling).

### The one-sentence verdict for Hunt

The wave-1 verdict stands and hardens: ship THE PIT on majors (Tier A) with the A1 listing gate and the wave-2 P0/P1 fixes and it is a defensible product; the memecoin track cannot be made safe by parameter tuning because both its price AND its payout-cap backstop are attacker-controllable, and the wave-2 work turns that from an assertion into a passing exploit test.

---

## 2. Authoritative severity register (deduplicated, root-cause grouped)

Severity is my final call. Fix type: CODE (a code change closes it), DESIGN (a mechanism / product decision), POLICY (a listing / ops decision code only enforces), CENTRALIZATION (owner-key hardening). Class: EXTERNAL (permissionless attacker), OWNER (needs owner-key compromise), ECON (economic design, not a bug), HARDENING.

### Group W2-A: JIT liquidity cap inflation (EXTERNAL) : flagship, triple-corroborated

| ID | Final sev | Class | One-line | Location | Fix | Found by | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W2-1 | HIGH | EXTERNAL | createMarket bakes the immutable OI cap + payout cap from a single-block-inflatable balanceOf read in the SAME permissionless tx, defeating max_payout <= costToMove/SF | OracleRouter `_trackedLiquidity` :899-910, `snapshotLiquidity` :692, `costToMoveEstimate1e18` :602, `maxMarketPayoutCap1e18` :619, NatSpec :673-683; MarketFactory `createMarket` :185-193; Market `_checkedNewOpenInterest` :892-902 | CODE | red-oracle F1, red-jit, red-composition C-1 | VERIFIED (PoC: 167x atomic inflation; inflated market accepts 33x honest OI) |

Root cause (one issue, three finders): the listing/snapshot path is the one place still keyed on a raw instantaneous balanceOf. Wave-1 B1 removed the LIVE read from the fill path (good, preserved) but the creation SNAPSHOT itself is a live balanceOf, taken inside permissionless createMarket, and the new increment-1 cost-to-move cap is read in the same tx from the same measure, so the attacker owns the snapshot instant. The NatSpec at OracleRouter :673-683 openly admits the value is single-block inflatable and fully recoverable, then wrongly reassures that "NO runtime cap or floor keys off a live read" and "a same-block spike cannot raise a cap"; the creation snapshot is exactly a same-tx live read that raises the cap permanently.

I concur with the three attackers and set this HIGH (they variously said HIGH / CRITICAL-in-context). It is not independently CRITICAL because on its own it only inflates a NUMBER; the realized drain requires composition with A1 (attacker-set memecoin settle price). A1 remains the CRITICAL; W2-1 is the force-multiplier that removes A1's only quantitative bound. For a majors-only launch (A1 gated out) W2-1 is latent, but it MUST be fixed before any Tier B/C market carries real value.

### Group W2-B: Jackpot capture (EXTERNAL + OWNER)

| ID | Final sev | Class | One-line | Location | Fix | Found by | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W2-2 | HIGH | EXTERNAL | Points-weighted draw pays a fixed fraction of the STANDING pot, so a seeded/donated pot > ~1.31x an epoch's honest fees is positive-EV wash-farmable across the 7 daily + 1 weekly draws | Jackpot :86-89, :419-427 (pays DAILY/WEEKLY bps of `balanceOf - totalClaimable`); PitPoints 7-day epoch, points-per-fill no intra-epoch decay; Market :826-834 (only 25% of the entry fee feeds the pot) | CODE | red-casino H-J1 | VERIFIED (model + source; threshold P>1.314F reproduced numerically) |
| W2-4 | HIGH | OWNER | Owner drains the jackpot by swapping the VRF coordinator for future draws; the malicious coordinator supplies a chosen `word` and winner = selectByWeight(epoch, word % total) is deterministic in that word | Jackpot `setCoordinator` :253 (onlyOwner, no timelock), `_requestDraw` :356-357 (pins current coordinator), `rawFulfillRandomWords` :406-421 | CODE + CENTRALIZATION | red-access TO-2 | VERIFIED (source; mechanism airtight) |

W2-2 refutes wave-1 I1, which held only in fully-drawn steady state (pot self-limits to ~0.33F). It breaks the moment the pot is seeded, donated, or grown by a draw lull (startDraw is permissionless but unincentivized, and skipped days are forfeited). Self-play with no external pot stays negative-sum, so the drain specifically targets SEEDED / COMMUNITY funds. red-casino L3 (win-streak farm, party-optional settle reaching a 5x points multiplier) and the daily 1.5x lower the threshold further and are folded in as amplifiers of W2-2.

### Group W2-C: Trusted-owner price and parameter control (OWNER)

| ID | Final sev | Class | One-line | Location | Fix | Found by | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W2-3 | HIGH | OWNER | Owner sets a LIVE market's settlement price and drains the counterparty, by pointing all >= 3 sources at owner-controlled adapters (median == owner's price, deviation 0). Contradicts the OracleRouter price-invariant NatSpec | OracleRouter NatSpec :16-22, `setSources` :328 (onlyOwner, no timelock), `_evaluate` :783-822, `checkPrice` :474; ChainlinkAdapter `setFeed` :47 (onlyOwner); consumed at Market `settle` :681 | CODE + CENTRALIZATION | red-access TO-1 | VERIFIED (PoC: owner drives median to any value both directions) |
| W2-5 | MEDIUM | OWNER | Owner nullifies in-flight PnL by breaking the oracle (setSources empty / failing feeds), forcing a neutral forced-unwind that denies a deep-ITM winner. Griefing, not theft; cannot exceed escrow or lock principal | OracleRouter `setSources` :328; Market settle/`_forcedUnwind` :681-713 | CENTRALIZATION | red-access TO-3 | VERIFIED (source) |
| W2-6 | MEDIUM | OWNER | Owner routes FUTURE markets' 4-way fees to owner addresses and sizes future caps (incl. inflating the creation snapshot via owner JIT pools); existing markets immutable | MarketFactory `setFeeSplit` :249, `setOiCapBps`/`setPerAddressOiCapBps` :261-266; OracleRouter `setTierConfig`/`setTrackedPools` | CENTRALIZATION | red-access TO-4 | VERIFIED (source) |
| W2-7 | LOW | OWNER | PauseGuardian.guardian is immutable per market with no rotation; a compromised guardian key cannot be rotated for a live market's life (bounded 24h/pause griefing only) | PauseGuardian :34 | CENTRALIZATION | red-access TO-5 | VERIFIED (source) |

W2-3 is the load-bearing new access finding: the router's headline invariant ("no admin function can ever set, override, or nudge a price") is false under composition. The sources are independent of each OTHER, never of the OWNER, and there is no timelock. My PoC installs three owner-controlled sources and drives checkPrice to any chosen price. Correct the NatSpec and add the mitigations in the fix plan.

### Group W2-D: Economic design (ECON) : maker fairness / house-vault thesis

| ID | Final sev | Class | One-line | Location | Fix | Found by | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W2-8 | HIGH-for-capital, INFO-for-security | ECON | Shared `multiple` makes every high-odds (k>1) offer +EV for the TAKER: same win barrier both sides, larger payoff for the taker, so taker gross EV = (k-1)*s*Q > 0. A mechanical symmetric house vault (E3) is a taker money-pump; maker capital is structurally -EV absent an information edge | Market `_resolve` :792-819, `_settleDecisive` :764, `_absPnl` :943-950 (shared multiple, asymmetric stakes) | DESIGN | red-gametheory F1 (+F2 straddle, F3 free-option) | VERIFIED (algebra; conservation and cap intact) |

Not a security bug: conservation is exact and no one loses more than escrow (red-settlement / red-pullpay confirm). It is a capital-attraction and house-vault-viability problem. F2 (near-risk-free straddle across two opposite high-odds makers) and F3 (a 30-day resting offer is a long-dated option the 10 bps entry fee underprices) are the same design axis and are folded in. I set the SECURITY severity to informational and the PRODUCT severity to high: do not build E3 as a mechanical symmetric quoter, and do not market "be the house" to LPs.

### Group W2-E: OI-cap monopolization and liveness (EXTERNAL / HARDENING)

| ID | Final sev | Class | One-line | Location | Fix | Found by | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W2-9 | MEDIUM | EXTERNAL | Per-address OI sub-cap is Sybil-defeated: nothing caps the NUMBER of addresses, so ceil(10000/2500)=4 free addresses reach ~99.9% of the global OI cap and deny all honest new opens for up to 30 days. Monopolization (M1) not closed, only made 2x harder | Market `_accrueAddressOpenInterest` :918-926, `_checkedNewOpenInterest` :892-902, MAX_DURATION :70 | CODE | red-dos SURVIVOR 1 (red-jit notes it as accepted residual) | VERIFIED (repo's own test MarketPerAddressOiCap.t.sol:44-64 drives 4 addrs to openInterest()==99.9% of cap) |
| W2-10 | MEDIUM | EXTERNAL | Forced-unwind free option on a YOUNG multi-source market: a losing party holds one cheap minority source dislocated from ~MIN_HOLD through expiry+24h; because the agreed-print ring was never filled, checkPrice stays in permanent COOLDOWN, so settle is impossible and expiry+24h triggers a neutral unwind refunding the loser's stake | OracleRouter `checkPrice` fallback :491-502, ring fill :480-488, `_fallbackPrice` :871-872; Market settle/`_forcedUnwind` :681-713 | CODE | red-breaker SURVIVOR 1 | VERIFIED (source; narrow to launch window; attentive winner defeats it by snapping 3 OK prints) |
| W2-11 | LOW/MED griefing | EXTERNAL | Whole-market opening-breaker DoS: hold an off-market pool to keep openingAllowed false; self-limiting, opening-only, no theft | OracleRouter `openingAllowed` :637-659; Market `_requireOpeningAllowed` :842 | POLICY/CODE | red-oracle F3, red-breaker SURVIVOR 2 | VERIFIED (source) |

W2-9: I keep MEDIUM (matches wave-1 B2 and red-dos; disagree with treating it as fully closed). A per-address bps sub-cap cannot close monopolization on a Sybil-cheap chain; it needs a real per-open cost or reserved honest headroom, or an explicit disclosed thin-market risk acceptance.

### Group W2-F: Push-payment fee liveness (EXTERNAL-adjacent / HARDENING) : one issue, three finders

| ID | Final sev | Class | One-line | Location | Fix | Found by | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W2-12 | MEDIUM | HARDENING | Fee distribution PUSHES to the 4 immutable recipients; wave-1 D1 made PARTY payouts pull but left the FEE leg pushing. A frozen (USDG is freeze-capable) recipient reverts EVERY fillOffer and decisive settle market-wide while the oracle is OK, and forced-unwind is unreachable then, re-breaking the "every position reaches terminal payout" invariant | Market `_distributeFee` :826-835, called at fill :589 and `_settleDecisive` :779 | CODE | red-pullpay, red-feebuyback F-LOW-1, red-dos SURVIVOR 2 | VERIFIED (source) |

Three attackers found the same residual; it is ONE issue. Not attacker-triggerable (recipients are protocol-owned, no ERC20 recipient callback), so I hold it at MEDIUM rather than HIGH, but the weakest link (the buyback recipient holding accruing USDG for a long pre-executor window, plausibly an EOA/placeholder) makes credit-on-failure cheap insurance worth doing before mainnet.

### Group W2-G: Oracle proxy decoupling and composition seams (EXTERNAL / HARDENING)

| ID | Final sev | Class | One-line | Location | Fix | Found by | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W2-13 | MEDIUM | HARDENING/POLICY | trackedPools (the cost-to-move / floor basis) and the pools the SETTLEMENT source actually reads are never cross-checked, so governance can size costToMove to many deep pools while the settlement source reads only the deepest one; the attacker moves only that pool. Compounds with the wave-1 A2 shared-ETH/USD-leg and the adapters' inability to deliver a true aggregated multi-pool USD TWAP for TOKEN/WETH memecoins | OracleRouter `setTrackedPools` :368 vs adapter pool configs; A2 (wave 1) | CODE + POLICY | red-oracle F2 | VERIFIED (source) |
| W2-14 | LOW | HARDENING | Opening breaker validates spot against `_evaluate`'s raw median, not `peekPrice` (the price the market would actually serve during fallback), so during multi-source fallback the breaker can allow opening at a stale price the market will use | OracleRouter `openingAllowed` :642 vs `peekPrice` :533 | CODE | red-composition C-2 | VERIFIED (source) |
| W2-15 | LOW | HARDENING | VRF commitment queue has no per-consumer fair-share, so a spin flooder can starve honest spins / draw commitments (liveness, self-limited by flooder fees); timeout re-arm allows a sole fulfiller to discard-and-re-roll over long windows (bias, not choice, defeated by any keeper) | CommitRevealCoordinator :311-318 (per-msg.sender rate limit, shared queue); SpinVRF/Jackpot share `_queue` | CODE | red-casino L1, L2 | VERIFIED (source; wave-1 C2/C3 residuals) |

### Refuted / confirmed-SOLID (do not re-open, do not disturb)

- Reentrancy / external-call / callback drain: NO SURVIVORS (red-reentrancy). Every attacker-reachable transfer lands in a nonReentrant, strict-CEI function; USDG has no transfer callback and the guards hold even if it did.
- Settlement + asymmetric-odds math: NO SURVIVORS (red-settlement). Conservation exact by algebra (winnerPayout + loserPayout + fee == winnerStake + loserStake) for all inputs, fuzz-confirmed; odds shift WHO posts what, never the ceiling.
- Pull-payment credit / withdraw accounting: NO SURVIVORS (red-pullpay). Escrow-solvency invariant holds with EQUALITY on every path; no position credits against another's stake; jackpot pot cannot underflow.
- Fee-split (4-way) conservation: SOLID (red-feebuyback). Four transfers sum EXACTLY to fee; shares are hardcoded constants (only addresses tunable); no skim, no self-referral loop in-engine.
- External access control: CLEAN (red-access Part A). Every setter onlyOwner/onlyGuardian; hooks pinned onlyMarket/registrar; VRF authority pinned per request/draw; Ownable2Step, renounce disabled; Market has no owner.
- The three composition seams: SOLID (red-composition). Odds x cost-to-move cap x per-address sub-cap; fee-split push x pull-payment credits; points/jackpot x odds x fee-split (negative-sum from an attacker's OWN fees). W2-2 attacks the SEEDED pot, a different vector, not this seam.
- Wave-1 casino fixes confirmed holding (red-casino): C1 uniform ENTRANTS mode deleted, both draws points-weighted; C4 creator-share excluded from epoch weight; C5 dedup + cancelStuckDraw moves no funds; D2 pull-payment jackpot credits.

Deduplication summary: 12 attacker reports collapse to 15 register items in 7 groups. The JIT theme (red-oracle F1 + red-jit + red-composition C-1) is ONE item (W2-1). The fee-push liveness theme (red-pullpay + red-feebuyback + red-dos) is ONE item (W2-12). The jackpot theme splits into the external wash-farm (W2-2, with L3/daily amplifiers) and the owner coordinator-swap (W2-4). The maker-fairness theme (red-gametheory F1/F2/F3) is ONE economic-design item (W2-8).

---

## 3. Prioritized fix plan

### P0 : blocks ANY real-value launch

- A1 listing gate (carried from wave 1, still the gate that makes the launch honest). Enforce in code that a value-bearing token is listable only if at least one configured source is independent of its settlement pool. For launch this resolves to a majors / real-Chainlink-feed allowlist. Without it, a Tier B/C token settles against its own single pool and is drainable from block one. Type: CODE + POLICY. Maps to: A1 (wave 1), gates W2-1 and W2-13.

### P1 : blocks mainnet with real value

- W2-1 (JIT cap inflation). Switch the snapshot / floor / cost-to-move BASIS off raw balanceOf onto a manipulation-resistant measure: time-averaged in-range liquidity via `consultMeanLiquidity` (already used by CrossPoolTwapAdapter for TWAP weighting) sampled over the settlement window, OR a min-over-trailing-window read, OR an owner-delayed snapshot (never a same-tx live read). Alternatively gate createMarket to owner/timelock for Tier B/C. This closes W2-1, and the same basis change closes the wave-1 B3/B4 live-read residuals. Do NOT touch `_openInterest` accounting or the escrow conservation math; change only the basis feeding the cap. Regression seed: contracts/test/redteam/JitSnapshotInflation.t.sol (must flip to REVERT / honest-cap after the fix). Type: CODE.
- W2-2 (jackpot wash-farm). Pay draws from a rate-limited DRIP bound to recent fee INFLOW rather than the standing balance, so pot value cannot outrun the epoch's honest point mass; OR require a minimum distinct-address point mass / participant count before a draw pays; OR bucket the daily weight per-day to kill the 7x amortization. Also fold in L3 by making the win-streak multiplier resistant to party-optional self-settle. Type: CODE (+ DESIGN for the drip curve).
- W2-3 (owner sets live price) and W2-4 (owner steers jackpot). Timelock the sensitive setters (setSources, setFeed, setCoordinator) so a live position can settle at the honest price / a draw can complete before a swap takes effect; require at least one genuinely owner-independent source for any value-bearing token; add a max-per-period pot-outflow guard and a two-key split between coordinator-setter and draw-starter; and CORRECT the OracleRouter price-invariant NatSpec (:16-22) to state the truth (sources are independent of each other, not of the owner; the guarantee is a timelock, not an impossibility). Type: CODE + CENTRALIZATION.
- W2-9 (OI-cap Sybil monopolization). Add a real cost to consuming the cap: a nonrefundable per-open bond, or reserved honest headroom, or an opening cost that scales with cap consumed. A per-address bps cap alone cannot close it on a Sybil-cheap chain. If not fixed, disclose it explicitly as an accepted thin-market liveness risk. Type: CODE (or POLICY if accepted).
- W2-12 (fee-push liveness). Credit the fee split to a pull balance, or try/catch each of the four fee transfers and credit-on-failure, so one frozen recipient cannot brick fills and decisive settlements market-wide. At minimum make the buyback (pre-executor) recipient a never-blacklistable multisig. Type: CODE.

### P2 : pre-scale

- W2-10 (forced-unwind free option on a fresh market). Pre-seed the agreed-print ring at listing (three permissionless checkPrice calls while OK) so the fallback path always exists and sustained deviation self-heals in <= 90 minutes instead of sticking in permanent cooldown; then force-unwind is never deviation-reachable on a young market. Type: CODE (cheap).
- W2-13 (tracked-pool / settlement-source decoupling + A2). Pin trackedPools to the actual settlement-source pools; ship an adapter that aggregates multi-pool AND converts WETH to USD so the breaker compares like units; tighten feedMaxStaleness (90000s vs 86400s heartbeat is loose). Type: CODE + POLICY.
- W2-14 (opening breaker fallback mismatch). Have openingAllowed compare spot against `peekPrice(token)` (the price checkPrice would actually serve) rather than `_evaluate`'s raw median. Type: CODE.
- W2-15 (VRF queue fairness + timeout re-arm). Fair-share / reserve queue capacity per consumer; remove the discard-and-re-roll bias on the timeout path (mix in data fixed at request time). Largely defanged once W2-2 lands, but fix before scaling spin volume. Type: CODE.

### P3 : hardening

- W2-5 / W2-6 / W2-7 (residual owner centralization): timelock the future-market parameter setters (defense in depth), make the PauseGuardian rotatable for future markets, and document the accepted trusted-owner surface. Type: CENTRALIZATION.
- W2-8 (maker fairness / house vault). PRODUCT, not a code bug. If E3 (house vault) is built, load its odds with drift + realized-vol + adverse-selection margin, prefer ONE side, cap odds well below 20:1 for symmetric tokens, and surface a "fair odds given m and this token's vol" UI helper; consider a protocol-side minimum vig on k as a function of m. Reframe the sec-5 narrative: makers are directional bettors, the edge accrues to informed takers. Do NOT market "be the house, earn the edge" to LPs. Type: DESIGN + UI.
- Doc drift (red-composition): the economics / fee-model design docs still say 40/40/20 + 70 bps; shipped code is 25/10/39/26 + 50 bps default. Code is source of truth; update the docs. Type: DOC.

---

## 4. What NOT to change (proven-correct SOLID consensus)

The fix wave must treat these as invariants and must not refactor through them while implementing section 3. Every one is a wave-2 NO-SURVIVORS / SOLID result plus my re-verification:

- Settlement + asymmetric-odds conservation. winnerPayout + loserPayout + fee == winnerStake + loserStake, exact by algebra and independent of rounding and of the fee, fuzz-confirmed (MarketOdds / SettlementFuzz / MarketInvariant green). Do NOT touch `_settleAtPrice`, `_resolve`, `_settleDecisive`, `_absPnl`, `_fillMath`, or `_openInterest` accounting; add gates AROUND them, never inside.
- Reentrancy posture. nonReentrant + strict CEI on every fund-moving path; no untrusted callback during a Market operation. The W2-12 credit-on-failure change must preserve pull safety and CEI ordering.
- Pull-payment credit / withdraw accounting. The escrow-solvency invariant holds with equality on every path; keyed on msg.sender, zeroed before transfer, per-account failure isolation. Do not restructure it.
- Fee-split conservation. Four transfers sum EXACTLY to fee; shares are hardcoded constants. Only the PUSH-vs-credit mechanism (W2-12) changes, never the split arithmetic.
- External access control and authority pinning. Ownable2Step everywhere, hooks onlyMarket/registrar, VRF authority pinned per request/draw, renounce disabled, Market has no owner. The W2-3/W2-4 fixes ADD timelocks and independence requirements; they must not widen any existing gate.
- Liveness bounds. Single pause capped at 24h (MAX_PAUSE_DURATION; the 48h figure is only the worst-case continuous pause one market can EXPERIENCE when its own key and the global key stack back-to-back, NOT the guardian's per-key emergency coverage: corrected in wave-2b R-10 per re-timelock Finding C), permissionless data-and-time-driven breaker transitions, never-revert casino hooks, forced-unwind reachable at expiry+24h. W2-10 and W2-12 are what make the forced-unwind guarantee actually hold under a fresh-market ring and a frozen fee recipient; preserve the guarantee, do not weaken it.
- The capped-payout invariant. Neither side loses more than escrowed; the winner never takes more than total escrow. This is the backstop that bounds A1's and W2-1's damage; do not weaken it while re-basing the cap (W2-1) or adding per-open cost (W2-9).
- Wave-1 casino fixes (C1/C4/C5/D2) are confirmed holding; do not regress them while fixing W2-2/W2-4/W2-15.

---

## 5. HIGHs: reproduced-with-PoC vs verified-by-reading

- W2-1 JIT snapshot inflation : REPRODUCED with a passing Foundry PoC (JitSnapshotInflation.t.sol : 167x atomic same-tx cap inflation with the pool fully recovered post-tx; inflated market accepts 33x the honest OI cap while an honest twin market reverts the identical fill).
- W2-3 TO-1 owner sets live settlement price : REPRODUCED with a passing PoC (TrustedOwnerPrice.t.sol : owner drives the router median to any price in either direction with deviation zero, refuting the NatSpec invariant).
- W2-2 jackpot wash-farm H-J1 : VERIFIED by numeric model + source (threshold P > 1.314F reproduced exactly; Jackpot :419-427 pays a fixed fraction of the standing balance). Stated as a model verification, not a full trading PoC, per scope.
- W2-4 TO-2 owner steers jackpot draws : VERIFIED by source (setCoordinator onlyOwner + no timelock + malicious coordinator supplies `word` + deterministic selectByWeight).
- W2-8 maker-fairness (economic design, not security) : VERIFIED by algebra (taker gross EV = (k-1)*s*Q > 0 for k>1; conservation and cap intact).
- W2-9 OI-cap Sybil monopolization : VERIFIED by the repository's OWN test (MarketPerAddressOiCap.t.sol:44-64 drives 4 addresses to 99.9% of the global cap).
- W2-5/6/7, W2-10 through W2-15 : VERIFIED by source reading.

## Counts (wave-2 final severity)

HIGH: 4 (W2-1 EXTERNAL, W2-2 EXTERNAL, W2-3 OWNER, W2-4 OWNER) plus W2-8 HIGH-for-capital / INFO-for-security (ECON). MEDIUM: 6 (W2-5, W2-6, W2-9, W2-10, W2-12, W2-13). LOW: 5 (W2-7, W2-11, W2-14, W2-15, plus the L3 amplifier folded into W2-2). Two EXTERNAL drains exist (W2-1 composed with A1, and W2-2), both code/design-fixable; the core engine has none. The wave-1 CRITICAL A1 stands unchanged and is the umbrella gate.
