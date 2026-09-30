// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VRFV2PlusClient} from "@chainlink/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {CommitRevealCoordinator} from "../../src/casino/CommitRevealCoordinator.sol";
import {SpinVRF} from "../../src/casino/SpinVRF.sol";
import {PitPoints} from "../../src/casino/PitPoints.sol";

/// @dev Bare consumer used to exercise the raw VRF surface directly.
contract RecordingConsumer {
    CommitRevealCoordinator public coordinator;
    uint256 public lastRequestId;
    uint256[] public lastWords;

    constructor(CommitRevealCoordinator coordinator_) {
        coordinator = coordinator_;
    }

    function request(uint32 numWords, uint16 confirmations) external returns (uint256) {
        return coordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: 0,
                requestConfirmations: confirmations,
                callbackGasLimit: 500_000,
                numWords: numWords,
                extraArgs: ""
            })
        );
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        lastRequestId = requestId;
        lastWords = randomWords;
    }

    function lastWordsLength() external view returns (uint256) {
        return lastWords.length;
    }
}

/// @dev A caller that finalizes the timeout fallback but reverts unless the delivered word equals a
///      target it wants. Used to prove a grinding caller cannot force a specific fallback outcome.
contract GrindingTimeoutCaller {
    CommitRevealCoordinator public coordinator;
    SpinVRF public spin;
    uint256 public wantWord;

    error Unfavorable();

    constructor(CommitRevealCoordinator coordinator_, SpinVRF spin_, uint256 wantWord_) {
        coordinator = coordinator_;
        spin = spin_;
        wantWord = wantWord_;
    }

    function tryFulfill(uint256 requestId) external {
        coordinator.fulfillTimeout(requestId);
        (,,,,,, uint256 word) = spin.getSpin(requestId);
        if (word != wantWord) revert Unfavorable();
    }
}

