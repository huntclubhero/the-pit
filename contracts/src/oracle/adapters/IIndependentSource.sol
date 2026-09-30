// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title IIndependentSource: marker a price source implements to declare pool independence
/// @notice A source that derives `token`'s price from a reference INDEPENDENT of any on-chain
///         settlement pool (a real external feed such as Chainlink or Pyth) implements this and
///         returns true for that token. Pool-derived sources (AMM TWAP adapters) do NOT implement
///         it, so the OracleRouter treats them as non-independent. The router uses this to enforce,
///         at listing time, that a Tier A_MAJOR token actually carries at least one genuinely
///         owner-independent feed rather than merely claiming the classification (wave-2 audit
///         TO-1 hardening: a compromised owner cannot classify a pool-only token as A_MAJOR to
///         skip the cost-to-move cap while pointing every source at owned pools).
/// @dev MUST be a view and MUST NOT revert; the router additionally wraps the call defensively.
interface IIndependentSource {
    /// @notice True when this source prices `token` from a settlement-pool-independent reference.
    /// @param token The ERC-20 being priced.
    /// @return independent True only when a real external (non-AMM) feed backs `token` here.
    function isIndependent(address token) external view returns (bool independent);
}
