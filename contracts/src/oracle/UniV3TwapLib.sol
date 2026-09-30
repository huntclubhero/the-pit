// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "./vendor/TickMath.sol";
import {FullMath} from "./vendor/FullMath.sol";

/// @title UniV3TwapLib: Uniswap v3 TWAP reader for THE PIT oracle layer
/// @notice Reads a time weighted average tick from a Uniswap v3 pool over a fixed window and
///         converts it to a 1e18-scaled price of the base token quoted in the quote token.
/// @dev Mean-tick rounding matches Uniswap's OracleLibrary exactly: the tick cumulative delta is
///      divided by the window with truncation, then decremented by one when the delta is negative
///      and not evenly divisible by the window (round toward negative infinity).
library UniV3TwapLib {
    /// @notice Reads the TWAP over `window` seconds and quotes 1e18 units of the base token.
    /// @dev Returns ok = false (never reverts) when:
    ///      window is zero, or the pool's observe call reverts for any reason. The dominant revert
    ///      cause is Uniswap's "OLD" error: the oldest stored observation is younger than `window`,
    ///      meaning the pool's observation cardinality cannot cover the requested lookback yet.
    /// @param pool The Uniswap v3 pool to read.
    /// @param window TWAP lookback in seconds.
    /// @param quoteIsToken0 True when the quote asset (USDG) is token0 of the pool, meaning the
    ///        base token being priced is token1. False when the quote asset is token1.
    /// @return price1e18 Price of one whole (1e18-scaled) base token in quote terms, 1e18 scale.
    /// @return ok True when the read succeeded.
    function readTwap(IUniswapV3Pool pool, uint32 window, bool quoteIsToken0)
        internal
        view
        returns (uint256 price1e18, bool ok)
    {
        if (window == 0) return (0, false);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        int56[] memory tickCumulatives;
        try pool.observe(secondsAgos) returns (int56[] memory ticks, uint160[] memory) {
            tickCumulatives = ticks;
        } catch {
            return (0, false);
        }

        int24 meanTick;
        unchecked {
            // Cumulative ticks are allowed to overflow by design in Uniswap v3; the delta remains
            // correct under wrapping arithmetic, so this subtraction is intentionally unchecked.
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 windowI = int56(uint56(window));
            meanTick = int24(delta / windowI);
            // Round toward negative infinity, matching Uniswap OracleLibrary semantics.
            if (delta < 0 && (delta % windowI != 0)) {
                meanTick = meanTick - 1;
            }
        }

        return (quoteAtTick(meanTick, quoteIsToken0), true);
    }

    /// @notice Reads the time-averaged (harmonic-mean) in-range liquidity over `window` seconds.
    /// @dev Reads the pool's secondsPerLiquidityCumulativeX128 accumulator, the very same
    ///      observation buffer the TWAP consults, so a single-block liquidity spike or drain
    ///      cannot move the result: the accumulator only credits liquidity in proportion to the
    ///      time it was actually in range, so one block of just-in-time liquidity contributes at
    ///      most one block of weight over the whole window. Returns ok = false (never reverts)
    ///      when the window is zero, the observe call reverts (Uniswap "OLD": the buffer cannot
    ///      cover the window yet), or the accumulator delta is zero (a degenerate, effectively
    ///      unbounded average that is treated as unusable).
    /// @param pool The Uniswap v3 pool to read.
    /// @param window Lookback in seconds; use the same horizon as the price TWAP.
    /// @return meanLiquidity Time-averaged in-range liquidity over the window, in the same
    ///         sqrt(amount0 * amount1) units as pool.liquidity().
    /// @return ok True when the read produced a usable, positive average.
    function consultMeanLiquidity(IUniswapV3Pool pool, uint32 window)
        internal
        view
        returns (uint256 meanLiquidity, bool ok)
    {
        if (window == 0) return (0, false);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        uint160[] memory secondsPerLiquidity;
        try pool.observe(secondsAgos) returns (int56[] memory, uint160[] memory splCumulatives) {
            secondsPerLiquidity = splCumulatives;
        } catch {
            return (0, false);
        }

        uint160 delta;
        unchecked {
            // The accumulator is allowed to overflow by design in Uniswap v3; the wrapped
            // subtraction still yields the correct in-window delta (now minus window-ago).
            delta = secondsPerLiquidity[1] - secondsPerLiquidity[0];
        }
        if (delta == 0) return (0, false);

        // delta = sum over the window of (secondsElapsed * 2^128 / liquidity), so the
        // time-averaged liquidity is window * 2^128 / delta (the harmonic mean of L over time).
        meanLiquidity = FullMath.mulDiv(uint256(window), uint256(1) << 128, uint256(delta));
        return (meanLiquidity, true);
    }

    /// @notice Time-averaged in-range QUOTE-side reserve of a pool over `window`, in raw
    ///         quote-token units. This is the manipulation-resistant depth measure for listing
    ///         floors and the cost-to-move payout cap.
    /// @dev Uniswap v3 in-range virtual reserves are x = L / sqrtP (token0) and y = L * sqrtP
    ///      (token1), with sqrtP = sqrtPriceX96 / 2^96. The quote-side reserve is x when the quote
    ///      asset is token0 and y when the quote asset is token1. BOTH factors are read
    ///      time-averaged over the SAME window from the SAME observation buffer the settlement TWAP
    ///      consults (the harmonic-mean in-range liquidity via secondsPerLiquidityCumulativeX128,
    ///      and the mean tick via tickCumulatives), in a single observe() call. Consequently
    ///      neither a single-block liquidity deposit NOR a single-block price push can raise the
    ///      result: a single-sided, out-of-range just-in-time LP deposit inflates only the pool's
    ///      raw token balance, never its time-averaged in-range liquidity, so this measure ignores
    ///      it entirely. Returns ok = false (never reverts) when the window is zero, observe reverts
    ///      (Uniswap "OLD": the buffer cannot cover the window yet), or the liquidity accumulator
    ///      delta is zero (a degenerate, effectively unbounded average treated as unusable).
    ///
    ///      CONCENTRATION CAVEAT (wave-3 R-1). This is a VIRTUAL in-range reserve (L * sqrtP or
    ///      L / sqrtP), i.e. LOCAL depth at the current tick. Concentrating a small amount of real
    ///      quote in a razor-thin tick band makes L (and hence this reserve) enormous while the pool's
    ///      real quote balance stays small, so this value ALONE overstates the depth that resists a
    ///      settlement-sized move. Callers using it to size a listing floor or a cost-to-move payout
    ///      cap MUST clamp it by the pool's real quote-token balance (see
    ///      OracleRouter._concentrationAwareQuoteAmount); this library returns the unclamped virtual
    ///      reserve so the caller, which knows the quote-token address, applies the MIN.
    /// @param pool The Uniswap v3 pool to read.
    /// @param window Lookback in seconds; use the same horizon as the settlement price TWAP.
    /// @param quoteIsToken0 True when the quote asset is token0 (base token is token1).
    /// @return quoteReserve Time-averaged in-range quote-side reserve, in raw quote-token units.
    /// @return ok True when the read produced a usable, positive reserve.
    function consultMeanQuoteReserve(IUniswapV3Pool pool, uint32 window, bool quoteIsToken0)
        internal
        view
        returns (uint256 quoteReserve, bool ok)
    {
        if (window == 0) return (0, false);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        int56[] memory tickCumulatives;
        uint160[] memory secondsPerLiquidity;
        try pool.observe(secondsAgos) returns (int56[] memory ticks, uint160[] memory spl) {
            tickCumulatives = ticks;
            secondsPerLiquidity = spl;
        } catch {
            return (0, false);
        }

        uint160 splDelta;
        unchecked {
            // Overflow is intended in Uniswap v3; the wrapped subtraction yields the in-window delta.
            splDelta = secondsPerLiquidity[1] - secondsPerLiquidity[0];
        }
        if (splDelta == 0) return (0, false);
        uint256 meanLiquidity = FullMath.mulDiv(uint256(window), uint256(1) << 128, uint256(splDelta));

        int24 meanTick;
        unchecked {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 windowI = int56(uint56(window));
            meanTick = int24(delta / windowI);
            // Round toward negative infinity, matching Uniswap OracleLibrary semantics.
            if (delta < 0 && (delta % windowI != 0)) {
                meanTick = meanTick - 1;
            }
        }
        uint256 sqrtPriceX96 = uint256(TickMath.getSqrtRatioAtTick(meanTick));

        // Quote-side virtual reserve: y = L * sqrtP (quote = token1) or x = L / sqrtP (quote =
        // token0), sqrtP expressed at 2^96 fixed point.
        if (quoteIsToken0) {
            quoteReserve = FullMath.mulDiv(meanLiquidity, uint256(1) << 96, sqrtPriceX96);
        } else {
            quoteReserve = FullMath.mulDiv(meanLiquidity, sqrtPriceX96, uint256(1) << 96);
        }
        return (quoteReserve, true);
    }

    /// @notice Converts a tick to a 1e18-scaled quote-per-base price.
    /// @dev Mirrors Uniswap OracleLibrary.getQuoteAtTick with baseAmount fixed at 1e18: when the
    ///      squared sqrt ratio fits in 256 bits it is used at X192 precision, otherwise the ratio
    ///      is first reduced to X128 precision via FullMath to avoid overflow.
    /// @param tick The tick to price.
    /// @param quoteIsToken0 True when the quote asset is token0 (base token is token1).
    /// @return price1e18 Price of one whole base token in quote terms, 1e18 scale.
    function quoteAtTick(int24 tick, bool quoteIsToken0) internal pure returns (uint256 price1e18) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            price1e18 = quoteIsToken0
                ? FullMath.mulDiv(uint256(1) << 192, 1e18, ratioX192)
                : FullMath.mulDiv(ratioX192, 1e18, uint256(1) << 192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, uint256(1) << 64);
            price1e18 = quoteIsToken0
                ? FullMath.mulDiv(uint256(1) << 128, 1e18, ratioX128)
                : FullMath.mulDiv(ratioX128, 1e18, uint256(1) << 128);
        }
    }
}
