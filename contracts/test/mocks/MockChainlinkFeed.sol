// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title MockChainlinkFeed: settable AggregatorV3Interface implementation for oracle tests
contract MockChainlinkFeed is AggregatorV3Interface {
    uint8 internal _decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _roundId;
    bool public revertOnRead;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
        _roundId = 1;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
        _roundId += 1;
    }

    function setRevertOnRead(bool value) external {
        revertOnRead = value;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "MockChainlinkFeed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 roundId_)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(!revertOnRead, "MOCK_FEED_REVERT");
        return (roundId_, _answer, _updatedAt, _updatedAt, roundId_);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(!revertOnRead, "MOCK_FEED_REVERT");
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
