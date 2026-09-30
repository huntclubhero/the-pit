// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {CoreBase} from "./CoreBase.t.sol";

/// @title Settlement math fuzz suite
/// @notice Runs the full postOffer / fillOffer / settle pipeline through the real
///         Market over the entire supported domain: gross collateral 1_000..1e30
///         (below 1_000 the 10 bps entry fee rounds to zero and the fill is rejected
///         as dust), multiple 1..10, entry and exit prices 1..1e36. Asserts exact
///         conservation including entry fees, clamp bounds, the fee invariants, and
///         that no valid input ever reverts.
contract SettlementFuzzTest is CoreBase {
    uint256 internal constant MIN_COLLATERAL = 1_000;
    uint256 internal constant MAX_COLLATERAL = 1e30;
    uint256 internal constant MAX_PRICE = 1e36;

    /// @dev Enormous tracked liquidity so the OI cap and liquidity floor never bind:
    ///      this suite targets the settlement math, not the fill gates.
    function _initialLiquidity() internal pure override returns (uint256) {
        return 1e60;
    }

    /// @dev Open a position of size `collateral` at `entry` and settle it at `exit`.
    function _openAndSettle(uint128 collateral, uint16 multiple, uint256 entry, uint256 exit, bool makerLong)
        internal
        returns (uint256 positionId)
    {
        router.setPrice(token, entry, Types.PriceStatus.OK);
        uint256 offerId = _postOfferFull(
            alice,
            makerLong ? Types.Side.LONG : Types.Side.SHORT,
            collateral,
            collateral,
            multiple,
            1 days,
            uint64(block.timestamp + 1 days),
            0
        );
        positionId = _fill(bob, offerId, collateral);

        vm.warp(block.timestamp + 1 days);
        router.setPrice(token, exit, Types.PriceStatus.OK);
        vm.prank(carol);
        market.settle(positionId);
        // Payouts are credited (pull-payment); realize both parties' balances so the
        // balance-based conservation and payout assertions observe the funds.
        _drain(alice);
        _drain(bob);
    }

    /// @dev Reference model of the entry fee: per-side fee on the gross fill and the
    ///      resulting net collateralEach.
    function _entryFeeAndNet(uint256 collateral, uint256 multiple)
        internal
        pure
        returns (uint256 feePerSide, uint256 net)
    {
        feePerSide = collateral * multiple * 10 / 10_000;
        net = collateral - feePerSide;
    }

    /// @dev Reference model of the spec's settlement math over the NET (post entry
    ///      fee) collateralEach.
    function _expectedPnlAndFee(uint256 net, uint256 multiple, uint256 entry, uint256 exit)
        internal
        pure
        returns (uint256 pnl, uint256 fee)
    {
        uint256 notional = net * multiple;
        uint256 diff = exit > entry ? exit - entry : entry - exit;
        if (diff >= entry) {
            pnl = net;
        } else {
            pnl = Math.min(Math.mulDiv(notional, diff, entry), net);
        }
        fee = pnl == 0 ? 0 : Math.min(notional * 50 / 10_000, pnl);
    }

    function testFuzz_settlementConservationAndBounds(
        uint128 collateralSeed,
        uint16 multipleSeed,
        uint256 entrySeed,
        uint256 exitSeed,
        bool makerLong
    ) public {
        uint128 collateral = uint128(bound(collateralSeed, MIN_COLLATERAL, MAX_COLLATERAL));
        uint16 multiple = uint16(bound(multipleSeed, 1, 10));
        uint256 entry = bound(entrySeed, 1, MAX_PRICE);
        uint256 exit = bound(exitSeed, 1, MAX_PRICE);

        _openAndSettle(collateral, multiple, entry, exit, makerLong);

        (uint256 entryFeeSide, uint256 net) = _entryFeeAndNet(collateral, multiple);
        (uint256 pnl, uint256 fee) = _expectedPnlAndFee(net, multiple, entry, exit);

        // Entry fee bounds: nonzero, and never more than 1 percent of the gross fill.
        assertGe(entryFeeSide, 1, "entry fee must be nonzero");
        assertLe(entryFeeSide, uint256(collateral) / 100, "entry fee above 1 percent");

        // Clamp and fee bounds over the net collateral.
        assertLe(pnl, net, "pnl exceeds collateral clamp");
        assertLe(fee, pnl, "fee exceeds pnl");

        // Party payouts. Maker is alice; long party depends on makerLong.
        {
            address longParty = makerLong ? alice : bob;
            address shortParty = makerLong ? bob : alice;
            if (pnl == 0) {
                assertEq(usdg.balanceOf(longParty), net, "flat long refund");
                assertEq(usdg.balanceOf(shortParty), net, "flat short refund");
                assertEq(fee, 0, "flat fee must be zero");
            } else if (exit > entry) {
                assertEq(usdg.balanceOf(longParty), net + pnl - fee, "long winner payout");
                assertEq(usdg.balanceOf(shortParty), net - pnl, "short loser payout");
            } else {
                assertEq(usdg.balanceOf(shortParty), net + pnl - fee, "short winner payout");
                assertEq(usdg.balanceOf(longParty), net - pnl, "long loser payout");
            }
        }

        // Fee split is exact: entry fees (split at fill) plus the settlement fee
        // (split at settle) sum to the recipient balances, dust in treasury. Each
        // _distributeFee call floors its jackpot/referral/buyback shares independently and gives
        // treasury the remainder, so per-recipient totals match the sum of the two floored calls.
        {
            uint256 entryTotal = 2 * entryFeeSide;
            assertEq(
                usdg.balanceOf(jackpot) + usdg.balanceOf(referral) + usdg.balanceOf(buyback) + usdg.balanceOf(treasury),
                entryTotal + fee,
                "fee split sum"
            );
            assertEq(usdg.balanceOf(jackpot), entryTotal * 2_500 / 10_000 + fee * 2_500 / 10_000, "jackpot share");
            assertEq(usdg.balanceOf(referral), entryTotal * 1_000 / 10_000 + fee * 1_000 / 10_000, "referral share");
            assertEq(usdg.balanceOf(buyback), entryTotal * 3_900 / 10_000 + fee * 3_900 / 10_000, "buyback share");
        }

        // Exact conservation: everything escrowed left the market, nothing more.
        // Total in was 2 x gross collateral (both sides), total out is party payouts
        // plus entry and settlement fees.
        assertEq(
            usdg.balanceOf(alice) + usdg.balanceOf(bob) + usdg.balanceOf(jackpot) + usdg.balanceOf(referral)
                + usdg.balanceOf(buyback) + usdg.balanceOf(treasury),
            2 * uint256(collateral),
            "conservation"
        );
        assertEq(usdg.balanceOf(address(market)), 0, "market drained exactly");
        assertEq(market.openInterest(), 0, "open interest cleared");
    }

    /// @notice Winner payout identity: net collateral + pnl - fee, and it never
    ///         exceeds 2 x gross collateral (capped payout guarantee).
    function testFuzz_winnerPayoutNeverExceedsTwiceCollateral(
        uint128 collateralSeed,
        uint16 multipleSeed,
        uint256 entrySeed,
        uint256 exitSeed
    ) public {
        uint128 collateral = uint128(bound(collateralSeed, MIN_COLLATERAL, MAX_COLLATERAL));
        uint16 multiple = uint16(bound(multipleSeed, 1, 10));
        uint256 entry = bound(entrySeed, 1, MAX_PRICE);
        uint256 exit = bound(exitSeed, 1, MAX_PRICE);

        _openAndSettle(collateral, multiple, entry, exit, true);

        assertLe(usdg.balanceOf(alice), 2 * uint256(collateral), "long payout cap");
        assertLe(usdg.balanceOf(bob), 2 * uint256(collateral), "short payout cap");
    }

    /// @notice Forced neutral unwind refunds both sides exactly collateralEach (net
    ///         of the entry fee charged at fill) for any position size; the entry
    ///         fees stay with the fee recipients.
    function testFuzz_forcedUnwindExactRefunds(uint128 collateralSeed, uint16 multipleSeed, uint256 entrySeed) public {
        uint128 collateral = uint128(bound(collateralSeed, MIN_COLLATERAL, MAX_COLLATERAL));
        uint16 multiple = uint16(bound(multipleSeed, 1, 10));
        uint256 entry = bound(entrySeed, 1, MAX_PRICE);

        router.setPrice(token, entry, Types.PriceStatus.OK);
        uint256 offerId = _postOfferFull(
            alice, Types.Side.LONG, collateral, collateral, multiple, 1 days, uint64(block.timestamp + 1 days), 0
        );
        uint256 positionId = _fill(bob, offerId, collateral);

        vm.warp(block.timestamp + 1 days + 24 hours + 1);
        router.setPrice(token, entry, Types.PriceStatus.UNAVAILABLE);
        vm.prank(carol);
        market.settle(positionId);
        // Forced unwind credits both sides (pull-payment); each pulls its refund.
        _drain(alice);
        _drain(bob);

        (uint256 entryFeeSide, uint256 net) = _entryFeeAndNet(collateral, multiple);
        assertEq(usdg.balanceOf(alice), net, "long refund");
        assertEq(usdg.balanceOf(bob), net, "short refund");
        assertEq(usdg.balanceOf(address(market)), 0, "market drained");
        assertEq(
            usdg.balanceOf(jackpot) + usdg.balanceOf(referral) + usdg.balanceOf(buyback) + usdg.balanceOf(treasury),
            2 * entryFeeSide,
            "entry fees only, no settlement fee"
        );
    }

    /// @notice Full-pipeline conservation including a partial fill and a cancel:
    ///         every USDG that entered the system (maker offer plus taker fill) is
    ///         accounted for exactly across the maker refund, both parties' payouts,
    ///         and the fee recipients, across post, fill, cancel, and settle paths.
    function testFuzz_fullPipelineConservationWithCancel(
        uint128 collateralSeed,
        uint128 fillSeed,
        uint16 multipleSeed,
        uint256 exitSeed
    ) public {
        uint128 collateral = uint128(bound(collateralSeed, 2 * MIN_COLLATERAL, MAX_COLLATERAL));
        uint128 fillAmount = uint128(bound(fillSeed, MIN_COLLATERAL, collateral));
        uint16 multiple = uint16(bound(multipleSeed, 1, 10));
        uint256 exit = bound(exitSeed, 1, MAX_PRICE);

        router.setPrice(token, 1e18, Types.PriceStatus.OK);
        uint256 offerId = _postOfferFull(
            alice,
            Types.Side.LONG,
            collateral,
            uint128(MIN_COLLATERAL),
            multiple,
            1 days,
            uint64(block.timestamp + 1 days),
            0
        );
        uint256 positionId = _fill(bob, offerId, fillAmount);

        vm.prank(alice);
        market.cancelOffer(offerId);

        vm.warp(block.timestamp + 1 days);
        router.setPrice(token, exit, Types.PriceStatus.OK);
        vm.prank(carol);
        market.settle(positionId);
        // Party payouts are credited (pull-payment); each pulls before the balance-based
        // conservation check. Alice's cancel refund was already pushed at cancel time.
        _drain(alice);
        _drain(bob);

        // Total in: alice funded `collateral`, bob funded `fillAmount`. Total out:
        // party balances plus every fee paid. Nothing is left in the market.
        assertEq(
            usdg.balanceOf(alice) + usdg.balanceOf(bob) + usdg.balanceOf(jackpot) + usdg.balanceOf(referral)
                + usdg.balanceOf(buyback) + usdg.balanceOf(treasury),
            uint256(collateral) + uint256(fillAmount),
            "pipeline conservation"
        );
        assertEq(usdg.balanceOf(address(market)), 0, "market drained exactly");
        assertEq(market.openInterest(), 0, "open interest cleared");
    }
}
