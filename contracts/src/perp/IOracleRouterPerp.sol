// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IOracleRouter} from "../interfaces/IOracleRouter.sol";

/// @title IOracleRouterPerp: the oracle surface the perp engine consumes
/// @notice Extends the frozen IOracleRouter with the two PUBLIC views the shipped
///         OracleRouter already exposes (breakerOf, maxMarketPayoutCap1e18) but which are
///         not part of the frozen interface file. This is a read-only widening: the deployed
///         OracleRouter satisfies it as-is with zero modification (spec 2.1, 2.3, 3.6).
interface IOracleRouterPerp is IOracleRouter {
    /// @notice Deviation-breaker state for a token. A genuine agreeing print zeroes both
    ///         values in the same checkPrice call, so reading them immediately AFTER
    ///         checkPrice classifies the print exactly (spec 2.3):
    ///         LIVE when status OK and both are zero, FALLBACK when status OK otherwise.
    function breakerOf(address token) external view returns (uint64 cooldownUntil, uint8 failedRounds);

    /// @notice Absolute maximum market payout in USD 1e18: cost-to-move / safetyFactor for
    ///         pool-priced tokens, type(uint256).max for A_MAJOR (independent feed).
    function maxMarketPayoutCap1e18(address token) external view returns (uint256);

    /// @notice A token's settlement-tier configuration (read-only widening of the PUBLIC
    ///         OracleRouter.tierConfigOf view; the deployed router satisfies it unmodified).
    ///         `tier` decodes the SettlementTier enum (0 = A_MAJOR, 1 = B_DEEP, 2 = C_MID,
    ///         3 = D_THIN); `spotSource` is the spot aggregator arming the opening spot-vs-TWAP
    ///         breaker (address(0) = breaker disabled). Used by listMarket to assert a
    ///         pool-priced market cannot be listed with its only manipulation gate disarmed.
    function tierConfigOf(address token)
        external
        view
        returns (
            uint8 tier,
            uint256 aggregateDepthFloorUsd1e18,
            uint32 seasoningWindow,
            uint256 costToMoveCoeff,
            uint256 safetyFactor,
            uint16 deviationBreakerBps,
            address spotSource,
            bool set
        );
}
