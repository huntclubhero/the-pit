// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {MarketFactory} from "../../src/core/MarketFactory.sol";
import {PauseGuardian} from "../../src/core/PauseGuardian.sol";
import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {ChainlinkAdapter} from "../../src/oracle/adapters/ChainlinkAdapter.sol";
import {IPriceSource} from "../../src/oracle/adapters/IPriceSource.sol";
import {PitPoints} from "../../src/casino/PitPoints.sol";
import {SpinVRF} from "../../src/casino/SpinVRF.sol";
import {Jackpot} from "../../src/casino/Jackpot.sol";

import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {MockVRFCoordinator} from "../mocks/MockVRFCoordinator.sol";

/// @title FullStack: cross-module integration tests over the REAL contracts
/// @notice Everything is real except the leaves: USDG, the three Chainlink feeds
///         behind the router's adapters, and the VRF coordinator. Covers the whole
///         lifecycle: market creation wiring, fill, points, spin, settlement,
///         fee split into the jackpot, and a weekly weighted draw.
contract FullStackTest is Test {
    MockUSDG internal usdg;
    OracleRouter internal router;
    ChainlinkAdapter[3] internal adapters;
    MockChainlinkFeed[3] internal feeds;
    PitPoints internal points;
    SpinVRF internal spin;
    Jackpot internal jackpot;
    MockVRFCoordinator internal coord;
    PauseGuardian internal pauseGuardian;
    MarketFactory internal factory;
    Market internal market;

    address internal token;
    address internal pool;
    address internal owner;
    address internal guardianMultisig;
    address internal treasury;
    address internal referral;
    address internal buyback;
    address internal alice; // maker
    address internal bob; // taker
    address internal carol; // market creator

    uint128 internal constant OFFER_COLLATERAL = 1_000e6;
    uint128 internal constant FILL = 500e6;
    uint16 internal constant MULTIPLE = 5;
    /// @dev Entry fee per side: FILL * MULTIPLE * 10 / 10_000 = 2.5e6, so the
    ///      position opens with collateralEach = 497.5e6 and the 5e6 entry fee total
    ///      is split 25/10/39/26 at fill: 1.25e6 jackpot, 0.5e6 referral, 1.95e6 buyback,
    ///      1.3e6 treasury.
    uint128 internal constant ENTRY_FEE_SIDE = 2_500_000;
    uint128 internal constant FILL_NET = FILL - ENTRY_FEE_SIDE;

    function setUp() public {
        vm.warp(1_800_000_000);

        token = makeAddr("memeToken");
        pool = makeAddr("v3PoolStandIn");
        owner = makeAddr("owner");
        guardianMultisig = makeAddr("guardianMultisig");
        treasury = makeAddr("treasury");
        referral = makeAddr("referral");
        buyback = makeAddr("buyback");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        usdg = new MockUSDG();
        router = new OracleRouter(owner, address(usdg));

        // Three independent price sources so no single feed can settle a position.
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](3);
        for (uint256 i = 0; i < 3; i++) {
            adapters[i] = new ChainlinkAdapter(owner);
            feeds[i] = new MockChainlinkFeed(8);
            feeds[i].setAnswer(1e8, block.timestamp);
            vm.prank(owner);
            adapters[i].setFeed(token, address(feeds[i]));
            sources[i] = OracleRouter.SourceConfig({source: IPriceSource(address(adapters[i])), maxStaleness: 1 hours});
        }
        address[] memory pools = new address[](1);
        pools[0] = pool;
        vm.startPrank(owner);
        router.setSources(token, sources);
        router.setGuards(token, OracleRouter.Tier.B, 2_500);
        router.setTrackedPools(token, pools);
        vm.stopPrank();
        // 50_000 USDG sitting in the pool: tracked liquidity 100_000e18, above the floor.
        usdg.mint(pool, 50_000e6);

        points = new PitPoints(owner);
        spin = new SpinVRF(owner, address(points));
        jackpot = new Jackpot(owner, address(usdg), address(points));
        coord = new MockVRFCoordinator();
        vm.startPrank(owner);
        points.setSpinVRF(address(spin));
        spin.setCoordinator(address(coord));
        spin.setRequestConfig(1, bytes32(uint256(1)), 500_000, 3, false);
        jackpot.setCoordinator(address(coord));
        jackpot.setRequestConfig(1, bytes32(uint256(1)), 500_000, 3, false);
        vm.stopPrank();

        pauseGuardian = new PauseGuardian(guardianMultisig);
        factory = new MarketFactory(
            address(usdg),
            address(router),
            address(points),
            Types.FeeSplit({
                jackpot: address(jackpot),
                treasury: treasury,
                referralPool: referral,
                buyback: buyback,
                vault: address(0)
            }),
            1_000,
            2_500,
            50,
            address(pauseGuardian),
            owner
        );
        vm.prank(owner);
        points.setRegistrar(address(factory));

        // Wave-2b R-7: a multi-source token needs a FULLY seeded fallback ring at market creation,
        // and each prime advances the ring at most one print per block. Seed two prints across two
        // blocks here; createMarket's own best-effort prime completes the third in its block.
        for (uint256 i = 0; i < 2; i++) {
            router.primeFallback(token);
            vm.roll(block.number + 1);
        }

        vm.prank(carol);
        market = Market(factory.createMarket(token));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _setAllFeeds(int256 answer) internal {
        for (uint256 i = 0; i < 3; i++) {
            feeds[i].setAnswer(answer, block.timestamp);
        }
    }

    function _postAndFill() internal returns (uint256 offerId, uint256 positionId) {
        usdg.mint(alice, OFFER_COLLATERAL);
        vm.startPrank(alice);
        usdg.approve(address(market), type(uint256).max);
        offerId = market.postOffer(
            Types.Side.LONG, OFFER_COLLATERAL, 100e6, MULTIPLE, 10_000, 1 days, uint64(block.timestamp + 1 days), 0
        );
        vm.stopPrank();

        usdg.mint(bob, FILL);
        vm.startPrank(bob);
        usdg.approve(address(market), type(uint256).max);
        positionId = market.fillOffer(offerId, FILL);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Wiring
    // ------------------------------------------------------------------

    function test_factoryRegistersMarketAndCreator() public view {
        assertTrue(points.isMarket(address(market)));
        assertEq(points.creatorOf(token), carol);
        assertEq(factory.marketFor(token), address(market));
    }

    function test_createMarket_requiresSeededFallbackRing() public {
        // Wave-2b R-7: a listable multi-source token with an EMPTY agreed-print ring must be
        // refused a market: an unseeded ring is the W2-10 permanent-COOLDOWN forced-unwind free
        // option, and primeFallback can no longer fill the ring inside one transaction.
        address token2 = makeAddr("memeToken2");
        address pool2 = makeAddr("v3PoolStandIn2");
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](3);
        vm.startPrank(owner);
        for (uint256 i = 0; i < 3; i++) {
            adapters[i].setFeed(token2, address(feeds[i]));
            sources[i] = OracleRouter.SourceConfig({source: IPriceSource(address(adapters[i])), maxStaleness: 1 hours});
        }
        router.setSources(token2, sources);
        router.setGuards(token2, OracleRouter.Tier.B, 2_500);
        address[] memory pools = new address[](1);
        pools[0] = pool2;
        router.setTrackedPools(token2, pools);
        vm.stopPrank();
        usdg.mint(pool2, 50_000e6);

        // Fully listable, but the ring holds at most the single print createMarket itself primes.
        vm.expectRevert(MarketFactory.FallbackRingNotSeeded.selector);
        factory.createMarket(token2);

        // Permissionless seeding across distinct blocks unblocks creation: two prints here plus
        // the third from createMarket's own best-effort prime in its block.
        router.primeFallback(token2);
        vm.roll(block.number + 1);
        router.primeFallback(token2);
        vm.roll(block.number + 1);
        address market2 = factory.createMarket(token2);
        assertEq(factory.marketFor(token2), market2);
        (, uint8 count,) = router.agreedPrintsOf(token2);
        assertEq(count, 3);
    }

    // ------------------------------------------------------------------
    // Full lifecycle: fill, points, spin, settle, fee split
    // ------------------------------------------------------------------

    function test_fullLifecycle() public {
        (, uint256 positionId) = _postAndFill();

        // Points: notional is the POST-FEE escrow times multiple: 497.5e6 x 5 =
        // 2_487.5 USDG. Base 10 pts per 100 USDG: taker 248.75e18, maker 2x:
        // 497.5e18. Creator carol gets 5% of every mint.
        uint256 takerBase = 248.75e18;
        assertEq(points.pointsOf(bob), takerBase);
        assertEq(points.pointsOf(alice), 2 * takerBase);
        assertEq(points.pointsOf(carol), (3 * takerBase) / 20);

        // The fill requested exactly one spin for the taker.
        assertEq(coord.requestCount(), 1);
        uint256[] memory words = new uint256[](1);
        words[0] = 9_999; // lands in [9900, 10000): 100x, minting the full 99x bonus
        coord.fulfill(address(spin), 1, words);
        (,,, bool fulfilled, uint256 multiplier,,) = spin.getSpin(1);
        assertTrue(fulfilled);
        assertEq(multiplier, 100);
        // Bonus: base x 99 on top of the original base.
        assertEq(points.pointsOf(bob), takerBase + takerBase * 99);

        // Price rips 20 percent on all three feeds; long (alice, the maker) wins.
        vm.warp(block.timestamp + 31 minutes);
        _setAllFeeds(1.2e8);

        uint256 marketBalanceBefore = usdg.balanceOf(address(market));
        vm.prank(alice);
        market.settle(positionId);
        // Payouts are credited (pull-payment); alice pulls her winnings. Bob (full loss) has
        // nothing credited.
        vm.prank(alice);
        market.withdraw();

        // Raw PnL = 2_487.5e6 x 0.2 = 497.5e6, clamped to collateralEach (497.5e6):
        // total win. Settlement fee = min(50 bps x 2_487.5e6, 497.5e6) = 12.4375e6, split
        // 25/10/39/26 (jackpot 3_109_375, referral 1_243_750, buyback 4_850_625, treasury
        // 3_233_750), stacked on top of the entry fee split already paid at fill.
        assertEq(usdg.balanceOf(alice), uint256(FILL_NET) + FILL_NET - 12_437_500);
        assertEq(usdg.balanceOf(bob), 0);
        assertEq(usdg.balanceOf(address(jackpot)), 1_250_000 + 3_109_375);
        assertEq(usdg.balanceOf(treasury), 1_300_000 + 3_233_750);
        assertEq(usdg.balanceOf(referral), 500_000 + 1_243_750);
        assertEq(usdg.balanceOf(buyback), 1_950_000 + 4_850_625);
        // Escrow conservation: only alice's unfilled 500e6 offer remainder stays.
        assertEq(usdg.balanceOf(address(market)), marketBalanceBefore - 2 * uint256(FILL_NET));
        assertEq(usdg.balanceOf(address(market)), 500e6);

        // Settlement points effects: bob (loser) got the multiplier-free 25 percent rebate.
        assertEq(points.pointsOf(bob), takerBase * 100 + takerBase / 4);
    }

    // ------------------------------------------------------------------
    // Jackpot: fees in, weighted weekly draw out
    // ------------------------------------------------------------------

    function test_weeklyDrawPaysFromRealFees() public {
        (, uint256 positionId) = _postAndFill();
        vm.warp(block.timestamp + 31 minutes);
        _setAllFeeds(1.2e8);
        vm.prank(alice);
        market.settle(positionId);
        // Alice pulls her credited settlement payout so her wallet reflects the win below.
        vm.prank(alice);
        market.withdraw();
        // 1.25e6 of entry-fee jackpot share from the fill plus 3.109375e6 from the settlement fee.
        uint256 pot = usdg.balanceOf(address(jackpot));
        assertEq(pot, 4_359_375);

        // W2-2b: file the fee inflow while its epoch is still current; the epoch's drip bucket
        // closes at the boundary and the weekly pays only inflow that arrived during it.
        jackpot.syncInflow();

        // Next epoch: the weekly draw covers the completed epoch's points.
        vm.warp(block.timestamp + 7 days);
        jackpot.startDraw(Jackpot.DrawKind.WEEKLY);
        uint256 requestId = coord.requestCount(); // ids are global and sequential
        uint256[] memory words = new uint256[](1);
        words[0] = 123_456_789;
        coord.fulfill(address(jackpot), requestId, words);

        // Weekly credits 50 percent of the pot to a weighted winner (pull payment, audit fix D2):
        // the USDG stays in the contract as a claimable credit until the winner withdraws.
        assertEq(jackpot.totalClaimable(), pot / 2, "half the pot credited");
        assertEq(jackpot.potBalance(), pot - pot / 2, "pot rolled forward by the credit");
        assertEq(usdg.balanceOf(address(jackpot)), pot, "funds stay until claimed");

        // The winner is one of the epoch's ACTUAL traders (creator-share weight is excluded, so
        // carol, who only earned the passive 5% share, can never win).
        Jackpot.Draw memory draw = jackpot.getDraw(0);
        assertTrue(draw.winner == alice || draw.winner == bob, "an actual trader won");
        assertEq(jackpot.claimable(draw.winner), pot / 2);

        uint256 winnerBefore = usdg.balanceOf(draw.winner);
        vm.prank(draw.winner);
        jackpot.claim();
        assertEq(usdg.balanceOf(draw.winner) - winnerBefore, pot / 2, "winner withdrew the credit");
        assertEq(usdg.balanceOf(address(jackpot)), pot - pot / 2, "only the un-drawn pot remains");
    }

    // ------------------------------------------------------------------
    // Oracle disagreement blocks entry
    // ------------------------------------------------------------------

    function test_feedDisagreementBlocksFills() public {
        usdg.mint(alice, OFFER_COLLATERAL);
        vm.startPrank(alice);
        usdg.approve(address(market), type(uint256).max);
        uint256 offerId = market.postOffer(
            Types.Side.LONG, OFFER_COLLATERAL, 100e6, MULTIPLE, 10_000, 1 days, uint64(block.timestamp + 1 days), 0
        );
        vm.stopPrank();

        // One feed doubles: pairwise deviation far beyond tier B's 2_500 bps.
        feeds[2].setAnswer(2e8, block.timestamp);

        usdg.mint(bob, FILL);
        vm.startPrank(bob);
        usdg.approve(address(market), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Market.OracleNotOk.selector, Types.PriceStatus.COOLDOWN));
        market.fillOffer(offerId, FILL);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Self-fill is rejected through the real stack
    // ------------------------------------------------------------------

    function test_selfFillRejected() public {
        usdg.mint(alice, OFFER_COLLATERAL + FILL);
        vm.startPrank(alice);
        usdg.approve(address(market), type(uint256).max);
        uint256 offerId = market.postOffer(
            Types.Side.LONG, OFFER_COLLATERAL, 100e6, MULTIPLE, 10_000, 1 days, uint64(block.timestamp + 1 days), 0
        );
        vm.expectRevert(Market.SelfFill.selector);
        market.fillOffer(offerId, FILL);
        vm.stopPrank();
    }
}
