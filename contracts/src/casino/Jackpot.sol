// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @notice Minimal surface of PitPoints used by Jackpot for weighted draws.
interface IPitPointsWeights {
    function currentEpoch() external view returns (uint256);
    function epochTotal(uint256 epoch) external view returns (uint256);
    function selectByWeight(uint256 epoch, uint256 target) external view returns (address);
}

/// @notice Minimal surface of a Market's pull-payment ledger used by collectFees (audit fix R-6):
///         withdraw() pays the CALLER its own credited balance, so the Jackpot can pull fee shares
///         that were credited to it while USDG had this contract frozen (wave-2 W2-12
///         credit-on-failure).
interface IMarketFeeCredit {
    function withdraw() external returns (uint256 amount);
}

/// @title Jackpot: the progressive USDG jackpot for THE PIT casino module
/// @notice Accrues USDG from protocol fees (the jackpot share, 25% of every entry and
///         settlement fee, arrives via plain transfers from Markets) and from anyone's donations.
///         Two provably fair VRF draws pay out of the shared pot, BOTH weighted by
///         epoch points via PitPoints' O(log n) checkpoint search:
///         daily mini-drop: 10% of the pot at draw completion, weighted by the
///         current (in-progress) epoch's points so far;
///         weekly mega-drop: 50% of the pot at draw completion, weighted by the
///         previous (complete) epoch's points.
/// @dev    Points scale with notional (money at risk) and the treasury/referral
///         burn makes the points-to-jackpot loop negative-sum, so weighting both
///         draws by points is manipulation-resistant. The audit removed an earlier
///         uniform "Pit Drop entrant" daily mode (audit fix C1): it selected
///         uniformly over 100x-spin entrant slots minted per fill EVENT, which was
///         capturable for cents by flooding tiny fills; entrant registration and
///         its plumbing are gone.
///
///         Fulfillment authority is pinned per draw to the coordinator that
///         accepted the request, so the admin can never influence an in-flight or
///         past draw. Zero-participant periods are consumed and the pot rolls
///         forward. Payouts are pull-payment credits (audit fix D2): fulfillment
///         records the winner and credits a claimable balance without pushing USDG,
///         so a frozen or blocklisted winner can never revert fulfillment and brick
///         the draw kind or lock the pot; the winner later calls claim().
contract Jackpot is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===============================================================
    // Types
    // ===============================================================

    /// @notice Which draw is being run.
    enum DrawKind {
        DAILY,
        WEEKLY
    }

    /// @notice Full on-chain audit record of a draw.
    /// @param kind        DAILY or WEEKLY.
    /// @param fulfilled   Whether the VRF response (or an owner cancel) closed the draw.
    /// @param cancelled   Whether the draw was closed by the owner escape hatch
    ///                    (retired coordinator) rather than by a VRF response.
    /// @param coordinator Coordinator pinned at request time; sole fulfiller.
    /// @param period      Day index (DAILY) or drawn epoch (WEEKLY).
    /// @param epoch       Weighting epoch (current epoch for DAILY, previous for WEEKLY).
    /// @param requestId   VRF request id.
    /// @param word        Fulfilled random word.
    /// @param winner      Selected winner (zero if none).
    /// @param amount      USDG credited to the winner (native 6 decimals).
    struct Draw {
        DrawKind kind;
        bool fulfilled;
        bool cancelled;
        address coordinator;
        uint64 period;
        uint256 epoch;
        uint256 requestId;
        uint256 word;
        address winner;
        uint256 amount;
    }

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Daily mini-drop pays AT MOST this fraction of the pot, in basis points.
    /// @dev    Upper bound only; the binding cap is usually the fee-inflow drip (see
    ///         MAX_EPOCH_PAYOUT_BPS). Excess pot rolls forward.
    uint256 public constant DAILY_BPS = 1000;

    /// @notice Weekly mega-drop pays AT MOST this fraction of the pot, in basis points.
    /// @dev    Upper bound only; the binding cap is usually the fee-inflow drip (see
    ///         MAX_EPOCH_PAYOUT_BPS). Excess pot rolls forward.
    uint256 public constant WEEKLY_BPS = 5000;

    /// @notice Basis point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Drip cap (audit fix W2-2): the ceiling, in basis points, on the TOTAL that every
    ///         draw weighted by a given epoch may collectively pay out, measured against the fee
    ///         INFLOW attributed to that same epoch (never against the standing balance).
    /// @dev    Design rationale (the drip curve). A points-weighted draw that paid a fixed fraction
    ///         of the STANDING pot was positive-EV wash-farmable the moment the pot exceeded ~1.31x
    ///         a weighting epoch's honest fees: a seeded, donated, or lull-grown pot persists across
    ///         epochs, but each draw is defended by only ONE epoch's points, so an attacker who
    ///         dominates that single epoch's points cheaply could capture a fixed slice of an
    ///         arbitrarily large standing pot. Binding every draw's payout to the epoch's own fee
    ///         inflow removes that temporal mismatch: the pot value can never outrun the honest
    ///         point mass that defends it, because the payout scales with the same fees that mint
    ///         the defending points. Since the jackpot receives FEE_SHARE_JACKPOT_BPS (25%) of
    ///         trading fees, epoch inflow is ~0.25x the epoch's fees; to dominate share q of the
    ///         epoch's points an attacker must spend ~q/(1-q) of the honest fee mass. Optimizing,
    ///         attacker EV stays non-positive as long as MAX_EPOCH_PAYOUT_BPS x 0.25 <= 1/A, where
    ///         A is the attacker's points-per-fee amplifier (max 7.5x = the 5x win-streak cap x the
    ///         1.5x daily-streak cap). At 5000 bps the break-even amplifier is A = 8 > 7.5, so the
    ///         drip alone makes the wash-farm non-positive-EV even at the maximum amplifier, and the
    ///         L3 win-streak throttle in PitPoints is defense in depth on top of it. A genuine
    ///         community SEED deposited via seed() is excluded from inflow entirely and is therefore
    ///         never payable by any draw, only accreting the standing pot that rolls forward.
    ///
    ///         Epoch-boundary closure (audit fix W2-2b): inflow is attributed by ARRIVAL, always to
    ///         the epoch that is CURRENT when the deposit is first observed, never to an epoch a
    ///         caller names. An epoch's inflow bucket therefore closes the moment currentEpoch
    ///         advances past it: a completed epoch's drip budget can only contain inflow observed
    ///         while that epoch was live, so the weekly mega-drop (which draws the PREVIOUS epoch)
    ///         can never sweep current-epoch honest fees backward into a cheaply-dominated past
    ///         epoch's budget. Inflow that arrives late in an epoch and is only observed after the
    ///         boundary conservatively attributes FORWARD to the new current epoch, whose points are
    ///         live and contestable (the non-positive-EV drip regime above); a keeper calling
    ///         syncInflow() near each boundary keeps that forward drift to dust.
    uint256 public constant MAX_EPOCH_PAYOUT_BPS = 5000;

    /// @notice Pot-outflow guard (audit fix W2-4): the hard ceiling, in basis points of the pot at
    ///         the window's first draw, on the TOTAL that may leave the pot within any rolling
    ///         OUTFLOW_WINDOW, enforced independently of the VRF coordinator.
    /// @dev    A malicious or swapped coordinator can only steer WHO wins an already-scheduled draw;
    ///         it cannot change the payout amount (set here) or the once-per-period draw cadence. This
    ///         guard is a coordinator-independent backstop: even if every cap above were bypassed, no
    ///         more than this fraction of the pot can be credited per rolling day. It is set equal to
    ///         WEEKLY_BPS so a by-design weekly mega-drop is unclamped ONLY when it is the window's
    ///         FIRST draw; any later draw in the same 24h window is clamped to what remains of the
    ///         window budget, INCLUDING the weekly itself when a daily draw fulfilled first on an
    ///         epoch-boundary day (order of fulfillment decides). The clamped remainder is not lost:
    ///         it rolls forward in the pot for a future draw (redistribution across random
    ///         points-weighted winners, never a drain; wave-2b R-10 per re-potguard (a)).
    uint256 public constant MAX_OUTFLOW_PER_WINDOW_BPS = 5000;

    /// @notice Rolling window over which MAX_OUTFLOW_PER_WINDOW_BPS is enforced.
    uint256 public constant OUTFLOW_WINDOW = 1 days;

    /// @notice Delay (audit fix W2-4) between proposing and accepting a coordinator CHANGE, so an
    ///         in-flight draw completes under the pinned old coordinator and the change is publicly
    ///         visible before it takes effect. The initial bootstrap set is immediate.
    uint256 public constant COORDINATOR_CHANGE_DELAY = 1 days;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice The USDG token the pot is denominated in (native 6 decimals).
    IERC20 public immutable usdg;

    /// @notice The PitPoints ledger providing epoch weights.
    IPitPointsWeights public immutable pitPoints;

    /// @notice Current VRF coordinator used for NEW draw requests only.
    IVRFCoordinatorV2Plus public coordinator;

    /// @notice A coordinator CHANGE proposed via proposeCoordinator, pending acceptCoordinator.
    address public pendingCoordinator;

    /// @notice Earliest timestamp at which the pending coordinator change may be accepted.
    uint256 public coordinatorChangeEffectiveTime;

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

    /// @notice Last day index a daily draw was started or skipped for.
    uint64 public lastDailyDay;

    /// @notice Last epoch a weekly draw was started or skipped for.
    uint64 public lastWeeklyEpoch;

    /// @notice A daily draw is awaiting VRF fulfillment.
    bool public dailyPending;

    /// @notice A weekly draw is awaiting VRF fulfillment.
    bool public weeklyPending;

    /// @notice Pending daily draw id + 1 (0 means none); the draw the escape hatch clears.
    uint256 private _pendingDailyDrawIdPlusOne;

    /// @notice Pending weekly draw id + 1 (0 means none); the draw the escape hatch clears.
    uint256 private _pendingWeeklyDrawIdPlusOne;

    /// @notice Pull-payment credit owed to each winner (native 6 decimals).
    mapping(address winner => uint256 amount) public claimable;

    /// @notice Sum of all outstanding claimable credits; excluded from the pot so a
    ///         credited-but-unclaimed award never inflates the next draw's payout.
    uint256 public totalClaimable;

    /// @notice USDG ever withdrawn via claim(); with balanceOf it reconstructs total received.
    /// @dev    cumulativeReceived = balanceOf(this) + cumulativePaidOut is monotonic and unaffected
    ///         by claims, so the inflow sync measures genuine deposits (fees + donations) only.
    uint256 public cumulativePaidOut;

    /// @notice cumulativeReceived (balanceOf + cumulativePaidOut) already attributed to an epoch's
    ///         inflow bucket or excluded as a seed. Deposits above this are un-attributed inflow.
    uint256 private _accountedReceived;

    /// @notice Fee inflow (native 6 decimals) attributed to each weighting epoch. The drip cap
    ///         bounds an epoch's draws to MAX_EPOCH_PAYOUT_BPS of this value. Attribution is by
    ///         arrival (audit fix W2-2b): a bucket only grows while its epoch is current and is
    ///         closed forever once currentEpoch advances past it.
    mapping(uint256 epoch => uint256 amount) public epochInflow;

    /// @notice USDG already credited by draws weighted by each epoch; keeps the daily + weekly draws
    ///         sharing one epoch within the single epoch drip budget.
    mapping(uint256 epoch => uint256 amount) public epochPaidOut;

    /// @notice Start timestamp of the current pot-outflow guard window.
    uint256 private _outflowWindowStart;

    /// @notice Pot value captured at the first draw of the current outflow window; the window cap is
    ///         MAX_OUTFLOW_PER_WINDOW_BPS of this reference.
    uint256 private _outflowWindowPotRef;

    /// @notice USDG credited so far within the current outflow window.
    uint256 private _outflowInWindow;

    /// @notice All draws ever run, in order.
    Draw[] private _draws;

    /// @notice Draw index + 1 by VRF request id (0 means unknown).
    mapping(uint256 requestId => uint256 drawIdPlusOne) private _drawIdByRequestId;

    // ===============================================================
    // Events
    // ===============================================================

    /// @notice A draw was started and awaits VRF fulfillment.
    event DrawStarted(uint256 indexed drawId, DrawKind indexed kind, uint256 requestId, uint64 period, uint256 epoch);

    /// @notice A period had no eligible participants; the pot rolls forward.
    event DrawSkipped(DrawKind indexed kind, uint64 period);

    /// @notice A draw completed; the full record is queryable via getDraw.
    event DrawResult(
        uint256 indexed drawId,
        DrawKind indexed kind,
        uint256 requestId,
        uint256 word,
        address indexed winner,
        uint256 amount,
        uint256 epoch
    );

    /// @notice A stuck pending draw was cancelled by the owner escape hatch; the pot
    ///         rolls forward and the draw kind is re-enabled. No funds moved.
    event DrawCancelled(uint256 indexed drawId, DrawKind indexed kind, uint256 requestId);

    /// @notice A winner withdrew their credited jackpot award.
    event Claimed(address indexed winner, uint256 amount);

    /// @notice VRF coordinator for new requests changed (bootstrap set or accepted change).
    event CoordinatorSet(address indexed coordinator);

    /// @notice A coordinator CHANGE was proposed and will be acceptable at effectiveTime.
    event CoordinatorChangeProposed(address indexed coordinator, uint256 effectiveTime);

    /// @notice A pending coordinator change was cancelled before acceptance.
    event CoordinatorChangeCancelled(address indexed coordinator);

    /// @notice Someone seeded the pot; the deposit accretes the standing pot but is excluded from
    ///         the fee-inflow drip so no draw can ever pay it out.
    event PotSeeded(address indexed from, uint256 amount);

    /// @notice Un-attributed deposits were attributed to an epoch's fee-inflow bucket.
    event InflowAttributed(uint256 indexed epoch, uint256 amount);

    /// @notice Fee shares credited to the Jackpot inside a Market (while USDG had this contract
    ///         frozen) were pulled back into the pot via collectFees (audit fix R-6).
    event FeesCollected(address indexed market, uint256 amount);

    /// @notice VRF request configuration for new requests changed.
    event RequestConfigSet(
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    );

    // ===============================================================
    // Errors
    // ===============================================================

    /// @notice The period boundary for this draw kind has not been crossed yet.
    error DrawNotDue(DrawKind kind);

    /// @notice A draw of this kind is already awaiting fulfillment.
    error DrawPending(DrawKind kind);

    /// @notice The VRF coordinator is not configured.
    error CoordinatorNotSet();

    /// @notice Caller is not the coordinator recorded for this draw.
    error OnlyRequestCoordinator(address caller, address expected);

    /// @notice No draw exists for this request id.
    error UnknownRequest(uint256 requestId);

    /// @notice The draw was already fulfilled (or cancelled).
    error AlreadyFulfilled(uint256 requestId);

    /// @notice Fulfillment carried no random words.
    error EmptyRandomWords();

    /// @notice The coordinator returned a request id already bound to a draw.
    error DuplicateRequestId(uint256 requestId);

    /// @notice No draw of this kind is pending; the escape hatch has nothing to clear.
    error NoPendingDraw(DrawKind kind);

    /// @notice The caller has no claimable jackpot credit.
    error NothingToClaim();

    /// @notice Zero address supplied where a real address is required.
    error ZeroAddress();

    /// @notice Ownership renunciation is permanently disabled.
    error RenounceDisabled();

    /// @notice setCoordinator is bootstrap-only; a live coordinator changes via proposeCoordinator.
    error CoordinatorAlreadySet();

    /// @notice No coordinator change is pending acceptance.
    error NoPendingCoordinatorChange();

    /// @notice The proposed coordinator change is not yet acceptable.
    error CoordinatorChangeNotReady(uint256 effectiveTime);

    /// @notice A zero seed amount is not a valid deposit.
    error ZeroAmount();

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param initialOwner Admin address; intended to be a timelocked multisig.
    /// @param usdg_        USDG token address.
    /// @param pitPoints_   PitPoints ledger address.
    /// @dev   Draw eligibility starts at the first full period boundary after
    ///        deployment: the deploy day and the in-progress epoch are consumed.
    constructor(address initialOwner, address usdg_, address pitPoints_) Ownable(initialOwner) {
        if (usdg_ == address(0) || pitPoints_ == address(0)) revert ZeroAddress();
        usdg = IERC20(usdg_);
        pitPoints = IPitPointsWeights(pitPoints_);
        lastDailyDay = uint64(block.timestamp / 1 days);
        uint256 epoch = IPitPointsWeights(pitPoints_).currentEpoch();
        lastWeeklyEpoch = epoch > 0 ? uint64(epoch - 1) : 0;
    }

    // ===============================================================
    // Admin (affects FUTURE draws only; past and in-flight draws are pinned)
    // ===============================================================

    /// @notice Bootstrap-only initial coordinator wiring. Once a coordinator is live, a CHANGE must
    ///         go through the delayed two-step proposeCoordinator / acceptCoordinator flow (audit
    ///         fix W2-4), so an in-flight draw completes under the pinned old coordinator and the
    ///         swap is publicly visible before it takes effect.
    /// @param newCoordinator The initial coordinator to wire at deploy.
    function setCoordinator(address newCoordinator) external onlyOwner {
        if (address(coordinator) != address(0)) revert CoordinatorAlreadySet();
        coordinator = IVRFCoordinatorV2Plus(newCoordinator);
        emit CoordinatorSet(newCoordinator);
    }

    /// @notice Proposes a coordinator CHANGE that becomes acceptable after COORDINATOR_CHANGE_DELAY
    ///         (audit fix W2-4). Existing draws stay pinned to the coordinator that accepted them, so
    ///         a proposal never touches an in-flight draw. Re-proposing overwrites a prior pending
    ///         proposal and restarts the delay.
    /// @param newCoordinator The coordinator to switch new requests to; zero is not permitted.
    function proposeCoordinator(address newCoordinator) external onlyOwner {
        if (newCoordinator == address(0)) revert ZeroAddress();
        pendingCoordinator = newCoordinator;
        uint256 effectiveTime = block.timestamp + COORDINATOR_CHANGE_DELAY;
        coordinatorChangeEffectiveTime = effectiveTime;
        emit CoordinatorChangeProposed(newCoordinator, effectiveTime);
    }

    /// @notice Finalizes a proposed coordinator change once the delay has elapsed. Permissionless:
    ///         it only applies the owner's already-published proposal and grants no new authority.
    function acceptCoordinator() external {
        address next = pendingCoordinator;
        if (next == address(0)) revert NoPendingCoordinatorChange();
        if (block.timestamp < coordinatorChangeEffectiveTime) {
            revert CoordinatorChangeNotReady(coordinatorChangeEffectiveTime);
        }
        coordinator = IVRFCoordinatorV2Plus(next);
        pendingCoordinator = address(0);
        coordinatorChangeEffectiveTime = 0;
        emit CoordinatorSet(next);
    }

    /// @notice Cancels a pending coordinator change before it is accepted.
    function cancelProposedCoordinator() external onlyOwner {
        address next = pendingCoordinator;
        if (next == address(0)) revert NoPendingCoordinatorChange();
        pendingCoordinator = address(0);
        coordinatorChangeEffectiveTime = 0;
        emit CoordinatorChangeCancelled(next);
    }

    /// @notice Sets the VRF request parameters used for new draw requests.
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
        emit RequestConfigSet(
            newSubscriptionId, newKeyHash, newCallbackGasLimit, newRequestConfirmations, newNativePayment
        );
    }

    /// @notice Owner escape hatch (audit fix C5): cancels a stuck pending draw whose
    ///         pinned coordinator has been retired and can no longer fulfill it,
    ///         clearing the pending flag so the draw kind can run again.
    /// @dev    The draw record is marked fulfilled + cancelled so a late response
    ///         from the retired coordinator is rejected as AlreadyFulfilled and can
    ///         never pay out. TRUST ASSUMPTION, STATED HONESTLY: this power can ONLY
    ///         unblock a draw kind and roll the un-drawn pot forward. It moves no
    ///         funds, selects no winner, and cannot redirect the pot. It exists so a
    ///         coordinator swap mid-draw cannot brick a draw kind permanently.
    /// @param kind The bricked draw kind to recover.
    function cancelStuckDraw(DrawKind kind) external onlyOwner {
        uint256 idPlusOne;
        if (kind == DrawKind.DAILY) {
            if (!dailyPending) revert NoPendingDraw(kind);
            idPlusOne = _pendingDailyDrawIdPlusOne;
            dailyPending = false;
            _pendingDailyDrawIdPlusOne = 0;
        } else {
            if (!weeklyPending) revert NoPendingDraw(kind);
            idPlusOne = _pendingWeeklyDrawIdPlusOne;
            weeklyPending = false;
            _pendingWeeklyDrawIdPlusOne = 0;
        }

        Draw storage draw = _draws[idPlusOne - 1];
        draw.fulfilled = true;
        draw.cancelled = true;
        emit DrawCancelled(idPlusOne - 1, kind, draw.requestId);
    }

    /// @notice Ownership renunciation is permanently disabled (audit F1): renouncing
    ///         would freeze coordinator rotation and the stuck-draw escape hatch
    ///         forever with no recovery. Rotate ownership via Ownable2Step instead.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ===============================================================
    // Draws
    // ===============================================================

    /// @notice Starts a draw once per period boundary. Anyone may call.
    /// @dev    DAILY: due once per UTC day; draws the CURRENT epoch so far, weighted
    ///         by its points. WEEKLY: due once per epoch and always draws the
    ///         PREVIOUS (complete) epoch, weighted by its points. An epoch with no
    ///         points consumes the period and rolls the pot forward.
    /// @param kind DAILY or WEEKLY.
    function startDraw(DrawKind kind) external {
        if (kind == DrawKind.DAILY) {
            uint64 day = uint64(block.timestamp / 1 days);
            if (day <= lastDailyDay) revert DrawNotDue(kind);
            if (dailyPending) revert DrawPending(kind);
            lastDailyDay = day;

            uint256 epoch = pitPoints.currentEpoch();
            _syncInflow();
            if (pitPoints.epochTotal(epoch) == 0) {
                emit DrawSkipped(kind, day);
                return;
            }
            dailyPending = true;
            _requestDraw(kind, day, epoch);
        } else {
            uint256 epoch = pitPoints.currentEpoch();
            if (epoch == 0) revert DrawNotDue(kind);
            uint256 target = epoch - 1;
            if (target <= lastWeeklyEpoch) revert DrawNotDue(kind);
            if (weeklyPending) revert DrawPending(kind);
            lastWeeklyEpoch = uint64(target);

            // W2-2b: sync to the CURRENT epoch, never to the drawn (previous) target epoch. The
            // target epoch's drip budget was frozen when the epoch rolled; attributing the sweep to
            // it here would let current-epoch honest inflow be harvested by whoever cheaply
            // dominated the completed epoch's points (the backward-attribution wash-farm).
            _syncInflow();
            if (pitPoints.epochTotal(target) == 0) {
                emit DrawSkipped(kind, uint64(target));
                return;
            }
            weeklyPending = true;
            _requestDraw(kind, uint64(target), target);
        }
    }

    /// @dev Requests one VRF word and records the draw. Reverts if the coordinator
    ///      is unset, refuses the request, or returns a colliding request id (audit
    ///      fix C5: never overwrite an existing draw record); startDraw is a plain
    ///      user action so a revert here is safe (all state changes roll back with it).
    function _requestDraw(DrawKind kind, uint64 period, uint256 epoch) internal {
        IVRFCoordinatorV2Plus coord = coordinator;
        if (address(coord) == address(0)) revert CoordinatorNotSet();

        VRFV2PlusClient.RandomWordsRequest memory req = VRFV2PlusClient.RandomWordsRequest({
            keyHash: keyHash,
            subId: subscriptionId,
            requestConfirmations: requestConfirmations,
            callbackGasLimit: callbackGasLimit,
            numWords: 1,
            extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: nativePayment}))
        });
        uint256 requestId = coord.requestRandomWords(req);
        if (_drawIdByRequestId[requestId] != 0) revert DuplicateRequestId(requestId);

        uint256 drawId = _draws.length;
        _draws.push(
            Draw({
                kind: kind,
                fulfilled: false,
                cancelled: false,
                coordinator: address(coord),
                period: period,
                epoch: epoch,
                requestId: requestId,
                word: 0,
                winner: address(0),
                amount: 0
            })
        );
        _drawIdByRequestId[requestId] = drawId + 1;
        if (kind == DrawKind.DAILY) {
            _pendingDailyDrawIdPlusOne = drawId + 1;
        } else {
            _pendingWeeklyDrawIdPlusOne = drawId + 1;
        }
        emit DrawStarted(drawId, kind, requestId, period, epoch);
    }

    /// @notice VRF v2.5 fulfillment entry point; completes the draw and credits the
    ///         winner. Authority is pinned to the coordinator recorded at request
    ///         time. Payout is the smallest of three caps (audit fixes W2-2, W2-4):
    ///         DAILY_BPS / WEEKLY_BPS of the standing pot, the weighting epoch's
    ///         fee-inflow drip budget (MAX_EPOCH_PAYOUT_BPS of that epoch's inflow,
    ///         shared across its draws), and the rolling pot-outflow guard. Whatever
    ///         is not paid rolls the pot forward.
    /// @dev    Pull payment (audit fix D2): the winner and amount are recorded and the
    ///         pending flag cleared UNCONDITIONALLY, and the award is credited to a
    ///         claimable balance rather than pushed. No external token transfer occurs
    ///         here, so a frozen or blocklisted winner cannot revert fulfillment,
    ///         brick the draw kind, or lock the pot. The winner withdraws via claim().
    /// @param requestId   The VRF request id being fulfilled.
    /// @param randomWords The verified random words; only the first is used.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external nonReentrant {
        uint256 idPlusOne = _drawIdByRequestId[requestId];
        if (idPlusOne == 0) revert UnknownRequest(requestId);
        Draw storage draw = _draws[idPlusOne - 1];
        if (msg.sender != draw.coordinator) revert OnlyRequestCoordinator(msg.sender, draw.coordinator);
        if (draw.fulfilled) revert AlreadyFulfilled(requestId);
        if (randomWords.length == 0) revert EmptyRandomWords();

        uint256 word = randomWords[0];
        draw.fulfilled = true;
        draw.word = word;

        address winner;
        uint256 total = pitPoints.epochTotal(draw.epoch);
        if (total > 0) {
            winner = pitPoints.selectByWeight(draw.epoch, word % total);
        }

        uint256 amount = 0;
        if (winner != address(0)) {
            // W2-2b: attribute any deposits observed since the last sync to the CURRENT epoch (by
            // arrival), never to draw.epoch. For a weekly draw draw.epoch is the PREVIOUS, already
            // closed epoch; filing fulfillment-window inflow into it would inflate a completed
            // epoch's drip budget with money its points never defended.
            _syncInflow();
            uint256 pot = usdg.balanceOf(address(this)) - totalClaimable;
            uint256 fractionCap = (pot * (draw.kind == DrawKind.DAILY ? DAILY_BPS : WEEKLY_BPS)) / BPS_DENOMINATOR;
            // Drip cap (W2-2): bound the payout to the weighting epoch's own fee inflow, never the
            // standing balance, and share one drip budget across every draw that epoch defends.
            uint256 budget = (epochInflow[draw.epoch] * MAX_EPOCH_PAYOUT_BPS) / BPS_DENOMINATOR;
            uint256 paid = epochPaidOut[draw.epoch];
            uint256 dripRemaining = budget > paid ? budget - paid : 0;
            amount = fractionCap < dripRemaining ? fractionCap : dripRemaining;
            // Pot-outflow guard (W2-4): coordinator-independent ceiling per rolling window.
            amount = _applyOutflowGuard(amount, pot);
            epochPaidOut[draw.epoch] += amount;
        }
        draw.winner = winner;
        draw.amount = amount;

        if (draw.kind == DrawKind.DAILY) {
            dailyPending = false;
            _pendingDailyDrawIdPlusOne = 0;
        } else {
            weeklyPending = false;
            _pendingWeeklyDrawIdPlusOne = 0;
        }

        if (amount > 0) {
            claimable[winner] += amount;
            totalClaimable += amount;
        }
        emit DrawResult(idPlusOne - 1, draw.kind, requestId, word, winner, amount, draw.epoch);
    }

    // ===============================================================
    // Pot funding and inflow accounting
    // ===============================================================

    /// @notice Seeds the pot WITHOUT feeding the fee-inflow drip (audit fix W2-2). The deposit
    ///         accretes the standing pot (and so the progressive-jackpot headline) but is excluded
    ///         from every epoch's inflow budget, so no draw can ever pay it out; it only rolls
    ///         forward. This is the safe way to fund a launch or community pot: a plain transfer,
    ///         by contrast, is counted as inflow (bounded to MAX_EPOCH_PAYOUT_BPS per epoch).
    /// @param amount USDG (native 6 decimals) to deposit. Requires prior approval.
    function seed(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // Attribute any genuine inflow observed so far before excluding this seed.
        _syncInflow();
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        // Exclude the seed from inflow: advance the accounted-received watermark past it so the
        // next sync sees no new inflow from this deposit.
        _accountedReceived += amount;
        emit PotSeeded(msg.sender, amount);
    }

    /// @notice Pulls fee shares credited to this contract inside `market` back into the pot (audit
    ///         fix R-6). When USDG freezes the Jackpot address, Markets cannot push its 25% fee
    ///         share and instead credit it to the Jackpot's pull-payment balance (wave-2 W2-12
    ///         credit-on-failure); without this collector those funds would be stranded forever,
    ///         because the Jackpot had no code path that calls Market.withdraw(). Once USDG
    ///         unfreezes the Jackpot, anyone calls this to recover the credit.
    /// @dev    Permissionless, like syncInflow and seed, because it grants no authority at all: the
    ///         only external call is market.withdraw(), which pays the CALLER (this contract) its
    ///         own credited balance, so neither the caller, the owner, nor the named market can
    ///         steal or misdirect funds; the sole possible state effect is the pot increasing. The
    ///         pulled amount is filed as CURRENT-epoch fee inflow, exactly as it would have been
    ///         had the original push landed (the W2-2b arrival-time attribution model): a pre-pull
    ///         sync first files any deposits that already arrived, then a post-pull sync attributes
    ///         precisely the collected amount, so the W2-2 drip accounting is never corrupted.
    ///         nonReentrant so an untrusted `market` target cannot re-enter claim, seed, collect,
    ///         or fulfillment mid-pull. Reverts inside market.withdraw() (e.g. nothing credited, or
    ///         this contract still frozen) bubble up. GENERAL DEPLOY RULE (documented for R-6):
    ///         every fee recipient wired into a Market's fee split must be withdraw-capable, i.e.
    ///         either an EOA/multisig that can call Market.withdraw() itself or a contract exposing
    ///         a collector like this one; the future Buyback executor needs the same function.
    /// @param  market The Market to pull this contract's credited fee balance from.
    /// @return collected The USDG amount (native 6 decimals) pulled into the pot.
    function collectFees(address market) external nonReentrant returns (uint256 collected) {
        if (market == address(0)) revert ZeroAddress();
        // File any deposits that already arrived, so the post-pull sync attributes exactly the
        // collected amount on its own.
        _syncInflow();
        uint256 balanceBefore = usdg.balanceOf(address(this));
        IMarketFeeCredit(market).withdraw();
        collected = usdg.balanceOf(address(this)) - balanceBefore;
        // The recovered fee share arrives in the pot NOW, so it is current-epoch inflow under the
        // W2-2b arrival-time model and becomes payable through the normal drip like any other fee.
        _syncInflow();
        emit FeesCollected(market, collected);
    }

    /// @notice Attributes any deposits observed since the last sync to the current epoch's fee
    ///         inflow bucket (audit fix W2-2b: attribution is always by arrival, to the CURRENT
    ///         epoch). Permissionless; a keeper should call it regularly and especially shortly
    ///         before each epoch boundary, because an epoch's bucket closes at rollover and any
    ///         still-unobserved tail inflow then attributes forward to the next epoch.
    function syncInflow() external {
        _syncInflow();
    }

    // ===============================================================
    // Claims (pull payment)
    // ===============================================================

    /// @notice Withdraws the caller's credited jackpot award. Reentrancy-guarded
    ///         SafeERC20 transfer with checks-effects-interactions ordering; a
    ///         reverting (e.g. frozen) recipient only fails their own claim and never
    ///         affects the pot or other winners.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        // Track the withdrawal so the inflow sync (which reads balanceOf) never mistakes a claim
        // outflow for negative inflow; cumulativeReceived = balanceOf + cumulativePaidOut is
        // monotonic across claims.
        cumulativePaidOut += amount;
        usdg.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ===============================================================
    // Internal: inflow accounting and outflow guard
    // ===============================================================

    /// @dev Attributes newly-observed deposits to the CURRENT epoch's fee-inflow bucket (audit fix
    ///      W2-2b). No caller can name the epoch: attribution is strictly by arrival, so a bucket
    ///      only ever grows while its epoch is current and is closed once currentEpoch advances
    ///      past it. That closure is what keeps a completed epoch's drip budget bound to inflow
    ///      that genuinely arrived during the epoch, breaking the backward-attribution wash-farm
    ///      in which a weekly draw of a cheaply-dominated previous epoch swept unattributed
    ///      current-epoch honest fees into that epoch's budget. Inflow is measured as the rise in
    ///      cumulativeReceived (balanceOf + cumulativePaidOut), which is monotonic and unaffected
    ///      by claims or by draw credits, so only genuine deposits (plain fee transfers and
    ///      donations) are counted. Seeds are pre-excluded by seed(). O(1).
    function _syncInflow() internal {
        uint256 received = usdg.balanceOf(address(this)) + cumulativePaidOut;
        uint256 accounted = _accountedReceived;
        if (received > accounted) {
            uint256 delta = received - accounted;
            _accountedReceived = received;
            uint256 epoch = pitPoints.currentEpoch();
            epochInflow[epoch] += delta;
            emit InflowAttributed(epoch, delta);
        }
    }

    /// @dev Clamps a draw's payout so the total credited within any rolling OUTFLOW_WINDOW cannot
    ///      exceed MAX_OUTFLOW_PER_WINDOW_BPS of the pot captured at the window's first draw. The
    ///      window resets on the first draw at or after OUTFLOW_WINDOW since the last window start,
    ///      so it is a coordinator-independent ceiling that no steered draw can raise. O(1).
    /// @param amount The pre-guard payout.
    /// @param pot    The current pot (balanceOf minus totalClaimable), the fresh-window reference.
    /// @return The payout after the outflow guard.
    function _applyOutflowGuard(uint256 amount, uint256 pot) internal returns (uint256) {
        if (block.timestamp >= _outflowWindowStart + OUTFLOW_WINDOW) {
            _outflowWindowStart = block.timestamp;
            _outflowWindowPotRef = pot;
            _outflowInWindow = 0;
        }
        uint256 cap = (_outflowWindowPotRef * MAX_OUTFLOW_PER_WINDOW_BPS) / BPS_DENOMINATOR;
        uint256 remaining = cap > _outflowInWindow ? cap - _outflowInWindow : 0;
        if (amount > remaining) amount = remaining;
        _outflowInWindow += amount;
        return amount;
    }

    // ===============================================================
    // Views
    // ===============================================================

    /// @notice Current USDG pot (native 6 decimals): the contract balance minus all
    ///         outstanding claimable credits, i.e. the amount future draws pay from.
    function potBalance() external view returns (uint256) {
        return usdg.balanceOf(address(this)) - totalClaimable;
    }

    /// @notice Deposits observed but not yet attributed to any epoch's inflow bucket, i.e. the
    ///         amount a syncInflow / draw would file next, always into the CURRENT epoch (audit
    ///         fix W2-2b). Zero right after a sync.
    function unattributedInflow() external view returns (uint256) {
        uint256 received = usdg.balanceOf(address(this)) + cumulativePaidOut;
        return received > _accountedReceived ? received - _accountedReceived : 0;
    }

    /// @notice Current pot-outflow guard window state (audit fix W2-4).
    /// @return windowStart Timestamp the current rolling window began.
    /// @return potRef      Pot captured at the window's first draw (the cap basis).
    /// @return creditedInWindow USDG already credited within the window.
    function outflowWindow() external view returns (uint256 windowStart, uint256 potRef, uint256 creditedInWindow) {
        return (_outflowWindowStart, _outflowWindowPotRef, _outflowInWindow);
    }

    /// @notice Total draws ever started.
    function drawCount() external view returns (uint256) {
        return _draws.length;
    }

    /// @notice Full audit record for a draw by id.
    function getDraw(uint256 drawId) external view returns (Draw memory) {
        return _draws[drawId];
    }

    /// @notice Draw id for a VRF request id; reverts if unknown.
    function drawIdForRequest(uint256 requestId) external view returns (uint256) {
        uint256 idPlusOne = _drawIdByRequestId[requestId];
        if (idPlusOne == 0) revert UnknownRequest(requestId);
        return idPlusOne - 1;
    }
}
