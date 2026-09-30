# THE PIT: Operations Runbook (Robinhood Chain, id 4663)

RPC: https://rpc.mainnet.chain.robinhood.com (chain id 4663, free gas)
Explorer: https://robinhoodchain.blockscout.com

## Canonical addresses (verified on-chain 2026-07-23)

| What | Address | Notes |
| --- | --- | --- |
| USDG (Global Dollar) | 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 | decimals 6. WARNING: impostor "Global Dollar"/USDG tokens exist on this chain; only this address is canonical. |
| WETH | 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 | |
| UniswapV3Factory | 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA | verified, OLI-tagged |
| Chainlink ETH/USD proxy | 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9 | 8 decimals, heartbeat 86400s, deviation 0.5 percent (Chainlink RDD path eth-usd-shared-svr). Feed-hunt note: a second proxy 0x5058aDee53b04e374d8bEDbAD634Bc4778F50b22 shares the same aggregator; the RDD documents 0x78F3..., use it. |
| Chainlink USDG/USD proxy | 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2 | 8 decimals, heartbeat 86400s (usdg-usd-shared-svr); useful for future USDG depeg monitoring. |
| Pyth price feeds (Pyth Core) | 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a | Bytecode verified on mainnet 2026-07-28; registered in pyth-crosschain contract manager for robinhood + robinhood_testnet (deploymentType pro-compatible-production). Unlocks a Tier A Pyth adapter (IIndependentSource); wire only after the dormant Pyth confidence/staleness checks from the final audit. Pyth ENTROPY is NOT deployed. |

Chainlink VRF v2.5 is NOT deployed on this chain; randomness comes from
CommitRevealCoordinator (see below). Pyth PRICE FEEDS are live (see table
above; verified 2026-07-28), but Pyth ENTROPY is not deployed, and neither
is Gelato VRF. Decision (2026-07-28): keep CommitRevealCoordinator, swap to
Pyth Entropy if and when Pyth deploys it here (spec section 10, item 6).

## Deploying the stack

`script/Deploy.s.sol` deploys and wires everything and writes
`deployments/robinhood-4663.json`.

Required env: `OWNER`, `GUARDIAN`, `TREASURY`, `REFERRAL_POOL`, `BUYBACK`.
Optional env: `USDG` (defaults to the canonical address above), `ETH_USD_FEED`
(defaults to the Chainlink ETH/USD proxy above), `VRF_OPERATOR` (defaults to
`OWNER`), `OI_CAP_BPS` (defaults to 1000), `OPEN_BOND_BPS` (defaults to 50,
max 500).

### Open bond is armed at deploy (wave-2b R-3)

The anti-monopolization open bond (W2-9) is armed at the factory inside the
deploy transaction at `OPEN_BOND_BPS` = 50 bps. Do NOT deploy a value-bearing
stack with `OPEN_BOND_BPS=0`: the per-market rate is immutable, createMarket is
permissionless, and post-deploy arming is timelocked, so a bond-0 factory lets
a monopolizer front-run createMarket for any hot token and bake bond 0 into
that market forever.

Frontend / integrator consequences of the armed bond:

- fillOffer pulls `bond = totalStake * openBondBps / 10_000` from the TAKER in
  addition to the taker collateral. The taker's USDG approval must cover
  `takerCollateral + bond` or the fill reverts on the bond transferFrom.
- The bond is nonrefundable BY DESIGN, including on a protocol-caused neutral
  forced-unwind (oracle failure past expiry): both parties get their stake
  back, the bond does not come back. Surface this in the fill UI (fairness
  disclosure, re-composition F4).

Dry run against a fork (no broadcast, no keys):

    forge script script/Deploy.s.sol --fork-url https://rpc.mainnet.chain.robinhood.com

Production broadcast adds `--broadcast` and a signer.

### Ownership handover runbook (wave-2b R-4)

Every owned contract (OracleRouter, ChainlinkAdapter, TwapAdapter,
TwapAdapterB, CrossPoolTwapAdapter, TwoHopTwapAdapter, PitPoints,
CommitRevealCoordinator, SpinVRF, Jackpot, MarketFactory) is handed to the
governance TIMELOCK, and the contracts are Ownable2Step, so the handover has
two phases:

