// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {CrossPoolTwapAdapter} from "../../src/oracle/adapters/CrossPoolTwapAdapter.sol";
import {UniV3TwapLib} from "../../src/oracle/UniV3TwapLib.sol";
import {FullMath} from "../../src/oracle/vendor/FullMath.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";

contract CrossPoolTwapAdapterTest is Test {
    address internal constant TOKEN = address(0xBEEF);
    uint32 internal constant WINDOW = 600;

    CrossPoolTwapAdapter internal adapter;
    MockV3Pool internal poolA;
    MockV3Pool internal poolB;

    function setUp() public {
        adapter = new CrossPoolTwapAdapter(address(this));
        poolA = new MockV3Pool();
        poolB = new MockV3Pool();
    }

    function _setMeanTick(MockV3Pool pool, int56 meanTick) internal {
        pool.setTickCumulative(WINDOW, 0);
        pool.setTickCumulative(0, meanTick * int56(uint56(WINDOW)));
    }

    /// @dev Program a pool's secondsPerLiquidityCumulativeX128 accumulator so the adapter's
    ///      time-averaged in-range liquidity read (window * 2^128 / delta) yields a positive
    ///      weight, and return the EXACT mean the adapter will compute (so expectations match the
    ///      double-flooring precisely). A larger targetL produces a larger weight.
    function _setMeanLiquidity(MockV3Pool pool, uint256 targetL) internal returns (uint256 meanL) {
        uint256 delta = FullMath.mulDiv(WINDOW, uint256(1) << 128, targetL);
        pool.setSecondsPerLiquidityCumulative(WINDOW, 0);
        pool.setSecondsPerLiquidityCumulative(0, uint160(delta));
        meanL = FullMath.mulDiv(WINDOW, uint256(1) << 128, delta);
    }

    /// @dev Sets the same mean-tick TWAP inputs and time-averaged-liquidity weights on both pools,
    ///      then registers them. Returns the exact weights the adapter will use.
    function _register(uint256 targetLiqA, uint256 targetLiqB) internal returns (uint256 wA, uint256 wB) {
        wA = _setMeanLiquidity(poolA, targetLiqA);
        wB = _setMeanLiquidity(poolB, targetLiqB);
        CrossPoolTwapAdapter.PoolConfig[] memory pools = new CrossPoolTwapAdapter.PoolConfig[](2);
        pools[0] = CrossPoolTwapAdapter.PoolConfig({pool: IUniswapV3Pool(address(poolA)), quoteIsToken0: false});
        pools[1] = CrossPoolTwapAdapter.PoolConfig({pool: IUniswapV3Pool(address(poolB)), quoteIsToken0: false});
        adapter.setPools(TOKEN, pools, WINDOW);
    }

    function test_twoPools_liquidityWeightedAverage() public {
        // Pool A at tick 0 (price exactly 1e18) with the smaller weight.
        // Pool B at tick 6931 (price about 2e18) with roughly triple the weight.
        _setMeanTick(poolA, 0);
        _setMeanTick(poolB, 6931);
        (uint256 wA, uint256 wB) = _register(1000, 3000);

        uint256 pA = UniV3TwapLib.quoteAtTick(0, false);
        uint256 pB = UniV3TwapLib.quoteAtTick(6931, false);
        uint256 expected = FullMath.mulDiv(pA, wA, wA + wB) + FullMath.mulDiv(pB, wB, wA + wB);

        (uint256 p, uint256 at, bool ok) = adapter.read(TOKEN);
        assertTrue(ok);
        assertEq(at, block.timestamp);
        assertEq(p, expected);
        // The weighted price must sit strictly between the two pool prices, closer to pool B.
        assertGt(p, pA);
        assertLt(p, pB);
        assertGt(p, (pA + pB) / 2);
    }

    function test_equalWeights_plainAverage() public {
        _setMeanTick(poolA, 0);
        _setMeanTick(poolB, 6931);
        (uint256 wA, uint256 wB) = _register(500, 500);
        assertEq(wA, wB);

        uint256 pA = UniV3TwapLib.quoteAtTick(0, false);
        uint256 pB = UniV3TwapLib.quoteAtTick(6931, false);
        uint256 expected = FullMath.mulDiv(pA, wA, wA + wB) + FullMath.mulDiv(pB, wB, wA + wB);

        (uint256 p,, bool ok) = adapter.read(TOKEN);
        assertTrue(ok);
        assertEq(p, expected);
    }

    function test_failedPool_isExcluded() public {
        _setMeanTick(poolA, 0);
        _setMeanTick(poolB, 6931);
        _register(1000, 3000);
        poolA.setRevertOnObserve(true);

        (uint256 p,, bool ok) = adapter.read(TOKEN);
        assertTrue(ok);
        // Only pool B contributes, so the price is exactly pool B's TWAP.
        assertEq(p, UniV3TwapLib.quoteAtTick(6931, false));
    }

    function test_zeroAverageLiquidityPool_isExcluded() public {
        // Pool A's accumulator delta is zero (a degenerate, unreadable average): the adapter's
        // time-averaged liquidity read returns ok = false, so pool A is skipped.
        _setMeanTick(poolA, 0);
        _setMeanTick(poolB, 6931);
        _register(1000, 3000);
        poolA.setSecondsPerLiquidityCumulative(WINDOW, 0);
        poolA.setSecondsPerLiquidityCumulative(0, 0);

        (uint256 p,, bool ok) = adapter.read(TOKEN);
        assertTrue(ok);
        assertEq(p, UniV3TwapLib.quoteAtTick(6931, false));
    }

    function test_negligibleLiquidityPool_isExcluded() public {
        // Pool A's average in-range liquidity rounds down to zero (huge accumulator delta): the
        // meanLiq == 0 skip branch excludes it, so only pool B contributes.
        _setMeanTick(poolA, 0);
        _setMeanTick(poolB, 6931);
        _register(1000, 3000);
        poolA.setSecondsPerLiquidityCumulative(WINDOW, 0);
        poolA.setSecondsPerLiquidityCumulative(0, type(uint160).max);

        (uint256 p,, bool ok) = adapter.read(TOKEN);
        assertTrue(ok);
        assertEq(p, UniV3TwapLib.quoteAtTick(6931, false));
    }

    function test_jitLiquiditySpikeDoesNotReweight() public {
        // A single-block liquidity spike on pool A cannot re-weight the composite: the weight is
        // the TIME-AVERAGED in-range liquidity, so a fresh instantaneous liquidity() has no say.
        // Here pool A's instantaneous liquidity is enormous but its averaged accumulator is small,
        // so pool B (larger average) still dominates.
        _setMeanTick(poolA, 0);
        _setMeanTick(poolB, 6931);
        (uint256 wA, uint256 wB) = _register(1000, 3000);
        poolA.setLiquidity(type(uint128).max); // instantaneous spike, ignored by the adapter

        uint256 pA = UniV3TwapLib.quoteAtTick(0, false);
        uint256 pB = UniV3TwapLib.quoteAtTick(6931, false);
        uint256 expected = FullMath.mulDiv(pA, wA, wA + wB) + FullMath.mulDiv(pB, wB, wA + wB);

        (uint256 p,, bool ok) = adapter.read(TOKEN);
        assertTrue(ok);
        assertEq(p, expected);
    }

    function test_allPoolsFail_notOk() public {
        _setMeanTick(poolA, 0);
        _setMeanTick(poolB, 6931);
        _register(1000, 3000);
        poolA.setRevertOnObserve(true);
        poolB.setRevertOnObserve(true);

        (uint256 p,, bool ok) = adapter.read(TOKEN);
        assertFalse(ok);
        assertEq(p, 0);
    }

    function test_unregisteredToken_notOk() public view {
        (,, bool ok) = adapter.read(address(0x1234));
        assertFalse(ok);
    }

    function test_setPools_validation() public {
        CrossPoolTwapAdapter.PoolConfig[] memory pools = new CrossPoolTwapAdapter.PoolConfig[](1);
        pools[0] = CrossPoolTwapAdapter.PoolConfig({pool: IUniswapV3Pool(address(poolA)), quoteIsToken0: false});

        vm.expectRevert(CrossPoolTwapAdapter.WindowZero.selector);
        adapter.setPools(TOKEN, pools, 0);

        pools[0].pool = IUniswapV3Pool(address(0));
        vm.expectRevert(CrossPoolTwapAdapter.PoolZero.selector);
        adapter.setPools(TOKEN, pools, WINDOW);
    }

    function test_setPools_emptyRemoves() public {
        _setMeanTick(poolA, 0);
        _register(1000, 3000);
        adapter.setPools(TOKEN, new CrossPoolTwapAdapter.PoolConfig[](0), 0);
        (,, bool ok) = adapter.read(TOKEN);
        assertFalse(ok);
    }

    function test_renounceOwnership_reverts() public {
        vm.expectRevert(CrossPoolTwapAdapter.RenounceDisabled.selector);
        adapter.renounceOwnership();
        assertEq(adapter.owner(), address(this));
    }
}
