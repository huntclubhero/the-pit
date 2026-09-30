// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {PauseGuardian} from "../../src/core/PauseGuardian.sol";
import {CoreBase} from "./CoreBase.t.sol";

/// @dev Minimal token reporting more than 18 decimals, for constructor validation.
contract HighDecimalsToken {
    function decimals() external pure returns (uint8) {
        return 20;
    }
}

/// @dev ERC20 that attempts to re-enter Market.settle from inside transfer, to prove
///      the reentrancy guard holds on the payout path.
contract ReentrantUSDG is ERC20 {
    Market public target;
    uint256 public positionToReenter;
    bool public armed;
    bool public reentryBlocked;

    constructor() ERC20("Evil USDG", "EUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(Market target_, uint256 positionId) external {
        target = target_;
        positionToReenter = positionId;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            try target.settle(positionToReenter) {}
            catch {
                reentryBlocked = true;
            }
        }
        return super.transfer(to, amount);
    }
}

// ======================================================================
// postOffer
// ======================================================================

contract MarketPostOfferTest is CoreBase {
    function test_postOffer_storesOfferEscrowsAndEmits() public {
        _fund(alice, 10_000e6);
        uint64 expiry = uint64(block.timestamp + 1 days);

        vm.expectEmit(true, true, true, true);
        emit Market.OfferPosted(0, alice, Types.Side.LONG, 10_000e6, 1_000e6, 5, 10_000, 1 days, expiry, 2e18);
        vm.prank(alice);
        uint256 offerId = market.postOffer(Types.Side.LONG, 10_000e6, 1_000e6, 5, 10_000, 1 days, expiry, 2e18);

        assertEq(offerId, 0);
        assertEq(market.nextOfferId(), 1);
        assertEq(usdg.balanceOf(alice), 0);
        assertEq(usdg.balanceOf(address(market)), 10_000e6);

        Types.Offer memory offer = market.offers(offerId);
        assertEq(offer.maker, alice);
        assertEq(offer.token, token);
        assertEq(uint8(offer.makerSide), uint8(Types.Side.LONG));
        assertEq(offer.collateralRemaining, 10_000e6);
        assertEq(offer.minFill, 1_000e6);
        assertEq(offer.multiple, 5);
        assertEq(offer.payoffRatioBps, 10_000);
        assertEq(offer.duration, 1 days);
        assertEq(offer.offerExpiry, expiry);
        assertEq(offer.limitEntry1e18, 2e18);
        assertFalse(offer.cancelled);
    }

    function test_postOffer_idsIncrement() public {
        uint256 first = _postOffer(alice, Types.Side.LONG, 1_000e6, 100e6);
        uint256 second = _postOffer(bob, Types.Side.SHORT, 1_000e6, 100e6);
        assertEq(first, 0);
        assertEq(second, 1);
    }

    function test_postOffer_boundaryParamsAccepted() public {
        _fund(alice, 4e6);
        vm.startPrank(alice);
        // multiple 1 and 10, payoff ratio at its 1:1 floor and 20:1 ceiling, duration exactly
        // 1 hour and 30 days, minFill == collateral.
        market.postOffer(Types.Side.LONG, 1e6, 1e6, 1, 10_000, 1 hours, uint64(block.timestamp + 1), 0);
        market.postOffer(Types.Side.SHORT, 1e6, 1e6, 10, 200_000, 30 days, uint64(block.timestamp + 1), 0);
        market.postOffer(Types.Side.LONG, 1e6, 1, 5, 10_000, 1 days, uint64(block.timestamp + 365 days), 0);
        market.postOffer(
            Types.Side.SHORT, 1e6, 1e6, 5, 50_000, 1 days, uint64(block.timestamp + 1 days), type(uint128).max
        );
        vm.stopPrank();
    }

    function test_postOffer_revertsOnZeroCollateral() public {
        vm.expectRevert(Market.ZeroCollateral.selector);
        vm.prank(alice);
        market.postOffer(Types.Side.LONG, 0, 0, 5, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
    }

    function test_postOffer_revertsOnZeroMinFill() public {
        vm.expectRevert(Market.InvalidMinFill.selector);
        vm.prank(alice);
        market.postOffer(Types.Side.LONG, 1_000e6, 0, 5, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
    }

    function test_postOffer_revertsOnMinFillAboveCollateral() public {
        vm.expectRevert(Market.InvalidMinFill.selector);
        vm.prank(alice);
        market.postOffer(Types.Side.LONG, 1_000e6, 1_000e6 + 1, 5, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
    }

    function test_postOffer_revertsOnZeroMultiple() public {
        vm.expectRevert(Market.InvalidMultiple.selector);
        vm.prank(alice);
        market.postOffer(Types.Side.LONG, 1_000e6, 100e6, 0, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
    }

    function test_postOffer_revertsOnMultipleAboveTen() public {
        vm.expectRevert(Market.InvalidMultiple.selector);
        vm.prank(alice);
        market.postOffer(Types.Side.LONG, 1_000e6, 100e6, 11, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
    }

    function test_postOffer_revertsOnPayoffRatioBelowOneToOne() public {
        vm.expectRevert(Market.InvalidPayoffRatio.selector);
        vm.prank(alice);
        market.postOffer(Types.Side.LONG, 1_000e6, 100e6, 5, 9_999, 1 days, uint64(block.timestamp + 1 days), 0);
    }

    function test_postOffer_revertsOnPayoffRatioAboveMax() public {
        vm.expectRevert(Market.InvalidPayoffRatio.selector);
        vm.prank(alice);
        market.postOffer(Types.Side.LONG, 1_000e6, 100e6, 5, 200_001, 1 days, uint64(block.timestamp + 1 days), 0);
    }

    function test_postOffer_revertsOnDurationTooShort() public {
        vm.expectRevert(Market.InvalidDuration.selector);
        vm.prank(alice);
        market.postOffer(Types.Side.LONG, 1_000e6, 100e6, 5, 10_000, 1 hours - 1, uint64(block.timestamp + 1 days), 0);
    }

    function test_postOffer_revertsOnDurationTooLong() public {
        vm.expectRevert(Market.InvalidDuration.selector);
        vm.prank(alice);
        market.postOffer(Types.Side.LONG, 1_000e6, 100e6, 5, 10_000, 30 days + 1, uint64(block.timestamp + 1 days), 0);
    }

    function test_postOffer_revertsOnExpiryNotInFuture() public {
        vm.expectRevert(Market.ExpiryInPast.selector);
        vm.prank(alice);
        market.postOffer(Types.Side.LONG, 1_000e6, 100e6, 5, 10_000, 1 days, uint64(block.timestamp), 0);
    }

    function test_postOffer_revertsWithoutAllowance() public {
        usdg.mint(alice, 1_000e6);
        vm.expectRevert();
        vm.prank(alice);
        market.postOffer(Types.Side.LONG, 1_000e6, 100e6, 5, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
    }
}

// ======================================================================
// cancelOffer
// ======================================================================

contract MarketCancelOfferTest is CoreBase {
    function test_cancelOffer_refundsAndEmits() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);

        vm.expectEmit(true, true, true, true);
        emit Market.OfferCancelled(offerId, alice, 10_000e6);
        vm.prank(alice);
        market.cancelOffer(offerId);

        assertEq(usdg.balanceOf(alice), 10_000e6);
        assertEq(usdg.balanceOf(address(market)), 0);
        Types.Offer memory offer = market.offers(offerId);
        assertTrue(offer.cancelled);
        assertEq(offer.collateralRemaining, 0);
    }

    function test_cancelOffer_refundsRemainderAfterPartialFill() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fill(bob, offerId, 4_000e6);

        vm.prank(alice);
        market.cancelOffer(offerId);
        assertEq(usdg.balanceOf(alice), 6_000e6);
        // The matched position escrow (2 x 3_980e6, net of the 20e6 entry fee per
        // side at multiple 5) stays in the market.
        assertEq(usdg.balanceOf(address(market)), 7_960e6);
    }

    function test_cancelOffer_fullyFilledOfferCancelsWithZeroRefund() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fill(bob, offerId, 10_000e6);

        vm.prank(alice);
        market.cancelOffer(offerId);
        assertEq(usdg.balanceOf(alice), 0);
        assertTrue(market.offers(offerId).cancelled);
    }

    function test_cancelOffer_revertsForNonMaker() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        vm.expectRevert(Market.NotMaker.selector);
        vm.prank(bob);
        market.cancelOffer(offerId);
    }

    function test_cancelOffer_revertsForUnknownOffer() public {
        vm.expectRevert(Market.NotMaker.selector);
        vm.prank(alice);
        market.cancelOffer(999);
    }

    function test_cancelOffer_revertsOnDoubleCancel() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        vm.prank(alice);
        market.cancelOffer(offerId);
        vm.expectRevert(Market.OfferAlreadyCancelled.selector);
        vm.prank(alice);
        market.cancelOffer(offerId);
    }
}

