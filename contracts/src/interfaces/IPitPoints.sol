// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Points engine hooks, called by Market contracts only (access-controlled)
/// @notice FROZEN: teammates must not modify this file. Interface changes go through the integrator.
interface IPitPoints {
    /// @param notional taker stake x multiple, USDG native decimals (the taker's own post-fee
    ///        fill notional; the maker still earns its 2x share of the base derived from it)
    function onFill(address longParty, address shortParty, address maker, address token, uint256 notional) external;

    /// @param notional loser stake x multiple, USDG native decimals (the notional exposure that
    ///        produced the winnings)
    /// @param pnlToWinner clamped gross PnL transferred winner-ward, USDG native decimals
    function onSettle(address winner, address loser, address token, uint256 notional, uint256 pnlToWinner) external;

    function onMarketCreated(address creator, address token) external;
}