1. Deploy.s.sol (phase 1, automatic): calls `transferOwnership(timelock)` on
   all eleven contracts AND schedules the acceptance batch on the timelock (eleven
   `acceptOwnership()` calls plus revocation of the deployer's temporary
   proposer/canceller roles) with delay `TIMELOCK_MIN_DELAY` and salt
   `HANDOVER_SALT`. It then asserts `pendingOwner() == timelock` on every
   contract and that the operation is pending; the operation id and salt are
   written to `deployments/robinhood-4663.json`.
2. FinalizeHandover.s.sol (phase 2, run by OWNER once the delay elapses):

       forge script script/FinalizeHandover.s.sol --rpc-url robinhood --broadcast

   Executes the batch via `timelock.executeBatch` and asserts
   `owner() == timelock` on every owned contract. Idempotent: re-running after
   execution just performs the ownership audit.

SECURITY WINDOW: until phase 2 executes, the DEPLOYER key is the live,
fully privileged, un-timelocked owner of the entire stack (Ownable2Step keeps
the current owner in power until acceptance). Treat the deployer key as a
production secret, do not discard or reuse it casually, and run phase 2 at the
earliest allowed time. If the deployer key is compromised in this window the
timelock provides NO protection; the only remedy is OWNER cancelling the
batch, the deployer (or attacker) being outrun on `transferOwnership`, or
redeploying.

## Major (Tier A) source quorum: wire 4+, not 3 (wave-2b R-5)

A Tier A_MAJOR token needs MIN_SOURCES = 3 FRESH sources per checkPrice or the
router returns STALE and settlement on that token is blocked. Since wave 2 the
only remediation levers (ChainlinkAdapter.setFeed, OracleRouter.setSources,
TwapAdapter/TwoHop setConfig) all sit behind the 2-day timelock. A major wired
with exactly 3 sources therefore freezes settlement for the whole timelock
window on any ROUTINE single-source failure (Chainlink feed deprecation or
migration, a TWAP pool draining below usefulness), and live positions risk the
expiry + 24h neutral forced-unwind, which denies an in-the-money winner.

POLICY: every A_MAJOR token MUST be registered with at least MIN_SOURCES + 1 =
4 sources before its market is created, so losing any single source keeps
quorum while the timelocked replacement is scheduled. On this chain the
standard WETH wiring is:

1. ChainlinkAdapter -> ETH/USD proxy (the independent source isListable needs)
2. TwapAdapter -> deepest WETH/USDG v3 pool
3. TwapAdapterB -> second WETH/USDG v3 pool (the deploy ships two independent
   single-pool TwapAdapter instances precisely for this slot; TwapAdapter
   stores one pool per token)
4. CrossPoolTwapAdapter -> aggregate across the registered WETH pools

If a major ever degrades to 3 healthy sources, treat it as an incident: the
quorum margin is consumed, and the timelocked repoint must be scheduled
IMMEDIATELY (delay starts at schedule time).

Tradeoffs (accepted): the pairwise deviation guard spans max minus min over
MORE sources, so a single outlier trips COOLDOWN slightly more often (fail-safe
direction: opening/settlement pause, fallback ring covers sustained
deviation); the median of 4 is the mean of the middle two; checkPrice costs
one extra source read.

Break-glass evaluated and REJECTED: a shorter (or guardian-held) delay for
setFeed specifically would reintroduce exactly the TO-1 instant-repoint attack
the wave-2 timelock closed; the 2-day delay on every price-config path is
load-bearing. The quorum margin restores liveness without weakening the delay,
so no break-glass path ships.

## TWAP source go-live procedure (REQUIRED once per tracked pool)

Fresh Uniswap v3 pools store exactly ONE price observation
(observationCardinality = 1). Any TWAP lookback then reverts "OLD" and our
adapters correctly report ok = false, which means the token cannot reach the
3-source minimum and stays unlistable. Before wiring any pool as a TWAP source
(TwapAdapter, CrossPoolTwapAdapter, or TwoHopTwapAdapter):

