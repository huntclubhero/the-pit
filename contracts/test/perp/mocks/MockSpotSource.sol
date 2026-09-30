// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ISpotSource} from "../../../src/oracle/adapters/ISpotSource.sol";

/// @title MockSpotSource: settable instantaneous price for the engine's vol-deviation proxy
/// @notice The economics v2 vol surcharge and cap discount derive recentDeviationBps from the
///         spread between this spot reading and the settlement mark, exactly as the opening
///         breaker does. Fully settable, can be told to revert or report not-ok.
contract MockSpotSource is ISpotSource {
    mapping(address => uint256) public spotOf;
    mapping(address => bool) public okOf;
    bool public revertOnRead;

    function setSpot(address token, uint256 price1e18, bool ok) external {
        spotOf[token] = price1e18;
        okOf[token] = ok;
    }

    function setRevertOnRead(bool v) external {
        revertOnRead = v;
    }

    /// @inheritdoc ISpotSource
    function readSpot(address token) external view returns (uint256 price1e18, bool ok) {
        require(!revertOnRead, "MockSpotSource: forced revert");
        return (spotOf[token], okOf[token]);
    }
}
