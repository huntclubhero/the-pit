// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Types} from "../src/interfaces/Types.sol";
import {IOracleRouter} from "../src/interfaces/IOracleRouter.sol";
import {PauseGuardian} from "../src/core/PauseGuardian.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {ChainlinkAdapter} from "../src/oracle/adapters/ChainlinkAdapter.sol";
import {TwapAdapter} from "../src/oracle/adapters/TwapAdapter.sol";
import {CrossPoolTwapAdapter} from "../src/oracle/adapters/CrossPoolTwapAdapter.sol";
import {TwoHopTwapAdapter} from "../src/oracle/adapters/TwoHopTwapAdapter.sol";
import {PitPoints} from "../src/casino/PitPoints.sol";
import {SpinVRF} from "../src/casino/SpinVRF.sol";
import {Jackpot} from "../src/casino/Jackpot.sol";
import {CommitRevealCoordinator} from "../src/casino/CommitRevealCoordinator.sol";
import {PerpTypes} from "../src/perp/interfaces/PerpTypes.sol";
import {IPerpRiskConfig} from "../src/perp/interfaces/IPerpRiskConfig.sol";
import {IOracleRouterVaultView} from "../src/perp/interfaces/IPerpVaultDeps.sol";
import {PerpRiskConfig} from "../src/perp/PerpRiskConfig.sol";
import {InsuranceFund} from "../src/perp/InsuranceFund.sol";
import {PitVault} from "../src/perp/PitVault.sol";
import {PerpEngine} from "../src/perp/PerpEngine.sol";
import {HandoverPlan} from "./Deploy.s.sol";

/// @title HandoverPlanV2: v2 salt + canonical owned-contract order for the perp stack
/// @notice The v2 stack hands over FOURTEEN owned contracts (the v1 eleven minus the retired
///         MarketFactory, plus PerpRiskConfig, InsuranceFund, PitVault, PerpEngine). The batch
///         encoding itself is inherited unchanged from HandoverPlan; only the salt and the
///         canonical order differ. Order (the batch hash depends on it):
///         router, chainlinkAdapter, twapAdapter, twapAdapterB, crossPoolTwapAdapter,
///         twoHopTwapAdapter, pitPoints, commitRevealCoordinator, spinVRF, jackpot,
///         perpRiskConfig, insuranceFund, pitVault, perpEngine.
abstract contract HandoverPlanV2 is HandoverPlan {
    /// @notice Salt identifying the one-time v2 ownership-acceptance batch on the timelock.
    bytes32 public constant HANDOVER_SALT_V2 = keccak256("THE_PIT_TIMELOCK_HANDOVER_V2");

    /// @notice Number of owned contracts in the v2 handover (PauseGuardian has no owner).
    uint256 public constant OWNED_COUNT_V2 = 14;
}

