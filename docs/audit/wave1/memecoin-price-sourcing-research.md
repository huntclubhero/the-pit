# Memecoin Price Sourcing for THE PIT: How Real Perp Venues Settle Thin Assets Safely

Research report, Wave 1 audit. Question: how do production perp/derivative venues source manipulation-resistant prices for thin or long-tail assets, and which mechanisms (oracle and non-oracle) could let THE PIT safely settle memecoin positions when the only native price is a single thin Uniswap v3 pool on Robinhood Chain (Orbit L2, chain id 4663; Chainlink majors only; no Pyth; example token whose only pool holds ~$1.2K)?

---

## (a) Blunt verdict

Safe memecoin settlement is achievable, but NOT by finding a better price feed for a token that only trades in one thin pool. There is no oracle, signed or otherwise, that makes a $1.2K single-pool token safe to settle a leveraged bet against: any feed built on that pool inherits the pool's manipulability, and a cryptographic signature over a manipulable number authenticates the number, it does not make it manipulation-resistant. Safety comes from two levers that are independent of feed vendor: (1) settling only against a reference whose measured cost-to-move through the settlement window exceeds the maximum payout the market can produce, and (2) THE PIT's own structural advantage, the hard per-market and per-address payout cap, which lets you set the maximum attacker profit BELOW that cost-to-move by construction. The correct design is therefore an economic gate, not a data-source count: replace the naive "3 sources" check with a measurable robustness gate that estimates cost-to-move-the-reference over the TWAP window against aggregate depth, and only lists a token (and only at a payout cap) where that cost comfortably exceeds the cap. Under that gate a deep memecoin (roughly $150M, multi-venue, millions in aggregate 2 percent depth) qualifies for meaningful capped markets, and a $1.2K single-pool token qualifies for nothing usable and should be excluded from continuous settlement entirely (at most an optimistic, fully-bonded, tiny-cap curiosity market). This is essentially the design Punch Markets already ships on the same Robinhood Chain, and it is the pattern Hyperliquid was forced into after the JELLY loss.

---

## (b) Ranked menu of mechanisms

Ranked by fit for a capped-payout p2p design on a fast Orbit L2. Each is a building block; the recommended architecture combines 1 + 2 (+ 3 for reach, + 4 as the backstop for the thin tail).

### 1. Hard per-market and per-address payout caps set below cost-of-manipulation  (PRIMARY LEVER)
- **Mechanism**: The maximum a position (and the maximum an address across positions in a market) can win is capped in the contract. Attacker max profit is bounded by that cap regardless of how far they push the reference. You then require `payout_cap <= cost_to_move_reference / safety_factor`.
- **Security property**: Turns manipulation into a strictly negative-EV action by construction. This is the ONLY lever that does not depend on trusting a data source, and it is the one Hyperliquid did not have on JELLY (HLP exposure was effectively unbounded through auto-deleveraging).
- **Latency**: None; enforced at position open.
- **Complexity**: Low. Pure contract logic.
- **Listing condition it enables**: Any token, but only at a cap small enough to sit under its cost-to-move. For a $1.2K pool that cap is sub-$100 (useless), which is exactly why the pool fails the gate. For a deep token it permits commercially meaningful caps.
- **Caveat**: A per-market cap is not enough alone; an attacker can open many markets or many addresses. Needs per-address and protocol-wide aggregation, plus per-block open-interest ceilings.

### 2. Aggregated multi-venue TWAP with a deviation circuit breaker  (WORKHORSE FEED)
- **Mechanism**: Take a time-weighted average (geometric-mean TWAP, Uniswap v3 style) over a window T of the token's price, aggregated across every independent venue that lists it (on-chain pools plus any CEX last-trade medians available via a signed feed). Run a live deviation check: if the instantaneous/spot price diverges from the TWAP beyond a threshold, PAUSE opening new positions while still allowing closes and liquidations. This is the Hyperliquid mark-price shape (median of oracle+EMA, own book, and a 5-venue perp median), the Vertex shape (Stork TWAP of median last-trade across reference exchanges), and the Punch Markets shape (FrothSwap TWAP + independent signed median, deviation-triggered pause).
- **Security property**: Cost to move the reference scales with the TWAP window length, the aggregate liquidity, and the number of independent venues an attacker must move simultaneously. Longer window and more venues raise the attack cost roughly linearly and multiplicatively respectively. The deviation breaker denies the attacker the ability to open a fresh position at a dislocated price, which is where the profit is captured.
- **Latency**: T (the window). For a fast L2, T on the order of minutes is cheap in wall-clock but must be long enough that cost-to-move exceeds the cap (see rubric). Requires growing the Uniswap v3 pool observation cardinality to cover T with margin, or the TWAP silently reverts / uses a shorter effective window.
- **Complexity**: Medium. On-chain TWAP read plus off-chain signed aggregation for CEX/cross-chain legs.
- **Listing condition it enables**: Deep, multi-venue tokens where measured cost-to-move over T exceeds `cap * safety_factor`. Does NOT rescue single-pool tokens: aggregating one venue is not aggregation.

