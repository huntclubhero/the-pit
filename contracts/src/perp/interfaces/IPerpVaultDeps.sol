// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpTypes} from "./PerpTypes.sol";
import {Types} from "../../interfaces/Types.sol";

/// @title Vault-side dependency views for THE PIT v2 perps
/// @notice NOT FROZEN. Defined by the vault module (perp-vault) as the minimal external surface
///         the PitVault requires from its neighbors. Two consumers:
///         1. IPerpMarketList MUST be implemented by the PerpEngine (perp-core): the vault
///            enumerates markets through it to mark its NAV (spec 4.3). marketState is the
///            same view already frozen on IPerpEngine; only marketCount and marketAt are new.
///         2. IOracleRouterVaultView is already satisfied by the shipped OracleRouter:
///            peekPrice is on the frozen IOracleRouter and maxMarketPayoutCap1e18 is a public
///            view on the OracleRouter implementation. No oracle change is needed.
interface IPerpMarketList {
    /// @notice Number of listed markets (close-only markets included; a listed market is never
    ///         removed from the list, matching the append-only registry the engine keeps).
    function marketCount() external view returns (uint256);

    /// @notice Market token at `index`, 0 <= index < marketCount(). Order is append-only.
    function marketAt(uint256 index) external view returns (address token);

    /// @notice Per-market aggregates (identical to IPerpEngine.marketState). MUST be a plain
    ///         view with no reentrancy lock: the vault reads it from inside engine-initiated
    ///         calls (reservePayout runs during openPosition, and totalAssets reads aggregates).
    function marketState(address token) external view returns (PerpTypes.MarketAggregates memory);

    /// @notice The per-market cost-to-move payout cap (USD 1e18) FROZEN by the engine at
    ///         listMarket, type(uint256).max for majors. The vault reads this frozen snapshot
    ///         (not the router's live value) for its per-market reserve cap so a later liquidity
    ///         shift can never move the cap on open positions (v1 baked-cap parity, spec 3.6).
    function marketMaxPayoutCap1e18(address token) external view returns (uint256);
}

/// @title Oracle views the PitVault consumes
/// @notice Satisfied by the shipped OracleRouter without modification.
interface IOracleRouterVaultView {
    /// @notice Non-mutating settlement-reference price (USDG per token, 1e18).
    function peekPrice(address token) external view returns (uint256 price1e18, Types.PriceStatus status);

    /// @notice Cost-to-move derived absolute payout cap in USD 1e18 (type(uint256).max = unbounded,
    ///         which is how the router answers for Tier A majors).
    function maxMarketPayoutCap1e18(address token) external view returns (uint256 cap1e18);

    /// @notice The spot-vs-TWAP opening (deviation) breaker state for a token (read-only widening
    ///         of the PUBLIC OracleRouter.openingAllowed view; the deployed router satisfies it
    ///         unmodified). `allowed` is false while the deviation breaker is tripped, which is
    ///         exactly when opens AND liquidations are blocked for a pool-priced market: during
    ///         that window an underwater-past-margin position cannot be liquidated, so the vault
    ///         hard-gates epoch settlement on it (B8) to stop a standing-queued LP crystallizing
    ///         the aggregate-loss-clamp NAV overstatement.
    function openingAllowed(address token) external view returns (bool allowed, uint8 reason);
}