// ======================================================================
// fillOffer
// ======================================================================

contract MarketFillOfferTest is CoreBase {
    function test_fillOffer_makerLongCreatesPositionAndEmits() public {
        router.setPrice(token, 1.5e18, Types.PriceStatus.OK);
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fund(bob, 4_000e6);

        // Entry fee per side at 1:1: 4_000e6 * 5 * 10 / 10_000 = 20e6; each stake 3_980e6.
        vm.expectEmit(true, true, true, true);
        emit Market.OfferFilled(offerId, 0, bob, alice, 4_000e6, 4_000e6, 1.5e18);
        vm.expectEmit(true, true, true, true);
        emit Market.EntryFeeCharged(offerId, 0, 20e6, 20e6, 3_980e6, 3_980e6);
        vm.prank(bob);
        uint256 positionId = market.fillOffer(offerId, 4_000e6);

        assertEq(positionId, 0);
        assertEq(market.nextPositionId(), 1);
        assertEq(market.offers(offerId).collateralRemaining, 6_000e6);
        assertEq(market.openInterest(), 7_960e6);
        assertEq(usdg.balanceOf(bob), 0);
        // 14_000e6 came in; 2 x 20e6 of entry fees left immediately.
        assertEq(usdg.balanceOf(address(market)), 13_960e6);
        // 40e6 entry fee total split 25/10/39/26: 10e6 / 4e6 / 15.6e6 / 10.4e6.
        assertEq(usdg.balanceOf(jackpot), 10e6);
        assertEq(usdg.balanceOf(referral), 4e6);
        assertEq(usdg.balanceOf(buyback), 15_600_000);
        assertEq(usdg.balanceOf(treasury), 10_400_000);

        Types.Position memory position = market.positions(positionId);
        assertEq(position.longParty, alice);
        assertEq(position.shortParty, bob);
        assertEq(position.token, token);
        assertEq(position.longStake, 3_980e6);
        assertEq(position.shortStake, 3_980e6);
        assertEq(position.multiple, 5);
        assertEq(position.openedAt, uint64(block.timestamp));
        assertEq(position.duration, 1 days);
        assertEq(position.entryPrice1e18, 1.5e18);
        assertFalse(position.settled);
    }

    function test_fillOffer_makerShortSwapsParties() public {
        uint256 offerId = _postOffer(alice, Types.Side.SHORT, 10_000e6, 1_000e6);
        uint256 positionId = _fill(bob, offerId, 2_000e6);

        Types.Position memory position = market.positions(positionId);
        assertEq(position.longParty, bob);
        assertEq(position.shortParty, alice);
    }

    function test_fillOffer_recordsPointsHookArgs() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fill(bob, offerId, 2_000e6);

        assertEq(pitPoints.onFillCalls(), 1);
        (address longParty, address shortParty, address maker, address hookToken, uint256 notional) =
            pitPoints.lastFill();
        assertEq(longParty, alice);
        assertEq(shortParty, bob);
        assertEq(maker, alice);
        assertEq(hookToken, token);
        // Points notional is the POST-FEE escrow times multiple: the 10e6 entry fee
        // per side (2_000e6 * 5 * 10 / 10_000) shrinks it from 10_000e6 to 9_950e6.
        assertEq(notional, uint256(2_000e6 - 10e6) * 5);
    }

    function test_fillOffer_survivesPointsRevert() public {
        pitPoints.setRevertOnCall(true);
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fund(bob, 2_000e6);

        vm.expectEmit(true, true, true, true);
        emit Market.PointsHookFailed(abi.encodeWithSignature("PointsIntentionalRevert()"));
        vm.prank(bob);
        uint256 positionId = market.fillOffer(offerId, 2_000e6);

        assertEq(pitPoints.onFillCalls(), 0);
        assertFalse(market.positions(positionId).settled);
        // Net of the 10e6 entry fee per side: 2 x 1_990e6.
        assertEq(market.openInterest(), 3_980e6);
    }

    function test_fillOffer_entireRemainingAmount() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fill(bob, offerId, 10_000e6);
        assertEq(market.offers(offerId).collateralRemaining, 0);
    }

    function test_fillOffer_multipleFillsCreateDistinctPositions() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        uint256 p0 = _fill(bob, offerId, 3_000e6);
        uint256 p1 = _fill(carol, offerId, 3_000e6);
        assertEq(p0, 0);
        assertEq(p1, 1);
        // Each fill escrows 2 x 2_985e6 (15e6 entry fee per side at multiple 5).
        assertEq(market.openInterest(), 11_940e6);
        assertEq(market.positions(p1).shortParty, carol);
    }

    function test_fillOffer_subMinFillRemainderStaysAndIsCancellable() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 4_000e6);
        _fill(bob, offerId, 7_000e6);
        assertEq(market.offers(offerId).collateralRemaining, 3_000e6);

        // The remainder is below minFill so it cannot be filled.
        _fund(carol, 3_000e6);
        vm.expectRevert(Market.FillBelowMin.selector);
        vm.prank(carol);
        market.fillOffer(offerId, 3_000e6);

        // But the maker can cancel it for a refund.
        vm.prank(alice);
        market.cancelOffer(offerId);
        assertEq(usdg.balanceOf(alice), 3_000e6);
    }

    function test_fillOffer_atOfferExpiryBoundaryStillLive() public {
        uint256 offerId =
            _postOfferFull(alice, Types.Side.LONG, 10_000e6, 1_000e6, 5, 1 days, uint64(block.timestamp + 100), 0);
        vm.warp(block.timestamp + 100);
        _fill(bob, offerId, 1_000e6);
    }

    function test_fillOffer_revertsWhenExpired() public {
        uint256 offerId =
            _postOfferFull(alice, Types.Side.LONG, 10_000e6, 1_000e6, 5, 1 days, uint64(block.timestamp + 100), 0);
        vm.warp(block.timestamp + 101);
        _fund(bob, 1_000e6);
        vm.expectRevert(Market.OfferNotLive.selector);
        vm.prank(bob);
        market.fillOffer(offerId, 1_000e6);
    }

    function test_fillOffer_revertsOnSelfFill() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fund(alice, 1_000e6);
        vm.expectRevert(Market.SelfFill.selector);
        vm.prank(alice);
        market.fillOffer(offerId, 1_000e6);
    }

    function test_fillOffer_revertsForUnknownOffer() public {
        vm.expectRevert(Market.OfferNotLive.selector);
        vm.prank(bob);
        market.fillOffer(42, 1_000e6);
    }

    function test_fillOffer_revertsWhenCancelled() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        vm.prank(alice);
        market.cancelOffer(offerId);
        _fund(bob, 1_000e6);
        vm.expectRevert(Market.OfferNotLive.selector);
        vm.prank(bob);
        market.fillOffer(offerId, 1_000e6);
    }

    function test_fillOffer_revertsBelowMinFill() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fund(bob, 1_000e6);
        vm.expectRevert(Market.FillBelowMin.selector);
        vm.prank(bob);
        market.fillOffer(offerId, 1_000e6 - 1);
    }

    function test_fillOffer_revertsAboveRemaining() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fund(bob, 10_000e6 + 1);
        vm.expectRevert(Market.FillExceedsRemaining.selector);
        vm.prank(bob);
        market.fillOffer(offerId, 10_000e6 + 1);
    }

    function test_fillOffer_revertsOnEveryNonOkOracleStatus() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fund(bob, 1_000e6);

        Types.PriceStatus[3] memory badStatuses =
            [Types.PriceStatus.COOLDOWN, Types.PriceStatus.STALE, Types.PriceStatus.UNAVAILABLE];
        for (uint256 i = 0; i < badStatuses.length; i++) {
            router.setPrice(token, 1e18, badStatuses[i]);
            vm.expectRevert(abi.encodeWithSelector(Market.OracleNotOk.selector, badStatuses[i]));
            vm.prank(bob);
            market.fillOffer(offerId, 1_000e6);
        }
    }

    function test_fillOffer_revertsOnZeroPrice() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        router.setPrice(token, 0, Types.PriceStatus.OK);
        _fund(bob, 1_000e6);
        vm.expectRevert(Market.ZeroPrice.selector);
        vm.prank(bob);
        market.fillOffer(offerId, 1_000e6);
    }

    function test_fillOffer_revertsOnEntryPriceAboveUint128() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        uint256 hugePrice = uint256(type(uint128).max) + 1;
        router.setPrice(token, hugePrice, Types.PriceStatus.OK);
        _fund(bob, 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, hugePrice));
        vm.prank(bob);
        market.fillOffer(offerId, 1_000e6);
    }

    function test_fillOffer_longMakerLimitCapsEntryFromAbove() public {
        uint256 offerId = _postOfferFull(
            alice, Types.Side.LONG, 10_000e6, 1_000e6, 5, 1 days, uint64(block.timestamp + 1 days), 2e18
        );
        _fund(bob, 2_000e6);

        router.setPrice(token, 2e18 + 1, Types.PriceStatus.OK);
        vm.expectRevert(abi.encodeWithSelector(Market.LimitEntryViolated.selector, 2e18 + 1, 2e18));
        vm.prank(bob);
        market.fillOffer(offerId, 1_000e6);

        // Exactly at the limit is fine.
        router.setPrice(token, 2e18, Types.PriceStatus.OK);
        vm.prank(bob);
        market.fillOffer(offerId, 1_000e6);
    }

    function test_fillOffer_shortMakerLimitCapsEntryFromBelow() public {
        uint256 offerId = _postOfferFull(
            alice, Types.Side.SHORT, 10_000e6, 1_000e6, 5, 1 days, uint64(block.timestamp + 1 days), 2e18
        );
        _fund(bob, 2_000e6);

        router.setPrice(token, 2e18 - 1, Types.PriceStatus.OK);
        vm.expectRevert(abi.encodeWithSelector(Market.LimitEntryViolated.selector, 2e18 - 1, 2e18));
        vm.prank(bob);
        market.fillOffer(offerId, 1_000e6);

        router.setPrice(token, 2e18, Types.PriceStatus.OK);
        vm.prank(bob);
        market.fillOffer(offerId, 1_000e6);
    }

    function test_fillOffer_oiCapBoundary() public {
        // Tracked liquidity 1_000_000e18, cap 10% = 100_000e18, i.e. 100_000e6 native
        // units of NET open interest. A gross fill of 50_251_256_281 at multiple 5
        // pays feePerSide = 251_256_281 (gross * 5 * 10 / 10_000, floored) and
        // escrows exactly 2 x 50_000e6: open interest sits exactly at the cap.
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 60_000e6, 1e6);
        _fill(bob, offerId, 50_251_256_281);
        assertEq(market.openInterest(), 100_000e6);

        // The next fill (gross 1e6, fee 5_000, net 995_000) would raise NET open
        // interest by 1_990_000, breaching the cap.
        _fund(carol, 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(Market.OiCapExceeded.selector, 100_000e6 + 1_990_000, uint256(100_000e18))
        );
        vm.prank(carol);
        market.fillOffer(offerId, 1e6);
    }

    function test_fillOffer_oiCapUsesCreationSnapshotNotLiveLiquidity() public {
        // The cap keys off the immutable creation snapshot (1_000_000e18), so live liquidity
        // moves do not change it. Halving live liquidity leaves the cap at 100_000e6 native.
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        router.setTrackedLiquidity(token, 500_000e18);
        _fill(bob, offerId, 10_000e6);
        assertEq(market.openInterest(), 19_900e6);
    }

    function test_fillOffer_jitLiquidityInflationCannotRaiseCap() public {
        // Fill open interest exactly to the snapshot-based cap (100_000e6 native).
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 60_000e6, 1e6);
        _fill(bob, offerId, 50_251_256_281);
        assertEq(market.openInterest(), 100_000e6);

        // An attacker inflates LIVE tracked liquidity 100x in the same block (JIT single-sided
        // liquidity). Because the cap reads the immutable creation snapshot, not live liquidity,
        // the extra headroom is illusory: the next fill still reverts at the snapshot cap.
        router.setTrackedLiquidity(token, 100_000_000e18);
        _fund(carol, 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(Market.OiCapExceeded.selector, 100_000e6 + 1_990_000, uint256(100_000e18))
        );
        vm.prank(carol);
        market.fillOffer(offerId, 1e6);
    }

    function test_fillOffer_singleBlockLiquidityDrainCannotBlockFill() public {
        // A single-block swap draining live liquidity to near zero used to trip the old live
        // liquidity floor. With the floor no longer read at fill time, an honest fill still
        // succeeds: the cap is anchored to the creation snapshot, never to live liquidity.
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        router.setTrackedLiquidity(token, 1);
        uint256 positionId = _fill(bob, offerId, 1_000e6);
        assertFalse(market.positions(positionId).settled);
        // feePerSide = 1_000e6 * 5 * 10 / 10_000 = 5e6, so open interest is 2 x 995e6.
        assertEq(market.openInterest(), 2 * uint256(995e6));
    }

    function test_fillOffer_revertsWhenMarketPaused() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fund(bob, 1_000e6);
        vm.prank(guardianMultisig);
        pauseGuardian.pause(address(market));

        vm.expectRevert(Market.MarketPaused.selector);
        vm.prank(bob);
        market.fillOffer(offerId, 1_000e6);
    }

    function test_fillOffer_revertsWhenGloballyPaused() public {
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6);
        _fund(bob, 1_000e6);
        vm.prank(guardianMultisig);
        pauseGuardian.pause(address(0));

        vm.expectRevert(Market.MarketPaused.selector);
        vm.prank(bob);
        market.fillOffer(offerId, 1_000e6);
    }

    function test_fillOffer_worksAfterPauseAutoExpires() public {
        uint256 offerId =
            _postOfferFull(alice, Types.Side.LONG, 10_000e6, 1_000e6, 5, 1 days, uint64(block.timestamp + 3 days), 0);
        vm.prank(guardianMultisig);
        pauseGuardian.pause(address(market));

        vm.warp(block.timestamp + 24 hours);
        _fill(bob, offerId, 1_000e6);
    }
}