### 3. Cross-pool and cross-chain aggregation  (REACH EXTENDER, real only if venues are independent)
- **Mechanism**: For a token that also trades on Ethereum mainnet (or other chains) and in multiple Robinhood Chain pools, read all of them and take a depth-weighted median/TWAP. Cross-chain legs are read either via a signed off-chain aggregator (RedStone/Stork/Pyth-Lazer pull model: fetch a signed payload, verify signature + timestamp on-chain at settlement) or via a canonical cross-chain messaging read (Chainlink CCIP, now available on Arbitrum Orbit, with the Risk Management Network as an independent kill switch).
- **Security property**: A genuine independence gain ONLY when the venues are not mirrors of the same liquidity. Two pools that are kept in sync by the same arbitrage bot, or a bridged/wrapped representation of the same token, are one venue for manipulation purposes: move the deep one and the others follow for free. Independence requires each venue to hold material standalone depth that an attacker must move separately and simultaneously.
- **Latency**: Off-chain signed feed adds seconds (staleness-checked). CCIP read adds cross-chain finality (tens of seconds to minutes) and its own trust set (the DON plus RMN).
- **Complexity**: High. Signature/timestamp verification, staleness heartbeats, per-chain readers, and the operational burden of a relayer (the same builder-operated relayer centralization risk called out for Hyperliquid HIP-3).
- **Pitfalls**: (i) mirror-liquidity double-counting inflates the robustness score with fake independence; (ii) a bridged-token price on the L2 can be pinned locally even if mainnet is honest; (iii) a signed feed over thin sources signs a manipulable number (authentication is not resistance); (iv) cross-chain read latency widens the window in which the L2 price and the reference disagree, which is itself an attack surface.
- **Listing condition it enables**: Tokens with true multi-chain, multi-pool depth (the archetypal deep memecoin). Lets a $150M token that trades on both mainnet and Robinhood Chain clear the venue-count and aggregate-depth floors.

### 4. Optimistic settlement (UMA-style bonded assertion + dispute window)  (BACKSTOP FOR THE TAIL AND FOR VOIDS)
- **Mechanism**: At settlement, a proposer posts the settlement price with a bond; a liveness window (UMA default 2 hours, configurable 2 hours to 2 days) lets anyone dispute by posting an equal bond; undisputed proposals settle optimistically, disputes escalate to UMA's Data Verification Mechanism token vote (resolves in roughly 48 to 96 hours, wrong side slashed). Bond is sized at or above the maximum payout so a false assertion is never profitable to leave unchallenged.
- **Security property**: Trust is economic, not oracular: correctness is enforced by the bond and the dispute escalation, so it works even for a token with NO continuous feed at all. Fits capped-payout p2p unusually well because payouts are bounded (so a bond >= max payout is affordable) and settlement is not latency-critical for an expiry-style bet.
- **Latency**: Hours (the liveness window), days if disputed. Unusable for anything that needs a live mark price for liquidation; usable for expiry/outcome settlement and as the "what price do we void at" arbiter.
- **Complexity**: Medium to high, plus a live dependency on UMA's dispute market and DVM being available on, or reachable from, Robinhood Chain.
- **Listing condition it enables**: Illiquid or exotic tokens with no safe continuous feed, but only in an expiry-settled, fully-bonded, small-cap format. This is the only mechanism that can touch a $1.2K-pool token at all, and even then only with cap <= bond and negligible size.

