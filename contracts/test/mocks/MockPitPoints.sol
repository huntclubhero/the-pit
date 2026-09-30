// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPitPoints} from "../../src/interfaces/IPitPoints.sol";

/// @title MockPitPoints: call-recording points engine with a togglable revert mode
/// @notice Records every hook invocation and its arguments. When revertOnCall is set,
///         every hook reverts, which lets tests prove that Market and MarketFactory
///         survive a broken points engine.
contract MockPitPoints is IPitPoints {
    error PointsIntentionalRevert();

    struct FillCall {
        address longParty;
        address shortParty;
        address maker;
        address token;
        uint256 notional;
    }

    struct SettleCall {
        address winner;
        address loser;
        address token;
        uint256 notional;
        uint256 pnlToWinner;
    }

    bool public revertOnCall;

    uint256 public onFillCalls;
    uint256 public onSettleCalls;
    uint256 public onMarketCreatedCalls;

    FillCall public lastFill;
    SettleCall public lastSettle;
    address public lastCreator;
    address public lastCreatedToken;

    function setRevertOnCall(bool value) external {
        revertOnCall = value;
    }

    /// @inheritdoc IPitPoints
    function onFill(address longParty, address shortParty, address maker, address token, uint256 notional) external {
        if (revertOnCall) revert PointsIntentionalRevert();
        onFillCalls++;
        lastFill = FillCall(longParty, shortParty, maker, token, notional);
    }

    /// @inheritdoc IPitPoints
    function onSettle(address winner, address loser, address token, uint256 notional, uint256 pnlToWinner) external {
        if (revertOnCall) revert PointsIntentionalRevert();
        onSettleCalls++;
        lastSettle = SettleCall(winner, loser, token, notional, pnlToWinner);
    }

    /// @inheritdoc IPitPoints
    function onMarketCreated(address creator, address token) external {
        if (revertOnCall) revert PointsIntentionalRevert();
        onMarketCreatedCalls++;
        lastCreator = creator;
        lastCreatedToken = token;
    }
}
