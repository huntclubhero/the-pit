// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {CoreBase} from "./CoreBase.t.sol";

/// @title Per-address open-interest sub-cap (B2)
/// @notice Proves the sub-cap blocks a colluding two-address pair from monopolizing the market OI
///         cap with risk-free self-trades, while never blocking honest independent traders. The
///         fixture bakes a 25 percent sub-cap (of the market OI cap) into the market.
contract MarketPerAddressOiCapTest is CoreBase {
    /// @dev Global cap = snapshot 1_000_000e18 x 10% = 100_000e18 -> 100_000e6 native.
    ///      Per-address sub-cap = 25% of that = 25_000e18 -> 25_000e6 native per participant.
    function _perAddressOiCapBps() internal pure override returns (uint16) {
        return 2_500;
    }

    function test_perAddressCap_blocksTwoAddressMonopolization() public {
        // Colluding pair: alice is the maker, bob the taker, so each accrues the same side escrow
        // on every self-trade. Using multiple 1, feePerSide = gross / 1_000.
        uint256 offerId =
            _postOfferFull(alice, Types.Side.LONG, 100_000e6, 1_000e6, 1, 1 days, uint64(block.timestamp + 1 days), 0);

        // Fill 20_000e6 gross: fee 20e6, net 19_980e6 to each side. Both under the 25_000e6 sub-cap.
        _fill(bob, offerId, 20_000e6);
        assertEq(market.openCollateralOf(alice), 19_980e6);
        assertEq(market.openCollateralOf(bob), 19_980e6);

        // A further 6_000e6 gross (net 5_994e6) would push each party to 25_974e6, above the
        // 25_000e6 sub-cap: the fill reverts on the maker's accrual. The pair therefore caps at
        // 2 x 25_000e6 = half the market OI cap, always leaving room for honest traders.
        _fund(bob, 6_000e6);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                Market.PerAddressOiCapExceeded.selector, alice, uint256(25_974e6) * 1e12, uint256(25_000e18)
            )
        );
        market.fillOffer(offerId, 6_000e6);
    }

    function test_perAddressCap_allowsHonestIndependentTraders() public {
        address dave = makeAddr("dave");

        // Honest pair 1: alice maker, bob taker, 25_000e6 gross (net 24_975e6), exactly under cap.
        uint256 offer1 =
            _postOfferFull(alice, Types.Side.LONG, 25_000e6, 1_000e6, 1, 1 days, uint64(block.timestamp + 1 days), 0);
        _fill(bob, offer1, 25_000e6);
        assertEq(market.openCollateralOf(alice), 24_975e6);
        assertEq(market.openCollateralOf(bob), 24_975e6);

        // Honest pair 2: carol maker, dave taker, fully independent. Not blocked by pair 1 (the
        // sub-cap is per address), and global OI (4 x 24_975e6 = 99_900e6) stays under the cap.
        uint256 offer2 =
            _postOfferFull(carol, Types.Side.SHORT, 25_000e6, 1_000e6, 1, 1 days, uint64(block.timestamp + 1 days), 0);
        _fill(dave, offer2, 25_000e6);
        assertEq(market.openCollateralOf(carol), 24_975e6);
        assertEq(market.openCollateralOf(dave), 24_975e6);
        assertEq(market.openInterest(), 4 * uint256(24_975e6));
    }

    function test_perAddressCap_freesHeadroomOnSettle() public {
        uint256 offerId =
            _postOfferFull(alice, Types.Side.LONG, 100_000e6, 1_000e6, 1, 1 days, uint64(block.timestamp + 1 days), 0);
        uint256 pos = _fill(bob, offerId, 25_000e6);
        assertEq(market.openCollateralOf(alice), 24_975e6);
        assertEq(market.openCollateralOf(bob), 24_975e6);

        // Flat settle releases both parties' open-collateral ledger entries.
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        market.settle(pos);
        assertEq(market.openCollateralOf(alice), 0);
        assertEq(market.openCollateralOf(bob), 0);

        // With the headroom freed, bob can open a fresh full-sub-cap position again.
        _fill(bob, offerId, 25_000e6);
        assertEq(market.openCollateralOf(bob), 24_975e6);
    }

    function test_perAddressCap_countsPostedStakeUnderOdds() public {
        // Under asymmetric odds the sub-cap counts each participant's OWN posted stake. A maker
        // posting a large stake at 20:1 odds is the monopolization risk (it locks the escrow), and
        // the sub-cap catches it on the MAKER's side even though the taker's proportional stake is
        // tiny. Maker LONG 30_000e6 at ratio 200_000 (20:1), multiple 1, taker fills 26_000e6.
        uint256 offerId = _postOfferOdds(
            alice, Types.Side.LONG, 30_000e6, 1, 1, 200_000, 1 days, uint64(block.timestamp + 1 days), 0
        );

        // makerStake = 26_000e6 - 26e6 = 25_974e6 > 25_000e6 sub-cap: the maker's accrual reverts.
        // (takerGross = 26_000e6 / 20 = 1_300e6, takerStake 1_298_700_000, far under the sub-cap.)
        _fund(bob, 1_300e6);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                Market.PerAddressOiCapExceeded.selector, alice, uint256(25_974e6) * 1e12, uint256(25_000e18)
            )
        );
        market.fillOffer(offerId, 26_000e6);
    }

    function test_perAddressCap_ledgerRecordsOwnStakeUnderOdds() public {
        // A successful 20:1 odds fill records each side's OWN unequal stake in the per-address
        // ledger, and the two entries sum to the market open interest.
        uint256 offerId = _postOfferOdds(
            alice, Types.Side.SHORT, 20_000e6, 1, 1, 200_000, 1 days, uint64(block.timestamp + 1 days), 0
        );
        // takerGross = 20_000e6 / 20 = 1_000e6. makerStake = 20_000e6 - 20e6 = 19_980e6, takerStake
        // = 1_000e6 - 1e6 = 999e6. Maker (alice) sits under the 25_000e6 sub-cap.
        _fund(bob, 1_000e6);
        vm.prank(bob);
        market.fillOffer(offerId, 20_000e6);

        assertEq(market.openCollateralOf(alice), 19_980e6);
        assertEq(market.openCollateralOf(bob), 999e6);
        assertEq(market.openInterest(), uint256(19_980e6) + 999e6);
    }

    function test_perAddressCap_freesHeadroomOnForcedUnwind() public {
        uint256 offerId =
            _postOfferFull(alice, Types.Side.LONG, 100_000e6, 1_000e6, 1, 1 days, uint64(block.timestamp + 1 days), 0);
        uint256 pos = _fill(bob, offerId, 25_000e6);

        // Force unwind (broken oracle past the deadline) also releases the ledger entries.
        vm.warp(block.timestamp + 1 days + 24 hours + 1);
        router.setPrice(token, 1e18, Types.PriceStatus.UNAVAILABLE);
        vm.prank(carol);
        market.settle(pos);
        assertEq(market.openCollateralOf(alice), 0);
        assertEq(market.openCollateralOf(bob), 0);
    }
}
