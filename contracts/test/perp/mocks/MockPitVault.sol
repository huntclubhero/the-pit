// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPitVault} from "../../../src/perp/interfaces/IPitVault.sol";

/// @title MockPitVault: recording counterparty vault for PerpEngine tests
/// @notice Tracks reservations per market (plus a high-water mark for the reserve-cap
///         invariant), enforces an optional global utilization cap exactly like the real
///         vault's reservePayout contract, pays wins from its USDG balance, and lets tests
///         override totalAssets.
contract MockPitVault is IPitVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdg;
    address public engine;

    mapping(address => uint256) public reservedOf; // per market token
    uint256 public totalReservedAmount;
    mapping(address => uint256) public maxReservedEverOf; // high-water mark per market
    uint256 public settledLossTotal;
    uint256 public settledWinTotal;

    /// @dev 0 = no utilization enforcement; else reservePayout reverts past bps of totalAssets.
    uint16 public maxUtilizationBps;
    /// @dev When nonzero, totalAssets() returns this instead of the USDG balance.
    uint256 public totalAssetsOverride;
    /// @dev Crystallized withdraw liability added back in drawdownReferenceAssets (B2 tests).
    uint256 public claimLiabilityOverride;
    uint256 public settledFundingCreditTotal;
    uint256 public cumulativeFeeRevenue;
    uint256 public cumulativeLiquidationRevenue;

    error OnlyEngine();
    error UtilizationExceeded();
    error ZeroAmount();

    constructor(IERC20 usdg_) {
        usdg = usdg_;
    }

    function setEngine(address engine_) external {
        engine = engine_;
    }

    function setMaxUtilizationBps(uint16 bps) external {
        maxUtilizationBps = bps;
    }

    function setTotalAssetsOverride(uint256 assets) external {
        totalAssetsOverride = assets;
    }

    function setClaimLiabilityOverride(uint256 liability) external {
        claimLiabilityOverride = liability;
    }

    /// @dev Test funding: seed the vault with USDG for win payouts.
    function fund(uint256 amount) external {
        usdg.safeTransferFrom(msg.sender, address(this), amount);
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert OnlyEngine();
        _;
    }

    // ============================= LP surface (stubs) =============================

    /// @inheritdoc IPitVault
    function deposit(uint256 assets, address) external returns (uint256 shares) {
        usdg.safeTransferFrom(msg.sender, address(this), assets);
        return assets;
    }

    /// @inheritdoc IPitVault
    function requestWithdraw(uint256 shares) external {}

    /// @inheritdoc IPitVault
    function claim() external pure returns (uint256 assets) {
        return 0;
    }

    /// @inheritdoc IPitVault
    function totalAssets() public view returns (uint256) {
        return totalAssetsOverride != 0 ? totalAssetsOverride : usdg.balanceOf(address(this));
    }

    /// @inheritdoc IPitVault
    function drawdownReferenceAssets() external view returns (uint256) {
        return totalAssets() + claimLiabilityOverride;
    }

    // ========================= engine-only counterparty =========================

    /// @inheritdoc IPitVault
    function reservePayout(address token, uint256 amount) external onlyEngine {
        if (amount == 0) revert ZeroAmount(); // mirrors the real PitVault
        reservedOf[token] += amount;
        totalReservedAmount += amount;
        if (reservedOf[token] > maxReservedEverOf[token]) maxReservedEverOf[token] = reservedOf[token];
        if (maxUtilizationBps != 0) {
            uint256 assets = totalAssetsOverride != 0 ? totalAssetsOverride : usdg.balanceOf(address(this));
            if (totalReservedAmount > assets * maxUtilizationBps / 10_000) revert UtilizationExceeded();
        }
    }

    /// @inheritdoc IPitVault
    function releasePayout(address token, uint256 amount) external onlyEngine {
        reservedOf[token] -= amount; // underflow reverts: catches release/reserve desync
        totalReservedAmount -= amount;
    }

    /// @inheritdoc IPitVault
    function settleTraderWin(address to, uint256 amount) external onlyEngine {
        if (amount == 0) revert ZeroAmount();
        settledWinTotal += amount;
        usdg.safeTransfer(to, amount);
    }

    /// @inheritdoc IPitVault
    /// @dev Funding-credit channel: pays from balance with NO reserve bound (B9), mirroring the
    ///      real vault, so conservation tests against the mock stay honest.
    function settleFundingCredit(address to, uint256 amount) external onlyEngine {
        if (amount == 0) revert ZeroAmount();
        settledFundingCreditTotal += amount;
        usdg.safeTransfer(to, amount);
    }

    /// @inheritdoc IPitVault
    /// @dev PULLS the loss from the engine (transferFrom against the engine's standing
    ///      approval), mirroring the real PitVault so conservation tests are honest.
    function settleTraderLoss(uint256 amount) external onlyEngine {
        if (amount == 0) revert ZeroAmount();
        settledLossTotal += amount;
        usdg.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @inheritdoc IPitVault
    /// @dev PULLS the fee revenue from the engine (economics v2), mirroring the real PitVault
    ///      so conservation tests against the mock stay honest.
    function receiveFeeRevenue(uint256 amount) external onlyEngine {
        if (amount == 0) revert ZeroAmount();
        cumulativeFeeRevenue += amount;
        usdg.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @inheritdoc IPitVault
    function receiveLiquidationRevenue(uint256 amount) external onlyEngine {
        if (amount == 0) revert ZeroAmount();
        cumulativeLiquidationRevenue += amount;
        usdg.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @inheritdoc IPitVault
    function totalReserved() external view returns (uint256) {
        return totalReservedAmount;
    }
}
