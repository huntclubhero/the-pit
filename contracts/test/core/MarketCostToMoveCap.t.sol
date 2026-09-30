// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {CoreBase} from "./CoreBase.t.sol";

/// @title MarketCostToMoveCapTest: the opening-side deviation breaker and the cost-to-move payout
///        cap at the Market level.
/// @notice Proves (1) the breaker gates OPENING only and never settlement, close, or forced unwind,
///         and (2) the factory bakes an absolute payout cap that bounds the maximum realizable
///         winner payout of a market by construction (fuzzed fill + settle).
contract MarketCostToMoveCapTest is CoreBase {
    address internal token2;
    Market internal capped;

    /// @dev Absolute payout cap (1e18 USD) for the capped market. Smaller than the oiCapBps cap
    ///      (10 percent of the 1_000_000e18 snapshot = 100_000e18) so the absolute cap is binding.
    uint256 internal constant CAP_1E18 = 50_000e18;

    function setUp() public override {
        super.setUp();
        token2 = makeAddr("cappedToken");
        router.setListable(token2, true);
        router.setSnapshotValue(token2, 1_000_000e18);
        router.setTrackedLiquidity(token2, 1_000_000e18);
        router.setPrice(token2, 1e18, Types.PriceStatus.OK);
        router.setPayoutCap(token2, CAP_1E18);
        capped = Market(factory.createMarket(token2));
    }

    function _fundApprove(address who, Market m, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(address(m), type(uint256).max);
    }

    // ===============================================================
    // The breaker gates OPENING only
    // ===============================================================

    function test_breaker_deniesFillOffer() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);

        router.setOpeningDenied(token, true, 1);

        _fund(bob, 10_000e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Market.OpeningPausedByDeviation.selector, uint8(1)));
        market.fillOffer(offerId, 10_000e6);
    }

    function test_breaker_neverGatesSettlementCloseOrForcedUnwind() public {
        // Two positions opened while the breaker allows opening.
        uint256 offer1 = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        uint256 pos1 = _fill(bob, offer1, 10_000e6);
        uint256 offer2 = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        uint256 pos2 = _fill(bob, offer2, 10_000e6);

        // Now the breaker trips: opening a NEW position is denied.
        router.setOpeningDenied(token, true, 1);
        uint256 offer3 = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fund(carol, 10_000e6);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Market.OpeningPausedByDeviation.selector, uint8(1)));
        market.fillOffer(offer3, 10_000e6);

        // CLOSE: a party settles pos1 after MIN_HOLD, before expiry, while the breaker denies
        // opening. Settlement must succeed (the breaker never touches it).
        vm.warp(block.timestamp + 31 minutes);
        router.setPrice(token, 1.05e18, Types.PriceStatus.OK);
        vm.prank(alice);
        market.settle(pos1);
        assertTrue(market.positions(pos1).settled);

        // FORCED UNWIND: pos2 reaches expiry + MAX_SETTLE_DELAY with a broken oracle. The
        // permissionless forced-unwind liveness path must succeed while the breaker denies opening.
        router.setPrice(token, 0, Types.PriceStatus.UNAVAILABLE);
        vm.warp(block.timestamp + 1 days + 24 hours + 1);
        vm.prank(carol); // not a party: permissionless after expiry
        market.settle(pos2);
        assertTrue(market.positions(pos2).settled);

        // Both parties can pull their forced-unwind refunds (each got collateralEach back).
        _drain(alice);
        _drain(bob);
    }

    // ===============================================================
    // The factory bakes the absolute payout cap; it bounds the OI cap
    // ===============================================================

    function test_factory_bakesPayoutCap() public view {
        assertEq(capped.maxPayoutCap1e18(), CAP_1E18);
        // The shared market (mock returns unbounded) has no absolute cap.
        assertEq(market.maxPayoutCap1e18(), type(uint256).max);
    }

    function test_cappedMarket_oiCapIsTheMinimum() public {
        // The bpsCap alone would allow 100_000e18 (10 percent of snapshot). The absolute cap
        // (50_000e18) binds: native cap = 50_000e18 / 1e12 = 50_000e6. A fill whose net escrow
        // pushes open interest past that reverts OiCapExceeded.
        uint256 nativeCap = CAP_1E18 / capped.collateralScale(); // 50_000e6

        // A single maker+taker fill escrows 2 * effectiveCollateral of open interest. Choose a
        // fill collateral whose doubled NET escrow exceeds the native cap.
        uint128 fill = uint128(nativeCap); // 2 * (fill - fee) > nativeCap
        _fundApprove(alice, capped, fill);
        vm.prank(alice);
        uint256 offerId =
            capped.postOffer(Types.Side.LONG, fill, 1_000e6, 5, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
        _fundApprove(bob, capped, fill);
        vm.prank(bob);
        vm.expectRevert();
        capped.fillOffer(offerId, fill);
    }

    function testFuzz_winnerPayoutNeverExceedsCap(uint128 collateralSeed, uint256 exitSeed, uint16 multipleSeed)
        public
    {
        uint256 nativeCap = CAP_1E18 / capped.collateralScale(); // 50_000e6
        // Any successful fill has 2 * effectiveCollateral escrowed <= nativeCap, so a maker
        // collateral up to nativeCap / 2 is safely fillable. Explore the full band.
        uint128 fill = uint128(bound(collateralSeed, 1_000e6, uint128(nativeCap / 2)));
        uint16 multiple = uint16(bound(multipleSeed, 1, 10));

        _fundApprove(alice, capped, fill);
        vm.prank(alice);
        uint256 offerId = capped.postOffer(
            Types.Side.LONG, fill, fill, multiple, 10_000, 1 days, uint64(block.timestamp + 1 days), 0
        );
        _fundApprove(bob, capped, fill);
        vm.prank(bob);
        uint256 positionId = capped.fillOffer(offerId, fill);

        // Settle after expiry at an arbitrary exit price (long or short can win, or it can be flat).
        vm.warp(block.timestamp + 1 days + 1);
        uint256 exit = bound(exitSeed, 1, 100e18);
        router.setPrice(token2, exit, Types.PriceStatus.OK);
        vm.prank(carol);
        capped.settle(positionId);

        // By construction the maximum single-position payout is bounded by the absolute cap:
        // winnerPayout <= 2 * collateralEach, and 2 * collateralEach * scale <= effective cap
        // <= CAP_1E18. Assert it directly on each party's credited balance.
        uint256 scale = capped.collateralScale();
        assertLe(capped.withdrawable(alice) * scale, CAP_1E18);
        assertLe(capped.withdrawable(bob) * scale, CAP_1E18);
        // And the combined settled payout (both legs) also stays within the cap.
        assertLe((capped.withdrawable(alice) + capped.withdrawable(bob)) * scale, CAP_1E18);
    }

    /// @notice The cost-to-move cap is RE-BASED on total escrow, so it holds under ASYMMETRIC odds:
    ///         however the escrow is split between maker and taker, no single-position payout can
    ///         exceed the absolute cap. A maker posts up to 20:1 odds; the taker fills the whole
    ///         offer; settlement at any exit price keeps every credited payout within CAP_1E18.
    function testFuzz_winnerPayoutNeverExceedsCapUnderOdds(
        uint128 makerCollSeed,
        uint32 ratioSeed,
        uint16 multipleSeed,
        uint256 exitSeed
    ) public {
        // Total escrow <= (1 + 10_000/ratio) * makerColl <= 2 * makerColl, so a maker collateral up
        // to nativeCap/2 (= 25_000e6) is safely fillable at any ratio; stay a touch below it.
        uint128 makerColl = uint128(bound(makerCollSeed, 20_000, 20_000e6));
        uint32 ratioBps = uint32(bound(ratioSeed, 10_000, 200_000));
        uint16 multiple = uint16(bound(multipleSeed, 1, 10));

        _fundApprove(alice, capped, makerColl);
        vm.prank(alice);
        uint256 offerId = capped.postOffer(
            Types.Side.LONG, makerColl, 1, multiple, ratioBps, 1 days, uint64(block.timestamp + 1 days), 0
        );
        // Fund the taker generously (makerColl >= its proportional stake) and fill the whole offer.
        _fundApprove(bob, capped, makerColl);
        vm.prank(bob);
        uint256 positionId = capped.fillOffer(offerId, makerColl);

        vm.warp(block.timestamp + 1 days + 1);
        uint256 exit = bound(exitSeed, 1, 100e18);
        router.setPrice(token2, exit, Types.PriceStatus.OK);
        vm.prank(carol);
        capped.settle(positionId);

        // Each leg's credited payout, and both legs combined, stay within the absolute cap.
        uint256 scale = capped.collateralScale();
        assertLe(capped.withdrawable(alice) * scale, CAP_1E18);
        assertLe(capped.withdrawable(bob) * scale, CAP_1E18);
        assertLe((capped.withdrawable(alice) + capped.withdrawable(bob)) * scale, CAP_1E18);
    }
}
