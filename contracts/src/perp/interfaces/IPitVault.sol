// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title PitVault (PLP): the LP-as-house counterparty vault for THE PIT v2 perps
/// @notice FROZEN: perp module teams must not modify signatures. The vault is an ERC-4626
///         style USDG vault (with a hard first-depositor inflation guard) that is the sole
///         automated counterparty to all net open interest. The engine is the only authorized
///         caller of the counterparty surface. See spec section 4.
interface IPitVault {
    // ----------------------------- LP surface -----------------------------
    /// @notice Deposit USDG at current NAV (post fee), mint PLP shares. Standard ERC-4626 deposit.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    /// @notice Queue a withdrawal: locks shares, prices at the next epoch-boundary NAV.
    function requestWithdraw(uint256 shares) external;
    /// @notice Claim a matured queued withdrawal (USDG), subject to the per-epoch cap and solvency floor.
    function claim() external returns (uint256 assets);
    /// @notice Total USDG value backing PLP: balance + engine receivable minus aggregate clamped trader uPnL.
    function totalAssets() external view returns (uint256);
    /// @notice Drawdown reference NAV: totalAssets() plus crystallized-but-unclaimed withdrawal
    ///         liability, so a routine LP exit (which lowers totalAssets but raises the liability)
    ///         does NOT read as a trading loss for the engine's drawdown circuit (spec 6.3).
    function drawdownReferenceAssets() external view returns (uint256);

    // ------------------- engine-only counterparty surface -----------------
    /// @notice Reserve `amount` of USDG payout capacity for a position (bounds vault max outflow).
    /// @dev Reverts if the reservation would breach the global utilization cap.
    function reservePayout(address token, uint256 amount) external;
    /// @notice Release a previously reserved payout amount (on close/liquidation).
    function releasePayout(address token, uint256 amount) external;
    /// @notice Pay a trader's realized win from reserves (bounded by totalReserved: the price
    ///         payout channel, capped per position at its reserved maxPayout).
    function settleTraderWin(address to, uint256 amount) external;
    /// @notice Pay a trader's realized funding credit (NOT bounded by the reserved-payout channel:
    ///         funding credits are funded by the opposing side's funding debits already collected
    ///         into the vault, so they are never clamped by a position's price maxPayout, spec 5).
    function settleFundingCredit(address to, uint256 amount) external;
    /// @notice Receive a trader's realized loss (engine transfers USDG in before or in this call).
    function settleTraderLoss(uint256 amount) external;
    /// @notice Receive protocol fee revenue for LPs (economics v2, finding A1): the engine's
    ///         immutable vault share of every trade fee plus the whole vol surcharge (finding A2).
    ///         Pulled from the engine via transferFrom against its standing approval; the USDG
    ///         lands in the vault balance and raises NAV pro-rata, minting NO shares.
    function receiveFeeRevenue(uint256 amount) external;
    /// @notice Receive the vault's share of a liquidation penalty (economics v2, finding A1).
    ///         Same mechanics as receiveFeeRevenue; tracked on a separate counter for reporting.
    function receiveLiquidationRevenue(uint256 amount) external;
    /// @notice Total USDG payout currently reserved across all markets.
    function totalReserved() external view returns (uint256);
}
