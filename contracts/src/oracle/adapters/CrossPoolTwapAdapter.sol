// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPriceSource} from "./IPriceSource.sol";
import {ISpotSource} from "./ISpotSource.sol";
import {ISettlementPoolSet} from "./ISettlementPoolSet.sol";
import {UniV3TwapLib} from "../UniV3TwapLib.sol";
import {FullMath} from "../vendor/FullMath.sol";

/// @title CrossPoolTwapAdapter: liquidity-weighted TWAP across every registered pool of a token
/// @notice WEIGHTING, PRECISELY: each contributing pool i reports a TWAP price p_i (1e18, quote
///         per token) and a weight w_i equal to the pool's TIME-AVERAGED in-range liquidity over
///         the same window as the price TWAP (the harmonic mean of pool.liquidity() across the
///         window, read from the secondsPerLiquidityCumulativeX128 accumulator). Weighting by the
///         time-averaged liquidity, not the instantaneous pool.liquidity(), means a just-in-time
///         liquidity spike cannot re-weight the composite toward a manipulated pool for a single
///         block: one block of liquidity earns at most one block of weight over the whole window.
///         Uniswap v3 in-range liquidity is denominated in sqrt(amount0 * amount1) units, so the
///         averaged L values are only comparable when the pools share the exact same token pair.
///         For that reason every pool registered for a token MUST pair the token against the same
///         quote asset (USDG), differing only in fee tier; under that constraint all w_i share one
///         unit and no further scale conversion is needed. The reported price is
///         sum_i(w_i * p_i) / sum_i(w_i), computed as sum_i(mulDiv(p_i, w_i, W)) with
///         W = sum_i(w_i), which floors each term independently (total downward rounding is
///         strictly less than n wei for n pools). Pools whose TWAP read fails or whose
///         time-averaged in-range liquidity is zero or unreadable are skipped; if no pool
///         contributes, ok = false.
/// @dev The owner (a timelocked multisig) can only register pools and tune the window; it can
///      never inject a price. updatedAt is block.timestamp for the same reason as TwapAdapter.
///
///      SPOT companion (readSpot, ISpotSource): the router's opening-side deviation breaker needs
///      the CURRENT instantaneous price aggregated the SAME way as the TWAP. readSpot mirrors read
///      exactly (same registered pools, same time-averaged in-range liquidity weights) but sources
///      each pool's price from slot0's current tick instead of the mean tick over the window. That
///      keeps spot and TWAP in the same tick-to-price space so their deviation is apples to apples.
///      readSpot is consulted ONLY by the opening breaker; it never settles anything.
contract CrossPoolTwapAdapter is IPriceSource, ISpotSource, ISettlementPoolSet, Ownable2Step {
    /// @notice Disabled: renouncing ownership would permanently freeze the pool registry.
    error RenounceDisabled();

    /// @notice One registered pool for a token.
    /// @param pool The Uniswap v3 pool pairing the token with USDG.
    /// @param quoteIsToken0 True when USDG is token0 of that pool.
    struct PoolConfig {
        IUniswapV3Pool pool;
        bool quoteIsToken0;
    }

    /// @notice token => registered pools.
    mapping(address => PoolConfig[]) internal _pools;

    /// @notice token => TWAP lookback in seconds shared by all of that token's pools.
    mapping(address => uint32) public twapWindow;

    /// @notice Emitted when a token's pool set is replaced (count = 0 means removed).
    event PoolsSet(address indexed token, uint256 count, uint32 twapWindow);

    /// @dev The token argument was the zero address.
    error TokenZero();
    /// @dev A nonempty pool set was supplied with a zero window.
    error WindowZero();
    /// @dev A supplied pool address was zero.
    error PoolZero();

    /// @param initialOwner Owner of the registry (timelocked multisig).
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Renouncing ownership is disabled: it would permanently freeze the pool registry
    ///         with no path to reconfigure sources. Ownership can still be transferred (two-step).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Replaces the full pool set for a token (empty array removes the token).
    /// @param token The token whose pool set is being configured.
    /// @param pools The pools pairing the token with USDG (same quote asset for every entry).
    /// @param window TWAP lookback in seconds; must be nonzero when pools is nonempty.
    function setPools(address token, PoolConfig[] calldata pools, uint32 window) external onlyOwner {
        if (token == address(0)) revert TokenZero();
        if (pools.length != 0 && window == 0) revert WindowZero();
        delete _pools[token];
        for (uint256 i = 0; i < pools.length; i++) {
            if (address(pools[i].pool) == address(0)) revert PoolZero();
            _pools[token].push(pools[i]);
        }
        twapWindow[token] = pools.length == 0 ? 0 : window;
        emit PoolsSet(token, pools.length, twapWindow[token]);
    }

    /// @notice Returns the registered pool set for a token.
    function poolsOf(address token) external view returns (PoolConfig[] memory) {
        return _pools[token];
    }

    /// @inheritdoc ISettlementPoolSet
    /// @dev Lets the OracleRouter verify that a tracked (cost-to-move) pool is one this source
    ///      actually reads for `token` (wave-2 W2-13). Never reverts.
    function readsPool(address token, address pool) external view returns (bool reads) {
        PoolConfig[] storage pools = _pools[token];
        for (uint256 i = 0; i < pools.length; i++) {
            if (address(pools[i].pool) == pool) return true;
        }
        return false;
    }

    /// @inheritdoc IPriceSource
    function read(address token) external view returns (uint256 price1e18, uint256 updatedAt, bool ok) {
        PoolConfig[] memory pools = _pools[token];
        uint32 window = twapWindow[token];
        if (pools.length == 0 || window == 0) return (0, 0, false);

        uint256[] memory prices = new uint256[](pools.length);
        uint256[] memory weights = new uint256[](pools.length);
        uint256 totalWeight = 0;

        for (uint256 i = 0; i < pools.length; i++) {
            (uint256 p, bool twapOk) = UniV3TwapLib.readTwap(pools[i].pool, window, pools[i].quoteIsToken0);
            if (!twapOk) continue;
            // Weight by TIME-AVERAGED in-range liquidity over the window (never the instantaneous
            // pool.liquidity()), so a single-block liquidity spike cannot re-weight the composite.
            (uint256 meanLiq, bool liqOk) = UniV3TwapLib.consultMeanLiquidity(pools[i].pool, window);
            if (!liqOk || meanLiq == 0) continue;
            prices[i] = p;
            weights[i] = meanLiq;
            totalWeight += meanLiq;
        }

        if (totalWeight == 0) return (0, 0, false);

        uint256 weighted = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            if (weights[i] == 0) continue;
            weighted += FullMath.mulDiv(prices[i], weights[i], totalWeight);
        }
        return (weighted, block.timestamp, true);
    }

    /// @inheritdoc ISpotSource
    /// @notice Instantaneous analog of read(): the CURRENT price from each registered pool's slot0
    ///         tick, aggregated with the identical time-averaged in-range liquidity weights. Same
    ///         pools, same weights, same rounding as read(); only the per-pool price basis differs
    ///         (current tick versus mean tick). A pool whose slot0 read reverts, or whose
    ///         time-averaged in-range liquidity is zero or unreadable, is skipped exactly as in
    ///         read(); if no pool contributes, ok = false. This is the spot leg of the router's
    ///         opening-side deviation breaker and is never consulted at settlement.
    function readSpot(address token) external view returns (uint256 price1e18, bool ok) {
        PoolConfig[] memory pools = _pools[token];
        uint32 window = twapWindow[token];
        if (pools.length == 0 || window == 0) return (0, false);

        uint256[] memory prices = new uint256[](pools.length);
        uint256[] memory weights = new uint256[](pools.length);
        uint256 totalWeight = 0;

        for (uint256 i = 0; i < pools.length; i++) {
            int24 tick;
            try pools[i].pool.slot0() returns (uint160, int24 currentTick, uint16, uint16, uint16, uint8, bool) {
                tick = currentTick;
            } catch {
                continue;
            }
            // Weight by the SAME time-averaged in-range liquidity as read(), so a single-block
            // liquidity spike cannot re-weight the composite spot toward a manipulated pool.
            (uint256 meanLiq, bool liqOk) = UniV3TwapLib.consultMeanLiquidity(pools[i].pool, window);
            if (!liqOk || meanLiq == 0) continue;
            prices[i] = UniV3TwapLib.quoteAtTick(tick, pools[i].quoteIsToken0);
            weights[i] = meanLiq;
            totalWeight += meanLiq;
        }

        if (totalWeight == 0) return (0, false);

        uint256 weighted = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            if (weights[i] == 0) continue;
            weighted += FullMath.mulDiv(prices[i], weights[i], totalWeight);
        }
        return (weighted, true);
    }
}
