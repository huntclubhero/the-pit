// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Types} from "../src/interfaces/Types.sol";
import {PauseGuardian} from "../src/core/PauseGuardian.sol";
import {MarketFactory} from "../src/core/MarketFactory.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {ChainlinkAdapter} from "../src/oracle/adapters/ChainlinkAdapter.sol";
import {TwapAdapter} from "../src/oracle/adapters/TwapAdapter.sol";
import {CrossPoolTwapAdapter} from "../src/oracle/adapters/CrossPoolTwapAdapter.sol";
import {TwoHopTwapAdapter} from "../src/oracle/adapters/TwoHopTwapAdapter.sol";
import {PitPoints} from "../src/casino/PitPoints.sol";
import {SpinVRF} from "../src/casino/SpinVRF.sol";
import {Jackpot} from "../src/casino/Jackpot.sol";
import {CommitRevealCoordinator} from "../src/casino/CommitRevealCoordinator.sol";

/// @title HandoverPlan: canonical construction of the timelock ownership-acceptance batch
/// @notice Shared by Deploy (which SCHEDULES the batch), FinalizeHandover (which EXECUTES it after
///         the timelock delay and asserts completion), and the fork suite (which proves the whole
///         flow end to end). Wave-2b R-4: transferOwnership on an Ownable2Step contract only sets
///         pendingOwner, so the deployer EOA remains the LIVE owner of every contract until the
///         timelock itself calls acceptOwnership. Scheduling that acceptance inside the deploy
///         transaction makes the handover self-completing instead of a forgettable manual action.
abstract contract HandoverPlan {
    /// @notice Salt identifying the one-time ownership-acceptance batch on the timelock. Fixed so
    ///         Deploy, FinalizeHandover, and any manual executor derive the identical operation id.
    bytes32 public constant HANDOVER_SALT = keccak256("THE_PIT_TIMELOCK_HANDOVER_V1");

    /// @notice Builds the acceptance batch: one acceptOwnership() call per owned contract, plus
    ///         (when the deployer is not OWNER) two trailing self-calls on the timelock revoking
    ///         the deployer's temporary PROPOSER_ROLE and CANCELLER_ROLE, so the deployer's only
    ///         timelock power dies in the same operation that completes the handover.
    /// @param owned The owned contracts, in the canonical handover order.
    /// @param timelock The governance timelock that must accept ownership of each.
    /// @param deployer The deploy broadcaster holding the temporary proposer role.
    /// @param revokeDeployer True when `deployer` differs from OWNER and its roles must be revoked.
    /// @return targets Batch call targets.
    /// @return values Batch call values (all zero).
    /// @return payloads Batch call payloads.
    function _handoverBatch(address[] memory owned, TimelockController timelock, address deployer, bool revokeDeployer)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        uint256 extra = revokeDeployer ? 2 : 0;
        uint256 n = owned.length + extra;
        targets = new address[](n);
        values = new uint256[](n);
        payloads = new bytes[](n);
        for (uint256 i = 0; i < owned.length; i++) {
            targets[i] = owned[i];
            payloads[i] = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        }
        if (revokeDeployer) {
            targets[owned.length] = address(timelock);
            payloads[owned.length] = abi.encodeCall(timelock.revokeRole, (timelock.PROPOSER_ROLE(), deployer));
            targets[owned.length + 1] = address(timelock);
            payloads[owned.length + 1] = abi.encodeCall(timelock.revokeRole, (timelock.CANCELLER_ROLE(), deployer));
        }
    }
}