### 5. Both-counterparties-attest, disagreement falls to dispute or void  (P2P-NATIVE, weak alone)
- **Mechanism**: In a matched p2p trade, both sides sign the settlement price they observe; if they agree within tolerance the market self-settles with no oracle; if they disagree it escalates to mechanism 4 (bonded dispute) or the market voids and both sides are made whole to entry.
- **Security property**: Cheap and oracle-free when honest, but two colluding accounts can attest any price, so it is only safe when (a) the two sides are economically adversarial (each loses if they attest a wrong price against their own interest) AND (b) disagreement has a real, bonded fallback. Void-on-disagreement removes the profit but a griefer can force voids to deny an honest winner.
- **Latency**: Instant on agreement; mechanism-4 latency on dispute.
- **Complexity**: Low to medium.
- **Listing condition it enables**: Small, genuinely bilateral markets as a cost-saver on top of mechanism 4; not a standalone safety mechanism.

### 6. TWAP sampled at a randomized instant within the window  (ANTI-PINNING ADD-ON)
- **Mechanism**: Instead of settling on the price at a known block, settle on the average (or a sample) taken at a block the attacker cannot predict in advance (commit-reveal randomness or a VRF-selected sample point inside the window).
- **Security property**: Defeats the cheap "pin the exact settlement block" attack that is especially dangerous on a fast L2 where an attacker can occupy one specific block cheaply. Raises required attack from a single block to holding the dislocation across the whole (unknown) window.
- **Latency**: Adds the randomness reveal (seconds to a block).
- **Complexity**: Low to medium; needs a randomness source on the Orbit chain.
- **Listing condition it enables**: A modifier that hardens 2 and 3; does not by itself make a thin token listable.

**Deprioritized / rejected**: a bare single-pool spot read (trivially manipulable), a signed feed that wraps only that single pool (authentication, not resistance), and "list it because a vendor has a feed name for it" (vendor coverage is not depth). Memesliquid-style marketing ("long any memecoin, deep cross-margin liquidity") could not be verified to a mechanism and should be treated as a claim, not a design.

---

## (c) Recommended LISTING-ELIGIBILITY RUBRIC (replaces the naive "3 sources" check)

The gate is a single inequality with measurable inputs. A token is listable at a given per-market payout cap only if the estimated cost to move the settlement reference through the settlement window exceeds that cap by a safety margin.

### Core inequality
```
payout_cap_per_market  <=  CostToMove(reference, window) / SafetyFactor
```
- `SafetyFactor`: 5x to 10x (higher for newer tokens / shorter history / fewer venues).
- `CostToMove(reference, window)`: the estimated capital an attacker must sink to hold the reference dislocated by the amount that would flip a max-cap position, for the full settlement window, net of arbitrage recapture.

### Cost-to-move estimator (heuristic, order-of-magnitude)
For a concentrated-liquidity / constant-product venue of liquidity `L`, holding a spot dislocation of factor `r` (target price / true price) for a window of `N` blocks against arbitrage intensity `A`, the accepted shape from the Euler and AMM-oracle research is:

```
CostToMove  ≈  Σ_over_independent_venues [ L_v · g(r) · N ] / (1 + A · N)
```
where `g(r)` grows superlinearly in the dislocation (for constant product, moving price by factor r sinks on the order of `L·(√r − 1)^2` per block before arbitrage). The three robustness facts that fall out of this and that the rubric operationalizes:
1. **Cost scales with aggregate liquidity L.** Thin pool => near-zero cost. This is why the $1.2K pool is hopeless.
2. **Cost scales with window length N.** Longer TWAP => linearly harder to sustain. This is the cheapest knob THE PIT controls.
3. **Cost collapses when arbitrage is absent or the attacker is the sole LP** (`A -> 0`, or the manipulator owns the liquidity). On a fast L2 with one LP and no external arbitrageurs, even a TWAP is cheap. This is the single most dangerous property of a native-only memecoin and the reason venue independence, not raw depth in one pool, is the real gate.

FLAG: the exact closed form above is a heuristic assembled from the Euler cost-of-attack model and an arXiv AMM-oracle-manipulation paper; the precise coefficient was extracted by a summarizer and I could not line-by-line verify the closed form. The STRUCTURE (superlinear in dislocation, linear in window, collapses without arbitrage or with a sole LP, scales with liquidity) is consistent and robust across all sources and is what the rubric should rely on. Calibrate the coefficient empirically against the actual pool before trusting a number.

