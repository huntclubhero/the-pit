// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AggregatorV3Interface} from "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPriceSource} from "./IPriceSource.sol";
import {UniV3TwapLib} from "../UniV3TwapLib.sol";
import {FullMath} from "../vendor/FullMath.sol";

/// @title TwoHopTwapAdapter: TOKEN/WETH TWAP times ETH/USD Chainlink feed as an IPriceSource
/// @notice Memecoin pools on Robinhood Chain are quoted in WETH, not USDG. This adapter prices a
///         token in USDG terms (1e18) as the product of two legs:
///         leg 1: the Uniswap v3 TWAP of the TOKEN/WETH pool over the configured window, giving
///         WETH per whole token at 1e18 scale;
///         leg 2: the Chainlink ETH/USD feed answer, normalized from the feed's native decimals
///         to 1e18 (USDG is treated as the USD unit, matching the rest of the oracle layer).
///         price1e18 = mulDiv(twapWethPerToken1e18, ethUsd1e18, 1e18).
///         ok = false whenever EITHER leg fails: the pool cannot serve the window (Uniswap "OLD",
///         cardinality too low or the pool is younger than the window), the feed reverts, reports
///         a non-positive answer, or its updatedAt is older than feedMaxStaleness.
/// @dev The owner (a timelocked multisig) can only point tokens at (pool, feed) pairs and tune
///      windows and staleness bounds; it can never inject a price. updatedAt is reported as
///      block.timestamp because the TWAP leg always extends to the current block; the feed leg's
///      staleness is enforced INTERNALLY against feedMaxStaleness (a stale feed flips ok to
///      false), so the router's per-source staleness bound composes safely on top.
contract TwoHopTwapAdapter is IPriceSource, Ownable2Step {
    /// @notice Per-token two-hop configuration.
    /// @param pool The Uniswap v3 pool pairing the token with WETH.
    /// @param twapWindow TWAP lookback in seconds for the TOKEN/WETH leg.
    /// @param tokenIsToken0 True when the PRICED token is token0 of the pool (WETH is token1).
    /// @param ethUsdFeed Chainlink ETH/USD aggregator proxy.
    /// @param feedMaxStaleness Max age in seconds of the feed's updatedAt before ok = false.
    /// @param feedDecimals Feed decimals cached at registration (keeps read() lean).
    struct TwoHopConfig {
        IUniswapV3Pool pool;
        uint32 twapWindow;
        bool tokenIsToken0;
        AggregatorV3Interface ethUsdFeed;
        uint64 feedMaxStaleness;
        uint8 feedDecimals;
    }

    /// @notice token => two-hop configuration. A zero pool address means unregistered.
    mapping(address => TwoHopConfig) public configs;

    /// @notice Emitted when a config is registered, replaced, or removed (pool = address(0)).
    event TwoHopConfigSet(
        address indexed token,
        address indexed pool,
        uint32 twapWindow,
        bool tokenIsToken0,
        address indexed ethUsdFeed,
        uint64 feedMaxStaleness
    );

    /// @dev The token argument was the zero address.
    error TokenZero();
    /// @dev A nonzero pool was supplied with a zero window.
    error WindowZero();
    /// @dev A nonzero pool was supplied with a zero feed address.
    error FeedZero();
    /// @dev A nonzero pool was supplied with a zero feed staleness bound.
    error StalenessZero();
    /// @dev The feed reports more decimals than the adapter supports (max 30).
    error UnsupportedFeedDecimals(uint8 decimals);
    /// @dev Renouncing ownership is disabled: it would permanently freeze the two-hop registry.
    error RenounceDisabled();

    /// @param initialOwner Owner of the registry (timelocked multisig).
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Renouncing ownership is disabled: it would permanently freeze the two-hop registry
    ///         with no path to reconfigure sources. Ownership can still be transferred (two-step).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Registers, replaces, or removes (pool = address(0)) the config for a token.
    /// @param token The token whose config is being set.
    /// @param pool The TOKEN/WETH Uniswap v3 pool, or zero to remove the config.
    /// @param twapWindow TWAP lookback in seconds; must be nonzero when pool is nonzero.
    /// @param tokenIsToken0 True when the priced token is token0 of the pool.
    /// @param ethUsdFeed Chainlink ETH/USD aggregator proxy; must be nonzero when pool is nonzero.
    /// @param feedMaxStaleness Max feed age in seconds; must be nonzero when pool is nonzero.
    function setConfig(
        address token,
        IUniswapV3Pool pool,
        uint32 twapWindow,
        bool tokenIsToken0,
        AggregatorV3Interface ethUsdFeed,
        uint64 feedMaxStaleness
    ) external onlyOwner {
        if (token == address(0)) revert TokenZero();
        if (address(pool) == address(0)) {
            delete configs[token];
            emit TwoHopConfigSet(token, address(0), 0, false, address(0), 0);
            return;
        }
        if (twapWindow == 0) revert WindowZero();
        if (address(ethUsdFeed) == address(0)) revert FeedZero();
        if (feedMaxStaleness == 0) revert StalenessZero();
        uint8 dec = ethUsdFeed.decimals();
        if (dec > 30) revert UnsupportedFeedDecimals(dec);
        configs[token] = TwoHopConfig({
            pool: pool,
            twapWindow: twapWindow,
            tokenIsToken0: tokenIsToken0,
            ethUsdFeed: ethUsdFeed,
            feedMaxStaleness: feedMaxStaleness,
            feedDecimals: dec
        });
        emit TwoHopConfigSet(token, address(pool), twapWindow, tokenIsToken0, address(ethUsdFeed), feedMaxStaleness);
    }

    /// @inheritdoc IPriceSource
    function read(address token) external view returns (uint256 price1e18, uint256 updatedAt, bool ok) {
        TwoHopConfig memory cfg = configs[token];
        if (address(cfg.pool) == address(0)) return (0, 0, false);

        // Leg 1: TOKEN/WETH TWAP. The pool's quote asset is WETH; when the priced token is
        // token0 the quote sits on the token1 side, so quoteIsToken0 = !tokenIsToken0.
        (uint256 wethPerToken1e18, bool twapOk) =
            UniV3TwapLib.readTwap(cfg.pool, cfg.twapWindow, !cfg.tokenIsToken0);
        if (!twapOk) return (0, 0, false);

        // Leg 2: ETH/USD Chainlink feed, staleness enforced here against feedMaxStaleness.
        uint256 ethUsd1e18;
        try cfg.ethUsdFeed.latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 feedUpdatedAt, uint80
        ) {
            if (answer <= 0) return (0, 0, false);
            if (feedUpdatedAt + cfg.feedMaxStaleness < block.timestamp) return (0, 0, false);
            ethUsd1e18 = _to1e18(uint256(answer), cfg.feedDecimals);
        } catch {
            return (0, 0, false);
        }

        return (FullMath.mulDiv(wethPerToken1e18, ethUsd1e18, 1e18), block.timestamp, true);
    }

    /// @dev Rescales a raw feed answer from `dec` decimals to 18 decimals.
    function _to1e18(uint256 raw, uint8 dec) private pure returns (uint256) {
        if (dec == 18) return raw;
        if (dec < 18) return raw * 10 ** (18 - dec);
        return raw / 10 ** (dec - 18);
    }
}
