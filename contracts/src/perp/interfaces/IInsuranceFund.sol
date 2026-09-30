// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title InsuranceFund: pre-ADL bad-debt backstop for THE PIT v2 perps
/// @notice FROZEN: perp module teams must not modify signatures. USDG-holding contract whose
///         only outflows are engine-verified bad-debt cover and bounded keeper-floor top-ups.
///         Governance withdrawal is timelocked. See spec section 6.
interface IInsuranceFund {
    /// @notice Cover a verified bad-debt shortfall by paying the vault. Engine-only.
    /// @param shortfall USDG units of uncovered loss.
    /// @param vault Recipient (the PitVault).
    /// @return covered Amount actually paid (min of shortfall and balance).
    function cover(uint256 shortfall, address vault) external returns (uint256 covered);
    /// @notice Pay a bounded keeper-floor top-up when a liquidation penalty is below the floor. Engine-only.
    function payKeeperFloor(address keeper, uint256 amount) external;
    /// @notice Current USDG balance of the fund.
    function balance() external view returns (uint256);
}