// ======================================================================
// entry fee
// ======================================================================

contract MarketEntryFeeTest is CoreBase {
    function test_entryFee_exactAtMultipleOne() public {
        uint256 offerId =
            _postOfferFull(alice, Types.Side.LONG, 10_000e6, 1_000e6, 1, 1 days, uint64(block.timestamp + 1 days), 0);
        _fund(bob, 10_000e6);

        // feePerSide = 10_000e6 * 1 * 10 / 10_000 = 10e6 (both sides at 1:1); each stake 9_990e6.
        vm.expectEmit(true, true, true, true);
        emit Market.EntryFeeCharged(offerId, 0, 10e6, 10e6, 9_990e6, 9_990e6);
        vm.prank(bob);
        uint256 positionId = market.fillOffer(offerId, 10_000e6);

        assertEq(market.positions(positionId).longStake, 9_990e6);
        assertEq(market.positions(positionId).shortStake, 9_990e6);
        assertEq(market.openInterest(), 2 * 9_990e6);
        // The 20e6 entry fee total left escrow immediately, split 25/10/39/26.
        assertEq(usdg.balanceOf(jackpot), 5e6);
        assertEq(usdg.balanceOf(referral), 2e6);
        assertEq(usdg.balanceOf(buyback), 7_800_000);
        assertEq(usdg.balanceOf(treasury), 5_200_000);
        assertEq(usdg.balanceOf(address(market)), 2 * 9_990e6);
    }

    function test_entryFee_exactAtMultipleTen() public {
        uint256 offerId =
            _postOfferFull(alice, Types.Side.LONG, 10_000e6, 1_000e6, 10, 1 days, uint64(block.timestamp + 1 days), 0);
        uint256 positionId = _fill(bob, offerId, 10_000e6);

        // feePerSide = 10_000e6 * 10 * 10 / 10_000 = 100e6: exactly 1 percent of the
        // gross fill, the maximum the fee can ever reach.
        assertEq(market.positions(positionId).longStake, 9_900e6);
        assertEq(market.positions(positionId).shortStake, 9_900e6);
        assertEq(market.openInterest(), 19_800e6);
        // 200e6 entry fee total split 25/10/39/26: 50e6 / 20e6 / 78e6 / 52e6.
        assertEq(usdg.balanceOf(jackpot), 50e6);
        assertEq(usdg.balanceOf(referral), 20e6);
        assertEq(usdg.balanceOf(buyback), 78e6);
        assertEq(usdg.balanceOf(treasury), 52e6);
        assertEq(usdg.balanceOf(address(market)), 19_800e6);
    }

    function test_entryFee_dustFillReverts() public {
        // gross * multiple = 999 < 1_000: the 10 bps fee rounds down to zero, so the
        // fill is dust and reverts (it could otherwise mint points at zero cost).
        uint256 offerId =
            _postOfferFull(alice, Types.Side.LONG, 10_000e6, 1, 1, 1 days, uint64(block.timestamp + 1 days), 0);
        _fund(bob, 1_000);
        vm.expectRevert(Market.EntryFeeExceedsCollateral.selector);
        vm.prank(bob);
        market.fillOffer(offerId, 999);

        // The smallest non-dust fill at multiple 1 pays exactly 1 unit per side; a total fee of 2
        // floors every non-treasury share to zero, so treasury receives all of it.
        vm.prank(bob);
        uint256 positionId = market.fillOffer(offerId, 1_000);
        assertEq(market.positions(positionId).longStake, 999);
        assertEq(market.positions(positionId).shortStake, 999);
        assertEq(
            usdg.balanceOf(jackpot) + usdg.balanceOf(treasury) + usdg.balanceOf(referral) + usdg.balanceOf(buyback), 2
        );
        assertEq(usdg.balanceOf(treasury), 2);
    }

    function test_entryFee_splitExactIncludingDust() public {
        // feePerSide 7 (gross 7_000 at multiple 1): total 14, split 25/10/39/26 floors to jackpot 3
        // (3.5), referral 1 (1.4), buyback 5 (5.46), and treasury takes 14 - 3 - 1 - 5 = 5 (its 3.64
        // base plus the rounding dust), all four summing exactly to the 14 charged.
        uint256 offerId =
            _postOfferFull(alice, Types.Side.LONG, 10_000e6, 1, 1, 1 days, uint64(block.timestamp + 1 days), 0);
        _fill(bob, offerId, 7_000);

        assertEq(usdg.balanceOf(jackpot), 3);
        assertEq(usdg.balanceOf(referral), 1);
        assertEq(usdg.balanceOf(buyback), 5);
        assertEq(usdg.balanceOf(treasury), 5);
        assertEq(
            usdg.balanceOf(jackpot) + usdg.balanceOf(referral) + usdg.balanceOf(buyback) + usdg.balanceOf(treasury), 14
        );
    }

    function test_entryFee_washCycleCostsExactFeesAndScalesPoints() public {
        // Wash-cycle economics: two wallets open a position and settle it flat. The
        // pair's only cash flow is the entry fee, 2 x feePerSide paid at fill, while
        // the points hook saw a notional proportional to the post-fee escrow: the
        // farming cost is real and proportional to the points minted.
        uint256 offerId = _postOffer(alice, Types.Side.LONG, 10_000e6, 1_000e6); // multiple 5
        uint256 positionId = _fill(bob, offerId, 10_000e6);

        uint256 feePerSide = uint256(10_000e6) * 5 * market.ENTRY_FEE_BPS() / 10_000;
        assertEq(feePerSide, 50e6);

        // Points scale with the post-fee notional: (gross - feePerSide) * multiple.
        (,,,, uint256 notional) = pitPoints.lastFill();
        assertEq(notional, uint256(10_000e6 - 50e6) * 5);

        // Flat settle: exit price equals the 1e18 entry.
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        // Each wallet started with 10_000e6 and ended with 9_950e6: the pair paid
        // exactly 2 x feePerSide, all of it now with the fee recipients.
        assertEq(usdg.balanceOf(alice), 10_000e6 - feePerSide);
        assertEq(usdg.balanceOf(bob), 10_000e6 - feePerSide);
        assertEq(
            usdg.balanceOf(jackpot) + usdg.balanceOf(treasury) + usdg.balanceOf(referral) + usdg.balanceOf(buyback),
            2 * feePerSide
        );
        assertEq(usdg.balanceOf(address(market)), 0);
        // Flat settlement mints no settlement points on top.
        assertEq(pitPoints.onSettleCalls(), 0);
    }

    /// @notice For every successful fill the entry fee follows the exact formula, is
    ///         never more than 1 percent of the gross fill, and is never zero.
    function testFuzz_entryFeeNeverExceedsOnePercentOfGross(uint128 grossSeed, uint16 multipleSeed) public {
        uint16 multiple = uint16(bound(multipleSeed, 1, 10));
        // Lower bound 1_000 keeps the fill above dust for every multiple; upper bound
        // keeps net open interest under the 100_000e6 OI cap of the fixture.
        uint128 gross = uint128(bound(grossSeed, 1_000, 50_000e6));
        uint256 offerId =
            _postOfferFull(alice, Types.Side.LONG, gross, gross, multiple, 1 days, uint64(block.timestamp + 1 days), 0);
        uint256 positionId = _fill(bob, offerId, gross);

        uint256 feePerSide = uint256(gross) - market.positions(positionId).longStake;
        assertEq(feePerSide, uint256(gross) * multiple * 10 / 10_000, "fee formula");
        assertLe(feePerSide, uint256(gross) / 100, "fee above 1 percent of gross");
        assertGe(feePerSide, 1, "successful fill must pay a nonzero fee");
    }
}