/// @title Deploy: full THE PIT stack deployment for Robinhood Chain (id 4663)
/// @notice Deploys and wires the entire protocol in dependency order, then begins the
///         Ownable2Step ownership handover of every owned contract to OWNER. Deployed addresses
///         plus the effective config are written to deployments/robinhood-4663.json.
///
///         Order and wiring:
///         1. PauseGuardian(GUARDIAN)
///         2. OracleRouter(deployer, USDG)
///         3. Adapters: ChainlinkAdapter, TwapAdapter, TwapAdapterB, CrossPoolTwapAdapter,
///            TwoHopTwapAdapter (per-token source registration is a post-deploy ops step; see
///            docs/ops-runbook.md). TWO independent single-pool TwapAdapter instances are deployed
///            (wave-2b R-5): a Tier A_MAJOR token requires MIN_SOURCES (3) fresh sources or
///            settlement returns STALE, and every source repoint is behind the 2-day timelock, so a
///            routine feed deprecation on a 3-source major would freeze settlement for the whole
///            timelock window. Majors MUST therefore be wired with at least MIN_SOURCES + 1 = 4
///            sources (e.g. Chainlink + TwapAdapter on pool 1 + TwapAdapterB on pool 2 + the
///            CrossPoolTwapAdapter aggregate): losing any single source keeps quorum while the
///            timelocked replacement is scheduled. The second instance exists so that 4th slot
///            never requires a fresh adapter deployment at repoint time.
///         4. PitPoints(deployer)
///         5. CommitRevealCoordinator(deployer, VRF_OPERATOR)
///         6. SpinVRF(deployer, points), Jackpot(deployer, USDG, points)
///         7. MarketFactory(USDG, router, points, feeSplit{jackpot, TREASURY, REFERRAL_POOL,
///            BUYBACK}, OI_CAP_BPS, PER_ADDRESS_OI_CAP_BPS, SETTLEMENT_FEE_BPS, guardian, deployer)
///         8. points.setRegistrar(factory), points.setSpinVRF(spin),
///            spin.setCoordinator(coordinator), jackpot.setCoordinator(coordinator),
///            spin/jackpot.setRequestConfig (billing fields zeroed: the commit-reveal
///            coordinator ignores them; confirmations = 3 sets the reveal block distance),
///            coordinator.setConsumer(spin), coordinator.setConsumer(jackpot),
///            coordinator.setReservedCommitments(jackpot, 2) (fair-share floor, audit fix W2-15)
///            (the SpinVRF<->Jackpot entrant wiring was removed in audit fix C1)
///         9. Deploy a TimelockController (proposer/executor = OWNER, self-administered; the
///            deployer holds a TEMPORARY proposer role, revoked by the acceptance batch) and
///            transferOwnership(timelock) on router, all five adapters, points, coordinator, spin,
///            jackpot, and factory. Every subsequent owner action is therefore delayed by
///            TIMELOCK_MIN_DELAY (wave-2 TO-1 / TO-2: a compromised owner key cannot instantly
///            repoint sources, feeds, or the VRF coordinator; a live position can settle at the
///            honest price first).
///         10. Schedule the ownership-ACCEPTANCE batch on the timelock (wave-2b R-4): Ownable2Step
///            transferOwnership only sets pendingOwner, so without this step the deployer EOA
///            stays the live, un-timelocked owner of all eleven contracts until someone remembers to
///            route acceptOwnership through the timelock. The script schedules one batch (eleven
///            acceptOwnership calls plus revocation of the deployer's temporary timelock roles)
///            with delay TIMELOCK_MIN_DELAY, then asserts pendingOwner() == timelock on every owned
///            contract and that the operation is pending. RUNBOOK: after the delay elapses, OWNER
///            runs script/FinalizeHandover.s.sol (or calls executeBatch manually with
///            HANDOVER_SALT); that script asserts owner() == timelock on every owned contract.
///            UNTIL THE BATCH EXECUTES, THE DEPLOYER KEY IS FULLY PRIVILEGED: treat it as a
///            production secret, and prefer executing the acceptance at the earliest allowed time.
/// @dev Env block:
///      OWNER (address, required): governance multisig; becomes the timelock's sole proposer and
///      executor. The deployed contracts are owned by the TIMELOCK, not OWNER directly.
///      TIMELOCK_MIN_DELAY (uint seconds, default 172800 = 2 days): governance timelock delay.
///      OPEN_BOND_BPS (uint, default 50, max 500): anti-monopolization open bond for new markets
///      (W2-9), basis points of a fill's total open interest, armed at the factory IN the deploy
///      transaction (wave-2b R-3: the per-market rate is immutable and createMarket is
///      permissionless, so arming later through the timelock leaves a front-run window in which a
///      monopolizer bakes bond 0 forever). Value-bearing markets must not ship at bond 0; 0 is an
///      explicit opt-out for valueless test deployments only. NOTE for integrators: with a nonzero
///      bond the taker must approve takerCollateral + bond or fillOffer reverts on the bond pull.
///      GUARDIAN (address, required): PauseGuardian authority.
///      TREASURY (address, required): treasury leg of the fee split.
///      REFERRAL_POOL (address, required): referral leg of the fee split.
///      BUYBACK (address, required): buyback leg of the fee split. Accumulates the 39% buyback share
///      in USDG; the separate Buyback executor (a later launch-time artifact) swaps it for $PIT and
///      burns it. Set to a treasury-controlled address at launch until the executor is deployed.
///      SETTLEMENT_FEE_BPS (uint, default 50): settlement fee for new markets, basis points of the
///      loser's notional; validated at or below Market.MAX_FEE_BPS (100).
///      USDG (address, default canonical 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168): collateral.
///      ETH_USD_FEED (address, default 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9, the Chainlink
///      ETH/USD aggregator proxy on Robinhood Chain per the Chainlink reference data directory):
///      recorded in the output JSON for the ops steps that wire WETH-quoted sources.
///      VRF_OPERATOR (address, default OWNER): commit-reveal operator.
///      OI_CAP_BPS (uint, default 1000 = 10 percent): OI cap for new markets.
contract Deploy is Script, HandoverPlan {
    /// @notice Canonical USDG (Global Dollar) on Robinhood Chain. Several impostor tokens with
    ///         the same name exist on this chain; only this address is canonical.
    address public constant DEFAULT_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @notice Chainlink ETH/USD aggregator proxy on Robinhood Chain (8 decimals, 24h heartbeat,
    ///         0.5 percent deviation threshold; path eth-usd-shared-svr in the Chainlink RDD).
    address public constant DEFAULT_ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    /// @notice Default OI cap for new markets, in basis points of the creation liquidity snapshot.
    uint256 public constant DEFAULT_OI_CAP_BPS = 1000;

    /// @notice Default per-address OI sub-cap for new markets, in basis points of the OI cap
    ///         (2500 = 25 percent, so two colluding addresses cap at half the market OI cap).
    uint256 public constant DEFAULT_PER_ADDRESS_OI_CAP_BPS = 2500;

    /// @notice Default settlement fee for new markets, in basis points of the loser's notional
    ///         (50 = 0.5 percent). Mirrors MarketFactory.DEFAULT_SETTLEMENT_FEE_BPS.
    uint256 public constant DEFAULT_SETTLEMENT_FEE_BPS = 50;

    /// @notice Hard ceiling on SETTLEMENT_FEE_BPS this script accepts (100 = 1 percent). Mirrors
    ///         Market.MAX_FEE_BPS and MarketFactory.MAX_SETTLEMENT_FEE_BPS; the factory constructor
    ///         is the authoritative enforcer, this is an early, clearer revert.
    uint256 public constant MAX_SETTLEMENT_FEE_BPS = 100;

    /// @notice Default anti-monopolization open bond for new markets, in basis points of a fill's
    ///         total open interest (50 = 0.5 percent), ARMED AT THE FACTORY DURING DEPLOY (wave-2b
    ///         R-3). It must be nonzero at deploy because openBondBps is baked immutably per market
    ///         and createMarket is permissionless: a factory deployed at bond 0 lets a monopolizer
    ///         front-run createMarket for a hot token before the (itself timelocked) post-deploy
    ///         arming and bake bond 0 into that market forever. Value-bearing markets MUST NOT ship
    ///         at bond 0.
    /// @dev    Why 50 bps: (1) well above the tiny-fill rounding floor: the market computes
    ///         bond = floor(totalStake * bps / 10_000), which floors to zero only for fills under
    ///         10_000 / 50 = 200 raw USDG units (0.0002 USDG at 6 decimals), so a bond-free Sybil
    ///         grief accretes at most 0.0002 USDG of OI per fill and the rounding discount on any
    ///         fill of 1 USDG or more is under 0.02 percent; (2) it matches the protocol's existing
    ///         fee scale (DEFAULT_SETTLEMENT_FEE_BPS is also 50), a one-time 0.5 percent of fill OI
    ///         that is small against the up-to-100 percent PnL swing for honest takers, while a
    ///         monopolizer consuming the whole OI cap pays 0.5 percent of that cap per lock cycle
    ///         regardless of how many Sybil addresses split the positions; (3) at 10 percent of
    ///         MAX_OPEN_BOND_BPS (500) it leaves governance headroom to raise the rate for thin
    ///         markets through the timelock without repricing genesis markets.
    uint256 public constant DEFAULT_OPEN_BOND_BPS = 50;

    /// @notice Hard ceiling on OPEN_BOND_BPS this script accepts (500 = 5 percent). Mirrors
    ///         Market.MAX_OPEN_BOND_BPS and MarketFactory.MAX_OPEN_BOND_BPS; the factory setter is
    ///         the authoritative enforcer, this is an early, clearer revert.
    uint256 public constant MAX_OPEN_BOND_BPS = 500;

    /// @notice Default governance timelock delay (2 days). Every owner action (setSources, setFeed,
    ///         setTierConfig, setCoordinator, ...) must be scheduled on the TimelockController and
    ///         wait this long before execution, giving any live position a window to settle at the
    ///         honest price before a source/parameter swap can take effect (wave-2 TO-1/TO-2).
    uint256 public constant DEFAULT_TIMELOCK_MIN_DELAY = 2 days;

    /// @dev OI_CAP_BPS does not fit the factory's uint16 parameter.
    error OiCapTooLarge(uint256 oiCapBps);
    /// @dev An owned contract's pendingOwner is not the timelock after the handover began.
    error PendingOwnerMismatch(address target);
    /// @dev The ownership-acceptance batch is not pending on the timelock after scheduling.
    error AcceptanceNotScheduled(bytes32 operationId);
    /// @dev PER_ADDRESS_OI_CAP_BPS does not fit the factory's uint16 parameter or is out of range.
    error PerAddressOiCapInvalid(uint256 perAddressOiCapBps);
    /// @dev SETTLEMENT_FEE_BPS exceeds Market.MAX_FEE_BPS, the hard settlement-fee cap.
    error SettlementFeeTooLarge(uint256 settlementFeeBps);
    /// @dev OPEN_BOND_BPS does not fit the factory's uint16 parameter.
    error OpenBondTooLarge(uint256 openBondBps);

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
        uint256 oiCapBps;
        uint256 perAddressOiCapBps;
        uint256 settlementFeeBps;
        uint256 openBondBps;
        uint256 timelockMinDelay;
    }

    /// @notice Every deployed contract of the stack.
    /// @dev twapAdapterB is a second, independent single-pool TwapAdapter instance (wave-2b R-5):
    ///      TwapAdapter holds one pool per token, so a major's quorum margin (4th source) needs a
    ///      second instance to reference a second pool of the same token.
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
        MarketFactory factory;
    }

    /// @notice Deploys, wires, hands over, schedules the timelock's ownership acceptance, asserts
    ///         the handover state, and writes deployments/robinhood-4663.json.
    function run() external {
        Config memory cfg = _readConfig();

        vm.startBroadcast();
        // The temporary owner during wiring must be the ACTUAL broadcast sender (msg.sender is
        // the harness caller and diverges from it when run() is driven from a fork test).
        (, address deployer,) = vm.readCallers();
        Deployment memory d = _deploy(cfg, deployer);
        _wire(d, cfg);
        // Hand every owned contract to the governance timelock, not the raw multisig, so all owner
        // actions are timelocked (wave-2 TO-1 / TO-2).
        _handOver(d, address(d.timelock));
        // Schedule the acceptance batch so the handover is self-completing (wave-2b R-4): the
        // timelock actually OWNS nothing until it calls acceptOwnership on each contract.
        bytes32 handoverId = _scheduleAcceptance(d, cfg, deployer);
        vm.stopBroadcast();

        _assertHandoverBegun(d, handoverId);
        _writeAddressBook(cfg, d, deployer, handoverId);
    }

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
        cfg.oiCapBps = vm.envOr("OI_CAP_BPS", DEFAULT_OI_CAP_BPS);
        if (cfg.oiCapBps > type(uint16).max) revert OiCapTooLarge(cfg.oiCapBps);
        cfg.perAddressOiCapBps = vm.envOr("PER_ADDRESS_OI_CAP_BPS", DEFAULT_PER_ADDRESS_OI_CAP_BPS);
        if (cfg.perAddressOiCapBps == 0 || cfg.perAddressOiCapBps > 10_000) {
            revert PerAddressOiCapInvalid(cfg.perAddressOiCapBps);
        }
        cfg.settlementFeeBps = vm.envOr("SETTLEMENT_FEE_BPS", DEFAULT_SETTLEMENT_FEE_BPS);
        if (cfg.settlementFeeBps > MAX_SETTLEMENT_FEE_BPS) revert SettlementFeeTooLarge(cfg.settlementFeeBps);
        cfg.openBondBps = vm.envOr("OPEN_BOND_BPS", DEFAULT_OPEN_BOND_BPS);
        if (cfg.openBondBps > MAX_OPEN_BOND_BPS) revert OpenBondTooLarge(cfg.openBondBps);
        cfg.timelockMinDelay = vm.envOr("TIMELOCK_MIN_DELAY", DEFAULT_TIMELOCK_MIN_DELAY);
    }

    /// @dev Deploys every contract in dependency order; `deployer` owns during wiring.
    function _deploy(Config memory cfg, address deployer) internal returns (Deployment memory d) {
        // Governance timelock: OWNER (the multisig) is the standing proposer and sole executor; the
        // timelock administers itself (admin = address(0)). Every owner action on the router,
        // adapters, factory, and casino contracts is handed to THIS timelock, so a compromised
        // owner key cannot instantly repoint sources/feeds/coordinator: the change must be
        // scheduled and wait out timelockMinDelay, giving live positions a window to settle at the
        // honest price (wave-2 TO-1 / TO-2 mitigation). The deployer additionally holds a TEMPORARY
        // proposer role, needed only to schedule the ownership-acceptance batch inside this same
        // deploy transaction (wave-2b R-4); that batch's trailing calls revoke the role, and until
        // it executes the deployer is the live owner of everything anyway, so the temporary role
        // adds no authority the deployer does not already hold in that window.
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
        d.factory = new MarketFactory(
            cfg.usdg,
            address(d.router),
            address(d.points),
            Types.FeeSplit({
                jackpot: address(d.jackpot),
                treasury: cfg.treasury,
                referralPool: cfg.referralPool,
                buyback: cfg.buyback,
                vault: address(0) // perp-only recipient; ignored by the v1 casino Market split
            }),
            uint16(cfg.oiCapBps),
            uint16(cfg.perAddressOiCapBps),
            uint16(cfg.settlementFeeBps),
            address(d.guardian),
            deployer
        );
    }

    /// @dev Cross-wires the casino and core modules.
    /// @dev The SpinVRF<->Jackpot entrant wiring was removed in audit fix C1 (the uniform Pit Drop
    ///      entrant daily draw is gone); the daily draw is now points-weighted like the weekly one.
    function _wire(Deployment memory d, Config memory cfg) internal {
        d.points.setRegistrar(address(d.factory));
        d.points.setSpinVRF(address(d.spin));
        d.spin.setCoordinator(address(d.coordinator));
        d.jackpot.setCoordinator(address(d.coordinator));
        // Billing fields (subId, keyHash, nativePayment) are ignored by the commit-reveal
        // coordinator; requestConfirmations = 3 sets the assigned-block distance.
        d.spin.setRequestConfig(0, bytes32(0), 500_000, 3, false);
        d.jackpot.setRequestConfig(0, bytes32(0), 500_000, 3, false);
        d.coordinator.setConsumer(address(d.spin), true);
        d.coordinator.setConsumer(address(d.jackpot), true);
        // Arm the anti-monopolization open bond for new markets AT DEPLOY (wave-2 W2-9, hardened by
        // wave-2b R-3). openBondBps is baked immutably per market and createMarket is
        // permissionless, so arming must land in the deploy transaction, before any market can
        // exist: post-deploy arming is timelocked and a monopolizer could front-run createMarket in
        // that window and bake bond 0 forever. OPEN_BOND_BPS=0 is an explicit opt-out that must
        // never be used for a value-bearing launch.
        if (cfg.openBondBps != 0) d.factory.setOpenBondBps(uint16(cfg.openBondBps));
        // Fair-share reservation (audit fix W2-15/L1): reserve a commitment floor for the low-volume
        // Jackpot consumer (a concurrent daily + weekly draw), so a high-volume spin flood on the
        // shared queue can never starve the draws of a commitment.
        d.coordinator.setReservedCommitments(address(d.jackpot), 2);
    }

    /// @dev Begins the two-step ownership handover of every owned contract.
    function _handOver(Deployment memory d, address newOwner) internal {
        d.router.transferOwnership(newOwner);
        d.chainlinkAdapter.transferOwnership(newOwner);
        d.twapAdapter.transferOwnership(newOwner);
        d.twapAdapterB.transferOwnership(newOwner);
        d.crossPoolAdapter.transferOwnership(newOwner);
        d.twoHopAdapter.transferOwnership(newOwner);
        d.points.transferOwnership(newOwner);
        d.coordinator.transferOwnership(newOwner);
        d.spin.transferOwnership(newOwner);
        d.jackpot.transferOwnership(newOwner);
        d.factory.transferOwnership(newOwner);
    }

    /// @dev Every owned contract, in the canonical handover order shared with FinalizeHandover and
    ///      the fork suite. PauseGuardian is absent by design: it has an immutable guardian and no
    ///      owner at all.
    function _ownedContracts(Deployment memory d) internal pure returns (address[] memory owned) {
        owned = new address[](11);
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
        owned[10] = address(d.factory);
    }

    /// @dev Schedules the ownership-acceptance batch on the timelock with delay timelockMinDelay
    ///      (wave-2b R-4). The batch is the one built by _handoverBatch: acceptOwnership on every
    ///      owned contract, plus revocation of the deployer's temporary proposer/canceller roles
    ///      when the deployer is not OWNER. Returns the operation id (also written to the address
    ///      book) so FinalizeHandover and any manual executor can verify and execute it.
    function _scheduleAcceptance(Deployment memory d, Config memory cfg, address deployer)
        internal
        returns (bytes32 id)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _handoverBatch(_ownedContracts(d), d.timelock, deployer, deployer != cfg.owner);
        d.timelock.scheduleBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT, cfg.timelockMinDelay);
        id = d.timelock.hashOperationBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT);
    }

    /// @dev Post-deploy handover assertions (wave-2b R-4): every owned contract's pendingOwner is
    ///      the timelock, and the acceptance batch is pending on the timelock. owner() itself still
    ///      equals the deployer here BY CONSTRUCTION (Ownable2Step); the owner() == timelock
    ///      assertion lives in FinalizeHandover, after the batch executes.
    function _assertHandoverBegun(Deployment memory d, bytes32 handoverId) internal view {
        address[] memory owned = _ownedContracts(d);
        for (uint256 i = 0; i < owned.length; i++) {
            if (Ownable2Step(owned[i]).pendingOwner() != address(d.timelock)) {
                revert PendingOwnerMismatch(owned[i]);
            }
        }
        if (!d.timelock.isOperationPending(handoverId)) revert AcceptanceNotScheduled(handoverId);
    }

    /// @dev Records every address plus the effective config as JSON.
    function _writeAddressBook(Config memory cfg, Deployment memory d, address deployer, bytes32 handoverId)
        internal
    {
        string memory json = "deploy";
        vm.serializeAddress(json, "timelock", address(d.timelock));
        vm.serializeUint(json, "timelockMinDelay", cfg.timelockMinDelay);
        vm.serializeAddress(json, "deployer", deployer);
        vm.serializeBytes32(json, "handoverOperationId", handoverId);
        vm.serializeBytes32(json, "handoverSalt", HANDOVER_SALT);
        vm.serializeUint(json, "openBondBps", cfg.openBondBps);
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
        vm.serializeAddress(json, "marketFactory", address(d.factory));
        vm.serializeAddress(json, "usdg", cfg.usdg);
        vm.serializeAddress(json, "ethUsdFeed", cfg.ethUsdFeed);
        vm.serializeAddress(json, "owner", cfg.owner);
        vm.serializeAddress(json, "guardianAuthority", cfg.guardianAuthority);
        vm.serializeAddress(json, "treasury", cfg.treasury);
        vm.serializeAddress(json, "referralPool", cfg.referralPool);
        vm.serializeAddress(json, "buyback", cfg.buyback);
        vm.serializeAddress(json, "vrfOperator", cfg.vrfOperator);
        vm.serializeUint(json, "settlementFeeBps", cfg.settlementFeeBps);
        string memory out = vm.serializeUint(json, "oiCapBps", cfg.oiCapBps);

        vm.createDir("deployments", true);
        vm.writeJson(out, "deployments/robinhood-4663.json");
    }
}