### Measurable gates (all must pass to list at a meaningful cap)
| Gate | Requirement | Rationale |
|---|---|---|
| Independent venue count | `>= 3` venues that each hold material standalone depth AND are not mirrors/bridges of one another (exclude wrapped or same-arb-bot-synced copies), OR a single venue so deep that `CostToMove >> cap` on its own | Kills fake independence; forces simultaneous multi-venue attack |
| Aggregate 2%-depth | `>= $X` (suggest floor around $2M to $5M of aggregate depth to move price 2%; tune to desired cap) | Sets the `L` in the cost formula above a useful floor |
| Cost-to-move vs cap | `CostToMove(window) >= SafetyFactor * cap` | The core inequality; the actual gate |
| TWAP window | `T` chosen so the inequality holds; longer for thinner/newer tokens | Turns the window knob into cost |
| Observation cardinality | Pool cardinality grown to cover `T` with margin | Otherwise the TWAP silently degrades to a shorter, cheaper-to-move window |
| Price history / seasoning | Minimum age and cumulative real (costly-to-fake) volume before eligible | Punch-style seasoning; denies wash-traded fake depth |
| Deviation circuit breaker | Live spot-vs-TWAP deviation threshold that pauses NEW positions (closes/liquidations stay open) | Denies opening at a dislocated price, where profit is captured |
| Per-block OI ceiling + per-address cap | OI proportional to underlying depth; per-address payout aggregation | Stops the many-markets / many-addresses bypass of a per-market cap |
| Void / dispute backstop | Every market has a bonded optimistic settlement (mechanism 4) as the "what do we settle at if the feed is bad" arbiter | Bounds the worst case even if the feed is compromised |

### Tiering (how tokens map to markets)
- **Tier A, majors (ETH, BTC, USDG):** Chainlink Data Feed exists on Robinhood Chain -> settle directly, high caps.
- **Tier B, deep memecoin (~$150M, multi-venue incl. mainnet):** passes all gates. Mechanism 2 + 3 aggregated TWAP with deviation breaker; cap set to `CostToMove/SafetyFactor`; commercially meaningful caps. LISTABLE.
- **Tier C, mid token (one deep pool + one CEX):** marginal. Long-window TWAP (mechanism 2 + 6) with a small cap and a mandatory bonded optimistic backstop (mechanism 4). LISTABLE ONLY AT SMALL CAP.
- **Tier D, $1.2K single thin pool:** fails venue-count, aggregate-depth, and cost-to-move gates at any useful cap. NOT LISTABLE for continuous settlement. Optional: an expiry-only, fully-bonded optimistic market (mechanism 4) with `cap <= bond` and negligible size, or exclude outright. This is the correct answer for the example token.

The one-line replacement for "3 sources": **do not count sources; measure cost-to-move the aggregated reference over the settlement window across independent venues, and only allow a payout cap that sits a safety factor below it.**

---

## (d) Sources

