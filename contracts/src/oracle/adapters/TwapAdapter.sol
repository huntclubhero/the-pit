// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPriceSource} from "./IPriceSource.sol";
import {UniV3TwapLib} from "../UniV3TwapLib.sol";

/// @title TwapAdapter: single Uniswap v3 pool TWAP as an IPriceSource
/// @notice Per-token configuration: (pool, twapWindow, quoteIsToken0). The reported price is the
///         time weighted average price over the window, quoted in the pool's USDG side, 1e18 scale.
/// @dev The owner (a timelocked multisig) can only point tokens at pools and tune windows; it can
///      never inject a price. updatedAt is reported as block.timestamp because a TWAP is an
///      aggregate that always extends to the current block; staleness of the underlying pool is
///      covered by the observe() lookback itself (ok = false when the pool cannot serve the window).
contract TwapAdapter is IPriceSource, Ownable2Step {
    /// @notice Per-token TWAP configuration.
    /// @param pool The Uniswap v3 pool pairing the token with USDG.
    /// @param twapWindow TWAP lookback in seconds.
    /// @param quoteIsToken0 True when USDG is token0 of the pool.
    struct TwapConfig {
        IUniswapV3Pool pool;
        uint32 twapWindow;
        bool quoteIsToken0;
    }

    /// @notice token => TWAP configuration. A zero pool address means unregistered.
    mapping(address => TwapConfig) public configs;

    /// @notice Emitted when a TWAP config is registered, replaced, or removed (pool = address(0)).
    event TwapConfigSet(address indexed token, address indexed pool, uint32 twapWindow, bool quoteIsToken0);

    /// @dev The token argument was the zero address.
    error TokenZero();
    /// @dev A nonzero pool was supplied with a zero window.
    error WindowZero();
    /// @dev Renouncing ownership is disabled: it would permanently freeze the TWAP registry.
    error RenounceDisabled();

    /// @param initialOwner Owner of the registry (timelocked multisig).
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Renouncing ownership is disabled: it would permanently freeze the TWAP registry
    ///         with no path to reconfigure sources. Ownership can still be transferred (two-step).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Registers, replaces, or removes (pool = address(0)) the TWAP config for a token.
    /// @param token The token whose config is being set.
    /// @param pool The Uniswap v3 pool, or zero to remove the config.
    /// @param twapWindow TWAP lookback in seconds; must be nonzero when pool is nonzero.
    /// @param quoteIsToken0 True when USDG is token0 of the pool.
    function setConfig(address token, IUniswapV3Pool pool, uint32 twapWindow, bool quoteIsToken0)
        external
        onlyOwner
    {
        if (token == address(0)) revert TokenZero();
        if (address(pool) == address(0)) {
            delete configs[token];
            emit TwapConfigSet(token, address(0), 0, false);
            return;
        }
        if (twapWindow == 0) revert WindowZero();
        configs[token] = TwapConfig({pool: pool, twapWindow: twapWindow, quoteIsToken0: quoteIsToken0});
        emit TwapConfigSet(token, address(pool), twapWindow, quoteIsToken0);
    }

    /// @inheritdoc IPriceSource
    function read(address token) external view returns (uint256 price1e18, uint256 updatedAt, bool ok) {
        TwapConfig memory cfg = configs[token];
        if (address(cfg.pool) == address(0)) return (0, 0, false);
        (uint256 price, bool twapOk) = UniV3TwapLib.readTwap(cfg.pool, cfg.twapWindow, cfg.quoteIsToken0);
        if (!twapOk) return (0, 0, false);
        return (price, block.timestamp, true);
    }
}
