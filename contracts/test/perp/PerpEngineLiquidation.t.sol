// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpEngineBase} from "./PerpEngineBase.t.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";

/// @notice Liquidation waterfall (spec 3.2/3.3, economics v2 split): penalty 20% keeper /
///         40% LP vault / 40% InsuranceFund plus dust, residual back to the trader, keeper
///         floor top-up, gap -> vault absorbs + IF.cover -> ADL at a profit haircut. All
///         wei-exact against the closed system.
contract PerpEngineLiquidationTest is PerpEngineBase {
    // alice long MEME 1000 at 6x: mNet 994, size 5964, entry 1.00, MMR 10%.
    // P_liq = (5964 minus 994) / (5964 * 0.9) = 0.92608...
    uint128 internal constant MARGIN = 1_000e6;
    uint32 internal constant LEV = 600;
    uint256 internal constant M_NET = 994e6;
    uint256 internal constant SIZE = 5_964e18;

    function _openAliceLong() internal returns (bytes32) {
        return open(alice, MEME, true, MARGIN, LEV);
    }

    function test_liquidate_notLiquidatableReverts() public {
        _openAliceLong();
        oracle.setLive(MEME, 93e16); // just above the boundary
        vm.prank(keeper);
        vm.expectRevert(PerpEngine.NotLiquidatable.selector);
        engine.liquidate(MEME, alice, true);
    }

    function test_liquidate_waterfallExact() public {
        _openAliceLong();
        uint256 sysBefore = systemBalance();
        oracle.setLive(MEME, 9e17); // pnl = minus 596.4; equity 397.6 < mm 536.76
        assertTrue(engine.liquidatable(MEME, alice, true));

        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 ifBefore = usdg.balanceOf(address(ifund));
        uint256 vaultBefore = usdg.balanceOf(address(vault));

        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        // notional at 0.9 = 5367.6; penalty = 1% = 53.676; keeper 20% = 10.7352;
        // vault 40% = 21.4704; IF 40% = 21.4704; residual = 397.6 minus 53.676 = 343.924.
        assertEq(usdg.balanceOf(keeper), 10_735_200, "keeper share");
        assertEq(usdg.balanceOf(address(ifund)), ifBefore + 21_470_400, "IF share");
        assertEq(usdg.balanceOf(alice), aliceBefore + 343_924_000, "residual to trader");
        assertEq(
            usdg.balanceOf(address(vault)),
            vaultBefore + 596_400_000 + 21_470_400,
            "vault got the loss plus its 40% penalty share"
        );
        assertEq(vault.cumulativeLiquidationRevenue(), 21_470_400, "liquidation revenue counted");
        // Conservation of the pot: keeper + vault + fund + residual == equity, wei-exact.
        assertEq(uint256(10_735_200) + 21_470_400 + 21_470_400 + 343_924_000, 397_600_000, "penalty split conserves");
        assertEq(posOf(MEME, alice, true).size1e18, 0, "position gone");
        assertEq(vault.reservedOf(MEME), 0, "reserve released");
        assertEq(usdg.balanceOf(address(engine)), 0, "engine fully unwound");
        assertEq(systemBalance(), sysBefore, "wei-exact conservation");
        assertAggMatchesPositions(MEME);
    }

    function test_liquidate_keeperFloorTopUp() public {
        // Tiny position: 20 USDG at 6x: mNet 19.88, notional 119.28. Deep drop: equity
        // small, penalty tiny: keeper share far below the 5 USDG floor: IF tops up.
        open(bob, MEME, true, 20e6, LEV);
        oracle.setLive(MEME, 9e17);
        vm.prank(keeper);
        engine.liquidate(MEME, bob, true);
        // Penalty = 1% of 107.352 = 1.07352; keeper cut 20% = 0.214704; floor tops to 5.
        assertEq(usdg.balanceOf(keeper), 5_000_000, "floor-topped keeper reward");
        assertEq(ifund.keeperFloorPaid(), 5_000_000 - 214_704);
    }

    function test_liquidate_emptyFundCannotBlockKeeperFloor() public {
        open(bob, MEME, true, 20e6, LEV);
        ifund.sweep(address(this)); // fund drained BEFORE the liquidation
        oracle.setLive(MEME, 9e17);
        vm.prank(keeper);
        engine.liquidate(MEME, bob, true);
        // The liquidation itself deposits the 40% penalty cut (0.429408) into the fund,
        // which then best-effort tops the keeper toward the floor with all it has:
        // keeper = 0.214704 share + 0.429408 partial floor = 0.644112, and never reverts.
        // The vault keeps its own 40% cut (0.429408) as LP revenue.
        assertEq(usdg.balanceOf(keeper), 214_704 + 429_408, "share plus partial floor");
        assertEq(ifund.keeperFloorPaid(), 429_408);
        assertEq(usdg.balanceOf(address(ifund)), 0);
        assertEq(vault.cumulativeLiquidationRevenue(), 429_408, "vault penalty cut intact");
    }

    function test_badDebt_fundCovers() public {
        // Bad debt needs funding drag: pnl is clamped at margin, so equity < 0 only via
        // funding/borrow. One-sided long at full skew, 30 days unpoked.
        open(alice, MEME, true, 2_000e6, 600); // notional 11928 > skew floor
        vm.warp(block.timestamp + 30 days);
        (int256 fundingOwed, uint256 borrowOwed) = engine.pendingOwedOf(MEME, alice, true);
        uint256 owed = uint256(fundingOwed) + borrowOwed;
        assertGt(owed, 1_988e6, "owed exceeds the whole margin");
        uint256 expectedShortfall = owed - 1_988e6;

        uint256 sysBefore = systemBalance();
        uint256 vaultBefore = usdg.balanceOf(address(vault));
        uint256 ifBefore = usdg.balanceOf(address(ifund));
        uint256 aliceBefore = usdg.balanceOf(alice);

        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        assertEq(ifund.coverCalls(), 1);
        assertEq(ifund.lastShortfall(), expectedShortfall);
        assertEq(ifund.totalCovered(), expectedShortfall, "IF fully covered");
        // Vault got the whole margin plus the IF cover: made whole at mark.
        assertEq(usdg.balanceOf(address(vault)), vaultBefore + 1_988e6 + expectedShortfall);
        // Fund paid the cover plus the full 5 USDG keeper floor (penalty was zero).
        assertEq(ifund.keeperFloorPaid(), 5e6);
        assertEq(usdg.balanceOf(address(ifund)), ifBefore - expectedShortfall - 5e6);
        assertEq(usdg.balanceOf(alice), aliceBefore, "trader gets nothing past margin");
        assertEq(systemBalance(), sysBefore, "conservation");
        assertAggMatchesPositions(MEME);
    }

    function test_badDebt_revertingFundCannotBlockLiquidation() public {
        open(alice, MEME, true, 2_000e6, 600);
        vm.warp(block.timestamp + 30 days);
        ifund.setRevertOnCall(true);
        vm.prank(keeper);
        engine.liquidate(MEME, alice, true); // cover + floor both best-effort
        assertEq(posOf(MEME, alice, true).size1e18, 0, "liquidation always executes");
    }

    function test_adl_haircutsOppositeWinnerExactly() public {
        // alice long (will go bankrupt via funding drag), bob short 500 at 2x (mNet 499,
        // size 998e18): the profitable opposite-side winner ADL must haircut.
        open(alice, MEME, true, 2_000e6, 600); // long OI 11928: pays funding
        open(bob, MEME, false, 500e6, 200);
        ifund.sweep(address(this)); // empty fund: forces ADL
        vm.warp(block.timestamp + 60 days); // massive funding drag on the net-long side
        oracle.setLive(MEME, 9e17); // shorts are in profit at minus 10%

        uint256 sysBefore = systemBalance();
        uint256 bobBefore = usdg.balanceOf(bob);
        uint256 jackpotBefore = usdg.balanceOf(jackpot);

        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        // Recompute everything from the FINAL indices (accrued at the 0.9 mark in-call).
        PerpTypes.MarketAggregates memory agg = aggOf(MEME);
        uint256 fX = uint256(int256(agg.fundingX1e18));
        uint256 bX = agg.borrowX1e18;
        // Bob (short, receiver): funding received = size * fX; borrow owed = size * bX.
        uint256 bobFundRecv = 998e18 * fX / 1e30;
        uint256 bobBor = 998e18 * bX / 1e30;
        uint256 bobPnl = 99_800_000; // 998 * 0.1 clamped profit
        // Alice's shortfall dwarfs bob's profit, so the haircut consumes ALL of it.
        uint256 aliceOwed = 11_928e18 * fX / 1e30 + 11_928e18 * bX / 1e30;
        uint256 shortfall = 1_192_800_000 + aliceOwed - 1_988e6;
        assertGt(shortfall, bobPnl, "fixture: shortfall exceeds victim profit");

        assertEq(posOf(MEME, bob, false).size1e18, 0, "victim force-closed");
        // Bob keeps margin + funding received minus borrow; profit fully haircut, NO fee.
        uint256 bobNet = 499e6 + bobFundRecv - bobBor;
        assertEq(usdg.balanceOf(bob), bobBefore + bobNet, "ADL settlement exact, no fee");
        assertEq(usdg.balanceOf(jackpot), jackpotBefore, "no fee on a forced ADL close");
        assertEq(systemBalance(), sysBefore, "conservation through ADL");
        assertEq(vault.reservedOf(MEME), 0);
        assertAggMatchesPositions(MEME);
    }

    function test_adl_skipsSameSideAndUnprofitable() public {
        open(alice, MEME, true, 2_000e6, 600); // bankrupt-to-be long
        open(carol, MEME, true, 300e6, 200); // same side: never ADL'd
        ifund.sweep(address(this));
        vm.warp(block.timestamp + 60 days);
        oracle.setLive(MEME, 98e16); // longs (carol) not profitable, no shorts to haircut

        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);
        // Carol untouched: same side positions are never ADL victims.
        assertGt(posOf(MEME, carol, true).size1e18, 0, "same-side position survives ADL");
        assertAggMatchesPositions(MEME);
    }

    function test_liquidate_clampedGapLossCannotCreateBadDebtWithoutFunding() public {
        // Pure price gap (no funding time): loss clamps at margin, equity floors at 0,
        // no shortfall, no IF call. The payout-cap discipline holds on the loss side too.
        _openAliceLong();
        oracle.setLive(MEME, 1e17); // catastrophic gap, same block
        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);
        assertEq(ifund.coverCalls(), 0, "no bad debt from a pure clamped gap");
        assertEq(vault.settledLossTotal(), M_NET);
    }

    // ============================ B3: winner never liquidatable ============================

    /// @notice A maximally-winning long past the payout cap must never be liquidatable: its
    ///         clamped equity is pinned at the cap while uncapped notional inflates mm, which
    ///         pre-fix let a keeper confiscate the capped payout (pa-liquidation F1).
    function test_liquidate_maximallyWinningLongNotLiquidatable() public {
        open(alice, MEME, true, 100e6, 600); // net 99.4, size 596.4e18, maxPayout 894.6
        oracle.setLive(MEME, 20e18); // 20x rally: clamped uPnL pinned at the 894.6 cap
        // Old code: mm = 10% * 596.4 * 20 = 1192.8 > clamped equity ~994 -> spuriously liquidatable.
        assertFalse(engine.liquidatable(MEME, alice, true), "a winning long must never be liquidatable");
        vm.prank(keeper);
        vm.expectRevert(PerpEngine.NotLiquidatable.selector);
        engine.liquidate(MEME, alice, true);
        // The trader can still close for the full capped payout.
        vm.prank(alice);
        engine.closePosition(MEME, true);
        assertEq(posOf(MEME, alice, true).size1e18, 0, "winner exits at the cap");
    }

    // ============================ B7: grandfathered MMR ============================

    /// @notice A permissionless refreshTier downgrade (higher MMR) must NOT retroactively tighten
    ///         maintenance on open positions: liquidation reads the entry MMR snapshot (spec 8.4).
    function test_grandfatherMmr_downgradeDoesNotRetroLiquidate() public {
        open(alice, MEME, true, 1_000e6, 600);
        assertEq(posOf(MEME, alice, true).entryMmrBps, 1_000, "MMR snapshot at open");
        // Governance / permissionless downgrade raises the tier MMR to 30%.
        PerpTypes.TierParams memory p = memeTierParams();
        p.mmrBps = 3_000;
        risk.setParams(MEME, p, 2);
        // At $0.93 the position is healthy under the grandfathered 10% but underwater under 30%.
        oracle.setLive(MEME, 93e16);
        assertFalse(engine.liquidatable(MEME, alice, true), "existing position grandfathered at entry MMR");
        vm.prank(keeper);
        vm.expectRevert(PerpEngine.NotLiquidatable.selector);
        engine.liquidate(MEME, alice, true);
        // A NEW open takes the current (downgraded) MMR; alice keeps her snapshot.
        open(bob, MEME, true, 1_000e6, 600);
        assertEq(posOf(MEME, bob, true).entryMmrBps, 3_000, "new opens use the current tier MMR");
        assertEq(posOf(MEME, alice, true).entryMmrBps, 1_000, "existing position keeps its snapshot");
    }

    // ============================ B6: ADL rework ============================

    /// @notice ADL ranks victims by (uPnL% * leverage): a small shortfall is fully absorbed by the
    ///         highest-score winner (carol, 6x), sparing the lower-score winner (bob, 2x). (B6c)
    function test_adl_ranksHighestScoreVictimFirst() public {
        // Crank funding + drop the skew floor so a modest dominant long bankrupts fast, yielding a
        // SMALL shortfall a single victim can absorb (so we can observe which victim ADL picks).
        PerpTypes.TierParams memory p = memeTierParams();
        p.kFPerHour1e18 = 1e18; // 100%/h at full skew
        risk.setParams(MEME, p, 2);
        engine.setSkewFloor(100e6);

        open(alice, MEME, true, 200e6, 600); // dominant long (OI 1192.8), the bad-debt source
        open(bob, MEME, false, 100e6, 200); // short 2x: LOW (uPnL% * leverage)
        open(carol, MEME, false, 100e6, 600); // short 6x: HIGH score
        ifund.sweep(address(this)); // empty fund forces ADL
        vm.warp(block.timestamp + 2 hours);
        oracle.setLive(MEME, 5e17); // deep drop: both shorts are big winners

        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        assertEq(posOf(MEME, carol, false).size1e18, 0, "highest-score victim deleveraged first");
        assertGt(posOf(MEME, bob, false).size1e18, 0, "lower-score victim spared");
        assertAggMatchesPositions(MEME);
    }

    /// @notice ADL bounds on VICTIMS FOUND, not total keys scanned: 32 same-side dust sybils
    ///         occupying low set indices can no longer starve ADL of the real opposite-side winner
    ///         sitting past index 32 (pa-margin-adl F2 / pa-dos M2). (B6b)
    function test_adl_victimBoundNotStarvedBySybilPadding() public {
        // 32 same-side dust longs FIRST (they take set indices 0..31), then the real short victim,
        // then alice LAST (so liquidating her pops the tail and leaves carol at index 32).
        for (uint256 i = 0; i < 32; i++) {
            address s = address(uint160(uint256(0x5B11000) + i));
            usdg.mint(s, 100e6);
            vm.prank(s);
            usdg.approve(address(engine), type(uint256).max);
            open(s, MEME, true, 10e6, 600); // minMargin dust longs (same side as alice)
        }
        open(carol, MEME, false, 500e6, 600); // the real opposite-side winner, at index 32
        open(alice, MEME, true, 2_000e6, 600); // dominant long (bad-debt source), inserted last

        ifund.sweep(address(this));
        vm.warp(block.timestamp + 60 days);
        oracle.setLive(MEME, 9e17); // shorts profit

        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        // Old code: 32 same-side skips exhaust the 32 budget, carol never reached, bad debt eaten.
        // (The 32 dust longs remain open, so assertAggMatchesPositions -- which only sums the four
        // named traders -- does not apply here; the point is that the far-indexed victim is hit.)
        assertEq(posOf(MEME, carol, false).size1e18, 0, "real victim reached past 32 sybil skips");
    }

    function test_liquidationPrice_viewMatchesTrigger() public {
        _openAliceLong();
        uint256 pLiq = engine.liquidationPrice(MEME, alice, true);
        // (5964 minus 994) / (5964 * 0.9) = 4970 / 5367.6 = 25/27 exactly.
        assertEq(pLiq, uint256(25e18) / 27);
        oracle.setLive(MEME, pLiq + 1e15);
        assertFalse(engine.liquidatable(MEME, alice, true));
        oracle.setLive(MEME, pLiq - 1e15);
        assertTrue(engine.liquidatable(MEME, alice, true));
    }
}