contract CommitRevealCoordinatorTest is Test {
    address internal constant OPERATOR = address(0x0921);
    address internal constant USER = address(0xCAFE);
    address internal constant MARKET_TOKEN = address(0xF00D);
    uint256 internal constant BASE_POINTS = 10e18;

    bytes32 internal constant SECRET = keccak256("the pit secret one");
    bytes32 internal constant SECRET_2 = keccak256("the pit secret two");

    CommitRevealCoordinator internal coordinator;
    PitPoints internal points;
    SpinVRF internal spin;
    RecordingConsumer internal consumer;

    function setUp() public {
        coordinator = new CommitRevealCoordinator(address(this), OPERATOR);
        points = new PitPoints(address(this));
        spin = new SpinVRF(address(this), address(points));
        points.setSpinVRF(address(spin));
        spin.setCoordinator(address(coordinator));
        consumer = new RecordingConsumer(coordinator);
        coordinator.setConsumer(address(spin), true);
        coordinator.setConsumer(address(consumer), true);
        vm.roll(1000);
        vm.warp(10_000_000);
    }

    function _commit(bytes32 secret) internal {
        vm.prank(OPERATOR);
        coordinator.commit(keccak256(abi.encodePacked(secret)));
    }

    function _requestSpin() internal {
        vm.prank(address(points));
        spin.requestSpin(USER, BASE_POINTS, MARKET_TOKEN);
    }

    /// @dev Recomputes the expected first word for a revealed request.
    function _expectedWord(bytes32 secret, uint256 requestId, bytes32 bh) internal pure returns (uint256) {
        bytes32 base = keccak256(abi.encodePacked(secret, requestId, bh));
        return uint256(keccak256(abi.encodePacked(base, uint256(0))));
    }

    // ===============================================================
    // Happy path through a real SpinVRF instance
    // ===============================================================

    function test_commitRequestReveal_happyPathThroughSpinVRF() public {
        _commit(SECRET);
        assertEq(coordinator.pendingCommitments(), 1);

        _requestSpin();
        assertEq(coordinator.pendingCommitments(), 0);
        assertEq(coordinator.lastRequestId(), 1);

        (
            address reqConsumer,
            bytes32 commitment,
            uint64 assignedBlock,
            uint64 deadline,
            uint32 numWords,
            bool fulfilled
        ) = coordinator.getRequest(1);
        assertEq(reqConsumer, address(spin));
        assertEq(commitment, keccak256(abi.encodePacked(SECRET)));
        // SpinVRF requests with its default requestConfirmations = 3.
        assertEq(assignedBlock, uint64(block.number) + 3);
        assertEq(deadline, uint64(block.timestamp) + coordinator.REVEAL_TIMEOUT());
        assertEq(numWords, 1);
        assertFalse(fulfilled);

        // Reveal only valid after the assigned block exists.
        vm.roll(uint256(assignedBlock) + 1);
        coordinator.reveal(1, SECRET);

        uint256 expected = _expectedWord(SECRET, 1, blockhash(assignedBlock));
        (,,, bool spinFulfilled, uint256 multiplier,, uint256 word) = spin.getSpin(1);
        assertTrue(spinFulfilled);
        assertEq(word, expected);
        assertEq(multiplier, spin.multiplierForWord(expected));
        (,,,,, bool nowFulfilled) = coordinator.getRequest(1);
        assertTrue(nowFulfilled);
    }

    function test_reveal_callableByAnyoneWithTheSecret() public {
        _commit(SECRET);
        _requestSpin();
        (,, uint64 assignedBlock,,,) = coordinator.getRequest(1);
        vm.roll(uint256(assignedBlock) + 1);
        vm.prank(address(0xD00D));
        coordinator.reveal(1, SECRET);
        (,,, bool fulfilled,,,) = spin.getSpin(1);
        assertTrue(fulfilled);
    }

    function test_fifoAssignmentOrder() public {
        _commit(SECRET);
        _commit(SECRET_2);
        _requestSpin();
        _requestSpin();
        (, bytes32 c1,,,,) = coordinator.getRequest(1);
        (, bytes32 c2,,,,) = coordinator.getRequest(2);
        assertEq(c1, keccak256(abi.encodePacked(SECRET)));
        assertEq(c2, keccak256(abi.encodePacked(SECRET_2)));
    }

    function test_multiWordRequestExpandsEntropy() public {
        _commit(SECRET);
        uint256 requestId = consumer.request(3, 1);
        (,, uint64 assignedBlock,,,) = coordinator.getRequest(requestId);
        vm.roll(uint256(assignedBlock) + 1);
        coordinator.reveal(requestId, SECRET);
        assertEq(consumer.lastRequestId(), requestId);
        assertEq(consumer.lastWordsLength(), 3);
        bytes32 base = keccak256(abi.encodePacked(SECRET, requestId, blockhash(assignedBlock)));
        for (uint256 i = 0; i < 3; i++) {
            assertEq(consumer.lastWords(i), uint256(keccak256(abi.encodePacked(base, i))));
        }
    }

    function test_zeroConfirmationsClampToOne() public {
        _commit(SECRET);
        uint256 requestId = consumer.request(1, 0);
        (,, uint64 assignedBlock,,,) = coordinator.getRequest(requestId);
        assertEq(assignedBlock, uint64(block.number) + 1);
    }

    // ===============================================================
    // Reveal guards
    // ===============================================================

    function test_reveal_revertsOnWrongSecret() public {
        _commit(SECRET);
        _requestSpin();
        (,, uint64 assignedBlock,,,) = coordinator.getRequest(1);
        vm.roll(uint256(assignedBlock) + 1);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.SecretMismatch.selector, 1));
        coordinator.reveal(1, SECRET_2);
    }

    function test_reveal_revertsBeforeAssignedBlock() public {
        _commit(SECRET);
        _requestSpin();
        (,, uint64 assignedBlock,,,) = coordinator.getRequest(1);
        // At the assigned block itself its hash is still unknown; must also revert.
        vm.roll(uint256(assignedBlock));
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.AssignedBlockNotReached.selector, assignedBlock));
        coordinator.reveal(1, SECRET);
    }

    function test_reveal_revertsAfterBlockhashWindowExpires() public {
        _commit(SECRET);
        _requestSpin();
        (,, uint64 assignedBlock,,,) = coordinator.getRequest(1);
        vm.roll(uint256(assignedBlock) + 257);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.RevealWindowExpired.selector, assignedBlock));
        coordinator.reveal(1, SECRET);
    }

    function test_reveal_revertsOnUnknownRequest() public {
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.UnknownRequest.selector, 99));
        coordinator.reveal(99, SECRET);
    }

    function test_reveal_revertsWhenAlreadyFulfilled() public {
        _commit(SECRET);
        _requestSpin();
        (,, uint64 assignedBlock,,,) = coordinator.getRequest(1);
        vm.roll(uint256(assignedBlock) + 1);
        coordinator.reveal(1, SECRET);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.AlreadyFulfilled.selector, 1));
        coordinator.reveal(1, SECRET);
    }

    // ===============================================================
    // Two-step timeout fallback (audit fix C2)
    // ===============================================================

    /// @dev Recomputes the fallback first word from the PINNED block plus the request-time-fixed
    ///      assignedBlock (audit fix W2-15/L2), not the calling block.
    function _expectedTimeoutWord(uint256 requestId, uint64 timeoutBlock) internal view returns (uint256) {
        (,, uint64 assignedBlock,,,) = coordinator.getRequest(requestId);
        bytes32 base = keccak256(abi.encodePacked(requestId, assignedBlock, timeoutBlock, blockhash(timeoutBlock)));
        return uint256(keccak256(abi.encodePacked(base, uint256(0))));
    }

    function test_timeout_twoStep_deliversPinnedBlockWord() public {
        _commit(SECRET);
        _requestSpin();
        (,,, uint64 deadline,,) = coordinator.getRequest(1);
        vm.warp(uint256(deadline));

        // Step 1: anyone arms a fresh future block.
        vm.prank(address(0xD00D));
        coordinator.armTimeout(1);
        uint64 tb = coordinator.timeoutBlockOf(1);
        assertEq(tb, uint64(block.number) + coordinator.TIMEOUT_BLOCK_DELAY());

        // Step 2: after the pinned block is mined, and even deep inside (but within) the window,
        // anyone finalizes; the word is bound to the pinned block, independent of the call block.
        vm.roll(uint256(tb) + 200);
        uint256 expected = _expectedTimeoutWord(1, tb);
        vm.prank(address(0xBEEF));
        coordinator.fulfillTimeout(1);

        (,,, bool fulfilled, uint256 multiplier,, uint256 word) = spin.getSpin(1);
        assertTrue(fulfilled);
        assertEq(word, expected, "word bound to the pinned future block");
        assertEq(multiplier, spin.multiplierForWord(expected));
        // The old grindable derivation (parent-of-current block) does NOT match.
        uint256 oldGrindable;
        {
            bytes32 base = keccak256(abi.encodePacked(uint256(1), blockhash(block.number - 1)));
            oldGrindable = uint256(keccak256(abi.encodePacked(base, uint256(0))));
        }
        assertTrue(word != oldGrindable, "not derived from the caller-selected parent block");
    }

    function test_armTimeout_revertsBeforeDeadline() public {
        _commit(SECRET);
        _requestSpin();
        (,,, uint64 deadline,,) = coordinator.getRequest(1);
        vm.warp(uint256(deadline) - 1);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.TimeoutNotReached.selector, deadline));
        coordinator.armTimeout(1);
    }

    function test_fulfillTimeout_revertsWhenNotArmed() public {
        _commit(SECRET);
        _requestSpin();
        (,,, uint64 deadline,,) = coordinator.getRequest(1);
        vm.warp(uint256(deadline));
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.TimeoutNotArmed.selector, 1));
        coordinator.fulfillTimeout(1);
    }

    function test_fulfillTimeout_revertsBeforePinnedBlock() public {
        _commit(SECRET);
        _requestSpin();
        (,,, uint64 deadline,,) = coordinator.getRequest(1);
        vm.warp(uint256(deadline));
        coordinator.armTimeout(1);
        uint64 tb = coordinator.timeoutBlockOf(1);
        // At the pinned block itself its hash is still unknown; must revert.
        vm.roll(uint256(tb));
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.TimeoutBlockNotReached.selector, tb));
        coordinator.fulfillTimeout(1);
    }

    /// @dev The core anti-grind property: while a pinned sample is still usable (mined, in the
    ///      256-block window) it cannot be re-armed away to fish for a different word.
    function test_timeout_usableSampleCannotBeReArmed() public {
        _commit(SECRET);
        _requestSpin();
        (,,, uint64 deadline,,) = coordinator.getRequest(1);
        vm.warp(uint256(deadline));
        coordinator.armTimeout(1);
        uint64 tb = coordinator.timeoutBlockOf(1);
        vm.roll(uint256(tb) + 1); // sample now usable
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.TimeoutAlreadyArmed.selector, tb));
        coordinator.armTimeout(1);
    }

    /// @dev A caller that reverts unless the fallback word matches a target it wants cannot force
    ///      selection: the word is pinned, identical every block, and the sample cannot be re-armed
    ///      away, so retrying across blocks never yields a different outcome.
    function test_timeout_grindingCallerCannotForceOutcome() public {
        _commit(SECRET);
        _requestSpin();
        (,,, uint64 deadline,,) = coordinator.getRequest(1);
        vm.warp(uint256(deadline));
        coordinator.armTimeout(1);
        uint64 tb = coordinator.timeoutBlockOf(1);
        vm.roll(uint256(tb) + 1);

        // The grinder wants a word it will never get (the pinned word plus one).
        uint256 pinnedWord = _expectedTimeoutWord(1, tb);
        GrindingTimeoutCaller grinder = new GrindingTimeoutCaller(coordinator, spin, pinnedWord + 1);

        // Retrying across many blocks always reverts: the word never changes.
        for (uint256 i = 0; i < 10; i++) {
            vm.expectRevert(GrindingTimeoutCaller.Unfavorable.selector);
            grinder.tryFulfill(1);
            vm.roll(block.number + 1);
        }
        (,,, bool fulfilled,,,) = spin.getSpin(1);
        assertFalse(fulfilled, "grinder never forced a fulfillment");
        // And it cannot re-arm to fish for a friendlier word while the sample is usable.
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.TimeoutAlreadyArmed.selector, tb));
        coordinator.armTimeout(1);
    }

    /// @dev Liveness: if a pinned sample expires UNUSED (nobody fulfilled within 256 blocks) the
    ///      fallback can be re-armed with a fresh block, so a stuck request is always resolvable.
    function test_timeout_reArmAfterExpiryPreservesLiveness() public {
        _commit(SECRET);
        _requestSpin();
        (,,, uint64 deadline,,) = coordinator.getRequest(1);
        vm.warp(uint256(deadline));
        coordinator.armTimeout(1);
        uint64 tb1 = coordinator.timeoutBlockOf(1);

        // Let the first pinned block leave the 256-block window unused.
        vm.roll(uint256(tb1) + 257);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.TimeoutBlockExpired.selector, tb1));
        coordinator.fulfillTimeout(1);

        // Re-arm is gated by the cooldown (audit fix W2-15/L2): too soon reverts.
        vm.expectRevert(
            abi.encodeWithSelector(
                CommitRevealCoordinator.TimeoutRearmCooldown.selector, block.timestamp + coordinator.REVEAL_TIMEOUT()
            )
        );
        coordinator.armTimeout(1);

        // After the cooldown, re-arm is permitted and the request finalizes on the fresh sample.
        vm.warp(block.timestamp + coordinator.REVEAL_TIMEOUT());
        coordinator.armTimeout(1);
        uint64 tb2 = coordinator.timeoutBlockOf(1);
        assertTrue(tb2 > tb1);
        vm.roll(uint256(tb2) + 1);
        coordinator.fulfillTimeout(1);
        (,,, bool fulfilled,,,) = spin.getSpin(1);
        assertTrue(fulfilled, "re-armed fallback resolves the stuck request");
    }

    function test_fulfillTimeout_revertsBeforeDeadline() public {
        _commit(SECRET);
        _requestSpin();
        (,,, uint64 deadline,,) = coordinator.getRequest(1);
        vm.warp(uint256(deadline) - 1);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.TimeoutNotReached.selector, deadline));
        coordinator.fulfillTimeout(1);
    }

    function test_fulfillTimeout_revertsWhenAlreadyRevealed() public {
        _commit(SECRET);
        _requestSpin();
        (,, uint64 assignedBlock, uint64 deadline,,) = coordinator.getRequest(1);
        vm.roll(uint256(assignedBlock) + 1);
        coordinator.reveal(1, SECRET);
        vm.warp(uint256(deadline));
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.AlreadyFulfilled.selector, 1));
        coordinator.fulfillTimeout(1);
    }

    function test_fulfillTimeout_revertsOnUnknownRequest() public {
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.UnknownRequest.selector, 7));
        coordinator.fulfillTimeout(7);
    }

    function test_armTimeout_revertsOnUnknownRequest() public {
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.UnknownRequest.selector, 7));
        coordinator.armTimeout(7);
    }

    // ===============================================================
    // Commitment discipline
    // ===============================================================

    function test_commit_revertsOnReuse() public {
        _commit(SECRET);
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommitRevealCoordinator.CommitmentAlreadySeen.selector, keccak256(abi.encodePacked(SECRET))
            )
        );
        coordinator.commit(keccak256(abi.encodePacked(SECRET)));
    }

    function test_commit_reuseRejectedEvenAfterConsumption() public {
        _commit(SECRET);
        _requestSpin(); // Consumes the commitment.
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommitRevealCoordinator.CommitmentAlreadySeen.selector, keccak256(abi.encodePacked(SECRET))
            )
        );
        coordinator.commit(keccak256(abi.encodePacked(SECRET)));
    }

    function test_commit_revertsOnZeroCommitment() public {
        vm.prank(OPERATOR);
        vm.expectRevert(CommitRevealCoordinator.CommitmentZero.selector);
        coordinator.commit(bytes32(0));
    }

    function test_commit_onlyOperator() public {
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.OnlyOperator.selector, address(this)));
        coordinator.commit(keccak256(abi.encodePacked(SECRET)));
    }

    // ===============================================================
    // Queue exhaustion and consumer gating
    // ===============================================================

    function test_queueExhaustion_spinVrfDegradesToSkip() public {
        // No commitments posted: the coordinator reverts and SpinVRF must swallow it.
        vm.expectEmit(true, true, true, true);
        emit SpinVRF.SpinSkipped(USER, BASE_POINTS, MARKET_TOKEN, spin.SKIP_COORDINATOR_REVERT());
        _requestSpin();
        assertEq(spin.spinCount(), 0);
        assertEq(coordinator.lastRequestId(), 0);
    }

    function test_queueExhaustion_directRequestRevertsCleanly() public {
        vm.expectRevert(CommitRevealCoordinator.NoCommitmentAvailable.selector);
        consumer.request(1, 1);
        // A fresh commitment immediately unblocks the same consumer.
        _commit(SECRET);
        assertEq(consumer.request(1, 1), 1);
    }

    function test_requestRandomWords_onlyConsumer() public {
        _commit(SECRET);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.OnlyConsumer.selector, address(this)));
        coordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: 0,
                requestConfirmations: 1,
                callbackGasLimit: 500_000,
                numWords: 1,
                extraArgs: ""
            })
        );
    }

    function test_requestRandomWords_revertsOnZeroWords() public {
        _commit(SECRET);
        vm.expectRevert(CommitRevealCoordinator.InvalidNumWords.selector);
        consumer.request(0, 1);
    }

    // ===============================================================
    // Admin surface
    // ===============================================================

    function test_setOperator_updatesAndGates() public {
        coordinator.setOperator(address(0xB0B));
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.OnlyOperator.selector, OPERATOR));
        coordinator.commit(keccak256(abi.encodePacked(SECRET)));
        vm.prank(address(0xB0B));
        coordinator.commit(keccak256(abi.encodePacked(SECRET)));
        assertEq(coordinator.pendingCommitments(), 1);
    }

    function test_setOperator_revertsOnZero() public {
        vm.expectRevert(CommitRevealCoordinator.ZeroAddress.selector);
        coordinator.setOperator(address(0));
    }

    function test_setConsumer_disallowGates() public {
        coordinator.setConsumer(address(consumer), false);
        _commit(SECRET);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.OnlyConsumer.selector, address(consumer)));
        consumer.request(1, 1);
    }

    function test_setConsumer_revertsOnZero() public {
        vm.expectRevert(CommitRevealCoordinator.ZeroAddress.selector);
        coordinator.setConsumer(address(0), true);
    }

    function test_adminFunctions_onlyOwner() public {
        vm.startPrank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD)));
        coordinator.setOperator(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD)));
        coordinator.setConsumer(address(0xB0B), true);
        vm.stopPrank();
    }

    function test_constructor_revertsOnZeroOperator() public {
        vm.expectRevert(CommitRevealCoordinator.ZeroAddress.selector);
        new CommitRevealCoordinator(address(this), address(0));
    }

    function test_renounceOwnership_reverts() public {
        vm.expectRevert(CommitRevealCoordinator.RenounceDisabled.selector);
        coordinator.renounceOwnership();
    }

    // ===============================================================
    // Per-consumer per-block rate limit (audit fix C3)
    // ===============================================================

    function test_rateLimit_capsConsumerDrawsPerBlock() public {
        coordinator.setMaxConsumerRequestsPerBlock(3);
        _commit(keccak256("r1"));
        _commit(keccak256("r2"));
        _commit(keccak256("r3"));
        _commit(keccak256("r4"));
        _commit(keccak256("r5"));

        // One consumer draws up to the cap in a single block.
        consumer.request(1, 1);
        consumer.request(1, 1);
        consumer.request(1, 1);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealCoordinator.ConsumerRateLimited.selector, address(consumer)));
        consumer.request(1, 1);

        // The buffered queue is not fully drained in one block: honest spins survive.
        assertEq(coordinator.pendingCommitments(), 2, "flood cannot vacuum the buffered queue");

        // Next block, draws resume against the surviving commitments.
        vm.roll(block.number + 1);
        assertEq(consumer.request(1, 1), 4);
        assertEq(coordinator.pendingCommitments(), 1);
    }

    function test_rateLimit_spinVrfDegradesToSkip() public {
        coordinator.setMaxConsumerRequestsPerBlock(1);
        _commit(SECRET);
        _commit(SECRET_2);

        // First spin consumes the block's quota.
        _requestSpin();
        assertEq(spin.spinCount(), 1);

        // Second spin in the same block hits the rate limit; SpinVRF degrades to SpinSkipped
        // (never reverts the fill) and the second commitment is preserved for a later block.
        vm.expectEmit(true, true, true, true);
        emit SpinVRF.SpinSkipped(USER, BASE_POINTS, MARKET_TOKEN, spin.SKIP_COORDINATOR_REVERT());
        _requestSpin();
        assertEq(spin.spinCount(), 1, "second spin skipped, not reverted");
        assertEq(coordinator.pendingCommitments(), 1, "starved spin's commitment survives");

        // A later block lets the preserved commitment serve an honest spin.
        vm.roll(block.number + 1);
        _requestSpin();
        assertEq(spin.spinCount(), 2, "honest spin succeeds next block");
    }

    function test_setMaxConsumerRequestsPerBlock_onlyOwnerAndNonZero() public {
        vm.expectRevert(CommitRevealCoordinator.InvalidRateLimit.selector);
        coordinator.setMaxConsumerRequestsPerBlock(0);

        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD)));
        coordinator.setMaxConsumerRequestsPerBlock(5);

        coordinator.setMaxConsumerRequestsPerBlock(5);
        assertEq(coordinator.maxConsumerRequestsPerBlock(), 5);
    }

    // ===============================================================
    // W2-15/L1: cross-consumer fair-share reservation
    // ===============================================================

    /// @dev A commitment floor reserved for a low-volume consumer cannot be drawn by another
    ///      (flooding) consumer, so a sustained spin flood can never starve the reserved Jackpot
    ///      draws of a commitment (the pre-fix shared-queue starvation, red-casino L1).
    function test_W2_15_reservationProtectsLowVolumeConsumer() public {
        RecordingConsumer reserved = new RecordingConsumer(coordinator);
        coordinator.setConsumer(address(reserved), true);
        coordinator.setReservedCommitments(address(reserved), 1);
        assertEq(coordinator.totalReservedCommitments(), 1);

        _commit(keccak256("a"));
        _commit(keccak256("b"));

        // The flooder drains everything ABOVE the reserved floor, then is blocked.
        assertEq(consumer.request(1, 1), 1);
        vm.expectRevert(
            abi.encodeWithSelector(CommitRevealCoordinator.ReservedForOtherConsumers.selector, address(consumer))
        );
        consumer.request(1, 1);

        // The reserved consumer still gets its guaranteed commitment.
        assertEq(reserved.request(1, 1), 2);
        assertEq(coordinator.pendingCommitments(), 0);
    }

    function test_W2_15_setReservedCommitments_updatesTotalAndGuards() public {
        coordinator.setReservedCommitments(address(consumer), 3);
        assertEq(coordinator.reservedCommitments(address(consumer)), 3);
        assertEq(coordinator.totalReservedCommitments(), 3);

        // Lowering a reservation adjusts the running total.
        coordinator.setReservedCommitments(address(consumer), 1);
        assertEq(coordinator.totalReservedCommitments(), 1);

        vm.expectRevert(CommitRevealCoordinator.ZeroAddress.selector);
        coordinator.setReservedCommitments(address(0), 1);

        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD)));
        coordinator.setReservedCommitments(address(consumer), 1);
    }

    // ===============================================================
    // W2-15/L2: re-arm cooldown removes the discard-and-re-roll bias
    // ===============================================================

    /// @dev After a pinned sample expires unused, the fallback cannot be re-armed until a full
    ///      REVEAL_TIMEOUT has elapsed, so a sole withholder cannot cheaply fish for a fresh sample.
    function test_W2_15_reArmBlockedByCooldown() public {
        _commit(SECRET);
        _requestSpin();
        (,,, uint64 deadline,,) = coordinator.getRequest(1);
        vm.warp(uint256(deadline));
        coordinator.armTimeout(1);
        uint64 tb1 = coordinator.timeoutBlockOf(1);

        // Let it expire unused; an immediate re-arm is refused by the cooldown.
        vm.roll(uint256(tb1) + 257);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommitRevealCoordinator.TimeoutRearmCooldown.selector, deadline + coordinator.REVEAL_TIMEOUT()
            )
        );
        coordinator.armTimeout(1);
    }
}
