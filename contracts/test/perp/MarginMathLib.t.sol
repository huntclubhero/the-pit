// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarginMathLib} from "../../src/perp/MarginMathLib.sol";

/// @notice Standalone unit + fuzz suite for MarginMathLib against an independent reference
///         model. USDG is 6 decimals throughout (usdgScale = 1e12).
contract MarginMathLibTest is Test {
    uint256 internal constant SCALE = 1e12; // 10 ** (18 minus 6)
    uint256 internal constant ONE = 1e18;

    // Fuzz domain bounds: realistic protocol magnitudes, far inside overflow territory.
    uint256 internal constant MAX_SIZE = 1e33; // 1e15 base tokens at 1e18
    uint256 internal constant MIN_PRICE = 1e6; // 1e-12 USDG per token
    uint256 internal constant MAX_PRICE = 1e24; // 1M USDG per token
    uint256 internal constant MAX_MARGIN = 1e15; // 1B USDG (6 dec)

    // ================================ notional / size ================================

    function test_notional_exactExample() public pure {
        // 2 tokens at 1.50 USDG each = 3 USDG = 3e6 units.
        assertEq(MarginMathLib.notionalUsdg(2e18, 15e17, SCALE), 3e6);
    }

    function test_sizeForNotional_roundTrip() public pure {
        // 100 USDG notional at price 0.25 = 400 tokens.
        uint256 size = MarginMathLib.sizeForNotional(100e6, 25e16, SCALE);
        assertEq(size, 400e18);
        assertEq(MarginMathLib.notionalUsdg(size, 25e16, SCALE), 100e6);
    }

    function testFuzz_sizeNotional_roundTripNeverGains(uint256 notional, uint256 price) public pure {
        notional = bound(notional, 1, 1e15);
        price = bound(price, MIN_PRICE, MAX_PRICE);
        uint256 size = MarginMathLib.sizeForNotional(notional, price, SCALE);
        uint256 back = MarginMathLib.notionalUsdg(size, price, SCALE);
        // Floor rounding in both directions can only lose dust, never mint value.
        assertLe(back, notional);
        assertGe(back + 2, notional); // at most 1 unit lost per floor step
    }

    function test_sizeForNotional_zeroPriceReverts() public {
        vm.expectRevert(MarginMathLib.ZeroPrice.selector);
        this.sizeForNotionalExternal(1e6, 0);
    }

    function sizeForNotionalExternal(uint256 n, uint256 p) external pure returns (uint256) {
        return MarginMathLib.sizeForNotional(n, p, SCALE);
    }

    // ================================ uPnL ================================

    function test_uPnl_longProfit() public pure {
        // 10 tokens, entry 1.00, mark 1.25: long +2.5 USDG, short minus 2.5.
        assertEq(MarginMathLib.uPnlUsdg(10e18, 1e18, 125e16, true, SCALE), int256(25e5));
        assertEq(MarginMathLib.uPnlUsdg(10e18, 1e18, 125e16, false, SCALE), -int256(25e5));
    }

    function test_uPnl_flatIsZero() public pure {
        assertEq(MarginMathLib.uPnlUsdg(10e18, 1e18, 1e18, true, SCALE), 0);
        assertEq(MarginMathLib.uPnlUsdg(10e18, 1e18, 1e18, false, SCALE), 0);
    }

    function testFuzz_uPnl_antiSymmetricAcrossSides(uint256 size, uint256 entry, uint256 mark) public pure {
        size = bound(size, 1, MAX_SIZE);
        entry = bound(entry, MIN_PRICE, MAX_PRICE);
        mark = bound(mark, MIN_PRICE, MAX_PRICE);
        int256 longPnl = MarginMathLib.uPnlUsdg(size, entry, mark, true, SCALE);
        int256 shortPnl = MarginMathLib.uPnlUsdg(size, entry, mark, false, SCALE);
        assertEq(longPnl, -shortPnl);
    }

    function testFuzz_uPnl_matchesReference(uint256 size, uint256 entry, uint256 mark) public pure {
        size = bound(size, 1, MAX_SIZE);
        entry = bound(entry, MIN_PRICE, MAX_PRICE);
        mark = bound(mark, MIN_PRICE, MAX_PRICE);
        int256 got = MarginMathLib.uPnlUsdg(size, entry, mark, true, SCALE);
        // Reference: signed full-precision computation.
        int256 expected;
        if (mark >= entry) {
            expected = int256(size * (mark - entry) / (ONE * SCALE));
        } else {
            expected = -int256(size * (entry - mark) / (ONE * SCALE));
        }
        assertEq(got, expected);
    }

    // ================================ clamp ================================

    function test_clampPnl_bounds() public pure {
        assertEq(MarginMathLib.clampPnl(int256(100), 50, 80), int256(80)); // win capped at maxPayout
        assertEq(MarginMathLib.clampPnl(-int256(100), 50, 80), -int256(50)); // loss capped at margin
        assertEq(MarginMathLib.clampPnl(int256(70), 50, 80), int256(70)); // inside band untouched
        assertEq(MarginMathLib.clampPnl(-int256(30), 50, 80), -int256(30));
        assertEq(MarginMathLib.clampPnl(0, 0, 0), 0);
    }

    function testFuzz_clampPnl_alwaysInsideBand(int256 pnl, uint256 margin, uint256 maxPayout) public pure {
        pnl = bound(pnl, type(int128).min, type(int128).max);
        margin = bound(margin, 0, MAX_MARGIN);
        maxPayout = bound(maxPayout, 0, 15 * MAX_MARGIN);
        int256 clamped = MarginMathLib.clampPnl(pnl, margin, maxPayout);
        assertGe(clamped, -int256(margin));
        assertLe(clamped, int256(maxPayout));
        // Identity inside the band.
        if (pnl >= -int256(margin) && pnl <= int256(maxPayout)) assertEq(clamped, pnl);
    }

    // ================================ equity ================================

    function testFuzz_equity_linearInComponents(uint256 margin, int256 pnl, int256 funding, uint256 borrowFee)
        public
        pure
    {
        margin = bound(margin, 0, MAX_MARGIN);
        pnl = bound(pnl, -int256(MAX_MARGIN), int256(15 * MAX_MARGIN));
        funding = bound(funding, -int256(MAX_MARGIN), int256(MAX_MARGIN));
        borrowFee = bound(borrowFee, 0, MAX_MARGIN);
        int256 eq = MarginMathLib.equityUsdg(margin, pnl, funding, borrowFee);
        assertEq(eq, int256(margin) + pnl - funding - int256(borrowFee));
    }

    // ================================ margin requirements ================================

    function test_maintenanceMargin_example() public pure {
        // 100 tokens at 2.00 = 200 USDG notional; 10% MMR = 20 USDG.
        assertEq(MarginMathLib.maintenanceMarginUsdg(100e18, 2e18, 1000, SCALE), 20e6);
    }

    function test_initialMargin_roundsUp() public pure {
        // 100 USDG notional at 6x max leverage: 100/6 = 16.666667 rounded up.
        uint256 im = MarginMathLib.initialMarginUsdg(100e18, 1e18, 600, SCALE);
        assertEq(im, 16_666_667);
    }

    function testFuzz_initialMargin_geNotionalOverLeverage(uint256 size, uint256 mark, uint32 lev) public pure {
        size = bound(size, 1, MAX_SIZE);
        mark = bound(mark, MIN_PRICE, MAX_PRICE);
        lev = uint32(bound(lev, 110, 1500));
        uint256 notional = MarginMathLib.notionalUsdg(size, mark, SCALE);
        uint256 im = MarginMathLib.initialMarginUsdg(size, mark, lev, SCALE);
        // Ceil rounding: im * lev / 100 >= notional.
        assertGe(im * lev / 100 + 1, notional);
    }

    // ================================ liquidation price ================================

    /// @dev Reference equity check at a hypothetical price, mirroring spec 1.7 directly.
    function _equityAt(uint256 size, uint256 entry, uint256 margin, int256 owed, uint256 price, bool isLong)
        internal
        pure
        returns (int256)
    {
        int256 pnl = MarginMathLib.uPnlUsdg(size, entry, price, isLong, SCALE);
        // Spec 1.7 uses UNCLAMPED PnL in the trigger inequality; the clamp only binds the
        // realized settlement. Using unclamped here matches the closed form.
        return int256(margin) + pnl - owed;
    }

    function _mm(uint256 size, uint256 price, uint16 mmrBps) internal pure returns (int256) {
        return int256(MarginMathLib.maintenanceMarginUsdg(size, price, mmrBps, SCALE));
    }

    function test_liqPrice_longExample() public pure {
        // Long 600 tokens at 1.00, margin 100 USDG (6x), MMR 10%, no funding.
        // P_liq = (600 minus 100) / (600 * 0.9) = 0.9259...
        uint256 pLiq = MarginMathLib.liquidationPrice1e18(600e18, 1e18, 100e6, 0, 1000, true, SCALE);
        assertApproxEqRel(pLiq, 925_925_925_925_925_925, 1e6);
    }

    function test_liqPrice_shortExample() public pure {
        // Short 600 tokens at 1.00, margin 100 USDG, MMR 10%.
        // P_liq = (600 + 100) / (600 * 1.1) = 1.0606...
        uint256 pLiq = MarginMathLib.liquidationPrice1e18(600e18, 1e18, 100e6, 0, 1000, false, SCALE);
        assertApproxEqRel(pLiq, 1_060_606_060_606_060_606, 1e6);
    }

    function test_liqPrice_zeroSizeIsZero() public pure {
        assertEq(MarginMathLib.liquidationPrice1e18(0, 1e18, 100e6, 0, 1000, true, SCALE), 0);
    }

    function test_liqPrice_overMarginedLongIsZero() public pure {
        // Margin exceeds full notional: no positive price can liquidate the long.
        uint256 pLiq = MarginMathLib.liquidationPrice1e18(100e18, 1e18, 200e6, 0, 500, true, SCALE);
        assertEq(pLiq, 0);
    }

    function testFuzz_liqPrice_longBoundaryExact(uint256 size, uint256 entry, uint256 margin, uint256 owedRaw)
        public
        pure
    {
        size = bound(size, 1e18, MAX_SIZE);
        entry = bound(entry, MIN_PRICE, MAX_PRICE);
        margin = bound(margin, 1e6, MAX_MARGIN);
        uint16 mmrBps = 1000;
        int256 owed = bound(int256(owedRaw), -int256(margin / 2), int256(margin / 2));
        uint256 pLiq = MarginMathLib.liquidationPrice1e18(size, entry, margin, owed, mmrBps, true, SCALE);
        if (pLiq == 0) {
            // Closed form says no adverse-direction liquidation price exists: equity at a
            // near-zero price must still clear maintenance.
            assertGe(_equityAt(size, entry, margin, owed, 1, true), _mm(size, 1, mmrBps));
            return;
        }
        // Step large enough to move equity by several whole USDG units past all floor dust:
        // a price move dP changes long equity by ~ size * dP / 1e30 USDG units.
        uint256 tick = pLiq / 1e6 + (4 * ONE * SCALE) / size + 2;
        // Just below the boundary: liquidatable.
        if (pLiq > tick) {
            assertLt(_equityAt(size, entry, margin, owed, pLiq - tick, true), _mm(size, pLiq - tick, mmrBps));
        }
        // Just above the boundary: safe.
        assertGe(_equityAt(size, entry, margin, owed, pLiq + tick, true), _mm(size, pLiq + tick, mmrBps));
    }

    function testFuzz_liqPrice_shortBoundaryExact(uint256 size, uint256 entry, uint256 margin, uint256 owedRaw)
        public
        pure
    {
        size = bound(size, 1e18, MAX_SIZE);
        entry = bound(entry, MIN_PRICE, MAX_PRICE);
        margin = bound(margin, 1e6, MAX_MARGIN);
        uint16 mmrBps = 800;
        int256 owed = bound(int256(owedRaw), -int256(margin / 2), int256(margin / 2));
        uint256 pLiq = MarginMathLib.liquidationPrice1e18(size, entry, margin, owed, mmrBps, false, SCALE);
        if (pLiq == 0) return; // short liquidatable at (or from) any positive price
        uint256 tick = pLiq / 1e6 + (4 * ONE * SCALE) / size + 2;
        // Just above the boundary: liquidatable (short loses as price rises).
        assertLt(_equityAt(size, entry, margin, owed, pLiq + tick, false), _mm(size, pLiq + tick, mmrBps));
        // Just below the boundary: safe.
        if (pLiq > tick) {
            assertGe(_equityAt(size, entry, margin, owed, pLiq - tick, false), _mm(size, pLiq - tick, mmrBps));
        }
    }

    function testFuzz_liqPrice_fundingDragPullsLongBoundaryUp(uint256 size, uint256 margin) public pure {
        size = bound(size, 1e18, MAX_SIZE);
        margin = bound(margin, 10e6, MAX_MARGIN);
        uint256 entry = 1e18;
        uint256 base = MarginMathLib.liquidationPrice1e18(size, entry, margin, 0, 1000, true, SCALE);
        uint256 dragged = MarginMathLib.liquidationPrice1e18(size, entry, margin, int256(margin / 4), 1000, true, SCALE);
        // Accruing owed funding moves the long liquidation price toward entry (up).
        assertGe(dragged, base);
    }

    // ================================ weighted entry ================================

    function test_weightedEntry_simpleAverage() public pure {
        assertEq(MarginMathLib.weightedEntry1e18(10e18, 1e18, 10e18, 3e18), 2e18);
    }

    function testFuzz_weightedEntry_betweenInputs(uint256 s1, uint256 p1, uint256 s2, uint256 p2) public pure {
        s1 = bound(s1, 1, MAX_SIZE);
        s2 = bound(s2, 1, MAX_SIZE);
        p1 = bound(p1, MIN_PRICE, MAX_PRICE);
        p2 = bound(p2, MIN_PRICE, MAX_PRICE);
        uint256 w = MarginMathLib.weightedEntry1e18(s1, p1, s2, p2);
        uint256 lo = p1 < p2 ? p1 : p2;
        uint256 hi = p1 > p2 ? p1 : p2;
        assertGe(w + 1, lo); // floor rounding may dip 1 wei below the exact average floor
        assertLe(w, hi);
    }
}
