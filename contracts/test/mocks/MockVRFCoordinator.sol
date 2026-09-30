// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {VRFV2PlusClient} from "@chainlink/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @notice Consumer callback surface (mirrors VRF v2.5 rawFulfillRandomWords).
interface IVRFV2PlusConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @title MockVRFCoordinator: test double for the Chainlink VRF v2.5 coordinator
/// @notice Records every request and lets tests fulfill with chosen words. Can be
///         switched into a reverting mode to exercise never-revert guarantees.
contract MockVRFCoordinator {
    /// @notice Everything the consumer sent with a request, plus the sender.
    struct RecordedRequest {
        address sender;
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    /// @notice Recorded requests by request id.
    mapping(uint256 requestId => RecordedRequest request) public requests;

    /// @notice Total requests accepted.
    uint256 public requestCount;

    /// @notice When true, requestRandomWords reverts (simulates a broken coordinator).
    bool public revertOnRequest;

    uint256 private _nextRequestId = 1;

    /// @notice Toggles forced reverts on requestRandomWords.
    function setRevertOnRequest(bool value) external {
        revertOnRequest = value;
    }

    /// @notice Overrides the next request id (e.g. to simulate duplicate ids).
    function setNextRequestId(uint256 requestId) external {
        _nextRequestId = requestId;
    }

    /// @notice VRF v2.5 request entry point; records and returns a fresh id.
    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req) external returns (uint256 requestId) {
        if (revertOnRequest) revert("MockVRFCoordinator: forced revert");
        requestId = _nextRequestId;
        _nextRequestId = requestId + 1;
        requestCount = requestCount + 1;
        requests[requestId] = RecordedRequest({
            sender: msg.sender,
            keyHash: req.keyHash,
            subId: req.subId,
            requestConfirmations: req.requestConfirmations,
            callbackGasLimit: req.callbackGasLimit,
            numWords: req.numWords,
            extraArgs: req.extraArgs
        });
    }

    /// @notice Test-driven fulfillment: calls the consumer with chosen words.
    function fulfill(address consumer, uint256 requestId, uint256[] calldata randomWords) external {
        IVRFV2PlusConsumer(consumer).rawFulfillRandomWords(requestId, randomWords);
    }
}
