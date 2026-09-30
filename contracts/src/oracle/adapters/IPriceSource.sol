// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title IPriceSource: minimal adapter interface consumed by the OracleRouter
/// @notice Every price source (Chainlink, Pyth, single-pool TWAP, cross-pool TWAP) exposes this
///         one read function. Sources NEVER settle anything on their own; the router medianizes
///         at least three of them before a price is usable.
interface IPriceSource {
    /// @notice Reads the current price of `token`, quoted in USDG, 1e18 scale.
    /// @dev MUST NOT revert for missing configuration or bad upstream data; return ok = false
    ///      instead. The router additionally wraps calls in try/catch as defense in depth.
    /// @param token The ERC-20 being priced.
    /// @return price1e18 USDG per whole token, 1e18 scale. Zero when ok is false.
    /// @return updatedAt Timestamp of the underlying observation, used for staleness checks.
    /// @return ok True only when the source produced a usable, positive price.
    function read(address token) external view returns (uint256 price1e18, uint256 updatedAt, bool ok);
}
