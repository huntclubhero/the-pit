// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Types} from "../interfaces/Types.sol";
import {PerpTypes} from "./interfaces/PerpTypes.sol";
import {IPitVault} from "./interfaces/IPitVault.sol";
import {IPerpRiskConfig} from "./interfaces/IPerpRiskConfig.sol";
import {IPerpMarketList, IOracleRouterVaultView} from "./interfaces/IPerpVaultDeps.sol";

/// @title PitVault (PLP): the LP-as-house counterparty vault for THE PIT v2 perps
/// @notice ERC-4626-modified USDG vault (spec section 4). LPs deposit USDG and mint PLP; the
///         vault is the sole automated counterparty to all net open interest, called only by the
///         authorized PerpEngine on its counterparty surface. Hard first-depositor inflation
///         guard: OZ virtual-shares decimal offset of 6, 1,000e6 dead shares carved from the
///         first deposit, and a 1 USDG minimum deposit.
///
///         NAV (totalAssets) = USDG balance
///                           minus crystallized-but-unclaimed withdrawal liability
///                           minus aggregate clamped trader unrealized PnL (spec 4.3).
///         The engine-receivable term of spec 4.3 is structurally zero here because
///         settleTraderLoss PULLS the USDG from the engine in the same call (the engine must
///         approve the vault); nothing is ever owed across calls. Funding and borrow accruals
///         that positions owe the vault are deliberately NOT counted until realized, which only
///         understates NAV (the safe direction for entering depositors).
///
///         Exit is a TWO-STEP queue: requestWithdraw locks shares into the current 24h epoch;
///         once the epoch has passed, the epoch settles (permissionlessly or lazily) at the NAV
///         of settlement, bounded by the per-epoch withdrawal cap (25% of TVL) AND the solvency
///         floor (fulfilment never pushes totalAssets below solvencyFloorBps of totalReserved);
///         fulfilment is pro-rata and the unfulfilled remainder rolls into the epoch of
///         settlement, re-pricing at that epoch's NAV. claim() then pays crystallized USDG.
///         Direct ERC-4626 withdraw/redeem/mint are disabled (deposit + the queue are the only
///         doors), so the vault can never be flash-drained around a known incoming loss.
///
///         $PIT LP incentives (the 15% tranche): PLP is a standard transferable ERC-20, so the
///         $PIT staking/emissions contract consumes PLP externally by holding it; no hook is
///         required in this contract and none is wired at launch (documented stub, spec 4.6).
/// @dev Reentrancy: USDG has no transfer hooks, but every fund-moving path is nonReentrant with
///      strict checks-effects-interactions anyway. View calls into the engine and router happen
///      inside totalAssets; the engine's marketState MUST be a plain view (IPerpVaultDeps).
contract PitVault is IPitVault, ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ================================ constants ================================

    uint256 private constant BPS = 10_000;
    /// @notice ERC-4626 virtual-shares decimal offset (inflation guard leg 1).
    uint8 public constant DECIMALS_OFFSET = 6;
    /// @notice Raw PLP share units burned to the dead address out of the first deposit (leg 2).
    uint256 public constant DEAD_SHARES = 1_000e6;
    /// @notice Recipient of the dead shares.
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice Minimum deposit: 1 USDG (inflation guard leg 3).
    uint256 public constant MIN_DEPOSIT = 1e6;
    /// @notice Withdraw-queue and deposit-cap epoch length (spec 4.4).
    uint256 public constant EPOCH_DURATION = 24 hours;
    /// @dev size1e18 * price1e18 / 1e30 = USDG units (6 decimals).
    uint256 private constant SIZE_TIMES_PRICE_TO_USDG = 1e30;
    /// @dev USD 1e18 -> USDG 6-decimal units.
    uint256 private constant USD1E18_TO_USDG = 1e12;
    /// @dev Fixed-point scale for the stored net-assets-per-share settlement price.
    uint256 private constant PER_SHARE_SCALE = 1e18;

    // ================================ parameter defaults + bounds ================================

    uint16 public constant DEFAULT_DEPOSIT_FEE_BPS = 10;
    uint16 public constant DEFAULT_WITHDRAW_FEE_BPS = 10;
    uint16 public constant DEFAULT_DEPOSIT_EPOCH_CAP_BPS = 2000;
    uint256 public constant DEFAULT_DEPOSIT_EPOCH_CAP_FLOOR = 100_000e6;
    uint16 public constant DEFAULT_WITHDRAW_EPOCH_CAP_BPS = 2500;
    uint16 public constant DEFAULT_SOLVENCY_FLOOR_BPS = 12_000;
    /// @dev Economics v2 (finding A2): the fresh-market ramp is now LINEAR PER DAY, 1%/day of
    ///      TVL over 14 days (was a flat 2% throttle over 7 days), so a new market cannot reach
    ///      full capacity until it has real price history and external arbitrage.
    uint16 public constant DEFAULT_NEW_MARKET_RAMP_BPS = 100;
    uint64 public constant DEFAULT_NEW_MARKET_RAMP_DURATION = 14 days;
    uint64 public constant DEFAULT_MAX_MARK_AGE = 15 minutes;
    /// @dev Deposit/withdraw fees can never exceed 1%.
    uint16 private constant MAX_VAULT_FEE_BPS = 100;
    /// @dev The solvency floor can never be configured below 1.0x totalReserved.
    uint16 private constant MIN_SOLVENCY_FLOOR_BPS = 10_000;
    /// @dev The solvency floor can never be configured above 1.5x totalReserved: a higher bound
    ///      would let a mis-set owner brick LP withdrawals across the normal utilization band
    ///      (at 1.5x, withdrawals only stall once utilization exceeds 66.7%, still above the 80%
    ///      util cap headroom but far safer than the old 3.0x which bricked past 33% util, B10).
    uint16 private constant MAX_SOLVENCY_FLOOR_BPS = 15_000;
    uint64 private constant MAX_MAX_MARK_AGE = 1 hours;
    uint64 private constant MAX_RAMP_DURATION = 30 days;

    // ================================ storage: wiring ================================

    /// @notice The single authorized engine (counterparty surface caller). Owner-set exactly once.
    address public engine;
    /// @dev Market-list view of the engine (same address as `engine`).
    IPerpMarketList private _engineViews;
    /// @notice Oracle router (peekPrice for NAV marks, maxMarketPayoutCap1e18 for reserve caps).
    IOracleRouterVaultView public immutable ROUTER;
    /// @notice Risk config supplying maxUtilizationBps and marketReserveCapBps.
    IPerpRiskConfig public riskConfig;
    /// @notice Deployment timestamp: epoch 0 starts here.
    uint64 public immutable GENESIS;

    // ================================ storage: governance params ================================

    /// @notice Deposit fee in bps, credited to vault NAV (anti NAV-sandwich).
    uint16 public depositFeeBps = DEFAULT_DEPOSIT_FEE_BPS;
    /// @notice Withdraw fee in bps, credited to vault NAV.
    uint16 public withdrawFeeBps = DEFAULT_WITHDRAW_FEE_BPS;
    /// @notice Per-epoch deposit cap in bps of TVL (NAV-timing damping).
    uint16 public depositEpochCapBps = DEFAULT_DEPOSIT_EPOCH_CAP_BPS;
    /// @notice Absolute per-epoch deposit floor so the cap never bricks bootstrap from zero TVL.
    uint256 public depositEpochCapFloor = DEFAULT_DEPOSIT_EPOCH_CAP_FLOOR;
    /// @notice Per-epoch withdrawal cap in bps of TVL (pro-rata, remainder rolls).
    uint16 public withdrawEpochCapBps = DEFAULT_WITHDRAW_EPOCH_CAP_BPS;
    /// @notice Withdrawal fulfilment never pushes totalAssets below this fraction of totalReserved.
    uint16 public solvencyFloorBps = DEFAULT_SOLVENCY_FLOOR_BPS;
    /// @notice Extra reserve throttle for a market's first ramp window, bps of TVL PER DAY
    ///         (linear ramp: day N allows N * newMarketRampBps of TVL, economics v2).
    uint16 public newMarketRampBps = DEFAULT_NEW_MARKET_RAMP_BPS;
    /// @notice Length of the new-market ramp window.
    uint64 public newMarketRampDuration = DEFAULT_NEW_MARKET_RAMP_DURATION;
    /// @notice Staleness bound on cached NAV marks; beyond it navMarkStale() flags (never freezes).
    uint64 public maxMarkAge = DEFAULT_MAX_MARK_AGE;

    // ================================ storage: counterparty surface ================================

    /// @inheritdoc IPitVault
    uint256 public override totalReserved;
    /// @notice Reserved payout capacity per market token, USDG units.
    mapping(address token => uint256) public reservedBy;
    /// @notice First-ever reservation timestamp per market (anchors the new-market ramp).
    mapping(address token => uint64) public firstReserveAt;
    /// @notice Cumulative trade-fee revenue received from the engine (fee carve + vol surcharge,
    ///         economics v2). Transparency counter only; the USDG sits in usdgBalance and NAV.
    uint256 public cumulativeFeeRevenue;
    /// @notice Cumulative liquidation-penalty revenue received from the engine (economics v2).
    uint256 public cumulativeLiquidationRevenue;

    // ================================ storage: withdraw queue ================================

    /// @notice Per-epoch withdraw-queue accounting.
    /// @param sharesRequested Total PLP raw shares queued into this epoch (frozen at settlement).
    /// @param sharesFulfilled Shares redeemed at settlement (burned); the rest rolled forward.
    /// @param assetsPerShareNet1e18 Net-of-fee USDG paid per fulfilled raw share, 1e18 fixed point.
    /// @param rolledToEpoch Epoch that received the unfulfilled remainder (settlement-time epoch).
    /// @param settled True once settled; a settled epoch's numbers are immutable.
    struct EpochInfo {
        uint128 sharesRequested;
        uint128 sharesFulfilled;
        uint256 assetsPerShareNet1e18;
        uint64 rolledToEpoch;
        bool settled;
    }

    /// @notice A user's open queue position: `shares` locked, currently attributed to `epoch`.
    struct WithdrawRequest {
        uint128 shares;
        uint64 epoch;
    }

    /// @notice Epoch accounting by epoch index.
    mapping(uint64 epoch => EpochInfo) public epochs;
    /// @notice Open queue position per user (one active chain per address).
    mapping(address user => WithdrawRequest) public requestOf;
    /// @notice Crystallized USDG a user can claim (resolved, priced, waiting for payout).
    mapping(address user => uint256) public claimableOf;
    /// @notice Sum of all crystallized-but-unclaimed USDG (a liability excluded from NAV).
    uint256 public totalClaimLiability;
    /// @notice USDG deposited per epoch (deposit-cap accounting).
    mapping(uint64 epoch => uint256) public depositedInEpoch;

    // ================================ events ================================

    event EngineSet(address indexed engine);
    event RiskConfigSet(address indexed riskConfig);
    event WithdrawRequested(address indexed user, uint256 shares, uint64 indexed epoch);
    event EpochSettled(uint64 indexed epoch, uint256 sharesFulfilled, uint256 netAssetsOwed, uint256 sharesRolled);
    event WithdrawResolved(address indexed user, uint256 assetsOwed);
    event WithdrawClaimed(address indexed user, uint256 assets);
    event PayoutReserved(address indexed token, uint256 amount, uint256 marketReserved, uint256 totalReserved);
    event PayoutReleased(address indexed token, uint256 amount, uint256 marketReserved, uint256 totalReserved);
    event TraderWinSettled(address indexed to, uint256 amount);
    event FundingCreditSettled(address indexed to, uint256 amount);
    event TraderLossSettled(uint256 amount);
    event FeeRevenueReceived(uint256 amount, uint256 cumulative);
    event LiquidationRevenueReceived(uint256 amount, uint256 cumulative);
    event VaultFeesSet(uint16 depositFeeBps, uint16 withdrawFeeBps);
    event DepositEpochCapSet(uint16 capBps, uint256 capFloor);
    event WithdrawEpochCapBpsSet(uint16 capBps);
    event SolvencyFloorBpsSet(uint16 floorBps);
    event NewMarketRampSet(uint16 rampBps, uint64 rampDuration);
    event MaxMarkAgeSet(uint64 maxMarkAge);

    // ================================ errors ================================

    error NotEngine();
    error EngineAlreadySet();
    error ZeroAddress();
    error ZeroAmount();
    error DepositBelowMinimum();
    error DepositEpochCapExceeded();
    error FirstDepositTooSmall();
    error ExitDisabledUseQueue();
    error MintDisabledUseDeposit();
    error NothingToClaim();
    error EpochNotMature();
    error PendingRequestInOtherEpoch();
    error UtilizationCapExceeded();
    error MarketReserveCapExceeded();
    error ReleaseExceedsReserved();
    error WinExceedsReserved();
    error CreditRecipientNotEngine();
    error ParamOutOfBounds();
    error SettlementPaused();

    // ================================ modifiers ================================

    modifier onlyEngine() {
        if (msg.sender != engine) revert NotEngine();
        _;
    }

    // ================================ constructor ================================

    /// @param usdg_ The USDG token (6 decimals).
    /// @param router_ The shipped OracleRouter (satisfies IOracleRouterVaultView as-is).
    /// @param riskConfig_ The PerpRiskConfig supplying utilization and market-cap bps.
    /// @param initialOwner The 2-day TimelockController (Ownable2Step handover pattern).
    constructor(IERC20 usdg_, IOracleRouterVaultView router_, IPerpRiskConfig riskConfig_, address initialOwner)
        ERC4626(usdg_)
        ERC20("Pit LP Vault", "PLP")
        Ownable(initialOwner)
    {
        if (address(router_) == address(0) || address(riskConfig_) == address(0)) revert ZeroAddress();
        ROUTER = router_;
        riskConfig = riskConfig_;
        GENESIS = uint64(block.timestamp);
    }

    // ================================ wiring (owner) ================================

    /// @notice Set the authorized engine, exactly once. After this the engine is the sole caller
    ///         of the counterparty surface and the NAV market list is read from it.
    function setEngine(address engine_) external onlyOwner {
        if (engine != address(0)) revert EngineAlreadySet();
        if (engine_ == address(0)) revert ZeroAddress();
        engine = engine_;
        _engineViews = IPerpMarketList(engine_);
        emit EngineSet(engine_);
    }

    /// @notice Swap the risk-config source (governance, timelocked via ownership).
    function setRiskConfig(IPerpRiskConfig riskConfig_) external onlyOwner {
        if (address(riskConfig_) == address(0)) revert ZeroAddress();
        riskConfig = riskConfig_;
        emit RiskConfigSet(address(riskConfig_));
    }

    // ================================ NAV ================================

    /// @inheritdoc IPitVault
    /// @dev totalAssets = USDG balance minus unclaimed crystallized withdrawals minus aggregate
    ///      clamped trader uPnL. Floors at zero (a bust vault reads zero, it never reverts, so
    ///      deposits and epoch settlement stay live through an outage; spec 2.3 NAV row).
    function totalAssets() public view override(ERC4626, IPitVault) returns (uint256) {
        int256 nav = int256(IERC20(asset()).balanceOf(address(this)));
        nav -= int256(totalClaimLiability);
        nav -= aggTraderUnrealizedPnl();
        return nav <= 0 ? 0 : uint256(nav);
    }

    /// @inheritdoc IPitVault
    /// @dev The engine's drawdown circuit anchors on THIS figure, not bare totalAssets: adding
    ///      back the crystallized-but-unclaimed withdrawal liability means a routine LP exit
    ///      (which lowers totalAssets and raises the liability in lockstep at settlement) does
    ///      not register as a trading drawdown, so it can never latch the opens circuit (B2).
    function drawdownReferenceAssets() external view override returns (uint256) {
        return totalAssets() + totalClaimLiability;
    }

    /// @notice Aggregate trader unrealized PnL across all markets, USDG units, positive = traders
    ///         are collectively up (a claim against the vault). Per spec 4.3: per market and side,
    ///         uPnL from the engine's running aggregates at the NAV mark; each side's loss is
    ///         clamped at that side's total margin (isolated margin: traders can never lose more),
    ///         and each market's net profit is clamped at the market's total reserved maxPayout
    ///         (the payout cap). The aggregate-level profit clamp slightly OVERSTATES the trader
    ///         claim versus per-position clamping, which understates NAV: safe for depositors.
    ///         Marks: peekPrice when OK, else the engine's cached mark (never zero during an
    ///         outage: dropping a market would inflate NAV, spec 4.3).
    function aggTraderUnrealizedPnl() public view returns (int256 total) {
        IPerpMarketList views = _engineViews;
        if (address(views) == address(0)) return 0;
        uint256 n = views.marketCount();
        for (uint256 i = 0; i < n; ++i) {
            address token = views.marketAt(i);
            PerpTypes.MarketAggregates memory agg = views.marketState(token);
            if (agg.totalLongSize1e18 == 0 && agg.totalShortSize1e18 == 0) continue;
            uint256 mark = _navMark(token, agg.cachedMark1e18);
            if (mark == 0) continue;
            int256 longUpnl = int256(Math.mulDiv(agg.totalLongSize1e18, mark, SIZE_TIMES_PRICE_TO_USDG))
                - int256(uint256(agg.totalLongCost));
            int256 shortUpnl = int256(uint256(agg.totalShortCost))
                - int256(Math.mulDiv(agg.totalShortSize1e18, mark, SIZE_TIMES_PRICE_TO_USDG));
            int256 longFloor = -int256(uint256(agg.totalLongMargin));
            int256 shortFloor = -int256(uint256(agg.totalShortMargin));
            if (longUpnl < longFloor) longUpnl = longFloor;
            if (shortUpnl < shortFloor) shortUpnl = shortFloor;
            int256 marketUpnl = longUpnl + shortUpnl;
            int256 payoutCeil = int256(uint256(agg.totalMaxPayout));
            if (marketUpnl > payoutCeil) marketUpnl = payoutCeil;
            total += marketUpnl;
        }
    }

    /// @notice True when any market with open interest is marking NAV off a cached mark older
    ///         than maxMarkAge (ops/UI signal). NAV itself never freezes (deposits stay live at a
    ///         cached-mark NAV, the depositor-safe understating direction, spec 4.3); the same
    ///         staleness predicate instead HARD-GATES epoch settlement via settlementPaused() (B8),
    ///         so maxMarkAge is a real bound on the price a queued withdrawal can crystallize at,
    ///         not merely an advisory flag.
    function navMarkStale() public view returns (bool) {
        IPerpMarketList views = _engineViews;
        if (address(views) == address(0)) return false;
        uint256 n = views.marketCount();
        for (uint256 i = 0; i < n; ++i) {
            address token = views.marketAt(i);
            PerpTypes.MarketAggregates memory agg = views.marketState(token);
            if (agg.totalLongSize1e18 == 0 && agg.totalShortSize1e18 == 0) continue;
            (uint256 p, Types.PriceStatus s) = ROUTER.peekPrice(token);
            if (s == Types.PriceStatus.OK && p > 0) continue;
            if (uint256(agg.cachedMarkAt) + maxMarkAge < block.timestamp) return true;
        }
        return false;
    }

    /// @notice True when epoch settlement must be paused because at least one open-interest market
    ///         is in a window where the aggregate loss clamp can OVERSTATE NAV (pa-vaultshares S1):
    ///         either (a) it is marking off a cached mark older than maxMarkAge (an oracle gap, the
    ///         navMarkStale condition), or (b) its spot-vs-TWAP deviation breaker is tripped, which
    ///         blocks opens AND liquidations so a position underwater past its own margin sits
    ///         uncollected while the clamp still books its loss only to margin. In either window a
    ///         permissionless settleEpoch by a standing-queued LP would crystallize the overstated
    ///         price and socialize the uncollectable bad debt onto the remaining LPs, so settlement
    ///         reverts (or defers, on the lazy path) until the market is fresh and unbroken again.
    ///         O(markets), matching the NAV loop; deposits and NAV reads are NOT gated (they use the
    ///         floored, never-reverting totalAssets in the depositor-safe direction).
    function settlementPaused() public view returns (bool) {
        IPerpMarketList views = _engineViews;
        if (address(views) == address(0)) return false;
        uint256 n = views.marketCount();
        for (uint256 i = 0; i < n; ++i) {
            address token = views.marketAt(i);
            PerpTypes.MarketAggregates memory agg = views.marketState(token);
            if (agg.totalLongSize1e18 == 0 && agg.totalShortSize1e18 == 0) continue;
            (uint256 p, Types.PriceStatus s) = ROUTER.peekPrice(token);
            // (a) stale cached mark past the hard maxMarkAge bound.
            if (!(s == Types.PriceStatus.OK && p > 0) && uint256(agg.cachedMarkAt) + maxMarkAge < block.timestamp) {
                return true;
            }
            // (b) deviation breaker tripped: liquidations blocked, overstatement can accumulate.
            (bool allowed,) = ROUTER.openingAllowed(token);
            if (!allowed) return true;
        }
        return false;
    }

    /// @dev NAV mark for one market: live peek when OK, else the engine's cached mark. Note the
    ///      cached-mark age bound is enforced at the SETTLEMENT caller (settlementPaused), not here,
    ///      so deposit/NAV reads degrade to the cached mark (never revert) while settlement is the
    ///      only path that a stale mark can hard-block (B8).
    function _navMark(address token, uint128 cachedMark1e18) private view returns (uint256) {
        (uint256 p, Types.PriceStatus s) = ROUTER.peekPrice(token);
        if (s == Types.PriceStatus.OK && p > 0) return p;
        return cachedMark1e18;
    }

    // ================================ epochs ================================

    /// @notice Current 24h epoch index (epoch 0 starts at deployment).
    function currentEpoch() public view returns (uint64) {
        return uint64((block.timestamp - GENESIS) / EPOCH_DURATION);
    }

    /// @notice Timestamp at which `epoch` ends (its requests become settleable).
    function epochEndsAt(uint64 epoch) public view returns (uint256) {
        return uint256(GENESIS) + (uint256(epoch) + 1) * EPOCH_DURATION;
    }

    // ================================ LP surface: deposit ================================

    /// @inheritdoc IPitVault
    /// @dev 10 bps fee accrues to NAV (assets transfer in full, shares mint on net). Per-epoch
    ///      deposit cap: max(depositEpochCapBps of TVL, depositEpochCapFloor) per 24h. First
    ///      deposit carves DEAD_SHARES to the dead address. Shares are converted BEFORE the
    ///      transfer-in so the incoming assets do not dilute the quote.
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IPitVault)
        nonReentrant
        returns (uint256 shares)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (assets < MIN_DEPOSIT) revert DepositBelowMinimum();
        uint64 epoch = currentEpoch();
        uint256 cap = Math.max(Math.mulDiv(totalAssets(), depositEpochCapBps, BPS), depositEpochCapFloor);
        uint256 already = depositedInEpoch[epoch];
        if (already + assets > cap) revert DepositEpochCapExceeded();
        depositedInEpoch[epoch] = already + assets;

        uint256 fee = Math.mulDiv(assets, depositFeeBps, BPS);
        shares = _convertToShares(assets - fee, Math.Rounding.Floor);
        bool first = totalSupply() == 0;
        if (first && shares <= DEAD_SHARES) revert FirstDepositTooSmall();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        if (first) {
            _mint(DEAD_ADDRESS, DEAD_SHARES);
            shares -= DEAD_SHARES;
        }
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626
    /// @dev Net of the deposit fee. Ignores the one-time dead-share carve of the first deposit.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets - Math.mulDiv(assets, depositFeeBps, BPS), Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        uint256 cap = Math.max(Math.mulDiv(totalAssets(), depositEpochCapBps, BPS), depositEpochCapFloor);
        uint256 already = depositedInEpoch[currentEpoch()];
        return already >= cap ? 0 : cap - already;
    }

    // ================================ LP surface: disabled 4626 doors ================================

    /// @inheritdoc ERC4626
    /// @dev Disabled: deposit() is the only entry (fee-correct); mint() would bypass the fee path.
    function mint(uint256, address) public pure override returns (uint256) {
        revert MintDisabledUseDeposit();
    }

    /// @inheritdoc ERC4626
    /// @dev Disabled: exits go through requestWithdraw + claim (two-step queue, spec 4.4).
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert ExitDisabledUseQueue();
    }

    /// @inheritdoc ERC4626
    /// @dev Disabled: exits go through requestWithdraw + claim (two-step queue, spec 4.4).
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert ExitDisabledUseQueue();
    }

    /// @inheritdoc ERC4626
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc ERC4626
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    // ================================ LP surface: withdraw queue ================================

    /// @inheritdoc IPitVault
    /// @dev Locks `shares` (transferred to the vault) into the CURRENT epoch. They price at the
    ///      NAV of that epoch's settlement, which can only happen after the epoch ends: an LP can
    ///      never realize today's NAV on the way out, so a known incoming loss cannot be
    ///      front-run (spec 4.4). Repeat requests in the same epoch merge; any older, matured
    ///      part of the chain resolves first.
    function requestWithdraw(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (shares > type(uint128).max) revert ParamOutOfBounds();
        _resolve(msg.sender);
        WithdrawRequest storage r = requestOf[msg.sender];
        uint64 epoch = currentEpoch();
        if (r.shares != 0 && r.epoch != epoch) revert PendingRequestInOtherEpoch();
        _transfer(msg.sender, address(this), shares);
        r.shares += uint128(shares);
        r.epoch = epoch;
        epochs[epoch].sharesRequested += uint128(shares);
        emit WithdrawRequested(msg.sender, shares, epoch);
    }

    /// @inheritdoc IPitVault
    /// @dev Resolves the caller's chain (lazily settling matured epochs) and pays everything
    ///      crystallized. The per-epoch cap and the solvency floor were already applied at
    ///      settlement, where the liability was created against NAV; the payment itself is
    ///      NAV-neutral (balance and liability drop together).
    function claim() external nonReentrant returns (uint256 assets) {
        _resolve(msg.sender);
        assets = claimableOf[msg.sender];
        if (assets == 0) revert NothingToClaim();
        claimableOf[msg.sender] = 0;
        // Saturating: per-user floor rounding can leave dust liability behind forever, which only
        // understates NAV. The subtraction itself can therefore never underflow in aggregate.
        totalClaimLiability = totalClaimLiability >= assets ? totalClaimLiability - assets : 0;
        IERC20(asset()).safeTransfer(msg.sender, assets);
        emit WithdrawClaimed(msg.sender, assets);
    }

    /// @notice Permissionless epoch settlement (the "vault epoch processor" of spec 8.5; claims
    ///         are merely delayed, never lost, if nobody calls this: claim() settles lazily).
    /// @dev B8: reverts while any open-interest market is stale or deviation-breaker-paused, so a
    ///      standing-queued LP cannot crystallize the NAV overstatement of that window.
    function settleEpoch(uint64 epoch) external nonReentrant {
        if (currentEpoch() <= epoch) revert EpochNotMature();
        if (settlementPaused()) revert SettlementPaused();
        _settleEpoch(epoch);
    }

    /// @dev Settle one matured epoch: price its queued shares at the CURRENT NAV, fulfil up to
    ///      min(per-epoch cap, solvency headroom) pro-rata, burn the fulfilled shares, create the
    ///      matching net-of-fee liability, and roll the remainder into the settlement-time epoch.
    function _settleEpoch(uint64 epoch) private {
        EpochInfo storage ep = epochs[epoch];
        if (ep.settled) return;
        ep.settled = true;
        uint128 requested = ep.sharesRequested;
        if (requested == 0) {
            emit EpochSettled(epoch, 0, 0, 0);
            return;
        }
        uint256 ta = totalAssets();
        uint256 grossRequested = _convertToAssets(requested, Math.Rounding.Floor);
        uint256 cap = Math.mulDiv(ta, withdrawEpochCapBps, BPS);
        uint256 floorAssets = Math.mulDiv(totalReserved, solvencyFloorBps, BPS);
        uint256 headroom = ta > floorAssets ? ta - floorAssets : 0;
        uint256 allow = Math.min(grossRequested, Math.min(cap, headroom));

        uint128 fulfilled;
        if (allow == 0) {
            fulfilled = 0;
        } else if (allow >= grossRequested) {
            fulfilled = requested;
        } else {
            fulfilled = uint128(Math.mulDiv(requested, allow, grossRequested));
        }

        uint256 netOwed = 0;
        if (fulfilled > 0) {
            uint256 grossAssets = _convertToAssets(fulfilled, Math.Rounding.Floor);
            netOwed = grossAssets - Math.mulDiv(grossAssets, withdrawFeeBps, BPS);
            ep.sharesFulfilled = fulfilled;
            ep.assetsPerShareNet1e18 = Math.mulDiv(netOwed, PER_SHARE_SCALE, fulfilled);
            _burn(address(this), fulfilled);
            totalClaimLiability += netOwed;
        }

        uint128 rolled = requested - fulfilled;
        if (rolled > 0) {
            uint64 target = currentEpoch();
            ep.rolledToEpoch = target;
            epochs[target].sharesRequested += rolled;
        }
        emit EpochSettled(epoch, fulfilled, netOwed, rolled);
    }

    /// @dev Walk a user's request chain: for every settled epoch, crystallize the user's pro-rata
    ///      fulfilment into claimableOf and carry the remainder to the epoch it rolled into,
    ///      settling matured epochs lazily along the way. Terminates because every roll targets
    ///      the strictly later settlement-time epoch. All rounding is floor (vault-favoring).
    function _resolve(address user) private {
        WithdrawRequest storage r = requestOf[user];
        uint128 shares = r.shares;
        if (shares == 0) return;
        uint64 epoch = r.epoch;
        uint256 owed = 0;
        while (shares > 0) {
            if (!epochs[epoch].settled) {
                if (currentEpoch() > epoch) {
                    // B8: defer settlement of a matured epoch while the NAV is unsafe to crystallize
                    // (stale mark or tripped deviation breaker). Any already-crystallized owed slice
                    // accumulated so far still pays; only the NEW settlement waits for a fresh mark.
                    if (settlementPaused()) break;
                    _settleEpoch(epoch);
                } else {
                    break;
                }
            }
            EpochInfo storage ep = epochs[epoch];
            uint128 requested = ep.sharesRequested;
            uint128 userFulfilled =
                requested == 0 ? 0 : uint128(Math.mulDiv(shares, ep.sharesFulfilled, requested));
            if (userFulfilled > 0) {
                owed += Math.mulDiv(userFulfilled, ep.assetsPerShareNet1e18, PER_SHARE_SCALE);
                shares -= userFulfilled;
            }
            if (shares == 0) break;
            if (ep.sharesFulfilled == requested) {
                // Fully fulfilled epoch: any residue is pure rounding dust; it stays locked as
                // vault-held shares (vault-favoring) rather than chasing a nonexistent roll.
                shares = 0;
                break;
            }
            epoch = ep.rolledToEpoch;
        }
        r.shares = shares;
        r.epoch = epoch;
        if (owed > 0) {
            claimableOf[user] += owed;
            emit WithdrawResolved(user, owed);
        }
    }

    // ================================ engine-only counterparty surface ================================

    /// @inheritdoc IPitVault
    /// @dev Enforces, in order: the GLOBAL utilization cap (sum of reserves <= maxUtilizationBps
    ///      of TVL, spec 4.5), then the PER-MARKET cap = min(router cost-to-move payout cap,
    ///      marketReserveCapBps of TVL), further throttled to newMarketRampBps of TVL during the
    ///      market's first ramp window (spec 3.6 + 4.5). The ramp anchors on the market's first
    ///      reservation through this vault.
    function reservePayout(address token, uint256 amount) external onlyEngine nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (firstReserveAt[token] == 0) firstReserveAt[token] = uint64(block.timestamp);
        uint256 ta = totalAssets();
        uint256 newTotal = totalReserved + amount;
        if (newTotal > Math.mulDiv(ta, riskConfig.maxUtilizationBps(), BPS)) revert UtilizationCapExceeded();
        uint256 newMarket = reservedBy[token] + amount;
        if (newMarket > _marketReserveCap(token, ta)) revert MarketReserveCapExceeded();
        reservedBy[token] = newMarket;
        totalReserved = newTotal;
        emit PayoutReserved(token, amount, newMarket, newTotal);
    }

    /// @inheritdoc IPitVault
    function releasePayout(address token, uint256 amount) external onlyEngine nonReentrant {
        uint256 marketReserved = reservedBy[token];
        if (amount > marketReserved) revert ReleaseExceedsReserved();
        uint256 newMarket = marketReserved - amount;
        uint256 newTotal = totalReserved - amount;
        reservedBy[token] = newMarket;
        totalReserved = newTotal;
        emit PayoutReleased(token, amount, newMarket, newTotal);
    }

    /// @inheritdoc IPitVault
    /// @dev Pays a realized trader win out of vault cash. Bounded by totalReserved as defense in
    ///      depth: the engine caps each position's payout at its reserved maxPayout, and the sum
    ///      of reservations is the vault's maximum contractual outflow at any instant.
    function settleTraderWin(address to, uint256 amount) external onlyEngine nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > totalReserved) revert WinExceedsReserved();
        IERC20(asset()).safeTransfer(to, amount);
        emit TraderWinSettled(to, amount);
    }

    /// @inheritdoc IPitVault
    /// @dev Pays a realized FUNDING credit out of vault cash. Deliberately NOT bounded by
    ///      totalReserved (unlike settleTraderWin): a funding credit is money the opposing side
    ///      already paid the vault as a funding debit, so it is not a "reserved price payout" and
    ///      must not be clamped by a position's maxPayout nor throttled by the market-wide reserve
    ///      bound (B9). Conservation still holds: the vault only fronts what payers owe against
    ///      margin the engine still escrows, and NAV excludes pending funding receivables (spec 4.3).
    ///      RH1: the recipient is asserted to be the engine itself (the engine always settles the
    ///      credit onward from its own balance), so a future engine change can never turn this
    ///      unbounded channel into a direct user payout. Also covers the zero address.
    function settleFundingCredit(address to, uint256 amount) external onlyEngine nonReentrant {
        if (to != engine) revert CreditRecipientNotEngine();
        if (amount == 0) revert ZeroAmount();
        IERC20(asset()).safeTransfer(to, amount);
        emit FundingCreditSettled(to, amount);
    }

    /// @inheritdoc IPitVault
    /// @dev Pulls the realized loss from the engine (the engine approves the vault at wiring
    ///      time), so the spec 4.3 engine-receivable term is structurally zero.
    function settleTraderLoss(uint256 amount) external onlyEngine nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit TraderLossSettled(amount);
    }

    /// @inheritdoc IPitVault
    /// @dev Economics v2 (finding A1/A2): the engine's immutable vault fee share plus the whole
    ///      vol surcharge. PULLS the USDG from the engine (same standing approval as
    ///      settleTraderLoss). The credit is a bare balance increase: totalAssets rises, no
    ///      shares mint, so it accrues pro-rata to every PLP holder (share price up).
    function receiveFeeRevenue(uint256 amount) external onlyEngine nonReentrant {
        if (amount == 0) revert ZeroAmount();
        cumulativeFeeRevenue += amount;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit FeeRevenueReceived(amount, cumulativeFeeRevenue);
    }

    /// @inheritdoc IPitVault
    /// @dev Economics v2 (finding A1): the vault's 40% share of every liquidation penalty.
    ///      Identical mechanics to receiveFeeRevenue; separate counter for APR decomposition.
    function receiveLiquidationRevenue(uint256 amount) external onlyEngine nonReentrant {
        if (amount == 0) revert ZeroAmount();
        cumulativeLiquidationRevenue += amount;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidationRevenueReceived(amount, cumulativeLiquidationRevenue);
    }

    /// @notice Live per-market reserve cap in USDG units (UI/quoting helper).
    function marketReserveCapOf(address token) external view returns (uint256) {
        return _marketReserveCap(token, totalAssets());
    }

    /// @dev min(cost-to-move payout cap scaled to USDG, marketReserveCapBps of TVL), with the
    ///      new-market ramp throttle while inside the ramp window. The cap is the engine's FROZEN
    ///      snapshot (taken at listMarket), NOT the router's live value: a later liquidity shift
    ///      can never move a market's cap on open positions (v1 baked-cap parity, B1). The engine
    ///      answers type(uint256).max for majors, leaving the TVL-percentage leg alone (spec 3.6).
    ///      Economics v2 ramp: LINEAR per day. Day N (1-indexed from the first reservation)
    ///      allows N * newMarketRampBps of TVL, so at launch defaults capacity grows 1%/day and
    ///      only min()-tightens against the other legs (the anti-drain cost-to-move leg is
    ///      untouched).
    function _marketReserveCap(address token, uint256 ta) private view returns (uint256) {
        IPerpMarketList views = _engineViews;
        uint256 routerCap1e18 =
            address(views) == address(0) ? type(uint256).max : views.marketMaxPayoutCap1e18(token);
        uint256 routerCapUsdg =
            routerCap1e18 == type(uint256).max ? type(uint256).max : routerCap1e18 / USD1E18_TO_USDG;
        uint256 cap = Math.min(routerCapUsdg, Math.mulDiv(ta, riskConfig.marketReserveCapBps(), BPS));
        uint64 anchor = firstReserveAt[token];
        if (anchor != 0 && block.timestamp < uint256(anchor) + newMarketRampDuration) {
            uint256 daysIn = (block.timestamp - uint256(anchor)) / 1 days + 1;
            cap = Math.min(cap, Math.mulDiv(ta, uint256(newMarketRampBps) * daysIn, BPS));
        }
        return cap;
    }

    // ================================ governance parameter setters ================================

    /// @notice Set deposit and withdraw fees (bps, each capped at 1%).
    function setVaultFees(uint16 depositFeeBps_, uint16 withdrawFeeBps_) external onlyOwner {
        if (depositFeeBps_ > MAX_VAULT_FEE_BPS || withdrawFeeBps_ > MAX_VAULT_FEE_BPS) revert ParamOutOfBounds();
        depositFeeBps = depositFeeBps_;
        withdrawFeeBps = withdrawFeeBps_;
        emit VaultFeesSet(depositFeeBps_, withdrawFeeBps_);
    }

    /// @notice Set the per-epoch deposit cap (bps of TVL) and its absolute bootstrap floor.
    function setDepositEpochCap(uint16 capBps, uint256 capFloor) external onlyOwner {
        if (capBps == 0 || capBps > BPS || capFloor < MIN_DEPOSIT) revert ParamOutOfBounds();
        depositEpochCapBps = capBps;
        depositEpochCapFloor = capFloor;
        emit DepositEpochCapSet(capBps, capFloor);
    }

    /// @notice Set the per-epoch withdrawal cap in bps of TVL.
    function setWithdrawEpochCapBps(uint16 capBps) external onlyOwner {
        if (capBps == 0 || capBps > BPS) revert ParamOutOfBounds();
        withdrawEpochCapBps = capBps;
        emit WithdrawEpochCapBpsSet(capBps);
    }

    /// @notice Set the solvency floor (bps of totalReserved that NAV must retain post-fulfilment).
    function setSolvencyFloorBps(uint16 floorBps) external onlyOwner {
        if (floorBps < MIN_SOLVENCY_FLOOR_BPS || floorBps > MAX_SOLVENCY_FLOOR_BPS) revert ParamOutOfBounds();
        solvencyFloorBps = floorBps;
        emit SolvencyFloorBpsSet(floorBps);
    }

    /// @notice Set the new-market reserve ramp (bps of TVL PER DAY, linear, and window length).
    function setNewMarketRamp(uint16 rampBps, uint64 rampDuration) external onlyOwner {
        if (rampBps == 0 || rampBps > BPS || rampDuration > MAX_RAMP_DURATION) revert ParamOutOfBounds();
        newMarketRampBps = rampBps;
        newMarketRampDuration = rampDuration;
        emit NewMarketRampSet(rampBps, rampDuration);
    }

    /// @notice Set the cached-mark staleness bound for the navMarkStale signal.
    function setMaxMarkAge(uint64 maxMarkAge_) external onlyOwner {
        if (maxMarkAge_ == 0 || maxMarkAge_ > MAX_MAX_MARK_AGE) revert ParamOutOfBounds();
        maxMarkAge = maxMarkAge_;
        emit MaxMarkAgeSet(maxMarkAge_);
    }

    // ================================ misc overrides ================================

    /// @inheritdoc ERC4626
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }
}
