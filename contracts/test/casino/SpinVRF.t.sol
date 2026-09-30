// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {CasinoTestBase} from "./CasinoTestBase.t.sol";
import {SpinVRF} from "../../src/casino/SpinVRF.sol";
import {MockVRFCoordinator} from "../mocks/MockVRFCoordinator.sol";

/// @title SpinVRF access, threshold mapping, audit trail, and skip-path tests
contract SpinVRFTest is CasinoTestBase {
    address internal alice;
    address internal bob;

    function setUp() public override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    /// @dev Fills and returns (requestId, takerEarn) for alice as taker.
    function fillAndGetRequest() internal returns (uint256 requestId, uint256 takerEarn) {
        uint256 before = points.pointsOf(alice);
        fill(alice, bob, bob, tokenB, 100e6);
        takerEarn = points.pointsOf(alice) - before;
        requestId = coordinator.requestCount();
    }

    // ===============================================================
    // Access control
    // ===============================================================

    function test_requestSpin_onlyPitPoints() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(SpinVRF.OnlyPitPoints.selector, rando));
        spin.requestSpin(alice, 1e18, tokenB);
    }

    function test_fulfill_onlyRecordedCoordinator() public {
        (uint256 requestId,) = fillAndGetRequest();
        uint256[] memory words = new uint256[](1);
        words[0] = 123;

        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(SpinVRF.OnlyRequestCoordinator.selector, rando, address(coordinator)));
        spin.rawFulfillRandomWords(requestId, words);
    }

    function test_adminCannotInfluenceInFlightSpin() public {
        (uint256 requestId, uint256 takerEarn) = fillAndGetRequest();

        // Admin swaps the coordinator while the spin is in flight.
        MockVRFCoordinator coordinator2 = new MockVRFCoordinator();
        spin.setCoordinator(address(coordinator2));

        // The new coordinator cannot fulfill the pinned request.
        uint256[] memory words = new uint256[](1);
        words[0] = 9999;
        vm.expectRevert(
            abi.encodeWithSelector(
                SpinVRF.OnlyRequestCoordinator.selector, address(coordinator2), address(coordinator)
            )
        );
        coordinator2.fulfill(address(spin), requestId, words);

        // The original coordinator still can.
        fulfillSpin(requestId, 9999);
        (,,, bool fulfilled, uint256 multiplier,,) = spin.getSpin(requestId);
        assertTrue(fulfilled);
        assertEq(multiplier, 100);
        assertEq(points.pointsOf(alice), takerEarn * 100, "99x bonus on top of base earn");
    }

    function test_fulfill_unknownRequestReverts() public {
        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(SpinVRF.UnknownRequest.selector, 777));
        coordinator.fulfill(address(spin), 777, words);
    }

    function test_fulfill_twiceReverts() public {
        (uint256 requestId,) = fillAndGetRequest();
        fulfillSpin(requestId, 5);
        uint256[] memory words = new uint256[](1);
        words[0] = 5;
        vm.expectRevert(abi.encodeWithSelector(SpinVRF.AlreadyFulfilled.selector, requestId));
        coordinator.fulfill(address(spin), requestId, words);
    }

    function test_fulfill_emptyWordsReverts() public {
        (uint256 requestId,) = fillAndGetRequest();
        uint256[] memory words = new uint256[](0);
        vm.expectRevert(SpinVRF.EmptyRandomWords.selector);
        coordinator.fulfill(address(spin), requestId, words);
    }

    // ===============================================================
    // Threshold mapping
    // ===============================================================

    function test_thresholdBoundaries_exact() public view {
        assertEq(spin.multiplierForWord(0), 1);
        assertEq(spin.multiplierForWord(5999), 1);
        assertEq(spin.multiplierForWord(6000), 2);
        assertEq(spin.multiplierForWord(8499), 2);
        assertEq(spin.multiplierForWord(8500), 5);
        assertEq(spin.multiplierForWord(9499), 5);
        assertEq(spin.multiplierForWord(9500), 20);
        assertEq(spin.multiplierForWord(9899), 20);
        assertEq(spin.multiplierForWord(9900), 100);
        assertEq(spin.multiplierForWord(9999), 100);
        // Modulus wraps.
        assertEq(spin.multiplierForWord(10_000), 1);
        assertEq(spin.multiplierForWord(10_000 + 6000), 2);
        assertEq(spin.multiplierForWord(type(uint256).max), spin.multiplierForWord(type(uint256).max % 10_000));
    }

    function testFuzz_thresholdMapping(uint256 word) public view {
        uint256 roll = word % 10_000;
        uint256 expected;
        if (roll < 6000) expected = 1;
        else if (roll < 8500) expected = 2;
        else if (roll < 9500) expected = 5;
        else if (roll < 9900) expected = 20;
        else expected = 100;
        assertEq(spin.multiplierForWord(word), expected);
    }

    function test_distribution_sequentialWordsExactCounts() public view {
        uint256 c1;
        uint256 c2;
        uint256 c5;
        uint256 c20;
        uint256 c100;
        for (uint256 word = 0; word < 10_000; word++) {
            uint256 m = spin.multiplierForWord(word);
            if (m == 1) c1++;
            else if (m == 2) c2++;
            else if (m == 5) c5++;
            else if (m == 20) c20++;
            else c100++;
        }
        assertEq(c1, 6000, "60%");
        assertEq(c2, 2500, "25%");
        assertEq(c5, 1000, "10%");
        assertEq(c20, 400, "4%");
        assertEq(c100, 100, "1%");
    }

    // ===============================================================
    // Bonus minting and audit trail
    // ===============================================================

    function test_bonusMinting_1xMintsNothing() public {
        (uint256 requestId, uint256 takerEarn) = fillAndGetRequest();
        fulfillSpin(requestId, 4321); // 1x
        assertEq(points.pointsOf(alice), takerEarn, "no bonus on 1x");
        (,,, bool fulfilled, uint256 multiplier,, uint256 word) = spin.getSpin(requestId);
        assertTrue(fulfilled);
        assertEq(multiplier, 1);
        assertEq(word, 4321);
    }

    function test_bonusMinting_20x() public {
        (uint256 requestId, uint256 takerEarn) = fillAndGetRequest();
        fulfillSpin(requestId, 9500); // 20x
        assertEq(points.pointsOf(alice), takerEarn * 20, "base + 19x bonus");
    }

    function test_auditTrail_fullRecord() public {
        (uint256 requestId, uint256 takerEarn) = fillAndGetRequest();
        (address user, address token, address reqCoordinator, bool fulfilled, uint256 multiplier, uint256 basePoints, uint256 word)
            = spin.getSpin(requestId);
        assertEq(user, alice);
        assertEq(token, tokenB);
        assertEq(reqCoordinator, address(coordinator));
        assertFalse(fulfilled);
        assertEq(multiplier, 0);
        assertEq(basePoints, takerEarn);
        assertEq(word, 0);

        fulfillSpin(requestId, 8765); // 5x
        (,,, fulfilled, multiplier,, word) = spin.getSpin(requestId);
        assertTrue(fulfilled);
        assertEq(multiplier, 5);
        assertEq(word, 8765);
        assertEq(spin.spinCount(), 1);
    }

    function test_requestRecordedOnCoordinator() public {
        (uint256 requestId,) = fillAndGetRequest();
        (address sender,,,,, uint32 numWords,) = coordinator.requests(requestId);
        assertEq(sender, address(spin), "spin contract is the requester");
        assertEq(numWords, 1, "exactly one word per spin");
    }

    // ===============================================================
    // 100x bonus (audit fix C1: the big bonus stays; no entrant lottery slot)
    // ===============================================================

    function test_100x_mintsFullBonusNoEntrantSlot() public {
        // The uniform Pit Drop entrant draw was removed in C1. A 100x outcome still
        // mints the full 99x bonus; it just no longer buys a separate lottery slot.
        (uint256 requestId, uint256 takerEarn) = fillAndGetRequest();
        fulfillSpin(requestId, 9950); // 100x
        assertEq(points.pointsOf(alice), takerEarn * 100, "base + 99x bonus");
        (,,, bool fulfilled, uint256 multiplier,,) = spin.getSpin(requestId);
        assertTrue(fulfilled);
        assertEq(multiplier, 100);
    }

    function test_renounceOwnership_reverts() public {
        vm.expectRevert(SpinVRF.RenounceDisabled.selector);
        spin.renounceOwnership();
    }

    // ===============================================================
    // Skip paths (requestSpin never reverts)
    // ===============================================================

    function test_skip_onCoordinatorRevert() public {
        coordinator.setRevertOnRequest(true);
        vm.expectEmit(true, true, true, true, address(spin));
        emit SpinVRF.SpinSkipped(alice, 10e18, tokenB, bytes32("COORDINATOR_REVERT"));
        fill(alice, bob, bob, tokenB, 100e6);
        assertEq(spin.spinCount(), 0, "no record for skipped spin");
        assertEq(points.pointsOf(alice), 10e18, "fill still earned");
    }

    function test_skip_onZeroBasePoints() public {
        vm.prank(address(points));
        vm.expectEmit(true, true, true, true, address(spin));
        emit SpinVRF.SpinSkipped(alice, 0, tokenB, bytes32("ZERO_BASE"));
        spin.requestSpin(alice, 0, tokenB);
        assertEq(spin.spinCount(), 0);
    }

    function test_skip_onZeroUser() public {
        vm.prank(address(points));
        vm.expectEmit(true, true, true, true, address(spin));
        emit SpinVRF.SpinSkipped(address(0), 1e18, tokenB, bytes32("ZERO_USER"));
        spin.requestSpin(address(0), 1e18, tokenB);
        assertEq(spin.spinCount(), 0);
    }

    function test_skip_onUnsetCoordinator() public {
        spin.setCoordinator(address(0));
        vm.prank(address(points));
        vm.expectEmit(true, true, true, true, address(spin));
        emit SpinVRF.SpinSkipped(alice, 1e18, tokenB, bytes32("NO_COORDINATOR"));
        spin.requestSpin(alice, 1e18, tokenB);
        assertEq(spin.spinCount(), 0);
    }

    function test_skip_onDuplicateRequestId() public {
        (uint256 requestId,) = fillAndGetRequest();
        // Force the coordinator to hand out the same id again.
        coordinator.setNextRequestId(requestId);
        vm.prank(address(points));
        vm.expectEmit(true, true, true, true, address(spin));
        emit SpinVRF.SpinSkipped(alice, 1e18, tokenB, bytes32("DUPLICATE_REQUEST_ID"));
        spin.requestSpin(alice, 1e18, tokenB);
        assertEq(spin.spinCount(), 1, "original record preserved");
        (,,,,, uint256 basePoints,) = spin.getSpin(requestId);
        assertGt(basePoints, 0);
    }
}
