// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Types} from "./Types.sol";

/// @title Oracle router: every settlement price is a median of independent sources with guards
/// @notice FROZEN: teammates must not modify this file. Interface changes go through the integrator.
interface IOracleRouter {
    /// @notice Composite settlement price for a token, USDG per token, 1e18 scale.
    /// @dev Non-view: may update breaker/cooldown state. Callers MUST branch on status
    ///      and never treat a non-OK price as settleable.
    function checkPrice(address token) external returns (uint256 price1e18, Types.PriceStatus status);

    /// @notice View variant for UI/quoting; never mutates breaker state.
    function peekPrice(address token) external view returns (uint256 price1e18, Types.PriceStatus status);

    /// @notice True if the token passes listing rules (tier gate, source count, aggregate-depth
    ///         floor, seasoning, and observation cardinality; see OracleRouter.isListable).
    function isListable(address token) external view returns (bool);

    /// @notice OPENING-SIDE deviation breaker: is it safe to OPEN a new position on `token` right
    ///         now? Compares the current aggregated spot price against the settlement TWAP and
    ///         denies opening when they diverge beyond the token's deviationBreakerBps. This is the
    ///         single additive function on this otherwise-frozen interface (increment 1 of the safe
    ///         memecoin settlement layer). It is an OPENING constraint ONLY: settlement, close, and
    ///         the forced-unwind liveness path MUST NEVER consult it, so a paused-opening token can
    ///         still always settle and unwind. Tier A (majors) and any token without a spot source
    ///         configured are always allowed (their independent feed needs no spot-vs-TWAP gate).
    /// @param token The ERC-20 whose opening gate is queried.
    /// @return allowed True when opening a new position is permitted.
    /// @return reason A diagnostic code for off-chain surfaces: 0 = ALLOWED, 1 = spot-vs-TWAP
    ///         deviation exceeds the breaker, 2 = reference unavailable (spot or TWAP unreadable).
    function openingAllowed(address token) external view returns (bool allowed, uint8 reason);

    /// @notice Tracked combined pool liquidity in USDG terms (1e18) used for OI caps.
    function trackedLiquidity(address token) external view returns (uint256 liquidityUsd1e18);

    /// @notice Snapshot liquidity at market creation; called once by the factory.
    function snapshotLiquidity(address token) external returns (uint256 liquidityUsd1e18);
}