Hyperliquid mechanism and incident:
- [Hyperliquid Docs, Robust price indices (oracle + mark price construction, venue weights)](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/robust-price-indices)
- [Hyperliquid Docs, Oracle](https://hyperliquid.gitbook.io/hyperliquid-docs/hypercore/oracle)
- [Hyperliquid Docs, HIP-3 builder-deployed perpetuals (deployer-chosen oracle, 500k HYPE stake, slashing on >50% move, cross-margin restriction)](https://hyperliquid.gitbook.io/hyperliquid-docs/hyperliquid-improvement-proposals-hips/hip-3-builder-deployed-perpetuals)
- [OAK Research, Hyperliquid and the JELLY attack: context, vulnerability and team solution](https://oakresearch.io/en/analyses/investigations/hyperliquid-jelly-attack-context-vulnerability-team-solution)
- [Halborn, Explained: The Hyperliquid Hack (March 2025)](https://www.halborn.com/blog/post/explained-the-hyperliquid-hack-march-2025)
- [CoinDesk, Hyperliquid delists JELLYJELLY after vault squeezed in $13M tussle](https://www.coindesk.com/markets/2025/03/26/hyperliquid-delists-jellyjelly-after-vault-squeezed-in-usd13m-tussle)

GMX:
- [GMX Docs, Trading on V2 (Chainlink Data Streams, keeper execution)](https://docs.gmx.io/docs/trading/v2/)
- [GMX substack, GMX V2 live with Chainlink Data Streams](https://gmxio.substack.com/p/gmx-v2-is-now-live-with-chainlink)

Drift:
- [Drift Protocol case study on Pyth (oracle-anchored DAMM)](https://www.pyth.network/blog/drift-protocol-revolutionizing-decentralized-derivatives-i-pyth-case-study)
- [Drift liquidity mechanisms (DAMM, DLOB, JIT)](https://levex.com/en/blog/drift-liquidity-mechanisms-explained)
- [Drift Docs, advanced orders (oracle vs mark price)](https://docs.drift.trade/trading/advanced-orders-faq)

Vertex:
- [Vertex Docs, Pricing (Oracles) (Stork TWAP of median last-trade across reference exchanges)](https://docs.vertexprotocol.com/basics/pricing-oracles)

Punch Markets (memecoin perps on Robinhood Chain, the direct reference design):
- [Punch Markets (Froth.meme launch -> FrothSwap graduate/season -> capped isolated perp; FrothSwap TWAP + independent signed median; deviation pause; OI ceilings, spreads, profit caps)](https://punch.markets/)

Oracle networks (feed sourcing reality):
- [Pyth Developer Hub, Price Aggregation (120+ publishers, median-of-votes with confidence)](https://docs.pyth.network/price-feeds/core/how-pyth-works/price-aggregation)
- [Pyth blog, price feed aggregation proposal](https://www.pyth.network/blog/pyth-price-aggregation-proposal)
- [RedStone, Pull oracles vs Push oracles (pull model, signed payloads, 50+ sources CEX+DEX)](https://blog.redstone.finance/2024/08/21/pull-oracles-vs-push-oracles/)
- [RedStone vs Chainlink vs Pyth comparison (2026)](https://blog.redstone.finance/2026/03/30/blockchain-oracles-comparison-chainlink-vs-pyth-vs-redstone-2026/)

TWAP manipulation-cost economics:
- [Euler, Uniswap v3 TWAP manipulation cost-of-attack (LaTeX source, capital and per-block cost formulas)](https://github.com/euler-xyz/uni-v3-twap-manipulation/blob/master/cost-of-attack.tex)
- [Euler Finance, Uniswap Oracle Attack Simulator](https://www.euler.finance/blog/oracle-attack-simulator)
- [Uniswap blog, Uniswap v3 TWAP oracles in proof of stake (multi-block, cardinality)](https://blog.uniswap.org/uniswap-v3-oracles)
- [Uniswap Docs, Oracle (geometric-mean TWAP, end-of-block observations, cardinality)](https://docs.uniswap.org/concepts/protocol/oracle)
- [arXiv 2606.03548, Cost of Manipulation in AMM-Based Oracles (closed-form heuristic; FLAGGED, coefficient not line-by-line verified)](https://arxiv.org/pdf/2606.03548)
- [arXiv 2406.02172, Layer-2 Arbitrage: swap dynamics and price disparities on rollups (fast-block arbitrage context)](https://arxiv.org/html/2406.02172v1)

Optimistic / non-oracle settlement:
- [UMA Docs, Setting custom bond and liveness parameters (2h default liveness, 2h-2d range, bond >= final fee)](https://docs.uma.xyz/developers/setting-custom-bond-and-liveness-parameters)
- [UMA Docs, How does UMA's oracle work (propose/dispute, DVM escalation)](https://docs.uma.xyz/protocol-overview/how-does-umas-oracle-work)

Cross-chain reading:
- [Chainlink CCIP comes to Arbitrum Orbit (cross-chain messaging/data for Orbit L2/L3; RMN kill switch)](https://www.newsbtc.com/news/chainlink-ccip-comes-to-arbitrum-orbit-as-layer-3-builders-chase-safer-messaging/)

### Verification flags
- The exact closed-form manipulation-cost coefficient (arXiv 2606.03548) was extracted by a summarizer, not read line by line; rely on its STRUCTURE, calibrate the coefficient empirically against the real pool before setting caps.
- Punch Markets publishes the SHAPE of its listing gates (durable liquidity, real price history, deviation pause, OI/profit caps) but not the exact numeric thresholds; treat the specific numbers in the rubric above as starting proposals to calibrate, not as Punch's published values.
- "Memesliquid" and similar "long any memecoin" marketing could not be traced to a verifiable pricing mechanism and is treated as a claim, not evidence.
- Whether Pyth or RedStone can be deployed permissionlessly on Robinhood Chain is mechanically plausible (both are pull oracles whose receiver contracts can be deployed to any EVM chain and fed signed payloads), BUT neither will produce a safe feed for a token that only trades in one thin on-chain pool: their aggregation collapses to that single manipulable source, so the output is a signed version of the manipulable price. Confirmed negative for single-pool tokens.
