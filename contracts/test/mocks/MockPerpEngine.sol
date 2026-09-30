// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";
import {IPitVault} from "../../src/perp/interfaces/IPitVault.sol";
import {IInsuranceFund} from "../../src/perp/interfaces/IInsuranceFund.sol";
import {IPerpMarketList} from "../../src/perp/interfaces/IPerpVaultDeps.sol";

/// @title MockPerpEngine: settable market registry + counterparty-surface passthrough for tests
/// @notice Implements IPerpMarketList (the vault's NAV dependency) with fully settable per-market
///         aggregates, and forwards counterparty/insurance calls so the vault and fund see this
///         contract as the authorized engine. Test-only.
contract MockPerpEngine is IPerpMarketList {
    IERC20 public immutable usdg;
    IPitVault public vault;
    IInsuranceFund public fund;

    address[] private _markets;
    mapping(address token => bool) private _known;
    mapping(address token => PerpTypes.MarketAggregates) private _aggs;
    mapping(address token => bool) private _capSet;
    mapping(address token => uint256) private _cap1e18;

    constructor(IERC20 usdg_) {
        usdg = usdg_;
    }

    // ================================ wiring ================================

    function setVault(IPitVault vault_) external {
        vault = vault_;
    }

    function setFund(IInsuranceFund fund_) external {
        fund = fund_;
    }

    /// @notice Approve the vault to pull USDG (settleTraderLoss uses transferFrom).
    function approveVault(uint256 amount) external {
        usdg.approve(address(vault), amount);
    }

    // ================================ registry setters ================================

    function setMarketState(address token, PerpTypes.MarketAggregates calldata agg) external {
        if (!_known[token]) {
            _known[token] = true;
            _markets.push(token);
        }
        _aggs[token] = agg;
    }

    /// @notice Set the engine's FROZEN per-market payout cap the vault now reads (B1). Unset
    ///         markets answer type(uint256).max (unbounded), matching a real major.
    function setMarketMaxPayoutCap1e18(address token, uint256 cap1e18) external {
        _capSet[token] = true;
        _cap1e18[token] = cap1e18;
    }

    // ================================ IPerpMarketList ================================

    /// @inheritdoc IPerpMarketList
    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    /// @inheritdoc IPerpMarketList
    function marketAt(uint256 index) external view returns (address) {
        return _markets[index];
    }

    /// @inheritdoc IPerpMarketList
    function marketState(address token) external view returns (PerpTypes.MarketAggregates memory) {
        return _aggs[token];
    }

    /// @inheritdoc IPerpMarketList
    function marketMaxPayoutCap1e18(address token) external view returns (uint256) {
        return _capSet[token] ? _cap1e18[token] : type(uint256).max;
    }

    // ================================ counterparty passthrough ================================

    function doReserve(address token, uint256 amount) external {
        vault.reservePayout(token, amount);
    }

    function doRelease(address token, uint256 amount) external {
        vault.releasePayout(token, amount);
    }

    function doWin(address to, uint256 amount) external {
        vault.settleTraderWin(to, amount);
    }

    function doFundingCredit(address to, uint256 amount) external {
        vault.settleFundingCredit(to, amount);
    }

    function doLoss(uint256 amount) external {
        usdg.approve(address(vault), amount);
        vault.settleTraderLoss(amount);
    }

    function doFeeRevenue(uint256 amount) external {
        usdg.approve(address(vault), amount);
        vault.receiveFeeRevenue(amount);
    }

    function doLiqRevenue(uint256 amount) external {
        usdg.approve(address(vault), amount);
        vault.receiveLiquidationRevenue(amount);
    }

    // ================================ insurance passthrough ================================

    function doCover(uint256 shortfall, address vault_) external returns (uint256) {
        return fund.cover(shortfall, vault_);
    }

    function doPayKeeperFloor(address keeper, uint256 amount) external {
        fund.payKeeperFloor(keeper, amount);
    }
}
