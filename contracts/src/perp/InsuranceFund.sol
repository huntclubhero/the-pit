// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IInsuranceFund} from "./interfaces/IInsuranceFund.sol";

/// @title InsuranceFund: pre-ADL bad-debt backstop for THE PIT v2 perps (spec 6.1/6.2)
/// @notice Standalone USDG holder. Inflows: 80% of liquidation penalties (routed by the engine),
///         the launch treasury seed (100k USDG proposed), and open permissionless top-ups via
///         seed() or plain transfers. Outflows are exhaustive and engine-only: cover() pays a
///         verified bad-debt shortfall to the configured vault, and payKeeperFloor() tops a
///         liquidation keeper up to the floor, bounded per call by keeperFloorCap (launch 5
///         USDG). There is NO external claim path.
/// @dev Governance withdrawal timelock: the owner of this contract IS the protocol's 2-day
///      TimelockController (Ownable2Step handover, same pattern as every v1 contract), so
///      governanceWithdraw is timelocked at the ownership layer: a compromised operational key
///      cannot flash-drain the fund (Drift lesson, spec 6.1). On top of the timelock,
///      governanceWithdraw is rate limited to max(govWithdrawCapBps of the window-start balance,
///      GOV_WITHDRAW_FLOOR) per GOV_WITHDRAW_WINDOW, bounding the blast radius of even a
///      compromised timelock to a fraction of the fund per week; cover() and payKeeperFloor are
///      NOT subject to the limit.
contract InsuranceFund is IInsuranceFund, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ================================ constants ================================

    /// @notice Launch per-call bound on keeper-floor top-ups: 5 USDG (spec 3.3).
    uint256 public constant DEFAULT_KEEPER_FLOOR_CAP = 5e6;
    /// @dev keeperFloorCap can never be configured above 100 USDG.
    uint256 private constant MAX_KEEPER_FLOOR_CAP = 100e6;
    /// @notice Fixed window over which governanceWithdraw is rate limited.
    uint64 public constant GOV_WITHDRAW_WINDOW = 7 days;
    /// @notice Launch per-window governance withdrawal cap: 25% of the balance at window start.
    uint16 public constant DEFAULT_GOV_WITHDRAW_CAP_BPS = 2500;
    /// @dev The per-window cap fraction can never be configured above 50%.
    uint16 private constant MAX_GOV_WITHDRAW_CAP_BPS = 5000;
    /// @notice Per-window allowance floor (10k USDG): a small or dust-level fund stays fully
    ///         withdrawable and a full migration terminates in bounded windows instead of
    ///         asymptoting on the percentage cap.
    uint256 public constant GOV_WITHDRAW_FLOOR = 10_000e6;
    /// @dev Basis points denominator.
    uint256 private constant BPS = 10_000;

    // ================================ storage ================================

    /// @notice The USDG token held by the fund.
    IERC20 public immutable USDG;
    /// @notice The single authorized engine (sole caller of cover/payKeeperFloor). Set once.
    address public engine;
    /// @notice The PitVault: the only recipient cover() will ever pay. Set once.
    address public vault;
    /// @notice Per-call bound on payKeeperFloor (governance adjustable within [0, 100 USDG]).
    uint256 public keeperFloorCap = DEFAULT_KEEPER_FLOOR_CAP;
    /// @notice Per-window governance withdrawal cap in bps of the balance at window start.
    uint16 public govWithdrawCapBps = DEFAULT_GOV_WITHDRAW_CAP_BPS;
    /// @notice Start timestamp of the active governance withdrawal window (0 = none opened yet).
    uint64 public govWindowStart;
    /// @notice USDG withdrawn by governance inside the active window.
    uint256 public govWindowWithdrawn;
    /// @notice Allowance snapshot of the active window (taken when the window opened).
    uint256 public govWindowCap;

    // ================================ events ================================

    event EngineSet(address indexed engine);
    event VaultSet(address indexed vault);
    event Covered(address indexed vault, uint256 requested, uint256 covered);
    event KeeperFloorPaid(address indexed keeper, uint256 requested, uint256 paid);
    event Seeded(address indexed from, uint256 amount);
    event GovernanceWithdrawal(address indexed to, uint256 amount);
    event KeeperFloorCapSet(uint256 cap);
    event GovWithdrawCapBpsSet(uint16 capBps);

    // ================================ errors ================================

    error NotEngine();
    error EngineAlreadySet();
    error VaultAlreadySet();
    error VaultMismatch();
    error ZeroAddress();
    error ZeroAmount();
    error KeeperFloorAboveCap();
    error ParamOutOfBounds();
    error GovWithdrawCapExceeded(uint256 requested, uint256 available);

    // ================================ modifiers ================================

    modifier onlyEngine() {
        if (msg.sender != engine) revert NotEngine();
        _;
    }

    // ================================ constructor ================================

    /// @param usdg_ The USDG token (6 decimals).
    /// @param initialOwner The 2-day TimelockController (Ownable2Step handover pattern).
    constructor(IERC20 usdg_, address initialOwner) Ownable(initialOwner) {
        if (address(usdg_) == address(0)) revert ZeroAddress();
        USDG = usdg_;
    }

    // ================================ wiring (owner, once) ================================

    /// @notice Set the authorized engine, exactly once.
    function setEngine(address engine_) external onlyOwner {
        if (engine != address(0)) revert EngineAlreadySet();
        if (engine_ == address(0)) revert ZeroAddress();
        engine = engine_;
        emit EngineSet(engine_);
    }

    /// @notice Set the vault cover() pays, exactly once.
    function setVault(address vault_) external onlyOwner {
        if (vault != address(0)) revert VaultAlreadySet();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultSet(vault_);
    }

    // ================================ engine-only outflows ================================

    /// @inheritdoc IInsuranceFund
    /// @dev Pays min(shortfall, balance) so a large gap event degrades gracefully instead of
    ///      reverting the liquidation that discovered it; the engine escalates the uncovered
    ///      remainder to ADL (spec 6.3). The recipient must equal the configured vault: even a
    ///      compromised engine cannot redirect fund assets elsewhere (defense in depth).
    function cover(uint256 shortfall, address vault_) external onlyEngine nonReentrant returns (uint256 covered) {
        if (vault_ != vault || vault_ == address(0)) revert VaultMismatch();
        if (shortfall == 0) revert ZeroAmount();
        covered = Math.min(shortfall, USDG.balanceOf(address(this)));
        if (covered > 0) USDG.safeTransfer(vault_, covered);
        emit Covered(vault_, shortfall, covered);
    }

    /// @inheritdoc IInsuranceFund
    /// @dev Bounded per call by keeperFloorCap. Pays min(amount, balance): an empty fund shorts
    ///      the keeper rather than bricking the liquidation path (liveness over reward).
    function payKeeperFloor(address keeper, uint256 amount) external onlyEngine nonReentrant {
        if (keeper == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > keeperFloorCap) revert KeeperFloorAboveCap();
        uint256 paid = Math.min(amount, USDG.balanceOf(address(this)));
        if (paid > 0) USDG.safeTransfer(keeper, paid);
        emit KeeperFloorPaid(keeper, amount, paid);
    }

    // ================================ inflows ================================

    /// @notice Permissionless top-up convenience (plain USDG transfers work identically).
    function seed(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        USDG.safeTransferFrom(msg.sender, address(this), amount);
        emit Seeded(msg.sender, amount);
    }

    // ================================ governance ================================

    /// @notice Withdraw fund assets. Owner-only, and the owner is the 2-day timelock: this IS the
    ///         timelocked governance withdrawal of spec 6.1. Additionally rate limited: at most
    ///         max(govWithdrawCapBps of the balance at window start, GOV_WITHDRAW_FLOOR) may leave
    ///         per GOV_WITHDRAW_WINDOW, so even a compromised timelock cannot flash-drain the
    ///         backstop; observers get at least one full window to react while cover() (engine
    ///         verified, vault-locked) keeps working at full size throughout.
    /// @dev The window opens lazily on the first withdrawal after the previous window elapsed and
    ///      snapshots its allowance from the live balance at that instant. Inflows during a window
    ///      do not raise the open window's allowance; a cap-fraction change (timelocked) applies
    ///      from the next window.
    function governanceWithdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (govWindowStart == 0 || block.timestamp >= uint256(govWindowStart) + GOV_WITHDRAW_WINDOW) {
            govWindowStart = uint64(block.timestamp);
            govWindowWithdrawn = 0;
            govWindowCap = _govWindowCapFor(USDG.balanceOf(address(this)));
        }
        uint256 available = govWindowCap - govWindowWithdrawn;
        if (amount > available) revert GovWithdrawCapExceeded(amount, available);
        govWindowWithdrawn += amount;
        USDG.safeTransfer(to, amount);
        emit GovernanceWithdrawal(to, amount);
    }

    /// @notice Set the per-window governance withdrawal cap fraction (bps of the balance at
    ///         window start), never zero and never above 50%.
    function setGovWithdrawCapBps(uint16 capBps) external onlyOwner {
        if (capBps == 0 || capBps > MAX_GOV_WITHDRAW_CAP_BPS) revert ParamOutOfBounds();
        govWithdrawCapBps = capBps;
        emit GovWithdrawCapBpsSet(capBps);
    }

    /// @notice Adjust the per-call keeper-floor bound (never above 100 USDG).
    function setKeeperFloorCap(uint256 cap) external onlyOwner {
        if (cap > MAX_KEEPER_FLOOR_CAP) revert ParamOutOfBounds();
        keeperFloorCap = cap;
        emit KeeperFloorCapSet(cap);
    }

    // ================================ views ================================

    /// @inheritdoc IInsuranceFund
    function balance() external view returns (uint256) {
        return USDG.balanceOf(address(this));
    }

    /// @notice Remaining governance withdrawal allowance right now. Mirrors the lazy window
    ///         rollover of governanceWithdraw: once the active window has elapsed (or none has
    ///         opened yet), the next withdrawal snapshots a fresh allowance from the live balance.
    function govWithdrawAvailable() external view returns (uint256) {
        if (govWindowStart == 0 || block.timestamp >= uint256(govWindowStart) + GOV_WITHDRAW_WINDOW) {
            return _govWindowCapFor(USDG.balanceOf(address(this)));
        }
        return govWindowCap - govWindowWithdrawn;
    }

    // ================================ internal ================================

    /// @dev Allowance of a freshly opened window given the balance at that instant.
    function _govWindowCapFor(uint256 bal) private view returns (uint256) {
        return Math.max(Math.mulDiv(bal, govWithdrawCapBps, BPS), GOV_WITHDRAW_FLOOR);
    }
}
