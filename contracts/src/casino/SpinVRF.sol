// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @notice Minimal surface of PitPoints used by SpinVRF.
interface IPitPointsSpinSink {
    function mintSpinBonus(address user, uint256 amount, address token) external;
}

/// @title SpinVRF: provably fair multiplier spins for THE PIT casino module
/// @notice Every taker fill triggers a spin request. The VRF word maps to a bonus
///         multiplier through fixed public thresholds, the bonus points are minted
///         retroactively, and the complete (request, word, multiplier) record is
///         stored on-chain forever: this powers the public fairness page.
/// @dev    Uses Chainlink VRF v2.5 (subscription model). requestSpin never reverts:
///         a failing or unset coordinator produces a SpinSkipped event instead, so
///         the points hooks that call it can uphold their own never-revert
///         guarantee. Fulfillment authority is pinned per request to the
///         coordinator that accepted it, so the admin can never influence an
///         in-flight or past spin by swapping the coordinator.
///
///         Threshold table on word % 10_000 (strict cumulative bounds):
///         [0, 6000) 1x, [6000, 8500) 2x, [8500, 9500) 5x, [9500, 9900) 20x,
///         [9900, 10000) 100x. Bonus minted = spinBase * (multiplier - 1). The
///         big 100x bonus is the sole reward for the top outcome; it buys no
///         separate jackpot lottery slot (the uniform Pit Drop entrant draw was
///         removed in audit fix C1 because it was cheaply floodable).
contract SpinVRF is Ownable2Step {
    // ===============================================================
    // Types
    // ===============================================================

    /// @notice Immutable audit record of a spin, written at request and completed
    ///         at fulfillment. Powers the public fairness page.
    struct SpinRecord {
        address user;
        address token;
        address coordinator;
        bool fulfilled;
        uint96 multiplier;
        uint256 basePoints;
        uint256 word;
    }

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Modulus applied to the VRF word before threshold mapping.
    uint256 public constant ROLL_MODULUS = 10_000;

    // Skip reason codes surfaced on the fairness page.
    bytes32 public constant SKIP_ZERO_BASE = "ZERO_BASE";
    bytes32 public constant SKIP_ZERO_USER = "ZERO_USER";
    bytes32 public constant SKIP_NO_COORDINATOR = "NO_COORDINATOR";
    bytes32 public constant SKIP_COORDINATOR_REVERT = "COORDINATOR_REVERT";
    bytes32 public constant SKIP_DUPLICATE_REQUEST_ID = "DUPLICATE_REQUEST_ID";

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice The PitPoints ledger; sole authorized spin requester and bonus sink.
    address public immutable pitPoints;

    /// @notice Current VRF coordinator used for NEW requests only.
    IVRFCoordinatorV2Plus public coordinator;

    /// @notice VRF subscription id (v2.5 uint256).
    uint256 public subscriptionId;

    /// @notice VRF key hash (gas lane) for new requests.
    bytes32 public keyHash;

    /// @notice Callback gas limit for new requests.
    uint32 public callbackGasLimit = 500_000;

    /// @notice Request confirmations for new requests.
    uint16 public requestConfirmations = 3;

    /// @notice Whether new requests pay the subscription in native token.
    bool public nativePayment;

    /// @notice Full spin audit trail by VRF request id.
    mapping(uint256 requestId => SpinRecord record) private _spins;

    /// @notice Number of spins ever requested (accepted by a coordinator).
    uint256 public spinCount;

    // ===============================================================
    // Events
    // ===============================================================

    /// @notice A spin was accepted by the coordinator and awaits fulfillment.
    event SpinRequested(uint256 indexed requestId, address indexed user, uint256 basePoints, address indexed token);

    /// @notice A spin could not be requested; no randomness was consumed.
    event SpinSkipped(address indexed user, uint256 basePoints, address indexed token, bytes32 reason);

    /// @notice A spin was fulfilled; the full record is queryable via getSpin.
    event SpinResult(
        uint256 indexed requestId, address indexed user, uint256 word, uint256 multiplier, uint256 bonusPoints
    );

    /// @notice VRF coordinator for new requests changed.
    event CoordinatorSet(address indexed coordinator);

    /// @notice VRF request configuration for new requests changed.
    event RequestConfigSet(
        uint256 subscriptionId, bytes32 keyHash, uint32 callbackGasLimit, uint16 requestConfirmations, bool nativePayment
    );

    // ===============================================================
    // Errors
    // ===============================================================

    /// @notice Caller is not the PitPoints ledger.
    error OnlyPitPoints(address caller);

    /// @notice Caller is not the coordinator recorded for this request.
    error OnlyRequestCoordinator(address caller, address expected);

    /// @notice No spin record exists for this request id.
    error UnknownRequest(uint256 requestId);

    /// @notice The spin was already fulfilled.
    error AlreadyFulfilled(uint256 requestId);

    /// @notice Fulfillment carried no random words.
    error EmptyRandomWords();

    /// @notice Zero address supplied where a real address is required.
    error ZeroAddress();

    /// @notice Ownership renunciation is permanently disabled.
    error RenounceDisabled();

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param initialOwner Admin address; intended to be a timelocked multisig.
    /// @param pitPoints_   The PitPoints ledger address.
    constructor(address initialOwner, address pitPoints_) Ownable(initialOwner) {
        if (pitPoints_ == address(0)) revert ZeroAddress();
        pitPoints = pitPoints_;
    }

    // ===============================================================
    // Admin (affects FUTURE requests only; past and in-flight spins are pinned)
    // ===============================================================

    /// @notice Sets the VRF coordinator used for new requests. Existing requests
    ///         remain fulfillable only by the coordinator that accepted them.
    function setCoordinator(address newCoordinator) external onlyOwner {
        coordinator = IVRFCoordinatorV2Plus(newCoordinator);
        emit CoordinatorSet(newCoordinator);
    }

    /// @notice Sets the VRF request parameters used for new requests.
    function setRequestConfig(
        uint256 newSubscriptionId,
        bytes32 newKeyHash,
        uint32 newCallbackGasLimit,
        uint16 newRequestConfirmations,
        bool newNativePayment
    ) external onlyOwner {
        subscriptionId = newSubscriptionId;
        keyHash = newKeyHash;
        callbackGasLimit = newCallbackGasLimit;
        requestConfirmations = newRequestConfirmations;
        nativePayment = newNativePayment;
        emit RequestConfigSet(newSubscriptionId, newKeyHash, newCallbackGasLimit, newRequestConfirmations, newNativePayment);
    }

    /// @notice Ownership renunciation is permanently disabled (audit F1): renouncing
    ///         would freeze coordinator rotation and request configuration forever with
    ///         no recovery. Rotate ownership via Ownable2Step's transfer/accept flow.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ===============================================================
    // Spin request (PitPoints only; never reverts)
    // ===============================================================

    /// @notice Requests a multiplier spin for a user. Callable only by PitPoints.
    /// @dev    Never reverts for PitPoints: every failure path emits SpinSkipped
    ///         and returns, preserving the points hooks' never-revert guarantee.
    /// @param user       The taker being awarded the spin.
    /// @param basePoints The taker's earned points for the fill (1e18 scale,
    ///                   multipliers included); the spin bonus scales from this.
    /// @param token      Market token of the originating fill (creator share
    ///                   attribution for the eventual bonus mint).
    function requestSpin(address user, uint256 basePoints, address token) external {
        if (msg.sender != pitPoints) revert OnlyPitPoints(msg.sender);
        if (user == address(0)) {
            emit SpinSkipped(user, basePoints, token, SKIP_ZERO_USER);
            return;
        }
        if (basePoints == 0) {
            emit SpinSkipped(user, basePoints, token, SKIP_ZERO_BASE);
            return;
        }
        IVRFCoordinatorV2Plus coord = coordinator;
        if (address(coord) == address(0)) {
            emit SpinSkipped(user, basePoints, token, SKIP_NO_COORDINATOR);
            return;
        }

        VRFV2PlusClient.RandomWordsRequest memory req = VRFV2PlusClient.RandomWordsRequest({
            keyHash: keyHash,
            subId: subscriptionId,
            requestConfirmations: requestConfirmations,
            callbackGasLimit: callbackGasLimit,
            numWords: 1,
            extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: nativePayment}))
        });

        try coord.requestRandomWords(req) returns (uint256 requestId) {
            if (_spins[requestId].user != address(0)) {
                // A coordinator returning a duplicate id would clobber an audit
                // record; refuse to overwrite and surface the anomaly instead.
                emit SpinSkipped(user, basePoints, token, SKIP_DUPLICATE_REQUEST_ID);
                return;
            }
            _spins[requestId] = SpinRecord({
                user: user,
                token: token,
                coordinator: address(coord),
                fulfilled: false,
                multiplier: 0,
                basePoints: basePoints,
                word: 0
            });
            spinCount = spinCount + 1;
            emit SpinRequested(requestId, user, basePoints, token);
        } catch {
            emit SpinSkipped(user, basePoints, token, SKIP_COORDINATOR_REVERT);
        }
    }

    // ===============================================================
    // VRF fulfillment
    // ===============================================================

    /// @notice VRF v2.5 fulfillment entry point; mirrors VRFConsumerBaseV2Plus
    ///         semantics with the authority pinned to the coordinator recorded at
    ///         request time.
    /// @param requestId   The VRF request id being fulfilled.
    /// @param randomWords The verified random words; only the first is used.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        SpinRecord storage spin = _spins[requestId];
        if (spin.user == address(0)) revert UnknownRequest(requestId);
        if (msg.sender != spin.coordinator) revert OnlyRequestCoordinator(msg.sender, spin.coordinator);
        if (spin.fulfilled) revert AlreadyFulfilled(requestId);
        if (randomWords.length == 0) revert EmptyRandomWords();

        uint256 word = randomWords[0];
        uint256 multiplier = multiplierForWord(word);
        spin.fulfilled = true;
        spin.word = word;
        spin.multiplier = uint96(multiplier);

        // The multiplier (including the top 100x) is rewarded solely as bonus
        // points. It no longer buys a uniform jackpot lottery slot: that Pit Drop
        // entrant draw was removed in audit fix C1 as cheaply floodable.
        uint256 bonus = spin.basePoints * (multiplier - 1);
        if (bonus > 0) {
            IPitPointsSpinSink(pitPoints).mintSpinBonus(spin.user, bonus, spin.token);
        }

        emit SpinResult(requestId, spin.user, word, multiplier, bonus);
    }

    // ===============================================================
    // Views
    // ===============================================================

    /// @notice Maps a VRF word to a spin multiplier by strict cumulative thresholds
    ///         on word % ROLL_MODULUS. Pure and public so anyone can re-derive any
    ///         historical outcome from the stored word.
    function multiplierForWord(uint256 word) public pure returns (uint256) {
        uint256 roll = word % ROLL_MODULUS;
        if (roll < 6000) return 1;
        if (roll < 8500) return 2;
        if (roll < 9500) return 5;
        if (roll < 9900) return 20;
        return 100;
    }

    /// @notice Full audit record for a spin request; powers the fairness page.
    function getSpin(uint256 requestId)
        external
        view
        returns (
            address user,
            address token,
            address requestCoordinator,
            bool fulfilled,
            uint256 multiplier,
            uint256 basePoints,
            uint256 word
        )
    {
        SpinRecord storage spin = _spins[requestId];
        return (spin.user, spin.token, spin.coordinator, spin.fulfilled, spin.multiplier, spin.basePoints, spin.word);
    }
}