1. Grow the observation ring buffer once per pool:

       POOLS=0xPoolA,0xPoolB CARDINALITY_TARGET=240 \
       forge script script/GrowCardinality.s.sol --rpc-url robinhood --broadcast

   The default target 240 covers roughly an hour of per-block observations,
   comfortably serving a 30 minute window. The call is permissionless and
   idempotent (pools already at or above target are skipped).

2. Wait for the window to fill. The cardinality bump only takes effect as swaps
   write new observations, and observe() can only serve a window fully covered
   by stored observations. Budget: at least one full TWAP window (for a 30
   minute window: 30 minutes) of ORDINARY TRADING after the bump, longer on
   quiet pools. Verify before wiring: the adapter's read() for the token must
   return ok = true.

3. Only then register the source on the router (setSources) and the pool in
   trackedLiquidity (setTrackedPools, plus setPoolQuote for WETH-quoted pools,
   see next section).

## Market creation: seed the fallback ring first (wave-2b R-7)

createMarket REVERTS with FallbackRingNotSeeded for any token configured with
two or more sources until the router's agreed-print ring is FULL (3 prints).
The ring accepts at most ONE print per block (this is what stops an attacker
baking three copies of one timing-chosen median as the fallback settlement
price), so before creating a market on a multi-source token:

    cast send $ROUTER "primeFallback(address)" $TOKEN   # block N
    cast send $ROUTER "primeFallback(address)" $TOKEN   # block N+1
    cast send $ROUTER "createMarket..." via factory     # block N+2: its own
                                                        # prime completes the ring

primeFallback is permissionless and only records a print while all sources
currently agree; if creation still reverts, sources are deviating and the
token SHOULD NOT get a market at that moment anyway. Single-source
(aggregating B_DEEP / C_MID) tokens never serve fallback and are exempt.

## WETH-quoted pools (memecoins)

Memecoin pools on this chain are quoted in WETH, not USDG. Two pieces of
configuration exist and BOTH are needed:

- Pricing: `TwoHopTwapAdapter.setConfig(token, pool, twapWindow, tokenIsToken0,
  ethUsdFeed, feedMaxStaleness)` prices the token in USDG terms as
  TWAP(TOKEN/WETH) x ChainlinkFeed(ETH/USD). Suggested feedMaxStaleness for the
  ETH/USD feed: 90000 (the feed heartbeat is 86400s; leave headroom).
- Liquidity: `OracleRouter.setPoolQuote(pool, WETH, ethUsdFeed,
  feedMaxStaleness)` declares a tracked pool as WETH-quoted so
  trackedLiquidity counts 2 x WETH balance x ETH/USD instead of 2 x USDG
  balance. Without this declaration a WETH pool contributes (almost) nothing
  and the token fails the 25K liquidity floor.

Reference rejection case (asserted in the fork suite): FWA
0xD60bF10a3556ae4538f8e2574d40e08C884549Eb, FWA/WETH 1 percent pool
0x24d2e7D6966c0490e29d797b67Cc67f486b2a114 holds about 0.32 WETH (roughly 1.2K
USD): correctly under the 25K floor, isListable(FWA) = false.

## THE PIT v2 (perps): deployment

`script/DeployPerpV2.s.sol` deploys and wires the entire v2 stack (oracle +
casino + timelock as in v1, minus the retired MarketFactory, plus the four perp
contracts) and writes `deployments/robinhood-4663-v2.json`. Wiring order
mirrors the integration-proven seam (spec 8.6, PerpIntegration.t.sol):

1. TimelockController (OWNER = proposer + sole executor; deployer holds a
   temporary proposer role revoked by the acceptance batch)
2. PauseGuardian, OracleRouter, adapters (ChainlinkAdapter, TwapAdapter,
   TwapAdapterB, CrossPoolTwapAdapter, TwoHopTwapAdapter)
3. Casino: PitPoints, CommitRevealCoordinator, SpinVRF, Jackpot (same
   cross-wiring as v1: request configs, consumers, jackpot fair-share floor)
