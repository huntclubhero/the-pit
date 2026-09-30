// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Types} from "../../../src/interfaces/Types.sol";
import {IOracleRouter} from "../../../src/interfaces/IOracleRouter.sol";
import {IOracleRouterPerp} from "../../../src/perp/IOracleRouterPerp.sol";

/// @title MockPerpOracle: fully settable oracle surface for PerpEngine tests
/// @notice Per-token settable price, status, breaker state (drives the LIVE/FALLBACK/BLOCKED
///         classifier), opening breaker, listability, and the cost-to-move payout cap.
contract MockPerpOracle is IOracleRouterPerp {
    mapping(address => uint256) public priceOf;
    mapping(address => Types.PriceStatus) public statusOf;
    mapping(address => uint64) public cooldownUntilOf;
    mapping(address => uint8) public failedRoundsOf;
    mapping(address => bool) public openingDeniedOf;
    mapping(address => uint8) public openingReasonOf;
    mapping(address => bool) public listableOf;
    mapping(address => uint256) internal _payoutCap1e18;
    mapping(address => bool) internal _payoutCapSet;
    mapping(address => uint256) public trackedLiquidityOf;
    // Settlement-tier config (B5): tier (0=A_MAJOR,1=B_DEEP,2=C_MID,3=D_THIN) + opening spotSource.
    mapping(address => uint8) internal _tierOf;
    mapping(address => address) internal _spotSourceOf;

    uint256 public checkPriceCalls;

    // ============================== setters ==============================

    function setPrice(address token, uint256 price1e18, Types.PriceStatus status) external {
        priceOf[token] = price1e18;
        statusOf[token] = status;
    }

    /// @dev Convenience: an OK price with a clean breaker (a LIVE print).
    function setLive(address token, uint256 price1e18) external {
        priceOf[token] = price1e18;
        statusOf[token] = Types.PriceStatus.OK;
        cooldownUntilOf[token] = 0;
        failedRoundsOf[token] = 0;
    }

    /// @dev Convenience: an OK price with a dirty breaker (a FALLBACK ring-median print).
    function setFallback(address token, uint256 price1e18) external {
        priceOf[token] = price1e18;
        statusOf[token] = Types.PriceStatus.OK;
        cooldownUntilOf[token] = uint64(block.timestamp + 30 minutes);
        failedRoundsOf[token] = 1;
    }

    /// @dev Convenience: a blocked print (COOLDOWN status).
    function setBlocked(address token) external {
        statusOf[token] = Types.PriceStatus.COOLDOWN;
    }

    function setBreaker(address token, uint64 cooldownUntil, uint8 failedRounds) external {
        cooldownUntilOf[token] = cooldownUntil;
        failedRoundsOf[token] = failedRounds;
    }

    function setOpeningDenied(address token, bool denied, uint8 reason) external {
        openingDeniedOf[token] = denied;
        openingReasonOf[token] = reason;
    }

    function setListable(address token, bool listable) external {
        listableOf[token] = listable;
    }

    function setPayoutCap1e18(address token, uint256 cap) external {
        _payoutCapSet[token] = true;
        _payoutCap1e18[token] = cap;
    }

    function setTrackedLiquidity(address token, uint256 liquidityUsd1e18) external {
        trackedLiquidityOf[token] = liquidityUsd1e18;
    }

    /// @dev Set a token's settlement tier and opening spot source (B5 listMarket gate).
    function setTierConfig(address token, uint8 tier, address spotSource) external {
        _tierOf[token] = tier;
        _spotSourceOf[token] = spotSource;
    }

    // ============================ IOracleRouter ============================

    /// @inheritdoc IOracleRouter
    function checkPrice(address token) external returns (uint256 price1e18, Types.PriceStatus status) {
        checkPriceCalls++;
        return (statusOf[token] == Types.PriceStatus.OK ? priceOf[token] : 0, statusOf[token]);
    }

    /// @inheritdoc IOracleRouter
    function peekPrice(address token) external view returns (uint256 price1e18, Types.PriceStatus status) {
        return (statusOf[token] == Types.PriceStatus.OK ? priceOf[token] : 0, statusOf[token]);
    }

    /// @inheritdoc IOracleRouter
    function isListable(address token) external view returns (bool) {
        return listableOf[token];
    }

    /// @inheritdoc IOracleRouter
    function openingAllowed(address token) external view returns (bool allowed, uint8 reason) {
        if (openingDeniedOf[token]) return (false, openingReasonOf[token]);
        return (true, 0);
    }

    /// @inheritdoc IOracleRouter
    function trackedLiquidity(address token) external view returns (uint256 liquidityUsd1e18) {
        return trackedLiquidityOf[token];
    }

    /// @inheritdoc IOracleRouter
    function snapshotLiquidity(address token) external view returns (uint256 liquidityUsd1e18) {
        return trackedLiquidityOf[token];
    }

    // =========================== IOracleRouterPerp ===========================

    /// @inheritdoc IOracleRouterPerp
    function breakerOf(address token) external view returns (uint64 cooldownUntil, uint8 failedRounds) {
        return (cooldownUntilOf[token], failedRoundsOf[token]);
    }

    /// @inheritdoc IOracleRouterPerp
    function maxMarketPayoutCap1e18(address token) external view returns (uint256) {
        return _payoutCapSet[token] ? _payoutCap1e18[token] : type(uint256).max;
    }

    /// @inheritdoc IOracleRouterPerp
    function tierConfigOf(address token)
        external
        view
        returns (uint8 tier, uint256, uint32, uint256, uint256, uint16, address spotSource, bool set)
    {
        tier = _tierOf[token];
        spotSource = _spotSourceOf[token];
        set = true;
    }
}