// ======================================================================
// settle
// ======================================================================

contract MarketSettleTest is CoreBase {
    /// @dev Gross fill collateral. At multiple 5 the entry fee per side is
    ///      C * 5 * 10 / 10_000 = 50e6, so the position opens with collateralEach
    ///      CE = 9_950e6 and the fee recipients already hold the 100e6 entry fee
    ///      total (25e6 jackpot, 10e6 referral, 39e6 buyback, 26e6 treasury) before settlement.
    uint128 internal constant C = 10_000e6;
    uint128 internal constant CE = 9_950e6;
    uint256 internal constant ENTRY_JACKPOT = 25e6;
    uint256 internal constant ENTRY_TREASURY = 26e6;
    uint256 internal constant ENTRY_REFERRAL = 10e6;
    uint256 internal constant ENTRY_BUYBACK = 39e6;
    uint256 internal positionId;
    uint64 internal openedAt;

    function setUp() public override {
        super.setUp();
        uint256 offerId = _postOffer(alice, Types.Side.LONG, C, 1_000e6);
        positionId = _fill(bob, offerId, C);
        openedAt = uint64(block.timestamp);
    }

    // ====================================================================== timing / auth ======================================================================

    function test_settle_revertsBeforeMinHoldForParty() public {
        vm.warp(openedAt + 30 minutes - 1);
        vm.expectRevert(abi.encodeWithSelector(Market.MinHoldNotReached.selector, uint256(openedAt) + 30 minutes));
        vm.prank(alice);
        market.settle(positionId);
    }

    function test_settle_partyCanSettleExactlyAtMinHold() public {
        vm.warp(openedAt + 30 minutes);
        vm.prank(bob);
        market.settle(positionId);
        assertTrue(market.positions(positionId).settled);
    }

    function test_settle_revertsForNonPartyBeforeExpiry() public {
        vm.warp(openedAt + 1 days - 1);
        vm.expectRevert(Market.NotPositionParty.selector);
        vm.prank(carol);
        market.settle(positionId);
    }

    function test_settle_anyoneCanSettleAtExpiry() public {
        vm.warp(openedAt + 1 days);
        vm.prank(carol);
        market.settle(positionId);
        assertTrue(market.positions(positionId).settled);
    }

    function test_settle_revertsForUnknownPosition() public {
        vm.expectRevert(Market.UnknownPosition.selector);
        market.settle(999);
    }

    function test_settle_revertsOnDoubleSettle() public {
        vm.warp(openedAt + 1 days);
        market.settle(positionId);
        vm.expectRevert(Market.PositionAlreadySettled.selector);
        market.settle(positionId);
    }

    // ====================================================================== pricing ======================================================================

    function test_settle_longWinsExactMath() public {
        // entry 1e18, exit 1.1e18, collateralEach CE 9_950e6, multiple 5: notional
        // 49_750e6, pnl 4_975e6, fee 248.75e6 (50 bps of notional, below pnl).
        vm.warp(openedAt + 1 days);
        router.setPrice(token, 1.1e18, Types.PriceStatus.OK);

        vm.expectEmit(true, true, true, true);
        emit Market.PositionSettled(positionId, alice, bob, 1.1e18, 4_975e6, 248_750_000, 14_676_250_000, 4_975e6);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        assertEq(usdg.balanceOf(alice), 14_676_250_000);
        assertEq(usdg.balanceOf(bob), 4_975e6);
        // Entry fees from the fill plus the 248.75e6 settlement fee split 25/10/39/26:
        // jackpot 62_187_500, referral 24_875_000, buyback 97_012_500, treasury 64_675_000.
        assertEq(usdg.balanceOf(jackpot), ENTRY_JACKPOT + 62_187_500);
        assertEq(usdg.balanceOf(treasury), ENTRY_TREASURY + 64_675_000);
        assertEq(usdg.balanceOf(referral), ENTRY_REFERRAL + 24_875_000);
        assertEq(usdg.balanceOf(buyback), ENTRY_BUYBACK + 97_012_500);
        assertEq(usdg.balanceOf(address(market)), 0);
        assertEq(market.openInterest(), 0);

        // Points hook saw the winner, the post-fee notional, and the clamped pnl.
        assertEq(pitPoints.onSettleCalls(), 1);
        (address winner, address loser, address hookToken, uint256 notional, uint256 pnlToWinner) =
            pitPoints.lastSettle();
        assertEq(winner, alice);
        assertEq(loser, bob);
        assertEq(hookToken, token);
        assertEq(notional, 49_750e6);
        assertEq(pnlToWinner, 4_975e6);
    }

    function test_settle_shortWinsExactMath() public {
        vm.warp(openedAt + 1 days);
        router.setPrice(token, 0.9e18, Types.PriceStatus.OK);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        // Same magnitudes as the long-win case, mirrored to bob (short).
        assertEq(usdg.balanceOf(bob), 14_676_250_000);
        assertEq(usdg.balanceOf(alice), 4_975e6);
        assertEq(usdg.balanceOf(jackpot), ENTRY_JACKPOT + 62_187_500);
        assertEq(usdg.balanceOf(treasury), ENTRY_TREASURY + 64_675_000);
        assertEq(usdg.balanceOf(referral), ENTRY_REFERRAL + 24_875_000);
        assertEq(usdg.balanceOf(buyback), ENTRY_BUYBACK + 97_012_500);
    }

    function test_settle_flatRefundsBothWithZeroFee() public {
        vm.warp(openedAt + 1 days);
        // Exit price unchanged at the 1e18 entry: zero settlement fee; both sides get
        // exactly collateralEach back (the entry fee was already charged at fill).
        vm.expectEmit(true, true, true, true);
        emit Market.PositionSettled(positionId, address(0), address(0), 1e18, 0, 0, CE, CE);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        assertEq(usdg.balanceOf(alice), CE);
        assertEq(usdg.balanceOf(bob), CE);
        assertEq(usdg.balanceOf(jackpot), ENTRY_JACKPOT);
        assertEq(usdg.balanceOf(treasury), ENTRY_TREASURY);
        assertEq(usdg.balanceOf(referral), ENTRY_REFERRAL);
        assertEq(usdg.balanceOf(buyback), ENTRY_BUYBACK);
        // No winner: the points hook is not invoked.
        assertEq(pitPoints.onSettleCalls(), 0);
    }

    function test_settle_pnlClampsAtCollateral() public {
        // 3x move: unclamped pnl (99_500e6) far exceeds collateral; clamp to CE.
        vm.warp(openedAt + 1 days);
        router.setPrice(token, 3e18, Types.PriceStatus.OK);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        // fee 248.75e6 out of the clamped 9_950e6 pnl.
        assertEq(usdg.balanceOf(alice), 2 * uint256(CE) - 248_750_000);
        assertEq(usdg.balanceOf(bob), 0);
        assertEq(
            usdg.balanceOf(jackpot) + usdg.balanceOf(treasury) + usdg.balanceOf(referral) + usdg.balanceOf(buyback),
            100e6 + 248_750_000
        );
        assertEq(usdg.balanceOf(address(market)), 0);
    }

    function test_settle_clampBoundaryMoveEqualToEntryOverMultiple() public {
        // exit 1.2e18: raw pnl = 49_750e6 * 0.2 = 9_950e6 = CE exactly: clamp is a
        // no-op and the winner nets CE + CE - fee.
        vm.warp(openedAt + 1 days);
        router.setPrice(token, 1.2e18, Types.PriceStatus.OK);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);
        assertEq(usdg.balanceOf(alice), 2 * uint256(CE) - 248_750_000);
        assertEq(usdg.balanceOf(bob), 0);
    }

    function test_settle_feeCappedByTinyPnl() public {
        // Tiny move: raw pnl 4_975 units is below the 248.75e6 notional fee, so the
        // whole pnl is consumed by the fee and the winner nets exactly CE.
        vm.warp(openedAt + 1 days);
        router.setPrice(token, 1e18 + 1e11, Types.PriceStatus.OK);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        assertEq(usdg.balanceOf(alice), CE);
        assertEq(usdg.balanceOf(bob), uint256(CE) - 4_975);
        // Settlement fee 4_975 split 25/10/39/26: jackpot 1_243, referral 497, buyback 1_940,
        // treasury 1_295 (its 1_293 base plus the 2-unit rounding dust).
        assertEq(usdg.balanceOf(jackpot), ENTRY_JACKPOT + 1_243);
        assertEq(usdg.balanceOf(referral), ENTRY_REFERRAL + 497);
        assertEq(usdg.balanceOf(buyback), ENTRY_BUYBACK + 1_940);
        assertEq(usdg.balanceOf(treasury), ENTRY_TREASURY + 1_295);
    }

    function test_settle_feeSplitDustGoesToTreasury() public {
        // Move sized so pnl = fee = 13 units (49_750e6 * 2.62e8 / 1e18 = 13 floored): the
        // 25/10/39/26 split floors to jackpot 3 (3.25), referral 1 (1.3), buyback 5 (5.07), and
        // treasury takes 13 - 3 - 1 - 5 = 4 (its 3.38 base plus the rounding dust), all four nonzero
        // and summing exactly to 13.
        vm.warp(openedAt + 1 days);
        router.setPrice(token, 1e18 + 2.62e8, Types.PriceStatus.OK);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        assertEq(usdg.balanceOf(jackpot), ENTRY_JACKPOT + 3);
        assertEq(usdg.balanceOf(referral), ENTRY_REFERRAL + 1);
        assertEq(usdg.balanceOf(buyback), ENTRY_BUYBACK + 5);
        assertEq(usdg.balanceOf(treasury), ENTRY_TREASURY + 4);
        assertEq(usdg.balanceOf(alice), CE);
        assertEq(usdg.balanceOf(bob), uint256(CE) - 13);
    }

    function test_settle_subUnitMoveSettlesFlat() public {
        // A move too small to round to one pnl unit: treated as flat, no fee.
        vm.warp(openedAt + 1 days);
        router.setPrice(token, 1e18 + 1e7, Types.PriceStatus.OK);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);
        assertEq(usdg.balanceOf(alice), CE);
        assertEq(usdg.balanceOf(bob), CE);
        assertEq(pitPoints.onSettleCalls(), 0);
    }

    function test_settle_earlySettleByLoserParty() public {
        // The losing side can voluntarily close early after MIN_HOLD.
        vm.warp(openedAt + 2 hours);
        router.setPrice(token, 1.1e18, Types.PriceStatus.OK);
        vm.prank(bob);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);
        assertEq(usdg.balanceOf(alice), 14_676_250_000);
        assertEq(usdg.balanceOf(bob), 4_975e6);
    }

    function test_settle_survivesPointsRevert() public {
        pitPoints.setRevertOnCall(true);
        vm.warp(openedAt + 1 days);
        router.setPrice(token, 1.1e18, Types.PriceStatus.OK);

        vm.expectEmit(true, true, true, true);
        emit Market.PointsHookFailed(abi.encodeWithSignature("PointsIntentionalRevert()"));
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        assertTrue(market.positions(positionId).settled);
        assertEq(usdg.balanceOf(alice), 14_676_250_000);
        assertEq(pitPoints.onSettleCalls(), 0);
    }

    // ====================================================================== oracle failure and unwind ======================================================================

    function test_settle_revertsWhileOracleNotOkBeforeDeadline() public {
        vm.warp(openedAt + 1 days);
        router.setPrice(token, 1e18, Types.PriceStatus.STALE);
        vm.expectRevert(abi.encodeWithSelector(Market.OracleNotOk.selector, Types.PriceStatus.STALE));
        vm.prank(carol);
        market.settle(positionId);
    }

    function test_settle_noUnwindExactlyAtDeadline() public {
        // The forced unwind requires strictly more than expiry + 24 hours.
        vm.warp(uint256(openedAt) + 1 days + 24 hours);
        router.setPrice(token, 1e18, Types.PriceStatus.UNAVAILABLE);
        vm.expectRevert(abi.encodeWithSelector(Market.OracleNotOk.selector, Types.PriceStatus.UNAVAILABLE));
        vm.prank(carol);
        market.settle(positionId);
    }

    function test_settle_forcedUnwindRefundsBothExactly() public {
        vm.warp(uint256(openedAt) + 1 days + 24 hours + 1);
        router.setPrice(token, 123e18, Types.PriceStatus.UNAVAILABLE);

        vm.expectEmit(true, true, true, true);
        emit Market.ForcedUnwind(positionId, alice, bob, CE, CE);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        // Both sides get exactly collateralEach (net of the entry fee charged at
        // fill); the unwind itself pays zero fee.
        assertEq(usdg.balanceOf(alice), CE);
        assertEq(usdg.balanceOf(bob), CE);
        assertEq(usdg.balanceOf(jackpot), ENTRY_JACKPOT);
        assertEq(usdg.balanceOf(treasury), ENTRY_TREASURY);
        assertEq(usdg.balanceOf(referral), ENTRY_REFERRAL);
        assertEq(usdg.balanceOf(buyback), ENTRY_BUYBACK);
        assertEq(usdg.balanceOf(address(market)), 0);
        assertEq(market.openInterest(), 0);
        assertTrue(market.positions(positionId).settled);
        assertEq(pitPoints.onSettleCalls(), 0);
    }

    function test_settle_forcedUnwindCannotResettle() public {
        vm.warp(uint256(openedAt) + 1 days + 24 hours + 1);
        router.setPrice(token, 1e18, Types.PriceStatus.UNAVAILABLE);
        vm.prank(carol);
        market.settle(positionId);
        vm.expectRevert(Market.PositionAlreadySettled.selector);
        vm.prank(carol);
        market.settle(positionId);
    }

    function test_settle_oracleRecoveryAfterDeadlineStillSettlesAtPrice() public {
        // Even past the unwind deadline, an OK oracle settles normally.
        vm.warp(uint256(openedAt) + 1 days + 48 hours);
        router.setPrice(token, 1.1e18, Types.PriceStatus.OK);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);
        assertEq(usdg.balanceOf(alice), 14_676_250_000);
    }

    // ====================================================================== pause ======================================================================

    function test_settle_revertsWhilePaused() public {
        vm.warp(openedAt + 1 days);
        vm.prank(guardianMultisig);
        pauseGuardian.pause(address(market));
        vm.expectRevert(Market.MarketPaused.selector);
        vm.prank(carol);
        market.settle(positionId);
    }

    function test_settle_worksAfterEarlyUnpause() public {
        vm.warp(openedAt + 1 days);
        vm.prank(guardianMultisig);
        pauseGuardian.pause(address(market));
        vm.prank(guardianMultisig);
        pauseGuardian.unpause(address(market));
        vm.prank(carol);
        market.settle(positionId);
        assertTrue(market.positions(positionId).settled);
    }

    /// @notice Proof that a position can always eventually settle or unwind under the
    ///         worst possible pausing schedule. The guardian holds two pause keys (the
    ///         market and the global key). With a 24 hour maximum pause and a 72 hour
    ///         per-key cooldown between pause starts, chaining both keys back to back
    ///         covers at most 48 consecutive hours, after which BOTH keys are still on
    ///         cooldown: a guaranteed open window follows and settlement succeeds.
    function test_settle_alwaysEventuallySettleableUnderWorstCasePausing() public {
        // Oracle is broken for good: only the forced unwind path can ever pay out.
        router.setPrice(token, 1e18, Types.PriceStatus.UNAVAILABLE);

        // Unwind becomes reachable strictly after expiry + 24h.
        uint256 unwindAt = uint256(openedAt) + 1 days + 24 hours + 1;

        // Adversarial guardian: pause the market key at the last second before the
        // unwind is reachable, then chain the global key the moment the first pause
        // expires.
        vm.warp(unwindAt - 1);
        vm.prank(guardianMultisig);
        pauseGuardian.pause(address(market));

        vm.warp(unwindAt);
        vm.expectRevert(Market.MarketPaused.selector);
        vm.prank(carol);
        market.settle(positionId);

        vm.warp(unwindAt - 1 + 24 hours);
        vm.prank(guardianMultisig);
        pauseGuardian.pause(address(0));

        vm.warp(unwindAt + 24 hours);
        vm.expectRevert(Market.MarketPaused.selector);
        vm.prank(carol);
        market.settle(positionId);

        // 48 hours after the first pause start both pauses have expired and both keys
        // are still inside their 72 hour cooldowns: the guardian is powerless.
        vm.warp(unwindAt - 1 + 48 hours);
        vm.prank(guardianMultisig);
        vm.expectRevert();
        pauseGuardian.pause(address(market));
        vm.prank(guardianMultisig);
        vm.expectRevert();
        pauseGuardian.pause(address(0));

        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);
        assertTrue(market.positions(positionId).settled);
        assertEq(usdg.balanceOf(alice), CE);
        assertEq(usdg.balanceOf(bob), CE);
    }
}