4. PerpRiskConfig (constructor seeds the LOCKED leverage schedule
   4x/6x/6x/8x/10x/15x plus every spec-10 launch default)
5. InsuranceFund, PitVault, PerpEngine (the engine max-approves the vault for
   USDG in its constructor: settleTraderLoss PULLS via transferFrom)
6. vault.setEngine, insuranceFund.setEngine, insuranceFund.setVault (all
   one-shot), points.setRegistrar(engine) + points.registerMarket(engine)
   (the engine is the v2 points consumer and takes the registrar slot the
   retired MarketFactory held)
7. Seeding: insuranceFund.seed(IF_SEED) and vault.deposit(VAULT_BOOTSTRAP,
   OWNER) (PLP bootstrap shares go to OWNER, never the deployer)
8. transferOwnership(timelock) on all FOURTEEN owned contracts + schedule of
   the acceptance batch under salt HANDOVER_SALT_V2

Required env: `OWNER`, `GUARDIAN`, `TREASURY`, `REFERRAL_POOL`, `BUYBACK`.
Optional env (v1-shared): `USDG`, `ETH_USD_FEED`, `VRF_OPERATOR` (defaults to
OWNER), `TIMELOCK_MIN_DELAY` (default 172800 = 2 days).
New v2 env:

- `IF_SEED` (default 100000000000 = 100k USDG, the spec 6.1 launch seed;
  0 is an explicit opt-out for valueless test deployments only)
- `VAULT_BOOTSTRAP` (default 100000000000 = 100k USDG, equal to the vault's
  deposit-epoch cap floor so it lands in epoch 0 with no governance action)
- Per-tier overrides, i in 0..5, defaulting to the spec-10 values baked into
  the PerpRiskConfig constructor: `TIER<i>_MMR_BPS`, `TIER<i>_OPEN_FEE_BPS`,
  `TIER<i>_CLOSE_FEE_BPS`, `TIER<i>_KF_PER_HOUR_1E18`,
  `TIER<i>_KB_PER_HOUR_1E18`, `TIER<i>_LIQ_PENALTY_BPS`,
  `TIER<i>_MAX_POSITION_MARGIN_USDG`. The locked max-leverage schedule is NOT
  env-overridable and the script asserts it post-deploy.
- Global overrides: `PAYOUT_CAP_MULTIPLE` (default 9), `MAX_UTILIZATION_BPS`
  (default 8000), `MARKET_RESERVE_CAP_BPS` (default 1000).

FUNDING PREREQUISITE: the deployer key must hold IF_SEED + VAULT_BOOTSTRAP
USDG (default 200k) or the script reverts before deploying anything.

Dry run against a fork (no broadcast, no keys; needs the USDG balance on the
simulated sender, which the fork suite provides via deal):

    forge script script/DeployPerpV2.s.sol --fork-url https://rpc.mainnet.chain.robinhood.com

Production broadcast adds `--broadcast` and a signer. The full lifecycle
(deploy, seeds, handover, timelocked listing, a live trade) is asserted by
`test/fork/ForkPerpV2.t.sol`:

    forge test --match-contract ForkTestDeployPerpV2 --fork-url https://rpc.mainnet.chain.robinhood.com

### Phase 2: FinalizeHandoverV2 is MANDATORY

Identical two-phase Ownable2Step pattern to v1, expanded to FOURTEEN owned
contracts (router, five adapters, points, coordinator, spin, jackpot,
perpRiskConfig, insuranceFund, pitVault, perpEngine; PauseGuardian has no
owner). DeployPerpV2 only sets pendingOwner and SCHEDULES the acceptance
batch. Once `TIMELOCK_MIN_DELAY` elapses, OWNER runs:

    forge script script/FinalizeHandoverV2.s.sol --rpc-url robinhood --broadcast

which executes the batch, revokes the deployer's temporary timelock roles in
the same operation, and asserts owner() == timelock on every contract
(idempotent: re-running performs a standalone ownership audit). SECURITY
WINDOW: until phase 2 executes the DEPLOYER key is the live, fully
privileged, un-timelocked owner of the entire v2 stack, including the seeded
InsuranceFund and the bootstrapped vault. Treat it as a production secret and
execute phase 2 at the earliest allowed time.

