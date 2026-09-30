// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {VRFV2PlusClient} from "@chainlink/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @notice Consumer callback surface (mirrors VRF v2.5 rawFulfillRandomWords).
interface ICommitRevealConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @title CommitRevealCoordinator: commit-reveal randomness with the VRF v2.5 request surface
/// @notice Chainlink VRF v2.5 is not deployed on Robinhood Chain (id 4663). This coordinator
///         speaks EXACTLY the coordinator surface SpinVRF and Jackpot already consume
///         (requestRandomWords(VRFV2PlusClient.RandomWordsRequest) returning a requestId, then a
///         call to rawFulfillRandomWords on the requester), so both modules run unmodified and
///         can be pointed at a real VRF coordinator later via their existing setCoordinator.
///
///         Protocol per request:
///         1. COMMIT: the authorized operator posts commitment = keccak256(secret) BEFORE any
///            request can consume it. Commitments queue up FIFO and are strictly single-use.
///         2. REQUEST: an authorized consumer requests random words. The request is assigned the
///            oldest unused commitment plus a fresh requestId and a FUTURE block number
///            (block.number + requestConfirmations from the VRF request, minimum 1).
///         3. REVEAL: once the assigned block exists, anyone holding the secret (the operator in
///            practice) reveals it. A secret whose hash does not match the commitment reverts.
///            word = keccak256(secret, requestId, blockhash(assignedBlock)); the coordinator then
///            calls rawFulfillRandomWords on the requesting consumer.
///
///         TRUST MODEL, STATED HONESTLY: the operator cannot choose outcomes, because the secret
///         is fixed (committed on-chain) before the assigned block hash is known, and the word
///         binds both. What the operator CAN do is censor timing: refuse to commit (new requests
///         revert and SpinVRF degrades to SpinSkipped) or refuse to reveal. Withholding a reveal
///         is a one-time REROLL, not a choice, and the fallback is a genuinely UNKNOWN sample, not
///         a caller-chosen one (audit fix C2). The fallback is a two-step, permissionless timeout:
///         after REVEAL_TIMEOUT anyone calls armTimeout, which pins a FRESH FUTURE block; once that
///         block is mined its hash (unknowable when armed) fixes the word, and anyone calls
///         fulfillTimeout to deliver it. The armer cannot grind: the future block hash is unknown
///         at arm time, so pinning it commits to a sample nobody can yet see. Once a usable sample
///         exists (the pinned block is mined and still inside the 256-block window) it cannot be
///         re-armed away; re-arming is permitted only after a pinned block's hash has expired
///         UNUSED (left the 256-block window with no fulfillment) AND a REVEAL_TIMEOUT re-arm
///         cooldown has elapsed since the last arm (audit fix W2-15/L2), and during the whole
///         256-block window any honest party can call fulfillTimeout to lock the sample in, so an
///         attacker cannot cheaply discard unfavorable samples: a discard-and-re-roll now costs a
///         full timeout per attempt. The fallback word is additionally bound to request-time-fixed
///         data (requestId, assignedBlock) so it is anchored to the original request. This replaces
///         the earlier
///         keccak256(requestId, blockhash(block.number - 1)) fallback, which derived the word from
///         the caller-selected parent block and was grindable block by block. Reveals are still
///         bounded by the EVM's 256-block blockhash window: a reveal attempted after the assigned
///         block hash has expired reverts, and that request waits for the timeout fallback (it
///         prevents the operator from steering into the degenerate blockhash(0) word).
/// @dev Consumers are allowlisted so outsiders cannot drain the commitment queue, and each
///      consumer is rate-limited to maxConsumerRequestsPerBlock commitments per block (audit fix
///      C3), so a fill-flooder cannot vacuum the buffered queue in a single block and starve
///      honest spins; excess requests in a block revert (SpinVRF degrades to SpinSkipped). On top
///      of the per-block cap, each consumer can be given a reserved commitment floor that no OTHER
///      consumer may draw (setReservedCommitments, audit fix W2-15/L1), so a sustained spin flood
///      across many blocks can never starve the low-volume Jackpot draws of a commitment. The
///      keyHash, subId, extraArgs, and callbackGasLimit fields of the VRF request are accepted and
///      ignored (there is no subscription billing here; gas is free on this chain).
contract CommitRevealCoordinator is Ownable2Step {
    // ===============================================================
    // Types
    // ===============================================================

    /// @notice One randomness request and everything needed to verify its fulfillment.
    /// @param consumer The requesting contract; sole receiver of rawFulfillRandomWords.
    /// @param commitment keccak256 of the operator secret assigned to this request.
    /// @param assignedBlock Future block whose hash is mixed into the revealed word.
    /// @param deadline Timestamp after which the two-step fallback fulfillment opens.
    /// @param timeoutBlock Future block pinned by armTimeout for the fallback sample (0 = unarmed).
    /// @param timeoutArmedAt Timestamp of the last armTimeout; gates the re-arm cooldown (0 = never).
    /// @param numWords Number of random words requested.
    /// @param fulfilled Whether the request has been fulfilled (reveal or fallback).
    struct Request {
        address consumer;
        bytes32 commitment;
        uint64 assignedBlock;
        uint64 deadline;
        uint64 timeoutBlock;
        uint64 timeoutArmedAt;
        uint32 numWords;
        bool fulfilled;
    }

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice After this long without a reveal, anyone may arm the fallback fulfillment.
    uint64 public constant REVEAL_TIMEOUT = 24 hours;

    /// @notice Future-block distance armTimeout pins for the fallback sample. Large enough that the
    ///         armer cannot see the target block's hash when arming (no grind), small enough to land
    ///         comfortably inside the 256-block blockhash window before fulfillTimeout is called.
    uint64 public constant TIMEOUT_BLOCK_DELAY = 5;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice The address allowed to post commitments.
    address public operator;

    /// @notice Contracts allowed to request random words (SpinVRF, Jackpot).
    mapping(address consumer => bool allowed) public isConsumer;

    /// @notice Commitments reserved for a consumer that no OTHER consumer may draw (audit fix
    ///         W2-15/L1). Reserving a floor for the low-volume Jackpot consumer guarantees a
    ///         high-volume spin flooder can never vacuum the queue down to zero and starve draws.
    mapping(address consumer => uint256 reserved) public reservedCommitments;

    /// @notice Sum of every consumer's reservation; the floor a drawing consumer must leave for the
    ///         others is totalReservedCommitments minus its own reservation.
    uint256 public totalReservedCommitments;

    /// @notice FIFO queue of posted, not yet assigned commitments.
    bytes32[] internal _queue;

    /// @notice Index of the oldest unassigned commitment in the queue.
    uint256 public queueHead;

    /// @notice Every commitment ever posted; enforces strict single-use.
    mapping(bytes32 commitment => bool seen) public commitmentSeen;

    /// @notice All requests by id.
    mapping(uint256 requestId => Request request) internal _requests;

    /// @notice Last assigned request id (ids start at 1).
    uint256 public lastRequestId;

    /// @notice Max commitments a single consumer may draw per block (audit fix C3). Bounds how fast
    ///         a fill-flooder can drain the buffered queue so honest spins in later blocks are not
    ///         starved; requests over the cap in a block revert (SpinVRF degrades to SpinSkipped).
    uint32 public maxConsumerRequestsPerBlock;

    /// @notice Last block in which a consumer drew a commitment (per-block rate-limit bookkeeping).
    mapping(address consumer => uint256 blockNumber) private _consumerLastBlock;

    /// @notice Commitments a consumer has drawn in _consumerLastBlock.
    mapping(address consumer => uint32 count) private _consumerRequestsThisBlock;

    // ===============================================================
    // Events
    // ===============================================================

    /// @notice The operator address changed.
    event OperatorSet(address indexed operator);

    /// @notice A consumer was allowed or disallowed.
    event ConsumerSet(address indexed consumer, bool allowed);

    /// @notice The operator posted a commitment.
    event CommitmentPosted(bytes32 indexed commitment, uint256 queueIndex);

    /// @notice A request was assigned a commitment and a future block.
    event RandomWordsRequested(
        uint256 indexed requestId, address indexed consumer, bytes32 indexed commitment, uint64 assignedBlock
    );

    /// @notice A request was fulfilled, via reveal or via the timeout fallback.
    event RandomWordsFulfilled(uint256 indexed requestId, uint256 firstWord, bool viaFallback);

    /// @notice The two-step timeout fallback was armed with a fresh future block.
    event TimeoutArmed(uint256 indexed requestId, uint64 timeoutBlock);

    /// @notice The per-consumer per-block request rate limit changed.
    event MaxConsumerRequestsPerBlockSet(uint32 maxRequests);

    /// @notice A consumer's reserved commitment floor changed.
    event ReservedCommitmentsSet(address indexed consumer, uint256 reserved);

    // ===============================================================
    // Errors
    // ===============================================================

    /// @notice Zero address supplied where a real address is required.
    error ZeroAddress();

    /// @notice Caller is not the operator.
    error OnlyOperator(address caller);

    /// @notice Caller is not an allowed consumer.
    error OnlyConsumer(address caller);

    /// @notice This commitment hash was already posted once; commitments are single-use.
    error CommitmentAlreadySeen(bytes32 commitment);

    /// @notice A zero commitment hash is not a valid commitment.
    error CommitmentZero();

    /// @notice No unassigned commitment is available; the operator must commit first.
    error NoCommitmentAvailable();

    /// @notice numWords must be at least 1.
    error InvalidNumWords();

    /// @notice No request exists for this id.
    error UnknownRequest(uint256 requestId);

    /// @notice The request was already fulfilled.
    error AlreadyFulfilled(uint256 requestId);

    /// @notice The revealed secret does not hash to the assigned commitment.
    error SecretMismatch(uint256 requestId);

    /// @notice The assigned block has not been mined yet; reveal is not valid before it exists.
    error AssignedBlockNotReached(uint64 assignedBlock);

    /// @notice The assigned block hash left the 256-block window; wait for the timeout fallback.
    error RevealWindowExpired(uint64 assignedBlock);

    /// @notice The fallback fulfillment is not open until the reveal deadline passes.
    error TimeoutNotReached(uint64 deadline);

    /// @notice The fallback must be armed (armTimeout) before it can be finalized.
    error TimeoutNotArmed(uint256 requestId);

    /// @notice The fallback is already armed with a still-usable pinned block.
    error TimeoutAlreadyArmed(uint64 timeoutBlock);

    /// @notice The pinned fallback block has not been mined yet; wait for it.
    error TimeoutBlockNotReached(uint64 timeoutBlock);

    /// @notice The pinned fallback block hash left the 256-block window unused; re-arm it.
    error TimeoutBlockExpired(uint64 timeoutBlock);

    /// @notice This consumer already drew its per-block quota of commitments.
    error ConsumerRateLimited(address consumer);

    /// @notice The per-block rate limit must be at least 1.
    error InvalidRateLimit();

    /// @notice Drawing this commitment would dip into the pool reserved for other consumers.
    error ReservedForOtherConsumers(address consumer);

    /// @notice The fallback cannot be re-armed until the re-arm cooldown elapses.
    error TimeoutRearmCooldown(uint256 readyAt);

    /// @notice Ownership renunciation is permanently disabled.
    error RenounceDisabled();

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param initialOwner Admin address; intended to be a timelocked multisig.
    /// @param operator_ Initial operator allowed to post commitments.
    /// @dev The per-consumer per-block request cap starts at 16, high enough for honest spin
    ///      throughput and low enough that no single block can vacuum a large buffered queue; the
    ///      owner tunes it via setMaxConsumerRequestsPerBlock.
    constructor(address initialOwner, address operator_) Ownable(initialOwner) {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorSet(operator_);
        maxConsumerRequestsPerBlock = 16;
        emit MaxConsumerRequestsPerBlockSet(16);
    }

    // ===============================================================
    // Admin
    // ===============================================================

    /// @notice Sets the operator allowed to post commitments.
    /// @param newOperator The new operator address.
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        operator = newOperator;
        emit OperatorSet(newOperator);
    }

    /// @notice Allows or disallows a consumer contract to request random words.
    /// @param consumer The consumer contract (SpinVRF, Jackpot).
    /// @param allowed True to allow requests from this consumer.
    function setConsumer(address consumer, bool allowed) external onlyOwner {
        if (consumer == address(0)) revert ZeroAddress();
        isConsumer[consumer] = allowed;
        emit ConsumerSet(consumer, allowed);
    }

    /// @notice Sets the per-consumer per-block commitment draw cap (audit fix C3).
    /// @param newMax Maximum commitments a single consumer may draw in one block (>= 1).
    function setMaxConsumerRequestsPerBlock(uint32 newMax) external onlyOwner {
        if (newMax == 0) revert InvalidRateLimit();
        maxConsumerRequestsPerBlock = newMax;
        emit MaxConsumerRequestsPerBlockSet(newMax);
    }

    /// @notice Reserves a floor of commitments for a consumer that no OTHER consumer may draw
    ///         (audit fix W2-15/L1). Wire the low-volume Jackpot consumer with a small reservation
    ///         (e.g. 2, covering a concurrent daily + weekly draw) so a spin flooder cannot starve
    ///         its draws by vacuuming the shared queue.
    /// @param consumer The consumer whose reserved floor is being set.
    /// @param reserved Number of commitments reserved for this consumer.
    function setReservedCommitments(address consumer, uint256 reserved) external onlyOwner {
        if (consumer == address(0)) revert ZeroAddress();
        totalReservedCommitments = totalReservedCommitments - reservedCommitments[consumer] + reserved;
        reservedCommitments[consumer] = reserved;
        emit ReservedCommitmentsSet(consumer, reserved);
    }

    /// @notice Ownership renunciation is permanently disabled (audit F1): renouncing would freeze
    ///         operator rotation and consumer allowlisting forever with no recovery. Rotate
    ///         ownership via Ownable2Step's transfer/accept flow instead.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ===============================================================
    // Operator: commitments
    // ===============================================================

    /// @notice Posts a commitment (keccak256 of a secret the operator keeps off-chain) into the
    ///         FIFO queue. Must happen BEFORE a request can consume it; each commitment is
    ///         single-use forever, including across reposts of the same hash.
    /// @param commitment keccak256(abi.encodePacked(secret)).
    function commit(bytes32 commitment) external {
        if (msg.sender != operator) revert OnlyOperator(msg.sender);
        if (commitment == bytes32(0)) revert CommitmentZero();
        if (commitmentSeen[commitment]) revert CommitmentAlreadySeen(commitment);
        commitmentSeen[commitment] = true;
        _queue.push(commitment);
        emit CommitmentPosted(commitment, _queue.length - 1);
    }

    // ===============================================================
    // Consumers: requests (VRF v2.5 surface)
    // ===============================================================

    /// @notice VRF v2.5 request entry point. Assigns the oldest unused commitment plus a future
    ///         block to a fresh request id. Reverts with NoCommitmentAvailable when the queue is
    ///         empty (SpinVRF catches this and degrades to SpinSkipped; Jackpot's startDraw
    ///         reverts cleanly and can be retried after the operator commits).
    /// @param req The VRF v2.5 request struct. Only requestConfirmations (future-block distance,
    ///        minimum 1) and numWords are honored; billing fields are ignored.
    /// @return requestId The id the consumer's fulfillment will reference.
    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req)
        external
        returns (uint256 requestId)
    {
        if (!isConsumer[msg.sender]) revert OnlyConsumer(msg.sender);
        if (req.numWords == 0) revert InvalidNumWords();
        uint256 available = _queue.length - queueHead;
        if (available == 0) revert NoCommitmentAvailable();

        // Fair-share reservation (audit fix W2-15/L1): a consumer may draw only while more than the
        // commitments reserved for OTHER consumers remain, so a spin flooder can never take the
        // last commitments reserved for the Jackpot draws. SpinVRF catches this as SpinSkipped.
        uint256 reservedForOthers = totalReservedCommitments - reservedCommitments[msg.sender];
        if (available <= reservedForOthers) revert ReservedForOtherConsumers(msg.sender);

        // Per-consumer per-block rate limit (audit fix C3): count only actual commitment draws, so
        // a flooder cannot vacuum the buffered queue in one block. The revert is caught by SpinVRF
        // and surfaced as SpinSkipped, so a rate-limited spin never blocks the underlying fill.
        if (_consumerLastBlock[msg.sender] != block.number) {
            _consumerLastBlock[msg.sender] = block.number;
            _consumerRequestsThisBlock[msg.sender] = 0;
        }
        if (_consumerRequestsThisBlock[msg.sender] >= maxConsumerRequestsPerBlock) {
            revert ConsumerRateLimited(msg.sender);
        }
        _consumerRequestsThisBlock[msg.sender] += 1;

        bytes32 commitment = _queue[queueHead];
        queueHead += 1;

        uint16 confirmations = req.requestConfirmations == 0 ? 1 : req.requestConfirmations;
        uint64 assignedBlock = uint64(block.number) + confirmations;

        requestId = ++lastRequestId;
        _requests[requestId] = Request({
            consumer: msg.sender,
            commitment: commitment,
            assignedBlock: assignedBlock,
            deadline: uint64(block.timestamp) + REVEAL_TIMEOUT,
            timeoutBlock: 0,
            timeoutArmedAt: 0,
            numWords: req.numWords,
            fulfilled: false
        });
        emit RandomWordsRequested(requestId, msg.sender, commitment, assignedBlock);
    }

    // ===============================================================
    // Fulfillment
    // ===============================================================

    /// @notice Reveals the secret behind a request's commitment and fulfills the request with
    ///         word = keccak256(secret, requestId, blockhash(assignedBlock)). Callable by anyone
    ///         who knows the secret (the operator in practice): the word is fully determined by
    ///         on-chain data plus the pre-committed secret, so the caller identity is irrelevant.
    /// @param requestId The request being fulfilled.
    /// @param secret The preimage of the assigned commitment.
    function reveal(uint256 requestId, bytes32 secret) external {
        Request storage r = _requests[requestId];
        if (r.consumer == address(0)) revert UnknownRequest(requestId);
        if (r.fulfilled) revert AlreadyFulfilled(requestId);
        if (keccak256(abi.encodePacked(secret)) != r.commitment) revert SecretMismatch(requestId);
        if (block.number <= r.assignedBlock) revert AssignedBlockNotReached(r.assignedBlock);
        bytes32 bh = blockhash(r.assignedBlock);
        if (bh == bytes32(0)) revert RevealWindowExpired(r.assignedBlock);

        r.fulfilled = true;
        bytes32 base = keccak256(abi.encodePacked(secret, requestId, bh));
        _deliver(requestId, r.consumer, r.numWords, base, false);
    }

    /// @notice Step 1 of the forced-fairness fallback (audit fix C2): after REVEAL_TIMEOUT with no
    ///         reveal, ANYONE may pin a fresh FUTURE block whose (as-yet-unknowable) hash becomes
    ///         the fallback entropy. The pinner cannot grind the outcome because the target hash is
    ///         not observable when arming. Arming is allowed only when unarmed or when a previously
    ///         pinned block's hash has expired UNUSED (left the 256-block window with no
    ///         fulfillment), so a usable sample can never be re-armed away to fish for a better one.
    /// @param requestId The request whose fallback is being armed.
    function armTimeout(uint256 requestId) external {
        Request storage r = _requests[requestId];
        if (r.consumer == address(0)) revert UnknownRequest(requestId);
        if (r.fulfilled) revert AlreadyFulfilled(requestId);
        if (block.timestamp < r.deadline) revert TimeoutNotReached(r.deadline);

        uint64 armed = r.timeoutBlock;
        // Re-arm only if the prior target was reached but its hash has since expired unused.
        bool expiredUnused = armed != 0 && block.number > armed && blockhash(armed) == bytes32(0);
        if (armed != 0 && !expiredUnused) revert TimeoutAlreadyArmed(armed);

        // Re-arm cooldown (audit fix W2-15/L2): even after a pinned sample expires unused, a fresh
        // sample cannot be fished for until REVEAL_TIMEOUT more has elapsed since the last arm. This
        // raises the cost of a discard-and-re-roll to a full timeout per attempt (on top of the
        // 256-block window during which any keeper's fulfillTimeout locks the sample in), so a sole
        // withholder gains no cheap fresh draw. The first arm (timeoutArmedAt == 0) is never gated.
        if (armed != 0 && block.timestamp < uint256(r.timeoutArmedAt) + REVEAL_TIMEOUT) {
            revert TimeoutRearmCooldown(uint256(r.timeoutArmedAt) + REVEAL_TIMEOUT);
        }

        uint64 target = uint64(block.number) + TIMEOUT_BLOCK_DELAY;
        r.timeoutBlock = target;
        r.timeoutArmedAt = uint64(block.timestamp);
        emit TimeoutArmed(requestId, target);
    }

    /// @notice Step 2 of the forced-fairness fallback (audit fix C2): once the block pinned by
    ///         armTimeout is mined and still inside the 256-block window, ANYONE may finalize the
    ///         request with word = keccak256(requestId, timeoutBlock, blockhash(timeoutBlock)), a
    ///         single sample nobody could choose. If the pinned block's hash has expired unused,
    ///         this reverts and the fallback must be re-armed, preserving liveness.
    /// @param requestId The request being force-fulfilled.
    function fulfillTimeout(uint256 requestId) external {
        Request storage r = _requests[requestId];
        if (r.consumer == address(0)) revert UnknownRequest(requestId);
        if (r.fulfilled) revert AlreadyFulfilled(requestId);
        if (block.timestamp < r.deadline) revert TimeoutNotReached(r.deadline);

        uint64 tb = r.timeoutBlock;
        if (tb == 0) revert TimeoutNotArmed(requestId);
        if (block.number <= tb) revert TimeoutBlockNotReached(tb);
        bytes32 bh = blockhash(tb);
        if (bh == bytes32(0)) revert TimeoutBlockExpired(tb);

        r.fulfilled = true;
        // Bind the fallback word to data FIXED AT REQUEST TIME (requestId, assignedBlock) alongside
        // the pinned block hash (audit fix W2-15/L2), so the entropy is anchored to the original
        // request and not solely to a re-armable block.
        bytes32 base = keccak256(abi.encodePacked(requestId, r.assignedBlock, tb, bh));
        _deliver(requestId, r.consumer, r.numWords, base, true);
    }

    /// @dev Expands the base entropy into numWords words and calls the consumer. A reverting
    ///      consumer reverts the whole fulfillment (including the fulfilled flag), so it can be
    ///      retried; both protocol consumers only revert on unknown or replayed request ids.
    function _deliver(uint256 requestId, address consumer, uint32 numWords, bytes32 base, bool viaFallback) internal {
        uint256[] memory words = new uint256[](numWords);
        for (uint256 i = 0; i < numWords; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(base, i)));
        }
        ICommitRevealConsumer(consumer).rawFulfillRandomWords(requestId, words);
        emit RandomWordsFulfilled(requestId, words[0], viaFallback);
    }

    // ===============================================================
    // Views
    // ===============================================================

    /// @notice Full stored record of a request.
    function getRequest(uint256 requestId)
        external
        view
        returns (
            address consumer,
            bytes32 commitment,
            uint64 assignedBlock,
            uint64 deadline,
            uint32 numWords,
            bool fulfilled
        )
    {
        Request storage r = _requests[requestId];
        return (r.consumer, r.commitment, r.assignedBlock, r.deadline, r.numWords, r.fulfilled);
    }

    /// @notice The future block pinned by armTimeout for a request's fallback sample (0 = unarmed).
    function timeoutBlockOf(uint256 requestId) external view returns (uint64) {
        return _requests[requestId].timeoutBlock;
    }

    /// @notice Number of posted commitments not yet assigned to a request.
    function pendingCommitments() external view returns (uint256) {
        return _queue.length - queueHead;
    }

    /// @notice Total commitments ever posted.
    function totalCommitments() external view returns (uint256) {
        return _queue.length;
    }

    /// @notice Commitment at a queue index (assigned and unassigned alike).
    function commitmentAt(uint256 index) external view returns (bytes32) {
        return _queue[index];
    }
}