// ======================================================================
// constructor validation and reentrancy
// ======================================================================

contract MarketConstructorTest is CoreBase {
    function _split() internal view returns (Types.FeeSplit memory) {
        return Types.FeeSplit({
            jackpot: jackpot, treasury: treasury, referralPool: referral, buyback: buyback, vault: address(0)
        });
    }

    function test_constructor_revertsOnZeroAddresses() public {
        address u = address(usdg);
        address r = address(router);
        address p = address(pitPoints);
        address g = address(pauseGuardian);

        vm.expectRevert(Market.ZeroAddress.selector);
        new Market(
            address(0),
            u,
            r,
            p,
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            g,
            1e18,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
        vm.expectRevert(Market.ZeroAddress.selector);
        new Market(
            token,
            address(0),
            r,
            p,
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            g,
            1e18,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
        vm.expectRevert(Market.ZeroAddress.selector);
        new Market(
            token,
            u,
            address(0),
            p,
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            g,
            1e18,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
        vm.expectRevert(Market.ZeroAddress.selector);
        new Market(
            token,
            u,
            r,
            address(0),
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            g,
            1e18,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
        vm.expectRevert(Market.ZeroAddress.selector);
        new Market(
            token,
            u,
            r,
            p,
            Types.FeeSplit(address(0), treasury, referral, buyback, address(0)),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            g,
            1e18,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
        vm.expectRevert(Market.ZeroAddress.selector);
        new Market(
            token,
            u,
            r,
            p,
            Types.FeeSplit(jackpot, address(0), referral, buyback, address(0)),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            g,
            1e18,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
        vm.expectRevert(Market.ZeroAddress.selector);
        new Market(
            token,
            u,
            r,
            p,
            Types.FeeSplit(jackpot, treasury, address(0), buyback, address(0)),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            g,
            1e18,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
        vm.expectRevert(Market.ZeroAddress.selector);
        new Market(
            token,
            u,
            r,
            p,
            Types.FeeSplit(jackpot, treasury, referral, address(0), address(0)),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            g,
            1e18,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
        vm.expectRevert(Market.ZeroAddress.selector);
        new Market(
            token,
            u,
            r,
            p,
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            address(0),
            1e18,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
    }

    function test_constructor_revertsOnInvalidOiCap() public {
        vm.expectRevert(Market.InvalidOiCap.selector);
        new Market(
            token,
            address(usdg),
            address(router),
            address(pitPoints),
            _split(),
            0,
            PER_ADDRESS_OI_CAP_BPS,
            address(pauseGuardian),
            0,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
        vm.expectRevert(Market.InvalidOiCap.selector);
        new Market(
            token,
            address(usdg),
            address(router),
            address(pitPoints),
            _split(),
            10_001,
            PER_ADDRESS_OI_CAP_BPS,
            address(pauseGuardian),
            0,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
    }

    function test_constructor_revertsOnInvalidPerAddressOiCap() public {
        vm.expectRevert(Market.InvalidPerAddressOiCap.selector);
        new Market(
            token,
            address(usdg),
            address(router),
            address(pitPoints),
            _split(),
            1_000,
            0,
            address(pauseGuardian),
            0,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
        vm.expectRevert(Market.InvalidPerAddressOiCap.selector);
        new Market(
            token,
            address(usdg),
            address(router),
            address(pitPoints),
            _split(),
            1_000,
            10_001,
            address(pauseGuardian),
            0,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
    }

    function test_constructor_revertsOnSettlementFeeAboveMax() public {
        // MAX_FEE_BPS (100) is accepted; one above it reverts, so the owner can never bake an
        // exorbitant settlement fee into a market. Cache the constant so its getter call does not
        // consume the expectRevert cheat.
        uint256 maxFee = market.MAX_FEE_BPS();
        new Market(
            token,
            address(usdg),
            address(router),
            address(pitPoints),
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            address(pauseGuardian),
            1e18,
            type(uint256).max,
            maxFee,
            uint16(0)
        );
        vm.expectRevert(Market.SettlementFeeTooHigh.selector);
        new Market(
            token,
            address(usdg),
            address(router),
            address(pitPoints),
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            address(pauseGuardian),
            1e18,
            type(uint256).max,
            maxFee + 1,
            uint16(0)
        );
    }

    function test_constructor_revertsOnHighDecimalUsdg() public {
        HighDecimalsToken weird = new HighDecimalsToken();
        vm.expectRevert(Market.UnsupportedDecimals.selector);
        new Market(
            token,
            address(weird),
            address(router),
            address(pitPoints),
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            address(pauseGuardian),
            0,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
    }

    function test_constructor_revertsOnOpenBondAboveMax() public {
        uint256 maxBond = market.MAX_OPEN_BOND_BPS();
        // Exactly at the cap is accepted.
        new Market(
            token,
            address(usdg),
            address(router),
            address(pitPoints),
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            address(pauseGuardian),
            1e18,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(maxBond)
        );
        // One above it reverts, so the owner can never bake a punitive open cost.
        vm.expectRevert(Market.OpenBondTooHigh.selector);
        new Market(
            token,
            address(usdg),
            address(router),
            address(pitPoints),
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            address(pauseGuardian),
            1e18,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(maxBond + 1)
        );
    }

    function test_openBond_chargedToTreasuryScalesWithOi() public {
        // A market with a 2% (200 bps) anti-monopolization open bond (wave-2 W2-9).
        router.setTrackedLiquidity(token, 1e30);
        router.setSnapshotValue(token, 1e30);
        router.setPrice(token, 1e18, Types.PriceStatus.OK);
        Market bonded = new Market(
            token,
            address(usdg),
            address(router),
            address(pitPoints),
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            address(pauseGuardian),
            1e30,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(200)
        );
        assertEq(bonded.openBondBps(), 200);

        // alice LONG maker 10_000e6, bob taker 10_000e6, symmetric 1:1, multiple 1.
        usdg.mint(alice, 10_000e6);
        vm.prank(alice);
        usdg.approve(address(bonded), type(uint256).max);
        vm.prank(alice);
        uint256 offerId = bonded.postOffer(
            Types.Side.LONG, 10_000e6, 1_000e6, 1, 10_000, 1 days, uint64(block.timestamp + 1 days), 0
        );

        // makerStake = takerStake = 10_000e6 - 10e6 entry fee = 9_990e6; totalStake = 19_980e6.
        // Open bond = 200 bps of 19_980e6 = 399_600_000, nonrefundably routed to the treasury (on
        // top of the treasury's entry-fee share).
        uint256 totalStake = 2 * (uint256(10_000e6) - 10e6);
        uint256 expectedBond = totalStake * 200 / 10_000;
        usdg.mint(bob, 10_000e6 + expectedBond); // taker posts its gross fill plus the bond
        vm.prank(bob);
        usdg.approve(address(bonded), type(uint256).max);

        uint256 treBefore = usdg.balanceOf(treasury);
        vm.expectEmit(true, true, false, true);
        emit Market.OpenBondCharged(0, bob, expectedBond);
        vm.prank(bob);
        bonded.fillOffer(offerId, 10_000e6);

        // Entry fee total 20e6, treasury entry share = 20e6 - 5e6 - 2e6 - 7.8e6 = 5.2e6.
        uint256 entryTreasuryShare = 5_200_000;
        assertEq(usdg.balanceOf(treasury) - treBefore, entryTreasuryShare + expectedBond);
        // The bond left escrow: open interest is exactly the two stakes, unaffected by the bond.
        assertEq(bonded.openInterest(), totalStake);
    }

    function test_constructor_storesConfig() public view {
        assertEq(address(market.usdg()), address(usdg));
        assertEq(address(market.router()), address(router));
        assertEq(address(market.points()), address(pitPoints));
        assertEq(address(market.guardian()), address(pauseGuardian));
        assertEq(market.feeJackpot(), jackpot);
        assertEq(market.feeTreasury(), treasury);
        assertEq(market.feeReferralPool(), referral);
        assertEq(market.feeBuyback(), buyback);
        assertEq(market.settlementFeeBps(), SETTLEMENT_FEE_BPS);
        assertEq(market.oiCapBps(), OI_CAP_BPS);
        assertEq(market.perAddressOiCapBps(), PER_ADDRESS_OI_CAP_BPS);
        assertEq(market.liquiditySnapshot1e18(), 1_000_000e18);
        assertEq(market.collateralScale(), 1e12);
        assertEq(market.token(), token);
    }

    function test_settle_reentrancyBlockedOnPayout() public {
        // Build a standalone market whose collateral token tries to re-enter settle
        // during the winner payout transfer.
        ReentrantUSDG evil = new ReentrantUSDG();
        Market evilMarket = new Market(
            token,
            address(evil),
            address(router),
            address(pitPoints),
            _split(),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            address(pauseGuardian),
            1e30,
            type(uint256).max,
            SETTLEMENT_FEE_BPS,
            uint16(0)
        );
        router.setTrackedLiquidity(token, 1e30);
        router.setPrice(token, 1e18, Types.PriceStatus.OK);

        evil.mint(alice, 1_000e6);
        evil.mint(bob, 1_000e6);
        vm.prank(alice);
        evil.approve(address(evilMarket), type(uint256).max);
        vm.prank(bob);
        evil.approve(address(evilMarket), type(uint256).max);

        vm.prank(alice);
        uint256 offerId = evilMarket.postOffer(
            Types.Side.LONG, 1_000e6, 1_000e6, 5, 10_000, 1 days, uint64(block.timestamp + 1 days), 0
        );
        vm.prank(bob);
        uint256 positionId = evilMarket.fillOffer(offerId, 1_000e6);

        vm.warp(block.timestamp + 1 days);
        router.setPrice(token, 1.1e18, Types.PriceStatus.OK);
        evil.arm(evilMarket, positionId);

        vm.prank(carol);
        evilMarket.settle(positionId);

        assertTrue(evil.reentryBlocked());
        assertTrue(evilMarket.positions(positionId).settled);
    }
}