### Listing a perp market (per-token, timelocked)

Per-token listing stays a post-deploy ops step, now TWO-legged (tier + list),
executed through the timelock. In order:

1. Oracle wiring for the token, exactly per the existing v1 sections above:
   grow observation cardinality on every pool (GrowCardinality.s.sol), wait a
   full TWAP window of ordinary trading, register sources (setSources),
   tracked pools + WETH pool quotes (setTrackedPools, setPoolQuote) and the
   manipulation-resistant depth geometry (setPoolGeometry). While the stack is
   pre-handover the deployer wires directly; after handover every setter goes
   through a scheduled timelock batch.
2. MAJORS 4-SOURCE POLICY (wave-2b R-5, unchanged and mandatory): every
   A_MAJOR token MUST carry at least MIN_SOURCES + 1 = 4 sources before
   listing (Chainlink + TwapAdapter pool 1 + TwapAdapterB pool 2 +
   CrossPoolTwapAdapter aggregate) so a single source failure cannot freeze
   the mark for the timelock window. A major at 3 healthy sources is an
   incident: schedule the repoint IMMEDIATELY.
3. Multi-source tokens: prime the fallback ring (primeFallback once per block
   for 3 blocks) before listing, per the v1 market-creation section. The perp
   engine's LIVE/FALLBACK print classifier reads the same breaker state.
4. Schedule ONE timelock batch: `perpRiskConfig.assignTier(token, tier)` then
   `perpEngine.listMarket(token)`. assignTier re-asserts at EXECUTION that the
   live FDV (totalSupply x peekPrice) sits inside the asserted tier band, and
   listMarket re-checks router.isListable, so a proposal that went stale
   during the delay fails closed.
5. Majors additionally get tighter params via
   `perpRiskConfig.setTokenOverride(token, params)` in the same batch
   (suggested: mmr 500 or 333 bps, fees 5/5 bps, kF 0.05 percent/h,
   maxPositionMargin 250k USDG). An override can never raise leverage above
   the locked schedule of the token's current tier.
6. New-market throttles apply automatically for 7 days: the engine ramp caps
   the market's reserve at 2 percent of TVL and the per-address share at 25
   percent of that. With a 100k bootstrap TVL a single address can reserve at
   most 500 USDG of payout (about 55 USDG margin at the 9x cap): grow TVL
   before expecting size.
7. Delisting = `perpEngine.setCloseOnly(token, true)` (timelocked): opens
   stop, closes + liquidations + funding continue. The PauseGuardian is the
   bounded emergency lever (24h max, blocks opens AND liquidations).

### Arming + seeding checklist (v2 launch)

- InsuranceFund: seeded at deploy (IF_SEED, 100k USDG). Target 3 percent of
  aggregate open notional (spec 6.2); top up permissionlessly via seed() or a
  plain USDG transfer. Withdrawals only via the timelock (governanceWithdraw).
- Vault: bootstrapped at deploy (VAULT_BOOTSTRAP, PLP to OWNER). Deposit cap
  is max(20 percent of TVL, 100k USDG) per 24h epoch; withdrawals go through
  the 24h two-step queue (25 percent of TVL per epoch, 1.2x solvency floor).
- CommitRevealCoordinator: keep the commitment queue stocked (section below);
  the perp engine mints points on fees, and points drive spins + draws
  exactly as in v1.
- Keeper backstops (all permissionless, spec 8.5): liquidate, pokeFunding
  (hourly cadence), PitVault.settleEpoch, PerpRiskConfig.refreshTier. Run ops
  bots for all four; the protocol degrades gracefully without them.
- Monitors: breaker events, vault NAV drawdown (10 percent/24h circuit trips
  ALL opens), navMarkStale(), InsuranceFund balance vs the 3 percent target,
  per-market realized vault edge (raise fees/caps via timelock if negative).

### v2 launch parameter table (deployed defaults)

