// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title PauseGuardian: bounded emergency pause switch for THE PIT markets
/// @notice A single guardian address (intended to be a timelocked multisig) can pause an
///         individual market, or all markets globally, for at most 24 hours per pause.
///         A pause blocks new fills AND settlement on affected markets, then auto-expires
///         with no further action required. The guardian can never touch funds, prices,
///         or protocol parameters: its only powers are pause and early unpause.
/// @dev Anti-griefing rule: a given pause key (a market address, or address(0) for the
///      global key) can be paused at most once per 72 hours, measured from the start of
///      the previous pause. Because the cooldown (72h) exceeds the maximum pause length
///      (24h), a pause can never be extended while active, and any position is always
///      eventually settleable: every 72 hour window contains at least 48 hours of
///      guaranteed unpaused time per key (fills and settlement check both the market key
///      and the global key, so worst case both keys alternate, still leaving unpaused
///      windows because cooldowns overlap pause windows).
///
///      DURATION BOUNDS, STATED PRECISELY (wave-2b R-10; earlier audit docs blurred the
///      two): a SINGLE pause lasts at most 24 hours (MAX_PAUSE_DURATION). The 48-hour
///      figure quoted in the wave-1/wave-2 audit docs is the worst-case CONTINUOUS pause
///      a single market can EXPERIENCE, reachable only by stacking its own key and the
///      global key back-to-back (24h + 24h); it is NOT the guardian's per-key emergency
///      coverage. Consequence for incident response: one pause (24h) cannot span the
///      2-day governance timelock delay, so an emergency whose fix needs a timelocked
///      config change has an UNCOVERED gap from hour 24 until the fix executes, and the
///      72h cooldown forbids re-pausing the same key sooner. Accepted tradeoff: the
///      autonomous breaker (cooldown / fallback state machine) and the source quorum
///      margin (wave-2b R-5: majors run 4 sources so losing one keeps quorum) handle the
///      single-feed emergencies that would otherwise need that window.
contract PauseGuardian {
    // ======================================================================
    // Constants
    // ======================================================================

    /// @notice Maximum duration of a single pause; pauses auto-expire after this.
    uint64 public constant MAX_PAUSE_DURATION = 24 hours;

    /// @notice Minimum time between two pause starts on the same key.
    uint64 public constant PAUSE_COOLDOWN = 72 hours;

    // ======================================================================
    // Storage
    // ======================================================================

    /// @notice The only address allowed to pause and unpause.
    address public immutable guardian;

    /// @notice Timestamp at which the last pause on a key started (0 = never paused).
    /// @dev Key is a market address, or address(0) for the global pause key.
    mapping(address => uint64) public lastPauseStart;

    /// @notice Timestamp at which the current or most recent pause on a key ends.
    mapping(address => uint64) public pauseEnd;

    // ======================================================================
    // Errors and events
    // ======================================================================

    /// @notice Caller is not the guardian.
    error NotGuardian();
    /// @notice The zero address was supplied where a real address is required.
    error ZeroAddress();
    /// @notice The key was paused less than PAUSE_COOLDOWN ago.
    /// @param availableAt Earliest timestamp at which this key can be paused again.
    error PauseOnCooldown(uint64 availableAt);
    /// @notice unpause was called on a key that is not currently paused.
    error NotCurrentlyPaused();

    /// @notice Emitted when a key is paused.
    event PauseTriggered(address indexed target, uint64 start, uint64 end);
    /// @notice Emitted when a key is unpaused early by the guardian.
    event Unpaused(address indexed target, uint64 at);

    // ======================================================================
    // Constructor and modifiers
    // ======================================================================

    /// @param guardian_ The pause authority (timelocked multisig in production).
    constructor(address guardian_) {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    // ======================================================================
    // Guardian actions
    // ======================================================================

    /// @notice Pause a market (or all markets when target is address(0)) for 24 hours.
    /// @dev Reverts if the key was paused less than 72 hours ago (measured start to
    ///      start). This makes rolling or extended pauses impossible by construction.
    /// @param target Market address to pause, or address(0) for the global pause.
    function pause(address target) external onlyGuardian {
        uint64 last = lastPauseStart[target];
        if (last != 0 && block.timestamp < last + PAUSE_COOLDOWN) {
            revert PauseOnCooldown(last + PAUSE_COOLDOWN);
        }
        uint64 start = uint64(block.timestamp);
        uint64 end = start + MAX_PAUSE_DURATION;
        lastPauseStart[target] = start;
        pauseEnd[target] = end;
        emit PauseTriggered(target, start, end);
    }

    /// @notice End an active pause on a key immediately.
    /// @dev Does NOT reset the 72 hour cooldown: the next pause on this key is still
    ///      gated on lastPauseStart, so an early unpause cannot be used to pause again
    ///      sooner.
    /// @param target Market address, or address(0) for the global key.
    function unpause(address target) external onlyGuardian {
        if (block.timestamp >= pauseEnd[target]) revert NotCurrentlyPaused();
        pauseEnd[target] = uint64(block.timestamp);
        emit Unpaused(target, uint64(block.timestamp));
    }

    // ======================================================================
    // Views
    // ======================================================================

    /// @notice True if the given market is paused, either individually or via the
    ///         global key. Purely timestamp based: pauses auto-expire.
    /// @param market The market to query.
    function isPaused(address market) external view returns (bool) {
        return block.timestamp < pauseEnd[market] || block.timestamp < pauseEnd[address(0)];
    }
}
