// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpEngineBase} from "./PerpEngineBase.t.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";

/// @notice Open / increase / close / reduce lifecycle: exact settlement math, the payout
///         clamp, fee routing (economics v2: 25/10/vault 20/25/20), points hooks, and
///         wei-exact conservation.
contract PerpEngineTradeTest is PerpEngineBase {
    // Fixture: alice long MEME, margin 1000 USDG at 6x, P0 = 1.00.
    // openFee = 6000 * 10bps = 6 USDG; mNet = 994; size = 5964e18; maxPayout = 8946.
    uint128 internal constant MARGIN = 1_000e6;
    uint32 internal constant LEV = 600;
    uint256 internal constant M_NET = 994e6;
    uint256 internal constant SIZE = 5_964e18;
    uint256 internal constant MAX_PAYOUT = 8_946e6;
    uint256 internal constant OPEN_FEE = 6e6;

    function test_open_positionStateExact() public {
        uint256 aliceBefore = usdg.balanceOf(alice);
        bytes32 key = open(alice, MEME, true, MARGIN, LEV);
        PerpTypes.Position memory p = posOf(MEME, alice, true);
        assertEq(p.trader, alice);
        assertEq(p.token, MEME);
        assertTrue(p.isLong);
        assertEq(p.size1e18, SIZE);
        assertEq(p.margin, M_NET);
        assertEq(p.entryPrice1e18, 1e18);
        assertEq(p.maxPayout, MAX_PAYOUT);
        assertEq(usdg.balanceOf(alice), aliceBefore - MARGIN);
        assertEq(usdg.balanceOf(address(engine)), M_NET);
        assertEq(vault.reservedOf(MEME), MAX_PAYOUT);
        assertEq(engine.addressReserved(MEME, alice), MAX_PAYOUT);
        assertEq(key, engine.positionKeyFor(MEME, alice, true));
        assertAggMatchesPositions(MEME);
    }

    function test_open_feeSplitExact() public {
        uint256 vaultBefore = usdg.balanceOf(address(vault));
        open(alice, MEME, true, MARGIN, LEV);
        // 6 USDG fee, economics v2 immutable split: 25% jackpot, 10% referral, 20% VAULT,
        // 25% buyback, 20% + dust treasury. The five legs sum to the fee, wei-exact.
        assertEq(usdg.balanceOf(jackpot), 1_500_000);
        assertEq(usdg.balanceOf(referral), 600_000);
        assertEq(usdg.balanceOf(address(vault)) - vaultBefore, 1_200_000, "vault fee leg");
        assertEq(vault.cumulativeFeeRevenue(), 1_200_000, "vault fee counter");
        assertEq(usdg.balanceOf(buyback), 1_500_000);
        assertEq(usdg.balanceOf(treasury), 1_200_000);
        assertEq(
            uint256(1_500_000) + 600_000 + 1_200_000 + 1_500_000 + 1_200_000, OPEN_FEE, "legs sum to the fee"
        );
    }

    function test_open_pointsHookCalled() public {
        open(alice, MEME, true, MARGIN, LEV);
        assertEq(points.onFillCalls(), 1);
    }

    function test_open_pointsRevertNeverBlocks() public {
        points.setRevertOnCall(true);
        bytes32 key = open(alice, MEME, true, MARGIN, LEV);
        assertEq(uint256(key), uint256(engine.positionKeyFor(MEME, alice, true)));
        assertEq(points.onFillCalls(), 0);
    }

    function test_open_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(PerpEngine.NotListed.selector);
        engine.openPosition(address(0xDEAD), true, MARGIN, LEV);
        vm.expectRevert(PerpEngine.MarginTooSmall.selector);
        engine.openPosition(MEME, true, 9e6, LEV); // below 10 USDG minMargin
        vm.expectRevert(PerpEngine.LeverageOutOfRange.selector);
        engine.openPosition(MEME, true, MARGIN, 100); // below 1.1x
        vm.expectRevert(PerpEngine.LeverageOutOfRange.selector);
        engine.openPosition(MEME, true, MARGIN, 601); // above tier cap
        engine.openPosition(MEME, true, MARGIN, LEV);
        vm.expectRevert(PerpEngine.PositionExists.selector);
        engine.openPosition(MEME, true, MARGIN, LEV);
        vm.stopPrank();
    }

    function test_open_positionMarginCap() public {
        vm.prank(alice);
        vm.expectRevert(PerpEngine.PositionMarginCapExceeded.selector);
        engine.openPosition(MEME, true, 10_100e6, 200); // net margin above the 10k cap
    }

    function test_close_profit_exactSettlement() public {
        open(alice, MEME, true, MARGIN, LEV);
        uint256 sysBefore = systemBalance();
        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 vaultBefore = usdg.balanceOf(address(vault));
        oracle.setLive(MEME, 12e17); // +20%

        vm.prank(alice);
        engine.closePosition(MEME, true);

        // pnl = 5964 * 0.2 = 1192.8; closedNotional = 7156.8; fee = 7.1568.
        uint256 expectedNet = M_NET + 1_192_800_000 - 7_156_800;
        assertEq(usdg.balanceOf(alice), aliceBefore + expectedNet);
        assertEq(vault.settledWinTotal(), 1_192_800_000);
        // The vault paid the win but collected its 20% share of the 7.1568 close fee.
        assertEq(usdg.balanceOf(address(vault)), vaultBefore - 1_192_800_000 + 1_431_360);
        assertEq(vault.reservedOf(MEME), 0);
        assertEq(usdg.balanceOf(address(engine)), 0);
        assertEq(posOf(MEME, alice, true).size1e18, 0);
        assertEq(systemBalance(), sysBefore, "conservation");
        assertAggMatchesPositions(MEME);
    }

    function test_close_loss_exactSettlement() public {
        open(alice, MEME, true, MARGIN, LEV);
        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 vaultBefore = usdg.balanceOf(address(vault));
        oracle.setLive(MEME, 9e17); // minus 10%

        vm.prank(alice);
        engine.closePosition(MEME, true);

        // pnl = minus 596.4; pot = 397.6; closedNotional = 5367.6; fee = 5.3676.
        assertEq(usdg.balanceOf(alice), aliceBefore + 397_600_000 - 5_367_600);
        assertEq(vault.settledLossTotal(), 596_400_000);
        // Loss pulled in plus the vault's 20% share of the 5.3676 close fee.
        assertEq(usdg.balanceOf(address(vault)), vaultBefore + 596_400_000 + 1_073_520);
        assertEq(usdg.balanceOf(address(engine)), 0);
        assertAggMatchesPositions(MEME);
    }

    function test_close_winClampedAtMaxPayout() public {
        open(alice, MEME, true, MARGIN, LEV);
        uint256 aliceBefore = usdg.balanceOf(alice);
        oracle.setLive(MEME, 3e18); // +200%: raw pnl 11928 > maxPayout 8946

        vm.prank(alice);
        engine.closePosition(MEME, true);

        // closedNotional = 17892; fee = 17.892; net = 994 + 8946 minus 17.892.
        assertEq(usdg.balanceOf(alice), aliceBefore + M_NET + MAX_PAYOUT - 17_892_000);
        assertEq(vault.settledWinTotal(), MAX_PAYOUT);
    }

    function test_close_lossClampedAtMargin() public {
        open(alice, MEME, true, MARGIN, LEV);
        uint256 aliceBefore = usdg.balanceOf(alice);
        oracle.setLive(MEME, 5e17); // raw loss 2982 > margin 994

        vm.prank(alice);
        engine.closePosition(MEME, true);

        assertEq(usdg.balanceOf(alice), aliceBefore, "trader loses at most margin");
        assertEq(vault.settledLossTotal(), M_NET);
        assertEq(usdg.balanceOf(address(engine)), 0);
    }

    function test_close_shortMirrorsProfit() public {
        open(bob, MEME, false, MARGIN, LEV);
        uint256 bobBefore = usdg.balanceOf(bob);
        oracle.setLive(MEME, 8e17); // minus 20%: short profits 1192.8

        vm.prank(bob);
        engine.closePosition(MEME, false);

        // closedNotional = 5964 * 0.8 = 4771.2; fee = 4.7712.
        assertEq(usdg.balanceOf(bob), bobBefore + M_NET + 1_192_800_000 - 4_771_200);
    }

    function test_increase_weightedEntryExact() public {
        open(alice, MEME, true, MARGIN, LEV);
        oracle.setLive(MEME, 15e17);
        vm.prank(alice);
        engine.increasePosition(MEME, true, MARGIN, LEV);

        PerpTypes.Position memory p = posOf(MEME, alice, true);
        // added size = 5964 / 1.5 = 3976; entry = (5964 + 5964) / 9940 = 1.20 exactly.
        assertEq(p.size1e18, SIZE + 3_976e18);
        assertEq(p.entryPrice1e18, 12e17);
        assertEq(p.margin, 2 * M_NET);
        assertEq(p.maxPayout, 2 * MAX_PAYOUT);
        assertEq(vault.reservedOf(MEME), 2 * MAX_PAYOUT);
        assertAggMatchesPositions(MEME);
    }

    function test_increase_missingPositionReverts() public {
        vm.prank(alice);
        vm.expectRevert(PerpEngine.PositionMissing.selector);
        engine.increasePosition(MEME, true, MARGIN, LEV);
    }

    function test_reduce_halfExactSettlement() public {
        open(alice, MEME, true, MARGIN, LEV);
        uint256 aliceBefore = usdg.balanceOf(alice);
        oracle.setLive(MEME, 12e17);

        vm.prank(alice);
        engine.reducePosition(MEME, true, 5_000);

        PerpTypes.Position memory p = posOf(MEME, alice, true);
        assertEq(p.size1e18, SIZE / 2);
        // IM(2982 tokens at 1.2) = 3578.4 / 6 = 596.4: released margin capped at 397.6.
        assertEq(p.margin, 596_400_000);
        // maxPayout recomputed: 9 * 596.4 = 5367.6.
        assertEq(p.maxPayout, 5_367_600_000);
        assertEq(vault.reservedOf(MEME), 5_367_600_000);
        // trader: released 397.6 + realized 596.4 minus fee 3.5784.
        assertEq(usdg.balanceOf(alice), aliceBefore + 397_600_000 + 596_400_000 - 3_578_400);
        assertAggMatchesPositions(MEME);
    }

    function test_reduce_invalidFractions() public {
        open(alice, MEME, true, MARGIN, LEV);
        vm.startPrank(alice);
        vm.expectRevert(PerpEngine.InvalidFraction.selector);
        engine.reducePosition(MEME, true, 0);
        vm.expectRevert(PerpEngine.InvalidFraction.selector);
        engine.reducePosition(MEME, true, 10_000);
        vm.stopPrank();
    }

    function test_majorMarket_lowerFees() public {
        // 1000 USDG at 10x on MAJOR: intended notional 10_000, fee 5 bps = 5 USDG.
        open(alice, MAJOR, true, MARGIN, 1_000);
        PerpTypes.Position memory p = posOf(MAJOR, alice, true);
        assertEq(p.margin, 995e6);
        // size = 9950 USDG notional at 50k = 0.199 tokens.
        assertEq(p.size1e18, 199e15);
        assertAggMatchesPositions(MAJOR);
    }

    function test_lifecycle_conservationAcrossMixedFlows() public {
        uint256 sysBefore = systemBalance();
        open(alice, MEME, true, 2_000e6, 400);
        open(bob, MEME, false, 1_500e6, 300);
        oracle.setLive(MEME, 11e17);
        open(carol, MEME, false, 800e6, 200);
        vm.prank(alice);
        engine.reducePosition(MEME, true, 3_000);
        oracle.setLive(MEME, 95e16);
        vm.prank(bob);
        engine.closePosition(MEME, false);
        vm.prank(alice);
        engine.closePosition(MEME, true);
        vm.prank(carol);
        engine.closePosition(MEME, false);
        assertEq(systemBalance(), sysBefore, "wei-exact conservation across mixed flows");
        assertEq(usdg.balanceOf(address(engine)), 0, "engine fully unwound");
        assertEq(vault.reservedOf(MEME), 0);
        assertAggMatchesPositions(MEME);
    }
}
