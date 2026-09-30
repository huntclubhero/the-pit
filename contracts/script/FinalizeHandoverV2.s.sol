// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {HandoverPlanV2} from "./DeployPerpV2.s.sol";

/// @title FinalizeHandoverV2: executes the v2 timelock's ownership-acceptance batch and verifies it
/// @notice Phase 2 of the v2 ownership handover (wave-2b R-4 pattern, expanded owned set).
///         DeployPerpV2.s.sol transfers ownership of all FOURTEEN owned contracts (the v1 casino +
///         oracle set minus the retired MarketFactory, plus PerpRiskConfig, InsuranceFund,
///         PitVault, PerpEngine) to the governance timelock (Ownable2Step: pendingOwner only) and
///         SCHEDULES the acceptance batch under HANDOVER_SALT_V2. Once TIMELOCK_MIN_DELAY has
///         elapsed, OWNER (the timelock's executor) broadcasts this script to EXECUTE that batch,
///         which makes the timelock the live owner of every contract and revokes the deployer's
///         temporary proposer/canceller roles in the same operation. The script then asserts
///         owner() == timelock on every owned contract, so a partial or forgotten handover cannot
///         pass silently. Idempotent: if the batch already executed it skips straight to the
///         assertions, so it doubles as a standalone ownership audit.
/// @dev Run (executor key = OWNER):
///      forge script script/FinalizeHandoverV2.s.sol --rpc-url robinhood --broadcast
///      Reads deployments/robinhood-4663-v2.json written by DeployPerpV2.s.sol. UNTIL THIS SCRIPT
///      (or a manual executeBatch with HANDOVER_SALT_V2) COMPLETES, THE DEPLOYER KEY REMAINS THE
///      FULLY PRIVILEGED, UN-TIMELOCKED OWNER OF THE ENTIRE V2 STACK: execute at the earliest
///      allowed time.
contract FinalizeHandoverV2 is Script, HandoverPlanV2 {
    /// @dev An owned contract's live owner is not the timelock after execution.
    error OwnerNotTimelock(address target, address currentOwner);
    /// @dev The acceptance operation is unknown to the timelock (wrong address book or salt).
    error UnknownHandoverOperation(bytes32 operationId);
    /// @dev The acceptance operation exists but its delay has not elapsed yet.
    error HandoverNotReady(bytes32 operationId, uint256 readyAt);

    /// @notice Executes the pending acceptance batch (if not already done) and asserts the
    ///         timelock owns every owned contract.
    function run() external {
        string memory json = vm.readFile("deployments/robinhood-4663-v2.json");
        TimelockController timelock = TimelockController(payable(vm.parseJsonAddress(json, ".timelock")));
        address deployer = vm.parseJsonAddress(json, ".deployer");
        address owner = vm.parseJsonAddress(json, ".owner");
        address[] memory owned = _ownedFromAddressBook(json);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _handoverBatch(owned, timelock, deployer, deployer != owner);
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT_V2);

        if (!timelock.isOperationDone(id)) {
            if (!timelock.isOperation(id)) revert UnknownHandoverOperation(id);
            if (!timelock.isOperationReady(id)) revert HandoverNotReady(id, timelock.getTimestamp(id));
            vm.startBroadcast();
            timelock.executeBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT_V2);
            vm.stopBroadcast();
        }

        // The post-handover invariant: the timelock is the LIVE owner of every owned contract, so
        // no un-timelocked owner path remains anywhere in the v2 stack.
        for (uint256 i = 0; i < owned.length; ++i) {
            address currentOwner = Ownable2Step(owned[i]).owner();
            if (currentOwner != address(timelock)) revert OwnerNotTimelock(owned[i], currentOwner);
        }
    }

    /// @dev The fourteen owned contracts from the address book, in the canonical v2 handover
    ///      order of DeployPerpV2._ownedContracts (the batch hash depends on this order).
    function _ownedFromAddressBook(string memory json) internal pure returns (address[] memory owned) {
        owned = new address[](OWNED_COUNT_V2);
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
        owned[10] = vm.parseJsonAddress(json, ".perpRiskConfig");
        owned[11] = vm.parseJsonAddress(json, ".insuranceFund");
        owned[12] = vm.parseJsonAddress(json, ".pitVault");
        owned[13] = vm.parseJsonAddress(json, ".perpEngine");
    }
}
