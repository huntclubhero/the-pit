// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {CoreBase} from "./CoreBase.t.sol";

/// @title Odds-based asymmetric collateral: worked examples and conservation fuzz
/// @notice Proves the asymmetric-odds economics: a taker filling a maker's 9:1 offer posts a
///         fraction of the escrow yet wins the whole escrow (a ~10x return) when right, and loses
///         exactly its own stake when wrong; the maker takes the mirror (small edge, large
///         liability). Exact numbers are asserted for both maker sides and both directions, and a
///         fuzz proves settlement conservation is EXACT and the capped-payout bounds hold across
///         the full odds band on unequal stakes.
contract MarketOddsTest is CoreBase {
    /// @dev Huge tracked liquidity so the OI cap never binds: this suite targets the odds math.
    function _initialLiquidity() internal pure override returns (uint256) {
        return 1e60;
    }

    /// @dev Open an asymmetric position: alice is the maker (posting `makerColl` at `ratioBps`
    ///      odds), bob is the taker filling the ENTIRE maker collateral. Bob is funded EXACTLY the
    ///      proportional taker collateral, so his post-settlement balance equals his payout.
    function _openOdds(Types.Side makerSide, uint128 makerColl, uint32 ratioBps, uint16 multiple)
        internal
        returns (uint256 positionId, uint256 takerGross)
    {
        router.setPrice(token, 1e18, Types.PriceStatus.OK);
        uint256 offerId = _postOfferOdds(
            alice, makerSide, makerColl, 1, multiple, ratioBps, 1 days, uint64(block.timestamp + 1 days), 0
        );
        takerGross = Math.ceilDiv(uint256(makerColl) * 10_000, ratioBps);
        _fund(bob, uint128(takerGross));
        vm.prank(bob);
        positionId = market.fillOffer(offerId, makerColl);
    }

    // ==================================================================================
    // Worked 9:1 (payoffRatioBps 90_000) examples: taker posts 1_000e6, escrow totals ~9_990e6
    // ==================================================================================

    /// @notice Maker SHORT, taker LONG, price UP: the taker wins the whole maker stake, turning a
    ///         1_000e6 posted stake into 9_945_045_000 (~9.95x) after the settlement fee.
    function test_odds_takerLongWinsAboutTenX() public {
        // multiple 1: makerStake 8_991e6 (9_000e6 - 9e6 fee), takerStake 999e6 (1_000e6 - 1e6 fee).
        (uint256 positionId, uint256 takerGross) = _openOdds(Types.Side.SHORT, 9_000e6, 90_000, 1);
        assertEq(takerGross, 1_000e6);

        // Position records the two UNEQUAL stakes; total escrow 9_990e6 is the payout ceiling.
        Types.Position memory p = market.positions(positionId);
        assertEq(p.longStake, 999e6); // taker (long)
        assertEq(p.shortStake, 8_991e6); // maker (short)

        vm.warp(block.timestamp + 1 days);
        router.setPrice(token, 2e18, Types.PriceStatus.OK); // +100%: absMove >= entry, full clamp
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        // transfer = shortStake 8_991e6 (winner takes the loser's whole stake). Settlement fee =
        // 50 bps of the loser notional 8_991e6 = 44_955_000. Taker payout = 999e6 + 8_991e6 - fee.
        assertEq(usdg.balanceOf(bob), 9_945_045_000); // ~9.95x the 1_000e6 posted
        assertEq(usdg.balanceOf(alice), 0); // maker lost its whole 8_991e6 stake
        // Conservation: payouts + settlement fee == total escrow 9_990e6 (entry fees already left).
        assertEq(usdg.balanceOf(bob) + usdg.balanceOf(alice) + 44_955_000, 9_990e6);
    }

    /// @notice Maker SHORT, taker LONG, price DOWN: the taker loses EXACTLY its own stake and the
    ///         maker keeps the escrow (its stake plus the taker's stake, minus fee).
    function test_odds_takerLongLosesWholeStake() public {
        // multiple 10: makerStake 8_910e6 (9_000e6 - 90e6), takerStake 990e6 (1_000e6 - 10e6).
        (uint256 positionId,) = _openOdds(Types.Side.SHORT, 9_000e6, 90_000, 10);

        vm.warp(block.timestamp + 1 days);
        router.setPrice(token, 0.9e18, Types.PriceStatus.OK); // -10%: at multiple 10 wipes the long
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        // transfer = takerStake 990e6. Loser notional 990e6 * 10 = 9_900e6, fee 50 bps = 49_500_000.
        assertEq(usdg.balanceOf(bob), 0); // taker lost its entire 990e6 stake
        assertEq(usdg.balanceOf(alice), 9_850_500_000); // maker: 8_910e6 + 990e6 - fee
        assertEq(usdg.balanceOf(alice) + usdg.balanceOf(bob) + 49_500_000, 9_900e6);
    }

    /// @notice Maker LONG, taker SHORT, price DOWN: the taker (short) wins the maker's whole stake.
    function test_odds_takerShortWinsAboutTenX() public {
        // multiple 10: makerStake 8_910e6 (long), takerStake 990e6 (short).
        (uint256 positionId, uint256 takerGross) = _openOdds(Types.Side.LONG, 9_000e6, 90_000, 10);
        assertEq(takerGross, 1_000e6);

        Types.Position memory p = market.positions(positionId);
        assertEq(p.longStake, 8_910e6); // maker (long)
        assertEq(p.shortStake, 990e6); // taker (short)

        vm.warp(block.timestamp + 1 days);
        router.setPrice(token, 0.9e18, Types.PriceStatus.OK); // -10%: wipes the long maker
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        // transfer = longStake 8_910e6. Loser notional 8_910e6 * 10 = 89_100e6, fee 50 bps =
        // 445_500_000. Taker payout = 990e6 + 8_910e6 - fee.
        assertEq(usdg.balanceOf(bob), 9_454_500_000); // ~9.45x the 1_000e6 posted
        assertEq(usdg.balanceOf(alice), 0);
        assertEq(usdg.balanceOf(bob) + usdg.balanceOf(alice) + 445_500_000, 9_900e6);
    }

    /// @notice Maker LONG, taker SHORT, price UP: the taker loses its whole stake, the maker wins
    ///         its small edge (turning 8_910e6 into 9_850_500_000, about +10.6%).
    function test_odds_makerLongWinsSmallEdge() public {
        (uint256 positionId,) = _openOdds(Types.Side.LONG, 9_000e6, 90_000, 10);

        vm.warp(block.timestamp + 1 days);
        router.setPrice(token, 1.1e18, Types.PriceStatus.OK); // +10%: wipes the short taker
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        // transfer = takerStake 990e6, loser notional 9_900e6, fee 49_500_000.
        assertEq(usdg.balanceOf(bob), 0);
        assertEq(usdg.balanceOf(alice), 9_850_500_000); // maker keeps escrow minus fee
        assertEq(usdg.balanceOf(alice) + usdg.balanceOf(bob) + 49_500_000, 9_900e6);
    }

    // ==================================================================================
    // Conservation and capped-payout bounds over the full odds band (fuzz)
    // ==================================================================================

    /// @notice For any maker collateral, odds, multiple, and entry/exit prices in the supported
    ///         domain: the fill+settle pipeline never reverts, settlement conservation is EXACT
    ///         (party payouts + all fees == every USDG that entered), the winner never receives more
    ///         than the total escrow, and the loser is never negative (never loses more than staked).
    function testFuzz_oddsConservationAndBounds(
        uint128 makerCollSeed,
        uint32 ratioSeed,
        uint16 multipleSeed,
        uint256 entrySeed,
        uint256 exitSeed,
        bool makerLong
    ) public {
        // Lower bound 20_000 keeps BOTH sides above the dust floor for every ratio/multiple:
        // takerGross >= ceil(20_000 / 20) = 1_000, so feeTaker >= 1 even at multiple 1.
        uint128 makerColl = uint128(bound(makerCollSeed, 20_000, 1e30));
        uint32 ratioBps = uint32(bound(ratioSeed, 10_000, 200_000));
        uint16 multiple = uint16(bound(multipleSeed, 1, 10));
        uint256 entry = bound(entrySeed, 1, 1e36);
        uint256 exit = bound(exitSeed, 1, 1e36);

        uint256 takerGross = Math.ceilDiv(uint256(makerColl) * 10_000, ratioBps);

        router.setPrice(token, entry, Types.PriceStatus.OK);
        uint256 offerId = _postOfferOdds(
            alice,
            makerLong ? Types.Side.LONG : Types.Side.SHORT,
            makerColl,
            1,
            multiple,
            ratioBps,
            1 days,
            uint64(block.timestamp + 1 days),
            0
        );
        _fund(bob, uint128(takerGross));
        vm.prank(bob);
        uint256 positionId = market.fillOffer(offerId, makerColl);

        // Total escrow is the sum of the two (unequal) stakes and the capped-payout ceiling.
        Types.Position memory p = market.positions(positionId);
        uint256 totalEscrow = uint256(p.longStake) + uint256(p.shortStake);

        vm.warp(block.timestamp + 1 days);
        router.setPrice(token, exit, Types.PriceStatus.OK);
        vm.prank(carol);
        market.settle(positionId);
        _drain(alice);
        _drain(bob);

        // Capped payout: neither party can ever receive more than the total escrow.
        assertLe(usdg.balanceOf(alice), totalEscrow, "alice payout above total escrow");
        assertLe(usdg.balanceOf(bob), totalEscrow, "bob payout above total escrow");

        // Exact conservation: every USDG that entered (maker collateral + taker collateral) is
        // accounted for across both parties' payouts and every fee (entry split at fill, settlement
        // split at settle). Nothing is minted, nothing is stranded.
        assertEq(
            usdg.balanceOf(alice) + usdg.balanceOf(bob) + usdg.balanceOf(jackpot) + usdg.balanceOf(referral)
                + usdg.balanceOf(buyback) + usdg.balanceOf(treasury),
            uint256(makerColl) + takerGross,
            "conservation"
        );
        assertEq(usdg.balanceOf(address(market)), 0, "market drained exactly");
        assertEq(market.openInterest(), 0, "open interest cleared");
    }
}
