// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title ISettlementPoolSet: marker a pool-aggregating settlement source implements to expose the
///        exact pools it reads when pricing a token
/// @notice The OracleRouter uses this at listing time to CROSS-CHECK that every pool it sizes the
///         cost-to-move / depth against is a pool the settlement source actually reads (wave-2
///         audit W2-13). Without this, governance could size the payout cap to deep pools the
///         settlement source never consults while the source reads only a shallow one, letting an
///         attacker move just that shallow pool. A source that does not implement this marker is
///         simply not cross-checked (the router treats it as covered).
/// @dev MUST be a view and MUST NOT revert; the router additionally wraps the call defensively.
interface ISettlementPoolSet {
    /// @notice True when this settlement source reads `pool` when pricing `token`.
    /// @param token The ERC-20 being priced.
    /// @param pool The candidate tracked pool address.
    /// @return reads True only when `pool` is in the source's registered pool set for `token`.
    function readsPool(address token, address pool) external view returns (bool reads);
}
