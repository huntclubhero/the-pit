// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {UniV3TwapLib} from "../../src/oracle/UniV3TwapLib.sol";
import {TickMath} from "../../src/oracle/vendor/TickMath.sol";
import {FullMath} from "../../src/oracle/vendor/FullMath.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";

/// @dev External wrapper so the library's internal try/catch on pool.observe is exercised
///      through real external calls.
contract TwapHarness {
    function readTwap(address pool, uint32 window, bool quoteIsToken0)
        external
        view
        returns (uint256 price1e18, bool ok)
    {
        return UniV3TwapLib.readTwap(IUniswapV3Pool(pool), window, quoteIsToken0);
    }

    function quoteAtTick(int24 tick, bool quoteIsToken0) external pure returns (uint256) {
        return UniV3TwapLib.quoteAtTick(tick, quoteIsToken0);
    }

    function consultMeanLiquidity(address pool, uint32 window) external view returns (uint256 meanLiquidity, bool ok) {
        return UniV3TwapLib.consultMeanLiquidity(IUniswapV3Pool(pool), window);
    }
}

contract UniV3TwapLibTest is Test {
    uint32 internal constant WINDOW = 600;

    TwapHarness internal harness;
    MockV3Pool internal pool;

    function setUp() public {
        harness = new TwapHarness();
        pool = new MockV3Pool();
    }

    function _setDelta(int56 delta) internal {
        pool.setTickCumulative(WINDOW, 0);
        pool.setTickCumulative(0, delta);
    }

    // ===============================================================
    // Vendored TickMath sanity (validates the 0.8 port transcription)
    // ===============================================================

    function test_vendoredTickMath_boundaryConstants() public pure {
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK), TickMath.MIN_SQRT_RATIO);
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK), TickMath.MAX_SQRT_RATIO);
        // Tick zero is exactly 2^96.
        assertEq(TickMath.getSqrtRatioAtTick(0), uint160(1) << 96);
    }

    function testFuzz_vendoredTickMath_roundtrip(int256 tickSeed) public pure {
        int24 tick = int24(bound(tickSeed, int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK)));
        uint160 sqrtRatio = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatio < TickMath.MAX_SQRT_RATIO) {
            assertEq(TickMath.getTickAtSqrtRatio(sqrtRatio), tick);
        }
    }

    // ===============================================================
    // TWAP correctness
    // ===============================================================

    function test_tickZero_exactlyOne_bothOrientations() public {
        _setDelta(0);
        (uint256 pToken0Quote, bool ok0) = harness.readTwap(address(pool), WINDOW, true);
        (uint256 pToken1Quote, bool ok1) = harness.readTwap(address(pool), WINDOW, false);
        assertTrue(ok0);
        assertTrue(ok1);
        assertEq(pToken0Quote, 1e18);
        assertEq(pToken1Quote, 1e18);
    }

    function test_meanTick6000_exactExpected_bothOrientations() public {
        // delta / window = 6000 exactly.
        _setDelta(int56(6000) * int56(uint56(WINDOW)));

        uint160 sqrtRatio = TickMath.getSqrtRatioAtTick(6000);
        uint256 ratioX192 = uint256(sqrtRatio) * sqrtRatio;
        uint256 expectedQuoteIsToken1 = FullMath.mulDiv(ratioX192, 1e18, uint256(1) << 192);
        uint256 expectedQuoteIsToken0 = FullMath.mulDiv(uint256(1) << 192, 1e18, ratioX192);

        (uint256 p1, bool ok1) = harness.readTwap(address(pool), WINDOW, false);
        (uint256 p0, bool ok0) = harness.readTwap(address(pool), WINDOW, true);
        assertTrue(ok1);
        assertTrue(ok0);
        assertEq(p1, expectedQuoteIsToken1);
        assertEq(p0, expectedQuoteIsToken0);
        // Orientation flip must invert the price direction.
        assertGt(p1, 1e18);
        assertLt(p0, 1e18);
    }

    function test_meanTick6931_approxDouble() public {
        _setDelta(int56(6931) * int56(uint56(WINDOW)));
        (uint256 p, bool ok) = harness.readTwap(address(pool), WINDOW, false);
        assertTrue(ok);
        // 1.0001^6931 is approximately 2.0; allow 0.02 percent.
        assertApproxEqRel(p, 2e18, 2e14);
    }

    function test_negativeDelta_notDivisible_roundsTowardNegativeInfinity() public {
        // delta = -601 over a 600s window: truncation gives -1, Uniswap semantics require -2.
        _setDelta(-601);
        (uint256 p, bool ok) = harness.readTwap(address(pool), WINDOW, false);
        assertTrue(ok);
        assertEq(p, harness.quoteAtTick(-2, false));
        assertTrue(p != harness.quoteAtTick(-1, false));
    }

    function test_negativeDelta_divisible_noExtraDecrement() public {
        _setDelta(-1200);
        (uint256 p, bool ok) = harness.readTwap(address(pool), WINDOW, false);
        assertTrue(ok);
        assertEq(p, harness.quoteAtTick(-2, false));
    }

    function test_positiveDelta_notDivisible_truncates() public {
        _setDelta(601);
        (uint256 p, bool ok) = harness.readTwap(address(pool), WINDOW, false);
        assertTrue(ok);
        assertEq(p, harness.quoteAtTick(1, false));
    }

    function test_nonzeroBaseCumulative_sameResult() public {
        // The absolute cumulative values must not matter, only the delta.
        pool.setTickCumulative(WINDOW, 1_000_000);
        pool.setTickCumulative(0, 1_000_000 + int56(120) * int56(uint56(WINDOW)));
        (uint256 p, bool ok) = harness.readTwap(address(pool), WINDOW, false);
        assertTrue(ok);
        assertEq(p, harness.quoteAtTick(120, false));
    }

    // ===============================================================
    // Failure paths
    // ===============================================================

    function test_windowTooYoung_okFalse() public {
        _setDelta(0);
        pool.setRevertOnObserve(true);
        (uint256 p, bool ok) = harness.readTwap(address(pool), WINDOW, false);
        assertFalse(ok);
        assertEq(p, 0);
    }

    function test_zeroWindow_okFalse() public {
        _setDelta(0);
        (uint256 p, bool ok) = harness.readTwap(address(pool), 0, false);
        assertFalse(ok);
        assertEq(p, 0);
    }

    // ===============================================================
    // consultMeanLiquidity (time-averaged in-range liquidity)
    // ===============================================================

    /// @dev Program the accumulator so the harmonic mean over the window equals `targetL`,
    ///      returning the exact value the library computes.
    function _setMeanLiquidity(uint256 targetL) internal returns (uint256 expected) {
        uint256 delta = FullMath.mulDiv(WINDOW, uint256(1) << 128, targetL);
        pool.setSecondsPerLiquidityCumulative(WINDOW, 0);
        pool.setSecondsPerLiquidityCumulative(0, uint160(delta));
        expected = FullMath.mulDiv(WINDOW, uint256(1) << 128, delta);
    }

    function test_consultMeanLiquidity_returnsHarmonicMean() public {
        uint256 expected = _setMeanLiquidity(1_000_000);
        (uint256 meanL, bool ok) = harness.consultMeanLiquidity(address(pool), WINDOW);
        assertTrue(ok);
        assertEq(meanL, expected);
    }

    function test_consultMeanLiquidity_ignoresInstantaneousLiquidity() public {
        // The instantaneous pool.liquidity() is deliberately different from the averaged value:
        // the read must key off the accumulator, not the spot liquidity.
        uint256 expected = _setMeanLiquidity(2_000_000);
        pool.setLiquidity(type(uint128).max);
        (uint256 meanL, bool ok) = harness.consultMeanLiquidity(address(pool), WINDOW);
        assertTrue(ok);
        assertEq(meanL, expected);
    }

    function test_consultMeanLiquidity_zeroDelta_okFalse() public {
        pool.setSecondsPerLiquidityCumulative(WINDOW, 0);
        pool.setSecondsPerLiquidityCumulative(0, 0);
        (uint256 meanL, bool ok) = harness.consultMeanLiquidity(address(pool), WINDOW);
        assertFalse(ok);
        assertEq(meanL, 0);
    }

    function test_consultMeanLiquidity_zeroWindow_okFalse() public view {
        (uint256 meanL, bool ok) = harness.consultMeanLiquidity(address(pool), 0);
        assertFalse(ok);
        assertEq(meanL, 0);
    }

    function test_consultMeanLiquidity_observeReverts_okFalse() public {
        _setMeanLiquidity(1_000_000);
        pool.setRevertOnObserve(true);
        (uint256 meanL, bool ok) = harness.consultMeanLiquidity(address(pool), WINDOW);
        assertFalse(ok);
        assertEq(meanL, 0);
    }
}
