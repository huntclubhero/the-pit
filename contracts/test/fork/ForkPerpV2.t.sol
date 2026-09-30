// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {ChainlinkAdapter} from "../../src/oracle/adapters/ChainlinkAdapter.sol";
import {IPriceSource} from "../../src/oracle/adapters/IPriceSource.sol";
import {PitPoints} from "../../src/casino/PitPoints.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";
import {PerpRiskConfig} from "../../src/perp/PerpRiskConfig.sol";
import {InsuranceFund} from "../../src/perp/InsuranceFund.sol";
import {PitVault} from "../../src/perp/PitVault.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {DeployPerpV2, HandoverPlanV2} from "../../script/DeployPerpV2.s.sol";
import {ForkTestBase} from "./Fork.t.sol";

/// @dev Resolves the address vm.startBroadcast() will actually use in this harness, so the fork
///      test can pre-fund the deployer with the USDG the seeding steps pull.
contract BroadcastProbe is Script {
    function senderOf() external returns (address who) {
        vm.startBroadcast();
        (, who,) = vm.readCallers();
        vm.stopBroadcast();
    }
}

/// @title ForkTestDeployPerpV2: the full v2 production deploy dry-run on the live Robinhood fork
/// @notice Runs script/DeployPerpV2.s.sol against mainnet state and proves the WHOLE lifecycle:
///         deploy + wiring + InsuranceFund seed + vault bootstrap, the 14-contract Ownable2Step
///         handover (schedule at deploy, delayed acceptance, deployer role revocation), the
///         TIMELOCKED per-market listing runbook end to end on real WETH (assignTier with the
///         live-FDV band assert, then listMarket against the live Chainlink feed), the FWA
///         thin-token rejection, and finally a real open/close round trip against the freshly
///         bootstrapped vault with exact fee accounting.
contract ForkTestDeployPerpV2 is ForkTestBase, HandoverPlanV2 {
    address internal constant OWNER = address(0x1111111111111111111111111111111111111111);
    address internal constant GUARDIAN = address(0x2222222222222222222222222222222222222222);
    address internal constant TREASURY = address(0x3333333333333333333333333333333333333333);
    address internal constant REFERRAL = address(0x4444444444444444444444444444444444444444);
    address internal constant BUYBACK = address(0x5555555555555555555555555555555555555555);

    /// @dev Test-only source staleness: the lifecycle warps ~4 days past the fork head (handover
    ///      delay + listing delay), so the live feed's fork-head print must stay acceptable.
    ///      Production wiring uses ~90000s (heartbeat 86400 plus headroom); this widened bound
    ///      changes nothing about the mechanics under test.
    uint64 internal constant LONG_FEED_STALENESS = 30 days;

    /// @dev Majors quorum policy (wave-2b R-5): MIN_SOURCES + 1 = 4 source slots. On this chain
    ///      ETH has one canonical feed, so all four slots reference the same adapter (the v1 fork
    ///      suite's approach); production fills slots 2 to 4 with the TWAP adapters.
    uint256 internal constant MAJOR_SOURCE_SLOTS = 4;

    uint256 internal constant BPS = 10_000;
    /// @dev size1e18 * price1e18 / 1e30 = USDG units, mirroring the engine.
    uint256 internal constant SIZE_TIMES_PRICE_TO_USDG = 1e30;
    /// @dev IF_SEED + VAULT_BOOTSTRAP script defaults, pre-dealt to the broadcaster.
    uint256 internal constant SEED_TOTAL = 200_000e6;
    uint256 internal constant TRADER_STAKE = 1_000e6;
    /// @dev Sized INSIDE the launch throttles: with the 100k bootstrap TVL, the 7-day new-market
    ///      ramp caps the market reserve at 2% of TVL (2,000 USDG) and the per-address share at
    ///      25% of that (500 USDG). maxPayout = 9 * marginNet must stay under 500 USDG, so a 50
    ///      USDG margin (reserve ~449.1) fits; 100 USDG would correctly revert
    ///      AddressReserveCapExceeded.
    uint128 internal constant TRADE_MARGIN = 50e6;
    /// @dev 2x: valid in every tier of the locked schedule (minimum tier cap is 4x).
    uint32 internal constant TRADE_LEVERAGE_X100 = 200;
    bytes32 internal constant LISTING_SALT = keccak256("FORK_TEST_LIST_WETH_V2");

    /// @dev The deployed v2 stack as read back from the address book.
    struct V2Book {
        TimelockController timelock;
        address deployer;
        uint256 timelockMinDelay;
        uint256 ifSeed;
        uint256 vaultBootstrap;
        bytes32 handoverId;
        OracleRouter router;
        ChainlinkAdapter chainlinkAdapter;
        PitPoints points;
        address jackpot;
        PerpRiskConfig riskConfig;
        InsuranceFund insuranceFund;
        PitVault vault;
        PerpEngine engine;
        address[] owned;
    }

    /// @dev Trade-mirror locals, bundled for stack relief.
    struct TradeCalc {
        uint256 openFee;
        uint256 marginNet;
        uint256 size;
        uint256 mark;
        uint256 closedNotional;
        uint256 closeFee;
        uint256 jackpotShare;
    }

    function _setDeployEnv() internal {
        vm.setEnv("OWNER", vm.toString(OWNER));
        vm.setEnv("GUARDIAN", vm.toString(GUARDIAN));
        vm.setEnv("TREASURY", vm.toString(TREASURY));
        vm.setEnv("REFERRAL_POOL", vm.toString(REFERRAL));
        vm.setEnv("BUYBACK", vm.toString(BUYBACK));
    }

    function test_deployPerpV2FullLifecycleOnFork() public onlyForked {
        _setDeployEnv();

        // The seeding steps pull IF_SEED + VAULT_BOOTSTRAP from the broadcaster's USDG balance.
        address broadcaster = new BroadcastProbe().senderOf();
        deal(USDG, broadcaster, SEED_TOTAL);

        new DeployPerpV2().run();

        V2Book memory b = _loadBook();
        _assertDeployAndSeeds(b);
        _assertHandoverScheduled(b);
        _wireWethSources(b);
        _executeHandover(b);
        _listWethViaTimelock(b);
        _assertFwaRejected(b);
        _tradeRoundTrip(b);
    }

    // ================================ lifecycle steps ================================

    function _loadBook() internal view returns (V2Book memory b) {
        string memory json = vm.readFile("deployments/robinhood-4663-v2.json");
        b.timelock = TimelockController(payable(vm.parseJsonAddress(json, ".timelock")));
        b.deployer = vm.parseJsonAddress(json, ".deployer");
        b.timelockMinDelay = vm.parseJsonUint(json, ".timelockMinDelay");
        b.ifSeed = vm.parseJsonUint(json, ".ifSeed");
        b.vaultBootstrap = vm.parseJsonUint(json, ".vaultBootstrap");
        b.handoverId = vm.parseJsonBytes32(json, ".handoverOperationId");
        b.router = OracleRouter(vm.parseJsonAddress(json, ".oracleRouter"));
        b.chainlinkAdapter = ChainlinkAdapter(vm.parseJsonAddress(json, ".chainlinkAdapter"));
        b.points = PitPoints(vm.parseJsonAddress(json, ".pitPoints"));
        b.jackpot = vm.parseJsonAddress(json, ".jackpot");
        b.riskConfig = PerpRiskConfig(vm.parseJsonAddress(json, ".perpRiskConfig"));
        b.insuranceFund = InsuranceFund(vm.parseJsonAddress(json, ".insuranceFund"));
        b.vault = PitVault(vm.parseJsonAddress(json, ".pitVault"));
        b.engine = PerpEngine(vm.parseJsonAddress(json, ".perpEngine"));

        // Canonical v2 handover order (the batch hash depends on it).
        b.owned = new address[](OWNED_COUNT_V2);
        b.owned[0] = address(b.router);
        b.owned[1] = address(b.chainlinkAdapter);
        b.owned[2] = vm.parseJsonAddress(json, ".twapAdapter");
        b.owned[3] = vm.parseJsonAddress(json, ".twapAdapterB");
        b.owned[4] = vm.parseJsonAddress(json, ".crossPoolTwapAdapter");
        b.owned[5] = vm.parseJsonAddress(json, ".twoHopTwapAdapter");
        b.owned[6] = address(b.points);
        b.owned[7] = vm.parseJsonAddress(json, ".commitRevealCoordinator");
        b.owned[8] = vm.parseJsonAddress(json, ".spinVRF");
        b.owned[9] = b.jackpot;
        b.owned[10] = address(b.riskConfig);
        b.owned[11] = address(b.insuranceFund);
        b.owned[12] = address(b.vault);
        b.owned[13] = address(b.engine);

        // Address-book sanity: the canonical chain constants round-tripped.
        assertEq(vm.parseJsonAddress(json, ".usdg"), USDG, "book usdg");
        assertEq(vm.parseJsonAddress(json, ".ethUsdFeed"), ETH_USD_FEED, "book ethUsdFeed");
        assertEq(vm.parseJsonAddress(json, ".owner"), OWNER, "book owner");
        // The effective tier table landed in the book with the LOCKED schedule.
        assertEq(vm.parseJsonUint(json, ".tier5.maxLeverageX100"), 1500, "tier5 leverage locked");
        assertEq(vm.parseJsonUint(json, ".tier0.maxLeverageX100"), 400, "tier0 leverage locked");
        assertEq(vm.parseJsonUint(json, ".tier0.mmrBps"), 1500, "tier0 mmr default");
        assertEq(vm.parseJsonUint(json, ".payoutCapMultiple"), 9, "payout cap default");
    }

    /// @dev The spec 8.6 seam holds on the freshly deployed stack, and both seeds landed.
    function _assertDeployAndSeeds(V2Book memory b) internal view {
        // Engine <> vault <> fund seam.
        assertEq(b.vault.engine(), address(b.engine), "vault engine");
        assertEq(b.insuranceFund.engine(), address(b.engine), "fund engine");
        assertEq(b.insuranceFund.vault(), address(b.vault), "fund vault");
        assertEq(address(b.engine.vault()), address(b.vault), "engine vault");
        assertEq(address(b.engine.insuranceFund()), address(b.insuranceFund), "engine fund");
        assertEq(address(b.engine.riskConfig()), address(b.riskConfig), "engine riskConfig");
        assertEq(address(b.engine.router()), address(b.router), "engine router");
        assertEq(
            IERC20(USDG).allowance(address(b.engine), address(b.vault)),
            type(uint256).max,
            "engine max-approved the vault (settleTraderLoss pull)"
        );
        // The engine is the points consumer and registrar.
        assertTrue(b.points.isMarket(address(b.engine)), "engine registered on points");
        assertEq(b.points.registrar(), address(b.engine), "engine is points registrar");
        // Fee split: the jackpot leg targets the deployed Jackpot.
        assertEq(b.engine.feeJackpot(), b.jackpot, "jackpot fee leg");
        assertEq(b.engine.feeTreasury(), TREASURY, "treasury fee leg");
        assertEq(b.engine.feeReferralPool(), REFERRAL, "referral fee leg");
        assertEq(b.engine.feeBuyback(), BUYBACK, "buyback fee leg");
        // Seeds: 100k USDG in the fund, 100k bootstrap NAV in the vault, PLP to OWNER.
        assertEq(b.insuranceFund.balance(), b.ifSeed, "IF seeded");
        assertEq(b.vault.totalAssets(), b.vaultBootstrap, "vault bootstrap NAV");
        assertGt(b.vault.balanceOf(OWNER), 0, "bootstrap PLP minted to OWNER");
        assertEq(b.vault.balanceOf(b.vault.DEAD_ADDRESS()), b.vault.DEAD_SHARES(), "dead shares carved");
        // Nothing is listed yet: listing is a post-deploy timelocked ops step.
        assertEq(b.engine.marketCount(), 0, "no markets at deploy");
    }

    /// @dev Phase-1 handover state: pendingOwner everywhere, acceptance batch pending.
    function _assertHandoverScheduled(V2Book memory b) internal view {
        for (uint256 i = 0; i < b.owned.length; ++i) {
            assertEq(Ownable2Step(b.owned[i]).owner(), b.deployer, "deployer owns until acceptance");
            assertEq(Ownable2Step(b.owned[i]).pendingOwner(), address(b.timelock), "timelock pending");
        }
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _handoverBatch(b.owned, b.timelock, b.deployer, b.deployer != OWNER);
        bytes32 id = b.timelock.hashOperationBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT_V2);
        assertEq(id, b.handoverId, "book records the operation id");
        assertTrue(b.timelock.isOperationPending(id), "acceptance scheduled at deploy");
        assertFalse(b.timelock.isOperationReady(id), "timelock delay is real");
    }

    /// @dev Ops window (deployer still owns the oracle stack): wire WETH per the majors policy.
    function _wireWethSources(V2Book memory b) internal {
        vm.startPrank(b.deployer);
        b.chainlinkAdapter.setFeed(WETH, ETH_USD_FEED);
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](MAJOR_SOURCE_SLOTS);
        for (uint256 i = 0; i < MAJOR_SOURCE_SLOTS; ++i) {
            sources[i] = OracleRouter.SourceConfig({
                source: IPriceSource(address(b.chainlinkAdapter)), maxStaleness: LONG_FEED_STALENESS
            });
        }
        b.router.setSources(WETH, sources);
        vm.stopPrank();
        assertTrue(b.router.isListable(WETH), "WETH listable as A_MAJOR");
    }

    /// @dev Phase 2: the delay cannot be bypassed; after it elapses OWNER executes and the
    ///      timelock becomes the live owner of all fourteen contracts, deployer roles revoked.
    function _executeHandover(V2Book memory b) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _handoverBatch(b.owned, b.timelock, b.deployer, b.deployer != OWNER);

        vm.prank(OWNER);
        vm.expectRevert();
        b.timelock.executeBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT_V2);

        vm.warp(block.timestamp + b.timelockMinDelay);
        assertTrue(b.timelock.isOperationReady(b.handoverId), "ready after the delay");
        vm.prank(OWNER);
        b.timelock.executeBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT_V2);

        for (uint256 i = 0; i < b.owned.length; ++i) {
            assertEq(Ownable2Step(b.owned[i]).owner(), address(b.timelock), "timelock owns after acceptance");
        }
        assertFalse(b.timelock.hasRole(b.timelock.PROPOSER_ROLE(), b.deployer), "deployer proposer revoked");
        assertFalse(b.timelock.hasRole(b.timelock.CANCELLER_ROLE(), b.deployer), "deployer canceller revoked");
        assertTrue(b.timelock.hasRole(b.timelock.PROPOSER_ROLE(), OWNER), "OWNER proposes");
        assertTrue(b.timelock.hasRole(b.timelock.EXECUTOR_ROLE(), OWNER), "OWNER executes");
    }

    /// @dev The documented per-market listing runbook, driven through the live timelock: one
    ///      scheduled batch of [assignTier(live-FDV band), listMarket(isListable re-check)].
    function _listWethViaTimelock(V2Book memory b) internal {
        uint256 fdv = b.riskConfig.fdvOf(WETH);
        uint8 tier = b.riskConfig.tierForFdv(fdv);

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        targets[0] = address(b.riskConfig);
        payloads[0] = abi.encodeCall(b.riskConfig.assignTier, (WETH, tier));
        targets[1] = address(b.engine);
        payloads[1] = abi.encodeCall(b.engine.listMarket, (WETH));

        vm.prank(OWNER);
        b.timelock.scheduleBatch(targets, values, payloads, bytes32(0), LISTING_SALT, b.timelockMinDelay);
        vm.warp(block.timestamp + b.timelockMinDelay);
        vm.prank(OWNER);
        b.timelock.executeBatch(targets, values, payloads, bytes32(0), LISTING_SALT);

        assertTrue(b.engine.isListed(WETH), "WETH listed");
        assertEq(b.engine.marketCount(), 1, "one market");
        assertEq(b.riskConfig.mcapTierOf(WETH), tier, "tier assigned at the live FDV band");
        // The tier's effective params serve, with leverage clamped to the locked schedule.
        PerpTypes.TierParams memory p = b.riskConfig.paramsFor(WETH);
        assertEq(p.maxLeverageX100, b.riskConfig.lockedMaxLeverageX100(tier), "locked leverage serves");
    }

    /// @dev The thin-token rejection survives into v2: FWA has no sources and a ~1.2K USD pool,
    ///      so even the timelock itself cannot list it.
    function _assertFwaRejected(V2Book memory b) internal {
        assertFalse(b.router.isListable(FWA), "FWA not listable");
        vm.prank(address(b.timelock));
        vm.expectRevert(PerpEngine.RouterNotListable.selector);
        b.engine.listMarket(FWA);
    }

    /// @dev A real open/close round trip against the bootstrapped vault at the live Chainlink
    ///      mark: fees route 25/10/39/26, the reservation releases, and the flat close returns
    ///      margin minus exactly the two fees (same-block close: no funding, no borrow, no PnL).
    function _tradeRoundTrip(V2Book memory b) internal {
        address trader = makeAddr("perpTrader");
        deal(USDG, trader, TRADER_STAKE);
        TradeCalc memory c;
        PerpTypes.TierParams memory p = b.riskConfig.paramsFor(WETH);

        c.openFee = Math.mulDiv(uint256(TRADE_MARGIN) * TRADE_LEVERAGE_X100 / 100, p.openFeeBps, BPS);
        c.marginNet = TRADE_MARGIN - c.openFee;

        vm.startPrank(trader);
        IERC20(USDG).approve(address(b.engine), type(uint256).max);
        b.engine.openPosition(WETH, true, TRADE_MARGIN, TRADE_LEVERAGE_X100);
        vm.stopPrank();

        PerpTypes.Position memory pos = b.engine.getPosition(WETH, trader, true);
        assertGt(pos.size1e18, 0, "position open");
        assertEq(uint256(pos.margin), c.marginNet, "net margin escrowed");
        assertEq(uint256(pos.maxPayout), b.riskConfig.payoutCapMultiple() * c.marginNet, "payout cap frozen at open");
        assertEq(b.vault.totalReserved(), uint256(pos.maxPayout), "vault reserved the cap");
        c.size = pos.size1e18;

        // Same-block close at the identical live mark: zero PnL, zero funding, zero borrow.
        (c.mark,) = b.router.peekPrice(WETH);
        assertEq(uint256(pos.entryPrice1e18), c.mark, "entry equals the live mark");
        c.closedNotional = Math.mulDiv(c.size, c.mark, SIZE_TIMES_PRICE_TO_USDG);
        c.closeFee = Math.mulDiv(c.closedNotional, p.closeFeeBps, BPS);
        c.jackpotShare = Math.mulDiv(c.openFee, 2_500, BPS) + Math.mulDiv(c.closeFee, 2_500, BPS);

        vm.prank(trader);
        b.engine.closePosition(WETH, true);

        assertEq(b.engine.getPosition(WETH, trader, true).size1e18, 0, "position closed");
        assertEq(b.vault.totalReserved(), 0, "reservation released");
        assertEq(
            IERC20(USDG).balanceOf(trader),
            TRADER_STAKE - c.openFee - c.closeFee,
            "flat round trip costs exactly the two fees"
        );
        assertEq(IERC20(USDG).balanceOf(b.jackpot), c.jackpotShare, "jackpot got its 25 percent of both fees");
        assertEq(b.vault.totalAssets(), b.vaultBootstrap, "vault NAV unchanged by the flat trade");
        assertEq(b.insuranceFund.balance(), b.ifSeed, "insurance fund untouched");
    }
}
