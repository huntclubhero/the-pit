// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPitPoints} from "../interfaces/IPitPoints.sol";

/// @notice Minimal surface of SpinVRF used by PitPoints. SpinVRF.requestSpin is
///         designed to never revert; PitPoints still wraps the call defensively.
interface ISpinVRF {
    function requestSpin(address user, uint256 basePoints, address token) external;
}

/// @title PitPoints: the on-chain points ledger for THE PIT casino module
/// @notice Points are a non-transferable, non-purchasable activity ledger. Points
///         carry NO financial promise, NO redemption right, and NO claim on any
///         asset, revenue, or governance power. They exist purely to rank activity
///         and to weight provably fair jackpot draws.
/// @dev    Implements the frozen IPitPoints hook interface. Hooks are callable only
///         by registered Market contracts and are engineered to never revert for a
///         registered caller on any reachable state: all arithmetic is bounded by
///         NOTIONAL_CAP, all loops are bounded, and the single external call made
///         from a hook (SpinVRF.requestSpin) is wrapped in try/catch.
///
///         Point scaling: points use 1e18 internal scale. Base points for a fill
///         are notional * 1e11 where notional is USDG native 6 decimals. Worked
///         example: 100 USDG notional = 100 * 1e6 = 1e8 native units, and
///         1e8 * 1e11 = 1e19 = 10e18, i.e. 10 points per 100 USDG notional.
contract PitPoints is IPitPoints, Ownable2Step {
    // ===============================================================
    // Types
    // ===============================================================

    /// @notice Reason codes attached to every points mint.
    enum PointsReason {
        FILL_TAKER,
        FILL_MAKER,
        SPIN_BONUS,
        LOSS_REBATE,
        CREATOR_SHARE
    }

    /// @notice Append-only per-epoch checkpoint enabling O(log n) weighted selection.
    /// @dev    cumulative is the running epoch total AFTER the mint that wrote this
    ///         checkpoint. A random target t in [0, epochTotal) selects the first
    ///         checkpoint with cumulative > t; each user's selection probability is
    ///         proportional to their total points earned in the epoch.
    struct Checkpoint {
        address user;
        uint256 cumulative;
    }

    /// @notice Win streak state for a user.
    /// @dev    shieldConsumedAt == 0 means the shield has never been consumed and is
    ///         available. Otherwise the shield refreshes SHIELD_WINDOW seconds after
    ///         consumption. streakAdvancedAt is the timestamp of the last streak
    ///         advance (0 = never advanced); it throttles advancement (audit fix L3).
    struct WinStreak {
        uint64 wins;
        uint64 shieldConsumedAt;
        uint64 streakAdvancedAt;
    }

    /// @notice Daily activity streak state for a user.
    /// @dev    lastDay is a UTC day index (timestamp / 1 days). lastDay == 0 doubles
    ///         as the never-active sentinel; the protocol deploys far past day 0.
    struct DailyStreak {
        uint64 lastDay;
        uint64 count;
    }

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Points (1e18 scale) minted per USDG native unit of notional.
    /// @dev    notional * 1e11 gives 10 points per 100 USDG notional; see header.
    uint256 public constant POINTS_PER_NOTIONAL_UNIT = 1e11;

    /// @notice Notional is clamped to this value before any points math. Guarantees
    ///         no overflow on any code path for arbitrary uint256 notional input,
    ///         which is part of the never-revert guarantee for hooks.
    uint256 public constant NOTIONAL_CAP = 1e38;

    /// @notice Epoch length for jackpot weighting.
    uint256 public constant EPOCH_LENGTH = 7 days;

    /// @notice Rolling window for the win-streak loss shield.
    uint256 public constant SHIELD_WINDOW = 24 hours;

    /// @notice Minimum spacing between win-streak advances (audit fix L3).
    /// @dev    settle() is party-optional after MIN_HOLD, so a farmer could open many self-financed
    ///         positions and settle only the winning ones, racking a 5x win-streak multiplier in a
    ///         rapid burst without ever recording a loss. Throttling advancement to at most one step
    ///         per window makes the multiplier reflect a streak sustained over real time rather than
    ///         a compressed selective-settle burst: a decisive win inside the window still earns full
    ///         lifetime and leaderboard credit but does not advance the multiplier. Honest streaks
    ///         built across a genuine trading session keep climbing. This is defense in depth on top
    ///         of the jackpot drip cap (Jackpot.MAX_EPOCH_PAYOUT_BPS), which already makes the
    ///         wash-farm non-positive-EV even at the maximum 7.5x points amplifier.
    uint256 public constant WIN_STREAK_ADVANCE_WINDOW = 1 hours;

    /// @notice Fixed-point scale for multipliers (10000 = 1.0x).
    uint256 public constant MULT_SCALE = 10_000;

    /// @notice Creator share, in MULT_SCALE basis points, minted additionally on
    ///         every non creator-share mint attributable to a token with a creator.
    /// @dev    Lifetime and cosmetic only: excluded from epoch weighting (see _mint).
    uint256 public constant CREATOR_SHARE_BPS = 500;

    /// @notice Loss rebate, in MULT_SCALE basis points of base points (no multipliers).
    uint256 public constant LOSS_REBATE_BPS = 2500;

    /// @notice Daily streak multiplier step per consecutive day beyond day 1 (+0.05x).
    uint256 public constant DAILY_STEP = 500;

    /// @notice Daily streak multiplier cap (1.5x).
    uint256 public constant DAILY_MULT_CAP = 15_000;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice Optional market registrar (e.g. a MarketFactory) allowed to register markets.
    address public registrar;

    /// @notice SpinVRF module asked for a multiplier spin on every taker fill.
    ISpinVRF public spinVRF;

    /// @notice Registered Market contracts allowed to call the IPitPoints hooks.
    mapping(address market => bool registered) public isMarket;

    /// @notice Creator of a market token; earns CREATOR_SHARE_BPS of all points
    ///         minted from that token's activity, forever. First writer wins.
    /// @dev    Creator-share points are LIFETIME and cosmetic only (pointsOf,
    ///         totalPoints, leaderboards). They are deliberately excluded from
    ///         epoch weighting, so a first-writer creator share can never be
    ///         converted into free jackpot-draw win probability (see _mint).
    mapping(address token => address creator) public creatorOf;

    /// @notice Lifetime points balance per user (1e18 scale). Non-transferable.
    mapping(address user => uint256 balance) public pointsOf;

    /// @notice Total points ever minted (1e18 scale).
    uint256 public totalPoints;

    mapping(address user => WinStreak state) private _winStreaks;
    mapping(address user => DailyStreak state) private _dailyStreaks;
    mapping(uint256 epoch => mapping(address user => uint256 balance)) private _epochPoints;
    mapping(uint256 epoch => uint256 total) private _epochTotals;
    mapping(uint256 epoch => Checkpoint[] checkpoints) private _checkpoints;

    // ===============================================================
    // Events
    // ===============================================================

    /// @notice Emitted on every points mint.
    event PointsEarned(
        address indexed user, PointsReason indexed reason, address indexed token, uint256 amount, uint256 epoch
    );

    /// @notice Emitted when a market is registered.
    event MarketRegistered(address indexed market);

    /// @notice Emitted when the registrar is set.
    event RegistrarSet(address indexed registrar);

    /// @notice Emitted when the SpinVRF module is set.
    event SpinVRFSet(address indexed spinVRF);

    /// @notice Emitted when a token's creator is recorded.
    event MarketCreatorSet(address indexed token, address indexed creator);

    /// @notice Emitted when a user's win streak advances after a win.
    event WinStreakAdvanced(address indexed user, uint64 wins);

    /// @notice Emitted when a loss is absorbed by the shield (streak unchanged).
    event ShieldConsumed(address indexed user, uint64 wins);

    /// @notice Emitted when a second loss inside the shield window resets the streak.
    event WinStreakReset(address indexed user);

    /// @notice Emitted when a user's daily activity streak updates.
    event DailyStreakUpdated(address indexed user, uint64 count, uint64 day);

    /// @notice Emitted when a settle carries no PnL or degenerate parties; no state change.
    event SettleNeutral(address indexed winner, address indexed loser, address indexed token);

    /// @notice Emitted when the defensive wrapper around SpinVRF.requestSpin caught a revert.
    event SpinRequestFailed(address indexed user, uint256 basePoints, address indexed token);

    // ===============================================================
    // Errors
    // ===============================================================

    /// @notice Caller is not a registered market.
    error NotMarket(address caller);

    /// @notice Caller is not the SpinVRF module.
    error NotSpinVRF(address caller);

    /// @notice Caller is neither the owner nor the registrar.
    error NotRegistrar(address caller);

    /// @notice Zero address supplied where a real address is required.
    error ZeroAddress();

    /// @notice Ownership renunciation is permanently disabled.
    error RenounceDisabled();

    // ===============================================================
    // Modifiers
    // ===============================================================

    modifier onlyMarket() {
        if (!isMarket[msg.sender]) revert NotMarket(msg.sender);
        _;
    }

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param initialOwner Admin address; intended to be a timelocked multisig.
    constructor(address initialOwner) Ownable(initialOwner) {}

    // ===============================================================
    // Admin
    // ===============================================================

    /// @notice Registers a Market contract, allowing it to call the points hooks.
    /// @dev    Callable by the owner or the registrar (e.g. a MarketFactory).
    /// @param market The market contract to register.
    function registerMarket(address market) external {
        if (msg.sender != owner() && msg.sender != registrar) revert NotRegistrar(msg.sender);
        if (market == address(0)) revert ZeroAddress();
        isMarket[market] = true;
        emit MarketRegistered(market);
    }

    /// @notice Sets the registrar allowed to register markets (e.g. a MarketFactory).
    /// @param newRegistrar The registrar address; zero disables registrar registration.
    function setRegistrar(address newRegistrar) external onlyOwner {
        registrar = newRegistrar;
        emit RegistrarSet(newRegistrar);
    }

    /// @notice Sets the SpinVRF module. Zero disables spin requests (fills still earn).
    /// @param newSpinVRF The SpinVRF contract address.
    function setSpinVRF(address newSpinVRF) external onlyOwner {
        spinVRF = ISpinVRF(newSpinVRF);
        emit SpinVRFSet(newSpinVRF);
    }

    /// @notice Ownership renunciation is permanently disabled (audit F1): renouncing
    ///         would freeze market registration and the SpinVRF wiring forever with no
    ///         recovery. Rotate ownership via Ownable2Step's transfer/accept flow instead.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ===============================================================
    // IPitPoints hooks (registered markets only; never revert for them)
    // ===============================================================

    /// @inheritdoc IPitPoints
    /// @dev Taker is whichever party is not the maker (long or short). Base points
    ///      are notional * POINTS_PER_NOTIONAL_UNIT (clamped at NOTIONAL_CAP), the
    ///      maker earns 2x base; each earner's own win-streak and daily-streak
    ///      multipliers apply to their earn. Daily activity is touched for every
    ///      involved address BEFORE multipliers are read, so a fill that starts a
    ///      new consecutive day already enjoys that day's multiplier. Finally a
    ///      multiplier spin is requested for the taker with the taker's earned
    ///      amount (multipliers included) as the spin base.
    function onFill(address longParty, address shortParty, address maker, address token, uint256 notional)
        external
        onlyMarket
    {
        uint256 base = _basePoints(notional);
        address taker = maker == longParty ? shortParty : longParty;

        _touchDaily(longParty);
        if (shortParty != longParty) _touchDaily(shortParty);
        if (maker != longParty && maker != shortParty) _touchDaily(maker);

        uint256 takerEarn = (base * _winMultiplier(_winStreaks[taker].wins) * _storedDailyMultiplier(taker))
            / (MULT_SCALE * MULT_SCALE);
        _mint(taker, takerEarn, PointsReason.FILL_TAKER, token);

        uint256 makerEarn = (2 * base * _winMultiplier(_winStreaks[maker].wins) * _storedDailyMultiplier(maker))
            / (MULT_SCALE * MULT_SCALE);
        _mint(maker, makerEarn, PointsReason.FILL_MAKER, token);

        ISpinVRF spin = spinVRF;
        // The code-length guard matters: a high-level call to a codeless address
        // would revert in THIS contract (extcodesize check) and try/catch cannot
        // swallow that, so it must be excluded up front.
        if (address(spin).code.length > 0 && takerEarn > 0 && taker != address(0)) {
            // requestSpin is itself non-reverting by design; the try/catch is a
            // second layer so a misconfigured spinVRF can never break fills.
            try spin.requestSpin(taker, takerEarn, token) {} catch {
                emit SpinRequestFailed(taker, takerEarn, token);
            }
        }
    }

    /// @inheritdoc IPitPoints
    /// @dev Winner advances their win streak; loser runs the shield state machine
    ///      and receives a loss rebate of LOSS_REBATE_BPS of base points with no
    ///      multipliers. A settle with pnlToWinner == 0, identical parties, or a
    ///      zero-address party is treated as neutral: no streak change, no rebate.
    function onSettle(address winner, address loser, address token, uint256 notional, uint256 pnlToWinner)
        external
        onlyMarket
    {
        if (pnlToWinner == 0 || winner == loser || winner == address(0) || loser == address(0)) {
            emit SettleNeutral(winner, loser, token);
            return;
        }

        _recordWin(winner);
        _recordLoss(loser);

        uint256 rebate = (_basePoints(notional) * LOSS_REBATE_BPS) / MULT_SCALE;
        _mint(loser, rebate, PointsReason.LOSS_REBATE, token);
    }

    /// @inheritdoc IPitPoints
    /// @dev First writer wins: once a token has a creator it can never be replaced,
    ///      so a later market on the same token cannot hijack the creator share.
    ///      Unlike the trading hooks, this one is also open to the registrar: it is
    ///      the MarketFactory (set as registrar) that reports creations, since the
    ///      market contract itself does not exist until after the creation call.
    function onMarketCreated(address creator, address token) external {
        if (!isMarket[msg.sender] && msg.sender != registrar) revert NotMarket(msg.sender);
        if (creatorOf[token] == address(0) && creator != address(0)) {
            creatorOf[token] = creator;
            emit MarketCreatorSet(token, creator);
        }
    }

    // ===============================================================
    // SpinVRF sink
    // ===============================================================

    /// @notice Mints retroactive spin bonus points. Callable only by SpinVRF.
    /// @dev    No multipliers apply here: the spin base already included them.
    ///         The creator share still applies (bonus points are market activity).
    /// @param user   Spin winner.
    /// @param amount Bonus points, 1e18 scale: spinBase * (multiplier - 1).
    /// @param token  Market token the originating fill was on.
    function mintSpinBonus(address user, uint256 amount, address token) external {
        if (msg.sender != address(spinVRF)) revert NotSpinVRF(msg.sender);
        _mint(user, amount, PointsReason.SPIN_BONUS, token);
    }

    // ===============================================================
    // Views
    // ===============================================================

    /// @notice Current 7-day epoch index (block.timestamp / EPOCH_LENGTH).
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH_LENGTH;
    }

    /// @notice Points earned by a user within an epoch (1e18 scale).
    function epochPointsOf(address user, uint256 epoch) external view returns (uint256) {
        return _epochPoints[epoch][user];
    }

    /// @notice Total points minted within an epoch (1e18 scale).
    function epochTotal(uint256 epoch) external view returns (uint256) {
        return _epochTotals[epoch];
    }

    /// @notice Number of weight checkpoints written in an epoch.
    function checkpointCount(uint256 epoch) external view returns (uint256) {
        return _checkpoints[epoch].length;
    }

    /// @notice Reads a single weight checkpoint.
    function checkpointAt(uint256 epoch, uint256 index) external view returns (address user, uint256 cumulative) {
        Checkpoint storage cp = _checkpoints[epoch][index];
        return (cp.user, cp.cumulative);
    }

    /// @notice O(log n) weighted selection: returns the user at the checkpoint
    ///         covering weight target within the epoch, or the zero address if the
    ///         epoch is empty or target is at or beyond the epoch total.
    /// @param epoch  Epoch to select within.
    /// @param target Random weight target; must be drawn in [0, epochTotal(epoch)).
    function selectByWeight(uint256 epoch, uint256 target) external view returns (address) {
        Checkpoint[] storage cps = _checkpoints[epoch];
        uint256 n = cps.length;
        if (n == 0 || target >= cps[n - 1].cumulative) return address(0);
        uint256 lo = 0;
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cps[mid].cumulative > target) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return cps[lo].user;
    }

    /// @notice Win streak state for a user.
    /// @return wins             Current consecutive-wins counter.
    /// @return shieldConsumedAt Timestamp of last shield consumption (0 = never).
    /// @return shieldAvailable  Whether a loss right now would be absorbed.
    function winStreakOf(address user) external view returns (uint64 wins, uint64 shieldConsumedAt, bool shieldAvailable) {
        WinStreak storage s = _winStreaks[user];
        return (s.wins, s.shieldConsumedAt, _shieldAvailable(s));
    }

    /// @notice Daily activity streak state for a user.
    /// @return lastDay UTC day index of last activity (0 = never active).
    /// @return count   Consecutive-day counter as of lastDay.
    function dailyStreakOf(address user) external view returns (uint64 lastDay, uint64 count) {
        DailyStreak storage s = _dailyStreaks[user];
        return (s.lastDay, s.count);
    }

    /// @notice Win-streak multiplier that would apply to a fill right now (MULT_SCALE = 1.0x).
    function winMultiplierOf(address user) external view returns (uint256) {
        return _winMultiplier(_winStreaks[user].wins);
    }

    /// @notice Timestamp of a user's last win-streak advance (0 = never); the throttle allows the
    ///         next advance at this time plus WIN_STREAK_ADVANCE_WINDOW (audit fix L3).
    function winStreakAdvancedAt(address user) external view returns (uint64) {
        return _winStreaks[user].streakAdvancedAt;
    }

    /// @notice Daily-streak multiplier that would apply to a fill right now,
    ///         projecting the activity touch the fill itself would perform.
    function dailyMultiplierOf(address user) external view returns (uint256) {
        DailyStreak storage s = _dailyStreaks[user];
        uint64 day = uint64(block.timestamp / 1 days);
        uint64 projected;
        if (s.lastDay == day) {
            projected = s.count;
        } else if (s.lastDay + 1 == day && s.count > 0) {
            projected = s.count + 1;
        } else {
            projected = 1;
        }
        return _dailyMultiplier(projected);
    }

    // ===============================================================
    // Internal: points math
    // ===============================================================

    /// @dev Clamps notional then scales to 1e18-scale base points. Never reverts:
    ///      max product is NOTIONAL_CAP * 1e11 = 1e49, far below uint256 max even
    ///      after multiplier stacking (x 7.5e8 worst case) and 99x spin bonuses.
    function _basePoints(uint256 notional) internal pure returns (uint256) {
        uint256 clamped = notional > NOTIONAL_CAP ? NOTIONAL_CAP : notional;
        return clamped * POINTS_PER_NOTIONAL_UNIT;
    }

    /// @dev Win streak multiplier table (MULT_SCALE scale):
    ///      wins 0 or 1: 1.0x, 2: 1.2x, 3: 1.5x, 4: 2x, 5: 3x, 6 and up: 5x cap.
    function _winMultiplier(uint64 wins) internal pure returns (uint256) {
        if (wins < 2) return 10_000;
        if (wins == 2) return 12_000;
        if (wins == 3) return 15_000;
        if (wins == 4) return 20_000;
        if (wins == 5) return 30_000;
        return 50_000;
    }

    /// @dev Daily streak multiplier: 1.0x on day 1, +0.05x per further consecutive
    ///      day, capped at 1.5x (reached at 11 consecutive days).
    function _dailyMultiplier(uint64 count) internal pure returns (uint256) {
        if (count <= 1) return MULT_SCALE;
        uint256 mult = MULT_SCALE + DAILY_STEP * (uint256(count) - 1);
        return mult > DAILY_MULT_CAP ? DAILY_MULT_CAP : mult;
    }

    /// @dev Multiplier from the stored (already touched this transaction) counter.
    function _storedDailyMultiplier(address user) internal view returns (uint256) {
        return _dailyMultiplier(_dailyStreaks[user].count);
    }

    /// @dev Records UTC-day activity: same day is a no-op, consecutive day
    ///      increments the counter, any gap resets it to 1.
    function _touchDaily(address user) internal {
        DailyStreak storage s = _dailyStreaks[user];
        uint64 day = uint64(block.timestamp / 1 days);
        if (s.lastDay == day) return;
        if (s.lastDay + 1 == day && s.count > 0) {
            s.count = s.count + 1;
        } else {
            s.count = 1;
        }
        s.lastDay = day;
        emit DailyStreakUpdated(user, s.count, day);
    }

    /// @dev The shield is available if never consumed or SHIELD_WINDOW has elapsed
    ///      since the last consumption.
    function _shieldAvailable(WinStreak storage s) internal view returns (bool) {
        return s.shieldConsumedAt == 0 || block.timestamp >= uint256(s.shieldConsumedAt) + SHIELD_WINDOW;
    }

    /// @dev Advances the win streak at most once per WIN_STREAK_ADVANCE_WINDOW (audit fix L3). A
    ///      decisive win before the window elapses is a no-op for the streak (it still earned its
    ///      lifetime/leaderboard points at the fill), so a selective self-settle burst cannot inflate
    ///      the multiplier. streakAdvancedAt == 0 (never advanced, incl. just after a reset) lets the
    ///      first win advance immediately so honest new/rebuilt streaks are not delayed.
    function _recordWin(address user) internal {
        WinStreak storage s = _winStreaks[user];
        if (s.streakAdvancedAt != 0 && block.timestamp < uint256(s.streakAdvancedAt) + WIN_STREAK_ADVANCE_WINDOW) {
            return;
        }
        s.wins = s.wins + 1;
        s.streakAdvancedAt = uint64(block.timestamp);
        emit WinStreakAdvanced(user, s.wins);
    }

    /// @dev Loss state machine: a loss at streak 0 changes nothing; otherwise the
    ///      first loss inside a shield window is absorbed (shield consumed, streak
    ///      unchanged, shield refreshes SHIELD_WINDOW after consumption) and a
    ///      second loss inside the window resets the streak to 0.
    function _recordLoss(address user) internal {
        WinStreak storage s = _winStreaks[user];
        if (s.wins == 0) return;
        if (_shieldAvailable(s)) {
            s.shieldConsumedAt = uint64(block.timestamp);
            emit ShieldConsumed(user, s.wins);
        } else {
            s.wins = 0;
            // Clear the advance throttle so a rebuilt streak's first win advances immediately.
            s.streakAdvancedAt = 0;
            emit WinStreakReset(user);
        }
    }

    /// @dev Central mint: updates lifetime balances always, updates the epoch
    ///      balance and appends the epoch weight checkpoint for every reason
    ///      EXCEPT the creator share, and mints the additional creator share
    ///      (bounded recursion of depth 1: creator-share mints never mint further
    ///      shares).
    ///
    ///      Creator-share exclusion (audit C4): a market creator earns a passive
    ///      CREATOR_SHARE_BPS cut of every mint on their token, recorded on a
    ///      first-writer-wins basis. Counting that passive cut toward epoch weight
    ///      would let anyone front-run a listing to farm free jackpot-draw win
    ///      probability (both the daily and weekly draws select by epoch weight).
    ///      Creator-share points are therefore kept out of _epochPoints,
    ///      _epochTotals, and _checkpoints; they still count toward pointsOf and
    ///      totalPoints so honest creators keep full lifetime and leaderboard
    ///      credit. Keeping the epoch total and the last checkpoint cumulative in
    ///      lockstep (both skip the creator share) preserves the invariant that
    ///      epochTotal(epoch) equals the final checkpoint cumulative, which the
    ///      weighted draw relies on.
    function _mint(address user, uint256 amount, PointsReason reason, address token) internal {
        if (amount == 0) return;
        pointsOf[user] += amount;
        totalPoints += amount;

        uint256 epoch = currentEpoch();
        if (reason != PointsReason.CREATOR_SHARE) {
            _epochPoints[epoch][user] += amount;
            uint256 cumulative = _epochTotals[epoch] + amount;
            _epochTotals[epoch] = cumulative;
            _checkpoints[epoch].push(Checkpoint({user: user, cumulative: cumulative}));
        }

        emit PointsEarned(user, reason, token, amount, epoch);

        if (reason != PointsReason.CREATOR_SHARE) {
            address creator = creatorOf[token];
            if (creator != address(0)) {
                uint256 share = (amount * CREATOR_SHARE_BPS) / MULT_SCALE;
                if (share > 0) {
                    _mint(creator, share, PointsReason.CREATOR_SHARE, token);
                }
            }
        }
    }
}
