// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpEngineBase} from "./PerpEngineBase.t.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";

/// @notice addMargin / removeMargin: the anti-JELLY initial-margin floor (spec 1.5): a
///         position can NEVER be walked into liquidation by its own margin withdrawal.
contract PerpEngineMarginTest is PerpEngineBase {
    // 3x position: margin 1200, fee on 3600 notional at 10 bps = 3.6, mNet 1196.4,
    // notional 3589.2, size 3589.2e18. IM at P=1 with 6x tier max = 3589.2 / 6 = 598.2.
    uint128 internal constant MARGIN = 1_200e6;
    uint32 internal constant LEV = 300;
    uint256 internal constant M_NET = 1_196_400_000;
    uint256 internal constant IM_REQ = 598_200_000;

    function _openThreeX() internal returns (bytes32) {
        return open(alice, MEME, true, MARGIN, LEV);
    }

    function test_addMargin_growsMarginPayoutAndReserve() public {
        _openThreeX();
        uint256 reserveBefore = vault.reservedOf(MEME);
        vm.prank(alice);
        engine.addMargin(MEME, true, 500e6);
        PerpTypes.Position memory p = posOf(MEME, alice, true);
        assertEq(p.margin, M_NET + 500e6);
        assertEq(p.maxPayout, 9 * M_NET + 9 * 500e6);
        assertEq(vault.reservedOf(MEME), reserveBefore + 9 * 500e6);
        assertEq(engine.addressReserved(MEME, alice), p.maxPayout);
        assertAggMatchesPositions(MEME);
    }

    function test_removeMargin_downToImFloorExactly() public {
        _openThreeX();
        uint256 removable = M_NET - IM_REQ; // 598.2 USDG
        uint256 aliceBefore = usdg.balanceOf(alice);

        vm.prank(alice);
        engine.removeMargin(MEME, true, uint128(removable));

        PerpTypes.Position memory p = posOf(MEME, alice, true);
        assertEq(p.margin, IM_REQ);
        assertEq(usdg.balanceOf(alice), aliceBefore + removable);
        // maxPayout shrank to 9 * remaining margin; reserve released.
        assertEq(p.maxPayout, 9 * IM_REQ);
        assertEq(vault.reservedOf(MEME), 9 * IM_REQ);
        assertAggMatchesPositions(MEME);

        // One more unit crosses the floor: anti-JELLY hard stop.
        vm.prank(alice);
        vm.expectRevert(PerpEngine.BelowInitialMarginFloor.selector);
        engine.removeMargin(MEME, true, 1);
    }

    function test_removeMargin_atMaxLeverageNothingRemovable() public {
        open(bob, MEME, true, 1_000e6, 600); // fully levered: margin == IM already
        vm.prank(bob);
        vm.expectRevert(PerpEngine.BelowInitialMarginFloor.selector);
        engine.removeMargin(MEME, true, 1e6);
    }

    function test_removeMargin_selfLiquidationImpossible() public {
        // THE JELLY test: after the maximum permitted withdrawal, the position is still
        // NOT liquidatable (IM floor is strictly above the maintenance line).
        _openThreeX();
        vm.prank(alice);
        engine.removeMargin(MEME, true, uint128(M_NET - IM_REQ));
        assertFalse(engine.liquidatable(MEME, alice, true), "owner cannot force own liquidation");
        // Maintenance margin is 10% of 3589.2 = 358.92 < IM 598.2: real distance remains.
        assertGt(engine.equityOf(MEME, alice, true), int256(358_920_000));
    }

    function test_removeMargin_lossReducesHeadroom() public {
        _openThreeX();
        oracle.setLive(MEME, 9e17); // minus 10%: uPnL = minus 358.92
        // equityAfter = newMargin minus 358.92 must clear IM at 0.9 = 3230.28/6 = 538.38.
        // Max removal = 1196.4 minus 358.92 minus 538.38 = 299.1.
        vm.prank(alice);
        engine.removeMargin(MEME, true, 299_100_000);
        vm.prank(alice);
        vm.expectRevert(PerpEngine.BelowInitialMarginFloor.selector);
        engine.removeMargin(MEME, true, 1_000_000);
    }

    function test_removeMargin_wholeMarginInvalid() public {
        _openThreeX();
        vm.prank(alice);
        vm.expectRevert(PerpEngine.InvalidAmount.selector);
        engine.removeMargin(MEME, true, uint128(M_NET));
    }

    function test_addMargin_settlesPendingFunding() public {
        // 2000 at 6x: mNet 1988, notional 11928 (above the 10k skew floor), payout 17.9k
        // (inside the 25k per-address reserve share).
        open(alice, MEME, true, 2_000e6, 600);
        vm.warp(block.timestamp + 10 hours);
        (int256 fundingOwed, uint256 borrowOwed) = engine.pendingOwedOf(MEME, alice, true);
        assertGt(fundingOwed, 0, "long pays on positive skew");

        uint256 vaultBefore = usdg.balanceOf(address(vault));
        vm.prank(alice);
        engine.addMargin(MEME, true, 500e6);

        PerpTypes.Position memory p = posOf(MEME, alice, true);
        // Margin absorbed the settled funding + borrow; snapshots reset.
        assertEq(uint256(p.margin), 1_988e6 + 500e6 - uint256(fundingOwed) - borrowOwed);
        (int256 f2, uint256 b2) = engine.pendingOwedOf(MEME, alice, true);
        assertEq(f2, 0);
        assertEq(b2, 0);
        // The owed cash moved engine -> vault.
        assertEq(usdg.balanceOf(address(vault)), vaultBefore + uint256(fundingOwed) + borrowOwed);
        assertAggMatchesPositions(MEME);
    }

    function test_addMargin_marginCapStillEnforced() public {
        // Lower payout multiple so the 10k margin cap is reachable without first hitting
        // the per-address reserve share (9x payouts would trip that cap earlier).
        risk.setPayoutCapMultiple(2);
        open(alice, MEME, true, 9_000e6, 200);
        vm.prank(alice);
        vm.expectRevert(PerpEngine.PositionMarginCapExceeded.selector);
        engine.addMargin(MEME, true, 2_000e6); // would cross the 10k tier cap
    }
}