| Parameter | Launch value | Where | Setter (timelocked) |
| --- | --- | --- | --- |
| Max leverage per tier | 4x/6x/6x/8x/10x/15x | PerpRiskConfig (LOCKED) | none (schedule is locked; setTierParams can only lower) |
| MMR per tier (pool-priced) | 1500/1000/1000/800/600/400 bps | PerpRiskConfig | setTierParams |
| Open/close fee | 10/10 bps (majors 5/5 via override) | PerpRiskConfig | setTierParams / setTokenOverride |
| kF (funding at full skew) | 0.25 percent/h (majors 0.05 via override) | PerpRiskConfig | setTierParams / setTokenOverride |
| kB (borrow at 100 percent util) | 0.01 percent/h | PerpRiskConfig | setTierParams |
| Liquidation penalty | 100 bps of notional | PerpRiskConfig | setTierParams |
| Per-position margin caps | 5k/10k/10k/25k/50k/50k USDG (majors 250k via override) | PerpRiskConfig | setTierParams / setTokenOverride |
| payoutCapMultiple | 9x margin | PerpRiskConfig | setPayoutCapMultiple |
| maxUtilizationBps | 8000 (80 percent of TVL) | PerpRiskConfig | setMaxUtilizationBps |
| marketReserveCapBps | 1000 (10 percent of TVL per market) | PerpRiskConfig | setMarketReserveCapBps |
| Tier refresh epoch / hysteresis | 24h / 20 percent | PerpRiskConfig | setRefreshCooldown / setHysteresisBps |
| minMargin | 10 USDG | PerpEngine | setMinMargin |
| Keeper share / floor | 20 percent / 5 USDG | PerpEngine | setKeeperParams |
| Per-address reserve share | 25 percent of market cap | PerpEngine | setPerAddressReserveShareBps |
| skewFloor | 10k USDG | PerpEngine | setSkewFloor |
| New-market ramp | 2 percent TVL / 7 days | PerpEngine + PitVault | setNewMarketRamp (both) |
| Drawdown circuit | 10 percent NAV / 24h | PerpEngine | setDrawdownCircuit / resetDrawdownCircuit |
| Vault deposit/withdraw fee | 10 bps each | PitVault | setVaultFees |
| Deposit epoch cap | 20 percent TVL, floor 100k USDG | PitVault | setDepositEpochCap |
| Withdraw epoch cap | 25 percent TVL | PitVault | setWithdrawEpochCapBps |
| Solvency floor | 1.2x totalReserved | PitVault | setSolvencyFloorBps |
| maxMarkAge (NAV cache) | 15 min | PitVault | setMaxMarkAge |
| Keeper floor cap | 5 USDG per liquidation | InsuranceFund | setKeeperFloorCap |
| IF seed / target | 100k USDG / 3 percent of open notional | InsuranceFund | seed (permissionless) / governanceWithdraw |

The effective values of every row are recorded in
`deployments/robinhood-4663-v2.json` at deploy time (read back from the
contracts, not from env).

## CommitRevealCoordinator operations

The operator (VRF_OPERATOR) must keep the commitment queue stocked:

1. Generate a random 32-byte secret off-chain, store it durably, and post
   `commit(keccak256(secret))`. Post batches ahead of expected demand: every
   spin request and every jackpot draw consumes one commitment, and an empty
   queue makes SpinVRF skip spins (SpinSkipped) and startDraw revert.
2. After a request is assigned (RandomWordsRequested event carries the
   commitment and assignedBlock), wait for assignedBlock to be mined, then call
   `reveal(requestId, secret)` PROMPTLY. Reveals expire with the EVM 256-block
   blockhash window; a missed window means waiting for the 24h public fallback
   (`fulfillTimeout`), which is a visible operational failure.
3. Commitments are strictly single-use; never reuse a secret.

Trust model: the operator can delay but cannot choose outcomes (the secret is
committed before the assigned block hash exists). Withholding a reveal only
trades a known sample for an unknown fallback sample after a public 24h
timeout. Swap in a real VRF later via SpinVRF.setCoordinator and
Jackpot.setCoordinator; in-flight requests stay pinned to this coordinator.
