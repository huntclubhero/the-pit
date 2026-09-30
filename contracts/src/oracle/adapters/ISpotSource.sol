// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title ISpotSource: instantaneous (slot0-derived) price aggregator for the opening breaker
/// @notice A companion to IPriceSource. Where IPriceSource.read returns the TIME-AVERAGED
///         (TWAP) settlement price, readSpot returns the CURRENT instantaneous price aggregated
///         across the SAME pools with the SAME liquidity-time weighting, so the OracleRouter's
///         spot-vs-TWAP opening breaker (openingAllowed) compares like with like. This source is
///         consulted ONLY by the opening breaker; it NEVER settles anything and is NEVER read on
///         the settlement, close, or forced-unwind paths.
/// @dev MUST NOT revert for missing configuration or bad upstream data: return ok = false. The
///      router additionally wraps the call in try/catch as defense in depth.
interface ISpotSource {
    /// @notice Reads the current instantaneous price of `token`, quoted in USDG, 1e18 scale.
    /// @param token The ERC-20 being priced.
    /// @return price1e18 USDG per whole token, 1e18 scale. Zero when ok is false.
    /// @return ok True only when the source produced a usable, positive spot price.
    function readSpot(address token) external view returns (uint256 price1e18, bool ok);
}
