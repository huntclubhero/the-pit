// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title ISettlementWindow: marker a TWAP-based settlement source implements to expose the
///        lookback window it averages over when pricing a token
/// @notice The OracleRouter uses this in the depth measurement to FLOOR every tracked pool's
///         geometry window at the token's settlement TWAP window (wave-2b audit R-9).
///         poolGeometry.window (the horizon of the time-averaged in-range reserve backing the
///         listing floor and the cost-to-move payout cap) is stored per pool with no structural
///         relation to the per-token TWAP window stored in the adapter; without a floor, a short
///         geometry window shrinks the depth-averaging horizon toward instantaneous and re-weakens
///         the W2-1 manipulation resistance the mean-reserve measure exists to provide. A pool
///         whose geometry window is shorter than this reported window contributes ZERO depth for a
///         value-bearing (B_DEEP / C_MID) token. A source that does not implement this marker is
///         simply not floored beyond the nonzero-window requirement (mirroring the W2-13
///         convention for sources that cannot be cross-checked).
/// @dev MUST be a view and MUST NOT revert; the router additionally wraps the call defensively.
///      The production CrossPoolTwapAdapter satisfies this interface through its public
///      twapWindow mapping getter.
interface ISettlementWindow {
    /// @notice The TWAP lookback window, in seconds, this source averages over for `token`.
    /// @param token The ERC-20 being priced.
    /// @return window The lookback in seconds (0 when the token is not registered).
    function twapWindow(address token) external view returns (uint32 window);
}
