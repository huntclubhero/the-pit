// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {HandoverPlan} from "./Deploy.s.sol";

/// @title FinalizeHandover: executes the timelock's ownership-acceptance batch and verifies it
/// @notice Wave-2b R-4, step 2 of the ownership handover. Deploy.s.sol transfers ownership of all
///         eleven owned contracts to the governance timelock (Ownable2Step: pendingOwner only) and
///         SCHEDULES the acceptance batch on the timelock. Once TIMELOCK_MIN_DELAY has elapsed,
///         OWNER (the timelock's executor) broadcasts this script to EXECUTE that batch, which
///         makes the timelock the live owner of every contract and revokes the deployer's
///         temporary proposer/canceller roles in the same operation. The script then asserts
///         owner() == timelock on every owned contract, so a partial or forgotten handover cannot
///         pass silently. Idempotent: if the batch already executed it skips straight to the
///         assertions, so it doubles as a standalone ownership audit.
/// @dev Run (executor key = OWNER):
///      forge script script/FinalizeHandover.s.sol --rpc-url robinhood --broadcast
///      Reads deployments/robinhood-4663.json written by Deploy.s.sol. UNTIL THIS SCRIPT (or a
///      manual executeBatch with HANDOVER_SALT) COMPLETES, THE DEPLOYER KEY REMAINS THE FULLY
///      PRIVILEGED, UN-TIMELOCKED OWNER OF THE ENTIRE STACK: execute at the earliest allowed time.
contract FinalizeHandover is Script, HandoverPlan {
    /// @dev An owned contract's live owner is not the timelock after execution.
    error OwnerNotTimelock(address target, address currentOwner);
    /// @dev The acceptance operation is unknown to the timelock (wrong address book or salt).
    error UnknownHandoverOperation(bytes32 operationId);
    /// @dev The acceptance operation exists but its delay has not elapsed yet.
    error HandoverNotReady(bytes32 operationId, uint256 readyAt);

    /// @notice Executes the pending acceptance batch (if not already done) and asserts the
    ///         timelock owns every owned contract.
    function run() external {
        string memory json = vm.readFile("deployments/robinhood-4663.json");
        TimelockController timelock = TimelockController(payable(vm.parseJsonAddress(json, ".timelock")));
        address deployer = vm.parseJsonAddress(json, ".deployer");
        address owner = vm.parseJsonAddress(json, ".owner");
        address[] memory owned = _ownedFromAddressBook(json);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _handoverBatch(owned, timelock, deployer, deployer != owner);
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT);

        if (!timelock.isOperationDone(id)) {
            if (!timelock.isOperation(id)) revert UnknownHandoverOperation(id);
            if (!timelock.isOperationReady(id)) revert HandoverNotReady(id, timelock.getTimestamp(id));
            vm.startBroadcast();
            timelock.executeBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT);
            vm.stopBroadcast();
        }

        // The post-handover invariant (wave-2b R-4): the timelock is the LIVE owner of every owned
        // contract, so no un-timelocked owner path remains anywhere in the stack.
        for (uint256 i = 0; i < owned.length; i++) {
            address currentOwner = Ownable2Step(owned[i]).owner();
            if (currentOwner != address(timelock)) revert OwnerNotTimelock(owned[i], currentOwner);
        }
    }

    /// @dev The eleven owned contracts from the address book, in the canonical handover order used by
    ///      Deploy._ownedContracts (the batch hash depends on this order).
    function _ownedFromAddressBook(string memory json) internal pure returns (address[] memory owned) {
        owned = new address[](11);
        owned[0] = vm.parseJsonAddress(json, ".oracleRouter");
        owned[1] = vm.parseJsonAddress(json, ".chainlinkAdapter");
        owned[2] = vm.parseJsonAddress(json, ".twapAdapter");
        owned[3] = vm.parseJsonAddress(json, ".twapAdapterB");
        owned[4] = vm.parseJsonAddress(json, ".crossPoolTwapAdapter");
        owned[5] = vm.parseJsonAddress(json, ".twoHopTwapAdapter");
        owned[6] = vm.parseJsonAddress(json, ".pitPoints");
        owned[7] = vm.parseJsonAddress(json, ".commitRevealCoordinator");
        owned[8] = vm.parseJsonAddress(json, ".spinVRF");
        owned[9] = vm.parseJsonAddress(json, ".jackpot");
        owned[10] = vm.parseJsonAddress(json, ".marketFactory");
    }
}
