// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpTypes} from "./PerpTypes.sol";

/// @title PerpRiskConfig: mcap-tiered risk parameters + tier assignment for THE PIT v2
/// @notice FROZEN: perp module teams must not modify signatures. Owner is the timelock.
///         The mcap tier drives max leverage and cannot be raised per-block (epoch + hysteresis;
///         downgrades apply immediately to new opens, upgrades queue through the timelock).
///         See spec sections 3.1, 8.4.
interface IPerpRiskConfig {
    /// @notice Resolved tier parameters for a token (reverts if the token has no tier assigned).
    function paramsFor(address token) external view returns (PerpTypes.TierParams memory);
    /// @notice Current mcap tier index for a token (0 = smallest band).
    function mcapTierOf(address token) external view returns (uint8);
    /// @notice Permissionless tier refresh: at most once per epoch per token, TWAP-based, hysteresis-bounded.
    ///         Downgrades take effect for new opens immediately; upgrades queue through governance.
    function refreshTier(address token) external;
    /// @notice payoutCapMultiple: a position's max payout = this * margin (governance, launch 9).
    function payoutCapMultiple() external view returns (uint256);
    /// @notice Global vault utilization cap in bps of TVL (governance, launch 8000 = 80%).
    function maxUtilizationBps() external view returns (uint16);
    /// @notice Per-market reserve cap in bps of TVL (governance, launch 1000 = 10%).
    function marketReserveCapBps() external view returns (uint16);
    /// @notice Volatility-pricing knobs (economics v2, finding A2): vol-scaled open-fee
    ///         surcharge credited to the LP vault and vol-scaled reserve-cap discount.
    ///         Timelock-settable within HARD caps (read-only widening of the frozen surface,
    ///         landed through the integrator with the economics wave).
    function volParams() external view returns (PerpTypes.VolParams memory);
}
