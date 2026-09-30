// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";

/// @notice Minimal Uniswap v3 pool surface needed to grow the observation ring buffer.
interface IPoolCardinality {
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

/// @title GrowCardinality: one-time observation cardinality bump for tracked pools
/// @notice Every Uniswap v3 pool used as a TWAP source MUST have its observation cardinality
///         grown once (fresh pools start at 1, which cannot serve any lookback window: observe()
///         reverts "OLD" and our adapters report ok = false). This script calls
///         increaseObservationCardinalityNext(target) on every pool in the POOLS env var.
///         The bump only takes effect as swaps write new observations, and the TWAP window only
///         becomes servable after the ring holds observations spanning it: after running this,
///         wait at least one full window of ordinary trading before relying on the TWAP source.
///         See docs/ops-runbook.md for the full procedure.
/// @dev Env:
///      POOLS: comma-separated pool addresses (required).
///      CARDINALITY_TARGET: desired observationCardinalityNext, default 240 (about one hour of
///      per-block observations, comfortably covering a 30 minute window).
///      Pools already at or above the target are skipped (the call would be a no-op anyway;
///      skipping keeps the broadcast minimal).
contract GrowCardinality is Script {
    /// @notice Default target cardinality when CARDINALITY_TARGET is unset.
    uint16 public constant DEFAULT_TARGET = 240;

    /// @dev CARDINALITY_TARGET does not fit uint16.
    error TargetTooLarge(uint256 target);

    /// @notice Reads POOLS and CARDINALITY_TARGET, then bumps each pool once.
    function run() external {
        address[] memory pools = vm.envAddress("POOLS", ",");
        uint256 rawTarget = vm.envOr("CARDINALITY_TARGET", uint256(DEFAULT_TARGET));
        if (rawTarget > type(uint16).max) revert TargetTooLarge(rawTarget);
        uint16 target = uint16(rawTarget);

        vm.startBroadcast();
        for (uint256 i = 0; i < pools.length; i++) {
            IPoolCardinality pool = IPoolCardinality(pools[i]);
            (,,,, uint16 cardinalityNext,,) = pool.slot0();
            if (cardinalityNext >= target) continue;
            pool.increaseObservationCardinalityNext(target);
        }
        vm.stopBroadcast();
    }
}
