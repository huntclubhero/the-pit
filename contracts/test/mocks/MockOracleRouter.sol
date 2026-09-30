// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Types} from "../../src/interfaces/Types.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";

/// @title MockOracleRouter: fully settable oracle router for core module tests
/// @notice Per-token settable price and status, tracked liquidity, snapshot value, and
///         listability. Records checkPrice and snapshotLiquidity call counts.
contract MockOracleRouter is IOracleRouter {
    mapping(address => uint256) public price1e18Of;
    mapping(address => Types.PriceStatus) public statusOf;
    mapping(address => uint256) public trackedLiquidityOf;
    mapping(address => uint256) public snapshotValueOf;
    mapping(address => bool) public listableOf;

    // Opening breaker: default ALLOWED so existing fill flows are unaffected; settable per token.
    mapping(address => bool) internal _openingDenied;
    mapping(address => uint8) internal _openingReason;

    // Absolute cost-to-move payout cap the factory reads (aux surface, not part of IOracleRouter).
    // Defaults to unbounded (type(uint256).max) so a market's cap stays governed by oiCapBps unless
    // a test opts into an explicit absolute cap.
    mapping(address => bool) internal _payoutCapSet;
    mapping(address => uint256) internal _payoutCap;

    uint256 public checkPriceCalls;
    uint256 public snapshotCalls;

    // ====================================================================== setters ======================================================================

    function setPrice(address token, uint256 price1e18, Types.PriceStatus status) external {
        price1e18Of[token] = price1e18;
        statusOf[token] = status;
    }

    function setTrackedLiquidity(address token, uint256 liquidityUsd1e18) external {
        trackedLiquidityOf[token] = liquidityUsd1e18;
    }

    function setSnapshotValue(address token, uint256 liquidityUsd1e18) external {
        snapshotValueOf[token] = liquidityUsd1e18;
    }

    function setListable(address token, bool listable) external {
        listableOf[token] = listable;
    }

    /// @dev Force openingAllowed(token) to deny with a reason code (default is allow).
    function setOpeningDenied(address token, bool denied, uint8 reason) external {
        _openingDenied[token] = denied;
        _openingReason[token] = reason;
    }

    /// @dev Set the absolute payout cap the factory reads via maxMarketPayoutCap1e18(token).
    function setPayoutCap(address token, uint256 cap1e18) external {
        _payoutCapSet[token] = true;
        _payoutCap[token] = cap1e18;
    }

    // ====================================================================== IOracleRouter ======================================================================

    /// @inheritdoc IOracleRouter
    function checkPrice(address token) external returns (uint256 price1e18, Types.PriceStatus status) {
        checkPriceCalls++;
        return (price1e18Of[token], statusOf[token]);
    }

    /// @inheritdoc IOracleRouter
    function peekPrice(address token) external view returns (uint256 price1e18, Types.PriceStatus status) {
        return (price1e18Of[token], statusOf[token]);
    }

    /// @inheritdoc IOracleRouter
    function isListable(address token) external view returns (bool) {
        return listableOf[token];
    }

    /// @inheritdoc IOracleRouter
    function trackedLiquidity(address token) external view returns (uint256 liquidityUsd1e18) {
        return trackedLiquidityOf[token];
    }

    /// @inheritdoc IOracleRouter
    function snapshotLiquidity(address token) external returns (uint256 liquidityUsd1e18) {
        snapshotCalls++;
        return snapshotValueOf[token];
    }

    /// @inheritdoc IOracleRouter
    function openingAllowed(address token) external view returns (bool allowed, uint8 reason) {
        if (_openingDenied[token]) return (false, _openingReason[token]);
        return (true, 0);
    }

    /// @notice Aux surface (not part of IOracleRouter): absolute payout cap the factory bakes into
    ///         a new market. Unbounded by default so the OI cap stays governed by oiCapBps.
    function maxMarketPayoutCap1e18(address token) external view returns (uint256) {
        return _payoutCapSet[token] ? _payoutCap[token] : type(uint256).max;
    }
}