/// @title DeployPerpV2: full THE PIT v2 (leveraged perps) stack deployment for Robinhood Chain
/// @notice Deploys and wires the entire v2 protocol in dependency order, seeds the InsuranceFund
///         and the PitVault bootstrap deposit, then begins the Ownable2Step ownership handover of
///         every owned contract to the governance TimelockController and SCHEDULES the acceptance
///         batch (same self-completing pattern as the v1 Deploy.s.sol, wave-2b R-4). Deployed
///         addresses plus the effective config are written to deployments/robinhood-4663-v2.json.
///
///         Order and wiring (mirrors the integration-proven seam of
///         test/perp/integration/PerpIntegration.t.sol and spec 8.6):
///         1. TimelockController(TIMELOCK_MIN_DELAY, proposers = {OWNER, deployer(temp)},
///            executors = {OWNER}, admin = 0)
///         2. PauseGuardian(GUARDIAN): immutable guardian, never owned, never handed over
///         3. OracleRouter(deployer, USDG)
///         4. Adapters: ChainlinkAdapter, TwapAdapter, TwapAdapterB, CrossPoolTwapAdapter,
///            TwoHopTwapAdapter (two independent single-pool TwapAdapter instances per wave-2b
///            R-5: a Tier A_MAJOR token MUST be wired with at least MIN_SOURCES + 1 = 4 sources;
///            see docs/ops-runbook.md). Per-token source registration is a post-deploy ops step.
///         5. Casino: PitPoints(deployer), CommitRevealCoordinator(deployer, VRF_OPERATOR),
///            SpinVRF(deployer, points), Jackpot(deployer, USDG, points)
///         6. PerpRiskConfig(router, deployer): the constructor seeds the LOCKED leverage
///            schedule (4x/6x/6x/8x/10x/15x) and every spec-10 launch default (MMR table, 10 bps
///            pool fees, kF 0.25%/h, kB 0.01%/h, penalty 100 bps, per-tier margin caps, payout
///            cap 9x, utilization 80%, market reserve 10% TVL, refresh 24h, hysteresis 20%).
///            Optional env overrides (below) are applied through the governance setters while
///            the deployer still owns the contract, and the script asserts the locked leverage
///            schedule was not tampered with.
///         7. InsuranceFund(USDG, deployer)
///         8. PitVault(USDG, router, riskConfig, deployer)
///         9. PerpEngine(deployer, USDG, router, vault, insuranceFund, riskConfig, points,
///            guardian, feeSplit{jackpot, TREASURY, REFERRAL_POOL, BUYBACK}); the engine
///            max-approves the vault for USDG in its own constructor (settleTraderLoss PULLS
///            realized losses via transferFrom).
///         10. Wire: vault.setEngine(engine) (one-shot), insuranceFund.setEngine(engine)
///            (one-shot; authorizes cover/payKeeperFloor), insuranceFund.setVault(vault)
///            (one-shot; pins the ONLY recipient cover() can ever pay),
///            points.setRegistrar(engine) + points.registerMarket(engine) (the engine is the v2
///            points consumer: onFill/onSettle require isMarket, and as registrar it fills the
///            slot the retired MarketFactory held), plus the v1 casino cross-wiring
///            (setSpinVRF, coordinators, request configs, consumers, jackpot fair-share floor).
///         11. Seed: insuranceFund.seed(IF_SEED) (spec 6.1 treasury seed, default 100k USDG) and
///            vault.deposit(VAULT_BOOTSTRAP, OWNER) (bootstrap LP capital; the PLP shares go to
///            OWNER, the governance multisig). The deployer must hold IF_SEED + VAULT_BOOTSTRAP
///            USDG or the script reverts before deploying anything.
///         12. transferOwnership(timelock) on all fourteen owned contracts and schedule the
///            acceptance batch (fourteen acceptOwnership calls plus revocation of the deployer's
///            temporary proposer/canceller roles) with delay TIMELOCK_MIN_DELAY and salt
///            HANDOVER_SALT_V2. RUNBOOK: after the delay elapses OWNER runs
///            script/FinalizeHandoverV2.s.sol (phase 2, MANDATORY). UNTIL THAT BATCH EXECUTES
///            THE DEPLOYER KEY IS THE FULLY PRIVILEGED, UN-TIMELOCKED OWNER OF THE ENTIRE STACK.
///
///         Per-token market listing stays a post-deploy TIMELOCKED ops step, exactly as in v1
///         (docs/ops-runbook.md, "Listing a perp market"): wire sources + geometry + cardinality
///         + fallback ring while un-timelocked config is still possible or via scheduled batches,
///         then schedule [riskConfig.assignTier(token, tier), engine.listMarket(token)] on the
///         timelock. listMarket re-checks router.isListable at execution.
/// @dev Env block (reused from v1): OWNER, GUARDIAN, TREASURY, REFERRAL_POOL, BUYBACK (required
///      addresses), USDG (default canonical), ETH_USD_FEED (default Chainlink ETH/USD proxy,
///      recorded for ops), VRF_OPERATOR (default OWNER), TIMELOCK_MIN_DELAY (default 2 days).
///      New for v2:
///      IF_SEED (uint USDG units, default 100_000e6 = the spec 6.1 launch seed; 0 is an explicit
///      opt-out for valueless test deployments only).
///      VAULT_BOOTSTRAP (uint USDG units, default 100_000e6 = the vault's deposit-epoch cap
///      floor, so the bootstrap lands in epoch 0 without any governance action; 0 opts out).
///      Per-tier launch-param overrides, all optional, defaulting to the PerpRiskConfig
///      constructor's spec-10 values: TIER<i>_MMR_BPS, TIER<i>_OPEN_FEE_BPS,
///      TIER<i>_CLOSE_FEE_BPS, TIER<i>_KF_PER_HOUR_1E18, TIER<i>_KB_PER_HOUR_1E18,
///      TIER<i>_LIQ_PENALTY_BPS, TIER<i>_MAX_POSITION_MARGIN_USDG for i in 0..5. The locked
///      max-leverage schedule is NOT env-overridable.
///      Global risk overrides, optional: PAYOUT_CAP_MULTIPLE (default 9),
///      MAX_UTILIZATION_BPS (default 8000), MARKET_RESERVE_CAP_BPS (default 1000).
///      Engine and vault operational knobs (minMargin 10 USDG, keeper 20%/5 USDG floor,
///      per-address reserve share 25%, skew floor 10k USDG, new-market ramp 2%/7d, drawdown
///      circuit 10%/24h, vault fees 10 bps, deposit cap 20%/100k floor, withdraw cap 25%,
///      solvency floor 1.2x, maxMarkAge 15 min) ship at their in-contract launch defaults and
///      are post-deploy timelocked setters; the effective values are recorded in the JSON.
contract DeployPerpV2 is Script, HandoverPlanV2 {
    /// @notice Canonical USDG (Global Dollar) on Robinhood Chain. Impostor tokens with the same
    ///         name exist on this chain; only this address is canonical.
    address public constant DEFAULT_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @notice Chainlink ETH/USD aggregator proxy on Robinhood Chain (8 decimals, 24h heartbeat).
    address public constant DEFAULT_ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    /// @notice Default governance timelock delay (2 days), identical to v1.
    uint256 public constant DEFAULT_TIMELOCK_MIN_DELAY = 2 days;

    /// @notice Default InsuranceFund launch seed: 100k USDG (spec 6.1/6.2 floor).
    uint256 public constant DEFAULT_IF_SEED = 100_000e6;

    /// @notice Default vault bootstrap deposit: 100k USDG. Chosen to equal
    ///         PitVault.DEFAULT_DEPOSIT_EPOCH_CAP_FLOOR so the bootstrap fits inside epoch 0's
    ///         deposit cap with zero TVL and no governance pre-action.
    uint256 public constant DEFAULT_VAULT_BOOTSTRAP = 100_000e6;

    /// @notice VRF request callback gas limit (billing fields are ignored by the commit-reveal
    ///         coordinator; this bounds the fulfillment callback), identical to v1.
    uint32 public constant VRF_CALLBACK_GAS_LIMIT = 500_000;

    /// @notice VRF request confirmations: the commit-reveal assigned-block distance (v1 value).
    uint16 public constant VRF_REQUEST_CONFIRMATIONS = 3;

    /// @notice Fair-share commitment floor reserved for the Jackpot consumer (audit fix W2-15).
    uint256 public constant JACKPOT_RESERVED_COMMITMENTS = 2;

    /// @dev An owned contract's pendingOwner is not the timelock after the handover began.
    error PendingOwnerMismatch(address target);
    /// @dev The ownership-acceptance batch is not pending on the timelock after scheduling.
    error AcceptanceNotScheduled(bytes32 operationId);
    /// @dev The deployer does not hold enough USDG for IF_SEED + VAULT_BOOTSTRAP.
    error DeployerUsdgInsufficient(uint256 needed, uint256 held);
    /// @dev An env value does not fit the target parameter type.
    error EnvValueTooLarge(string name, uint256 value);
    /// @dev A post-wire sanity assertion failed (defensive; should be unreachable).
    error WiringAssertFailed(string what);
    /// @dev The deployed risk config's leverage schedule diverges from the LOCKED spec schedule.
    error LockedScheduleMismatch(uint8 tier);

    /// @notice Resolved environment configuration.
    struct Config {
        address owner;
        address guardianAuthority;
        address treasury;
        address referralPool;
        address buyback;
        address usdg;
        address ethUsdFeed;
        address vrfOperator;
        uint256 timelockMinDelay;
        uint256 ifSeed;
        uint256 vaultBootstrap;
        uint256 payoutCapMultiple;
        uint256 maxUtilizationBps;
        uint256 marketReserveCapBps;
    }

    /// @notice Every deployed contract of the v2 stack.
    struct Deployment {
        TimelockController timelock;
        PauseGuardian guardian;
        OracleRouter router;
        ChainlinkAdapter chainlinkAdapter;
        TwapAdapter twapAdapter;
        TwapAdapter twapAdapterB;
        CrossPoolTwapAdapter crossPoolAdapter;
        TwoHopTwapAdapter twoHopAdapter;
        PitPoints points;
        CommitRevealCoordinator coordinator;
        SpinVRF spin;
        Jackpot jackpot;
        PerpRiskConfig riskConfig;
        InsuranceFund insuranceFund;
        PitVault vault;
        PerpEngine engine;
    }

    /// @notice Deploys, wires, seeds, hands over, schedules the timelock's ownership acceptance,
    ///         asserts the handover state, and writes deployments/robinhood-4663-v2.json.
    function run() external {
        Config memory cfg = _readConfig();

        vm.startBroadcast();
        // The temporary owner during wiring must be the ACTUAL broadcast sender (msg.sender is
        // the harness caller and diverges from it when run() is driven from a fork test).
        (, address deployer,) = vm.readCallers();
        _requireSeedFunding(cfg, deployer);
        Deployment memory d = _deploy(cfg, deployer);
        _wireCasino(d);
        _wirePerp(d);
        _applyRiskOverrides(d, cfg);
        _assertWiring(d, cfg);
        _seed(d, cfg);
        // Hand every owned contract to the governance timelock, not the raw multisig, so all
        // owner actions are timelocked (wave-2 TO-1 / TO-2, unchanged for v2).
        _handOver(d, address(d.timelock));
        // Schedule the acceptance batch so the handover is self-completing (wave-2b R-4): the
        // timelock actually OWNS nothing until it calls acceptOwnership on each contract.
        bytes32 handoverId = _scheduleAcceptance(d, cfg, deployer);
        vm.stopBroadcast();

        _assertHandoverBegun(d, handoverId);
        _writeAddressBook(cfg, d, deployer, handoverId);
    }

    // ======================================================================
    // Config
    // ======================================================================

    /// @dev Reads and validates the env block.
    function _readConfig() internal view returns (Config memory cfg) {
        cfg.owner = vm.envAddress("OWNER");
        cfg.guardianAuthority = vm.envAddress("GUARDIAN");
        cfg.treasury = vm.envAddress("TREASURY");
        cfg.referralPool = vm.envAddress("REFERRAL_POOL");
        cfg.buyback = vm.envAddress("BUYBACK");
        cfg.usdg = vm.envOr("USDG", DEFAULT_USDG);
        cfg.ethUsdFeed = vm.envOr("ETH_USD_FEED", DEFAULT_ETH_USD_FEED);
        cfg.vrfOperator = vm.envOr("VRF_OPERATOR", cfg.owner);
        cfg.timelockMinDelay = vm.envOr("TIMELOCK_MIN_DELAY", DEFAULT_TIMELOCK_MIN_DELAY);
        cfg.ifSeed = vm.envOr("IF_SEED", DEFAULT_IF_SEED);
        cfg.vaultBootstrap = vm.envOr("VAULT_BOOTSTRAP", DEFAULT_VAULT_BOOTSTRAP);
        // Global risk knobs: defaults mirror the PerpRiskConfig constructor's spec-10 values;
        // the setters validate ranges authoritatively at apply time.
        cfg.payoutCapMultiple = vm.envOr("PAYOUT_CAP_MULTIPLE", uint256(0));
        cfg.maxUtilizationBps = vm.envOr("MAX_UTILIZATION_BPS", uint256(0));
        cfg.marketReserveCapBps = vm.envOr("MARKET_RESERVE_CAP_BPS", uint256(0));
        if (cfg.maxUtilizationBps > type(uint16).max) {
            revert EnvValueTooLarge("MAX_UTILIZATION_BPS", cfg.maxUtilizationBps);
        }
        if (cfg.marketReserveCapBps > type(uint16).max) {
            revert EnvValueTooLarge("MARKET_RESERVE_CAP_BPS", cfg.marketReserveCapBps);
        }
    }

    /// @dev The deployer funds IF_SEED + VAULT_BOOTSTRAP out of its own USDG balance; fail before
    ///      deploying anything rather than after half the stack exists.
    function _requireSeedFunding(Config memory cfg, address deployer) internal view {
        uint256 needed = cfg.ifSeed + cfg.vaultBootstrap;
        uint256 held = IERC20(cfg.usdg).balanceOf(deployer);
        if (held < needed) revert DeployerUsdgInsufficient(needed, held);
    }

    // ======================================================================
    // Deploy + wire
    // ======================================================================

    /// @dev Deploys every contract in dependency order; `deployer` owns during wiring.
    function _deploy(Config memory cfg, address deployer) internal returns (Deployment memory d) {
        // Governance timelock: identical construction to v1 (OWNER = standing proposer and sole
        // executor, self-administered, deployer holds a TEMPORARY proposer role revoked by the
        // acceptance batch).
        bool deployerIsOwner = deployer == cfg.owner;
        address[] memory proposers = new address[](deployerIsOwner ? 1 : 2);
        proposers[0] = cfg.owner;
        if (!deployerIsOwner) proposers[1] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = cfg.owner;
        d.timelock = new TimelockController(cfg.timelockMinDelay, proposers, executors, address(0));

        d.guardian = new PauseGuardian(cfg.guardianAuthority);
        d.router = new OracleRouter(deployer, cfg.usdg);
        d.chainlinkAdapter = new ChainlinkAdapter(deployer);
        d.twapAdapter = new TwapAdapter(deployer);
        d.twapAdapterB = new TwapAdapter(deployer);
        d.crossPoolAdapter = new CrossPoolTwapAdapter(deployer);
        d.twoHopAdapter = new TwoHopTwapAdapter(deployer);
        d.points = new PitPoints(deployer);
        d.coordinator = new CommitRevealCoordinator(deployer, cfg.vrfOperator);
        d.spin = new SpinVRF(deployer, address(d.points));
        d.jackpot = new Jackpot(deployer, cfg.usdg, address(d.points));

        // The v2 perp stack, in the exact dependency order the integration suite proves
        // (PerpIntegration.t.sol setUp, spec 8.6).
        d.riskConfig = new PerpRiskConfig(IOracleRouter(address(d.router)), deployer);
        d.insuranceFund = new InsuranceFund(IERC20(cfg.usdg), deployer);
        d.vault = new PitVault(
            IERC20(cfg.usdg),
            IOracleRouterVaultView(address(d.router)),
            IPerpRiskConfig(address(d.riskConfig)),
            deployer
        );
        d.engine = new PerpEngine(
            deployer,
            cfg.usdg,
            address(d.router),
            address(d.vault),
            address(d.insuranceFund),
            address(d.riskConfig),
            address(d.points),
            address(d.guardian),
            Types.FeeSplit({
                jackpot: address(d.jackpot),
                treasury: cfg.treasury,
                referralPool: cfg.referralPool,
                buyback: cfg.buyback,
                vault: address(d.vault) // economics v2: 20% of every trade fee is LP revenue
            })
        );
    }

    /// @dev Casino cross-wiring, identical to v1 (minus the retired MarketFactory registrar).
    function _wireCasino(Deployment memory d) internal {
        d.points.setSpinVRF(address(d.spin));
        d.spin.setCoordinator(address(d.coordinator));
        d.jackpot.setCoordinator(address(d.coordinator));
        // Billing fields (subId, keyHash, nativePayment) are ignored by the commit-reveal
        // coordinator; requestConfirmations sets the assigned-block distance.
        d.spin.setRequestConfig(0, bytes32(0), VRF_CALLBACK_GAS_LIMIT, VRF_REQUEST_CONFIRMATIONS, false);
        d.jackpot.setRequestConfig(0, bytes32(0), VRF_CALLBACK_GAS_LIMIT, VRF_REQUEST_CONFIRMATIONS, false);
        d.coordinator.setConsumer(address(d.spin), true);
        d.coordinator.setConsumer(address(d.jackpot), true);
        // Fair-share reservation (audit fix W2-15/L1): the low-volume Jackpot consumer keeps a
        // commitment floor so a spin flood can never starve the draws.
        d.coordinator.setReservedCommitments(address(d.jackpot), JACKPOT_RESERVED_COMMITMENTS);
    }

    /// @dev Perp seam wiring (spec 8.6). The engine max-approved the vault for USDG in its own
    ///      constructor; everything else is one-shot owner setters.
    function _wirePerp(Deployment memory d) internal {
        // The vault's counterparty surface and NAV market list bind to the engine, exactly once.
        d.vault.setEngine(address(d.engine));
        // The fund authorizes the engine (cover / payKeeperFloor) and pins the vault as the only
        // recipient cover() can ever pay, exactly once each.
        d.insuranceFund.setEngine(address(d.engine));
        d.insuranceFund.setVault(address(d.vault));
        // The engine is the v2 points consumer: onFill/onSettle demand isMarket, and it takes the
        // registrar slot the retired MarketFactory held in v1.
        d.points.setRegistrar(address(d.engine));
        d.points.registerMarket(address(d.engine));
    }

    /// @dev Applies optional env overrides to the risk config through its governance setters
    ///      (deployer is still the owner here), then asserts the LOCKED leverage schedule.
    function _applyRiskOverrides(Deployment memory d, Config memory cfg) internal {
        if (cfg.payoutCapMultiple != 0 && cfg.payoutCapMultiple != d.riskConfig.payoutCapMultiple()) {
            d.riskConfig.setPayoutCapMultiple(cfg.payoutCapMultiple);
        }
        if (cfg.maxUtilizationBps != 0 && cfg.maxUtilizationBps != d.riskConfig.maxUtilizationBps()) {
            d.riskConfig.setMaxUtilizationBps(uint16(cfg.maxUtilizationBps));
        }
        if (cfg.marketReserveCapBps != 0 && cfg.marketReserveCapBps != d.riskConfig.marketReserveCapBps()) {
            d.riskConfig.setMarketReserveCapBps(uint16(cfg.marketReserveCapBps));
        }
        for (uint8 tier = 0; tier < 6; ++tier) {
            (PerpTypes.TierParams memory p, bool changed) = _envTierParams(d.riskConfig, tier);
            if (changed) d.riskConfig.setTierParams(tier, p);
            // Tripwire: whatever the overrides did, the LOCKED schedule stands (setTierParams
            // can lower leverage for de-risking but this script never should at launch).
            if (d.riskConfig.tierDefaults(tier).maxLeverageX100 != d.riskConfig.lockedMaxLeverageX100(tier)) {
                revert LockedScheduleMismatch(tier);
            }
        }
    }

    /// @dev Resolves one tier's params from env, defaulting every field to the constructor-seeded
    ///      spec value. The locked max leverage is never env-readable.
    function _envTierParams(PerpRiskConfig risk, uint8 tier)
        internal
        view
        returns (PerpTypes.TierParams memory p, bool changed)
    {
        PerpTypes.TierParams memory def = risk.tierDefaults(tier);
        string memory prefix = string.concat("TIER", vm.toString(uint256(tier)), "_");
        p.maxLeverageX100 = def.maxLeverageX100;
        p.mmrBps = _envU16(string.concat(prefix, "MMR_BPS"), def.mmrBps);
        p.openFeeBps = _envU16(string.concat(prefix, "OPEN_FEE_BPS"), def.openFeeBps);
        p.closeFeeBps = _envU16(string.concat(prefix, "CLOSE_FEE_BPS"), def.closeFeeBps);
        p.kFPerHour1e18 = _envU64(string.concat(prefix, "KF_PER_HOUR_1E18"), def.kFPerHour1e18);
        p.kBPerHour1e18 = _envU64(string.concat(prefix, "KB_PER_HOUR_1E18"), def.kBPerHour1e18);
        p.liqPenaltyBps = _envU16(string.concat(prefix, "LIQ_PENALTY_BPS"), def.liqPenaltyBps);
        p.maxPositionMargin = _envU128(string.concat(prefix, "MAX_POSITION_MARGIN_USDG"), def.maxPositionMargin);
        changed = p.mmrBps != def.mmrBps || p.openFeeBps != def.openFeeBps || p.closeFeeBps != def.closeFeeBps
            || p.kFPerHour1e18 != def.kFPerHour1e18 || p.kBPerHour1e18 != def.kBPerHour1e18
            || p.liqPenaltyBps != def.liqPenaltyBps || p.maxPositionMargin != def.maxPositionMargin;
    }

    function _envU16(string memory name, uint16 def) internal view returns (uint16) {
        uint256 v = vm.envOr(name, uint256(def));
        if (v > type(uint16).max) revert EnvValueTooLarge(name, v);
        return uint16(v);
    }

    function _envU64(string memory name, uint64 def) internal view returns (uint64) {
        uint256 v = vm.envOr(name, uint256(def));
        if (v > type(uint64).max) revert EnvValueTooLarge(name, v);
        return uint64(v);
    }

    function _envU128(string memory name, uint128 def) internal view returns (uint128) {
        uint256 v = vm.envOr(name, uint256(def));
        if (v > type(uint128).max) revert EnvValueTooLarge(name, v);
        return uint128(v);
    }

    /// @dev Post-wire sanity: the seam the integration suite proves must hold on the freshly
    ///      deployed stack before any value moves.
    function _assertWiring(Deployment memory d, Config memory cfg) internal view {
        if (d.vault.engine() != address(d.engine)) revert WiringAssertFailed("vault.engine");
        if (d.insuranceFund.engine() != address(d.engine)) revert WiringAssertFailed("insuranceFund.engine");
        if (d.insuranceFund.vault() != address(d.vault)) revert WiringAssertFailed("insuranceFund.vault");
        if (IERC20(cfg.usdg).allowance(address(d.engine), address(d.vault)) != type(uint256).max) {
            revert WiringAssertFailed("engine->vault USDG approval");
        }
        if (!d.points.isMarket(address(d.engine))) revert WiringAssertFailed("points.isMarket(engine)");
        if (d.points.registrar() != address(d.engine)) revert WiringAssertFailed("points.registrar");
        if (address(d.engine.vault()) != address(d.vault)) revert WiringAssertFailed("engine.vault");
        if (address(d.engine.insuranceFund()) != address(d.insuranceFund)) {
            revert WiringAssertFailed("engine.insuranceFund");
        }
        if (address(d.engine.riskConfig()) != address(d.riskConfig)) revert WiringAssertFailed("engine.riskConfig");
        if (address(d.engine.router()) != address(d.router)) revert WiringAssertFailed("engine.router");
        if (address(d.engine.guardian()) != address(d.guardian)) revert WiringAssertFailed("engine.guardian");
        if (d.engine.feeJackpot() != address(d.jackpot)) revert WiringAssertFailed("engine.feeJackpot");
    }

    /// @dev InsuranceFund seed (spec 6.1) and vault bootstrap deposit, funded by the deployer.
    ///      PLP bootstrap shares are minted to OWNER (the governance multisig), never the
    ///      deployer, so the deployer key holds no residual protocol position after handover.
    function _seed(Deployment memory d, Config memory cfg) internal {
        if (cfg.ifSeed > 0) {
            IERC20(cfg.usdg).approve(address(d.insuranceFund), cfg.ifSeed);
            d.insuranceFund.seed(cfg.ifSeed);
        }
        if (cfg.vaultBootstrap > 0) {
            IERC20(cfg.usdg).approve(address(d.vault), cfg.vaultBootstrap);
            d.vault.deposit(cfg.vaultBootstrap, cfg.owner);
        }
    }

    // ======================================================================
    // Handover
    // ======================================================================

    /// @dev Begins the two-step ownership handover of every owned contract.
    function _handOver(Deployment memory d, address newOwner) internal {
        address[] memory owned = _ownedContracts(d);
        for (uint256 i = 0; i < owned.length; ++i) {
            Ownable2Step(owned[i]).transferOwnership(newOwner);
        }
    }

    /// @dev Every owned contract, in the canonical v2 handover order shared with
    ///      FinalizeHandoverV2 and the fork suite (see HandoverPlanV2). PauseGuardian is absent
    ///      by design: it has an immutable guardian and no owner at all.
    function _ownedContracts(Deployment memory d) internal pure returns (address[] memory owned) {
        owned = new address[](OWNED_COUNT_V2);
        owned[0] = address(d.router);
        owned[1] = address(d.chainlinkAdapter);
        owned[2] = address(d.twapAdapter);
        owned[3] = address(d.twapAdapterB);
        owned[4] = address(d.crossPoolAdapter);
        owned[5] = address(d.twoHopAdapter);
        owned[6] = address(d.points);
        owned[7] = address(d.coordinator);
        owned[8] = address(d.spin);
        owned[9] = address(d.jackpot);
        owned[10] = address(d.riskConfig);
        owned[11] = address(d.insuranceFund);
        owned[12] = address(d.vault);
        owned[13] = address(d.engine);
    }

    /// @dev Schedules the ownership-acceptance batch on the timelock with delay timelockMinDelay
    ///      (wave-2b R-4, v2 salt). Returns the operation id, also written to the address book.
    function _scheduleAcceptance(Deployment memory d, Config memory cfg, address deployer)
        internal
        returns (bytes32 id)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _handoverBatch(_ownedContracts(d), d.timelock, deployer, deployer != cfg.owner);
        d.timelock.scheduleBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT_V2, cfg.timelockMinDelay);
        id = d.timelock.hashOperationBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT_V2);
    }

    /// @dev Post-deploy handover assertions: every owned contract's pendingOwner is the timelock,
    ///      and the acceptance batch is pending. owner() still equals the deployer here BY
    ///      CONSTRUCTION (Ownable2Step); the owner() == timelock assertion lives in
    ///      FinalizeHandoverV2, after the batch executes.
    function _assertHandoverBegun(Deployment memory d, bytes32 handoverId) internal view {
        address[] memory owned = _ownedContracts(d);
        for (uint256 i = 0; i < owned.length; ++i) {
            if (Ownable2Step(owned[i]).pendingOwner() != address(d.timelock)) {
                revert PendingOwnerMismatch(owned[i]);
            }
        }
        if (!d.timelock.isOperationPending(handoverId)) revert AcceptanceNotScheduled(handoverId);
    }

    // ======================================================================
    // Address book
    // ======================================================================

    /// @dev Records every address plus the effective config as JSON.
    function _writeAddressBook(Config memory cfg, Deployment memory d, address deployer, bytes32 handoverId)
        internal
    {
        string memory json = "deployV2";
        vm.serializeAddress(json, "timelock", address(d.timelock));
        vm.serializeUint(json, "timelockMinDelay", cfg.timelockMinDelay);
        vm.serializeAddress(json, "deployer", deployer);
        vm.serializeBytes32(json, "handoverOperationId", handoverId);
        vm.serializeBytes32(json, "handoverSalt", HANDOVER_SALT_V2);
        vm.serializeAddress(json, "pauseGuardian", address(d.guardian));
        vm.serializeAddress(json, "oracleRouter", address(d.router));
        vm.serializeAddress(json, "chainlinkAdapter", address(d.chainlinkAdapter));
        vm.serializeAddress(json, "twapAdapter", address(d.twapAdapter));
        vm.serializeAddress(json, "twapAdapterB", address(d.twapAdapterB));
        vm.serializeAddress(json, "crossPoolTwapAdapter", address(d.crossPoolAdapter));
        vm.serializeAddress(json, "twoHopTwapAdapter", address(d.twoHopAdapter));
        vm.serializeAddress(json, "pitPoints", address(d.points));
        vm.serializeAddress(json, "commitRevealCoordinator", address(d.coordinator));
        vm.serializeAddress(json, "spinVRF", address(d.spin));
        vm.serializeAddress(json, "jackpot", address(d.jackpot));
        vm.serializeAddress(json, "perpRiskConfig", address(d.riskConfig));
        vm.serializeAddress(json, "insuranceFund", address(d.insuranceFund));
        vm.serializeAddress(json, "pitVault", address(d.vault));
        vm.serializeAddress(json, "perpEngine", address(d.engine));
        vm.serializeAddress(json, "usdg", cfg.usdg);
        vm.serializeAddress(json, "ethUsdFeed", cfg.ethUsdFeed);
        vm.serializeAddress(json, "owner", cfg.owner);
        vm.serializeAddress(json, "guardianAuthority", cfg.guardianAuthority);
        vm.serializeAddress(json, "treasury", cfg.treasury);
        vm.serializeAddress(json, "referralPool", cfg.referralPool);
        vm.serializeAddress(json, "buyback", cfg.buyback);
        vm.serializeAddress(json, "vrfOperator", cfg.vrfOperator);
        vm.serializeUint(json, "ifSeed", cfg.ifSeed);
        vm.serializeUint(json, "vaultBootstrap", cfg.vaultBootstrap);
        _serializeLaunchParams(json, d);
        string memory out = _serializeTierTable(json, d);

        vm.createDir("deployments", true);
        vm.writeJson(out, "deployments/robinhood-4663-v2.json");
    }

    /// @dev Effective global launch parameters, read back from the deployed contracts (source of
    ///      truth), not from env.
    function _serializeLaunchParams(string memory json, Deployment memory d) internal {
        vm.serializeUint(json, "payoutCapMultiple", d.riskConfig.payoutCapMultiple());
        vm.serializeUint(json, "maxUtilizationBps", d.riskConfig.maxUtilizationBps());
        vm.serializeUint(json, "marketReserveCapBps", d.riskConfig.marketReserveCapBps());
        vm.serializeUint(json, "refreshCooldown", d.riskConfig.refreshCooldown());
        vm.serializeUint(json, "hysteresisBps", d.riskConfig.hysteresisBps());
        vm.serializeUint(json, "engineMinMargin", d.engine.minMargin());
        vm.serializeUint(json, "engineKeeperShareBps", d.engine.keeperShareBps());
        vm.serializeUint(json, "engineKeeperFloorUsdg", d.engine.keeperFloorUsdg());
        vm.serializeUint(json, "enginePerAddressReserveShareBps", d.engine.perAddressReserveShareBps());
        vm.serializeUint(json, "engineSkewFloorUsdg", d.engine.skewFloorUsdg());
        vm.serializeUint(json, "engineRampCapBps", d.engine.rampCapBps());
        vm.serializeUint(json, "engineRampDuration", d.engine.rampDuration());
        vm.serializeUint(json, "engineDrawdownCircuitBps", d.engine.drawdownCircuitBps());
        vm.serializeUint(json, "engineDrawdownWindow", d.engine.drawdownWindow());
        vm.serializeUint(json, "vaultDepositFeeBps", d.vault.depositFeeBps());
        vm.serializeUint(json, "vaultWithdrawFeeBps", d.vault.withdrawFeeBps());
        vm.serializeUint(json, "vaultDepositEpochCapBps", d.vault.depositEpochCapBps());
        vm.serializeUint(json, "vaultDepositEpochCapFloor", d.vault.depositEpochCapFloor());
        vm.serializeUint(json, "vaultWithdrawEpochCapBps", d.vault.withdrawEpochCapBps());
        vm.serializeUint(json, "vaultSolvencyFloorBps", d.vault.solvencyFloorBps());
        vm.serializeUint(json, "vaultNewMarketRampBps", d.vault.newMarketRampBps());
        vm.serializeUint(json, "vaultNewMarketRampDuration", d.vault.newMarketRampDuration());
        vm.serializeUint(json, "vaultMaxMarkAge", d.vault.maxMarkAge());
        vm.serializeUint(json, "insuranceKeeperFloorCap", d.insuranceFund.keeperFloorCap());
    }

    /// @dev Effective per-tier parameter table, read back from the deployed risk config.
    function _serializeTierTable(string memory json, Deployment memory d) internal returns (string memory out) {
        for (uint8 tier = 0; tier < 6; ++tier) {
            PerpTypes.TierParams memory p = d.riskConfig.tierDefaults(tier);
            string memory tKey = string.concat("tier", vm.toString(uint256(tier)));
            vm.serializeUint(tKey, "maxLeverageX100", p.maxLeverageX100);
            vm.serializeUint(tKey, "mmrBps", p.mmrBps);
            vm.serializeUint(tKey, "openFeeBps", p.openFeeBps);
            vm.serializeUint(tKey, "closeFeeBps", p.closeFeeBps);
            vm.serializeUint(tKey, "kFPerHour1e18", p.kFPerHour1e18);
            vm.serializeUint(tKey, "kBPerHour1e18", p.kBPerHour1e18);
            vm.serializeUint(tKey, "liqPenaltyBps", p.liqPenaltyBps);
            string memory tierJson = vm.serializeUint(tKey, "maxPositionMarginUsdg", p.maxPositionMargin);
            out = vm.serializeString(json, tKey, tierJson);
        }
    }
}
