// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Types} from "../interfaces/Types.sol";
import {IPitPoints} from "../interfaces/IPitPoints.sol";
import {PauseGuardian} from "../core/PauseGuardian.sol";

import {PerpTypes} from "./interfaces/PerpTypes.sol";
import {IPerpEngine} from "./interfaces/IPerpEngine.sol";
import {IPerpMarketList} from "./interfaces/IPerpVaultDeps.sol";
import {IPitVault} from "./interfaces/IPitVault.sol";
import {IInsuranceFund} from "./interfaces/IInsuranceFund.sol";
import {IPerpRiskConfig} from "./interfaces/IPerpRiskConfig.sol";
import {IOracleRouterPerp} from "./IOracleRouterPerp.sol";
import {ISpotSource} from "../oracle/adapters/ISpotSource.sol";
import {MarginMathLib} from "./MarginMathLib.sol";
import {FundingLib} from "./FundingLib.sol";

/// @title PerpEngine: the singleton leveraged perps clearinghouse for THE PIT v2
/// @notice Holds all isolated trader margin, executes every open/close/liquidation against
///         the PitVault at the OracleRouter mark (GMX-v2 style oracle execution, no orderbook,
///         no spread), and enforces the reincarnated capped-payout invariant: every position's
///         payout is capped at payoutCapMultiple * margin and the SUM of caps per market is
///         bounded by min(cost-to-move / safetyFactor, a TVL percentage), so manipulating a
///         market's price can never extract more from the vault than the move costs.
/// @dev Owner is intended to be the reused 2-day TimelockController (Ownable2Step handover).
///      Every fund-touching external is nonReentrant with strict CEI: per-market aggregates
///      are mutated ONLY inside the four internal mutators (_aggOpenFamily, _aggCloseFamily,
///      _aggLiquidateFamily, _aggAccrue), each entered only from nonReentrant externals, and
///      no external call ever sits between an aggregate read and its paired write (the GMX v1
///      $42M desync lesson; USDG has no transfer hooks). The points hook is best-effort
///      try/catch and can never block a trade.
contract PerpEngine is IPerpEngine, IPerpMarketList, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // ======================================================================
    // Constants
    // ======================================================================

    /// @notice Basis point denominator.
    uint256 public constant BPS_DENOM = 10_000;
    /// @notice Leverage fixed-point denominator: leverageX100 of 450 is 4.5x.
    uint256 public constant LEVERAGE_DENOM = 100;
    /// @notice Minimum leverage (1.1x dust floor, spec 1.3).
    uint32 public constant MIN_LEVERAGE_X100 = 110;
    /// @notice Price scale, identical to the router.
    uint256 public constant PRICE_SCALE = 1e18;
    /// @notice Jackpot share of every protocol fee, bps (reused v1 share, spec 7).
    uint256 public constant FEE_SHARE_JACKPOT_BPS = 2_500;
    /// @notice Referral pool share of every protocol fee, bps.
    uint256 public constant FEE_SHARE_REFERRAL_BPS = 1_000;
    /// @notice LP vault share of every protocol fee, bps (economics v2, finding A1): 20% of
    ///         every trade fee is real LP revenue, credited to PitVault NAV via
    ///         receiveFeeRevenue (no shares minted). IMMUTABLE like the rest of the split: a
    ///         settable split would reopen the trusted-owner fee-redirection finding.
    uint256 public constant FEE_SHARE_VAULT_BPS = 2_000;
    /// @notice Buyback share of every protocol fee, bps (trimmed 39% -> 25% to fund the vault
    ///         share). Treasury takes the rest plus dust.
    uint256 public constant FEE_SHARE_BUYBACK_BPS = 2_500;
    /// @notice Hard cap on position KEYS examined during ADL candidate collection (RB6): the
    ///         open-position count is permissionless-growable under the reserve caps (~11k dust
    ///         positions at $10M TVL), so collection work and memory must be O(constant), never
    ///         O(n), or a packed book OOGs the liquidation that ADL exists to backstop. At ~8k
    ///         gas per examined key the full scan costs ~2M gas; realistic books sit far below
    ///         256 open positions per market, so genuine victims are inside the window.
    uint256 public constant MAX_ADL_SCAN = 256;
    /// @notice Maximum victims force-closed per ADL pass (each close is an expensive settlement).
    uint256 public constant MAX_ADL_VICTIMS = 32;

    // ======================================================================
    // Immutables
    // ======================================================================

    /// @notice USDG collateral token (native 6 decimals).
    IERC20 public immutable usdg;
    /// @notice 10 ** (18 minus USDG decimals), mirroring OracleRouter.usdgScale.
    uint256 public immutable usdgScale;
    /// @notice The mark price, breaker, opening gate and cost-to-move source (reused, audited).
    IOracleRouterPerp public immutable router;
    /// @notice The LP counterparty vault.
    IPitVault public immutable vault;
    /// @notice Pre-ADL bad-debt backstop.
    IInsuranceFund public immutable insuranceFund;
    /// @notice Tier risk parameters (timelocked governance).
    IPerpRiskConfig public immutable riskConfig;
    /// @notice Points engine; every call is wrapped in try/catch (best effort, never blocking).
    IPitPoints public immutable points;
    /// @notice Bounded emergency pause switch (blocks opens and liquidations only).
    PauseGuardian public immutable guardian;
    /// @notice Jackpot fee recipient (25% of every fee).
    address public immutable feeJackpot;
    /// @notice Treasury fee recipient (20% of every fee plus round-down dust).
    address public immutable feeTreasury;
    /// @notice Referral pool fee recipient (10% of every fee).
    address public immutable feeReferralPool;
    /// @notice Buyback fee recipient (25% of every fee).
    address public immutable feeBuyback;

    // ======================================================================
    // Storage
    // ======================================================================

    /// @dev Positions keyed by keccak256(abi.encode(token, trader, isLong)).
    mapping(bytes32 => PerpTypes.Position) private _positions;
    /// @dev Per-market aggregates: mutated ONLY by the four internal mutators.
    mapping(address => PerpTypes.MarketAggregates) private _agg;
    /// @dev Open position keys per market (ADL iteration and the aggregates invariant harness).
    mapping(address => EnumerableSet.Bytes32Set) private _marketPositionKeys;

    /// @notice True once a token is listed as a perp market.
    mapping(address => bool) public isListed;
    /// @notice Listing timestamp (drives the new-market reserve ramp, spec 4.5).
    mapping(address => uint64) public listedAt;
    /// @inheritdoc IPerpMarketList
    /// @dev The router's cost-to-move payout cap FROZEN at listMarket (B1). Every reserve-cap
    ///      read (engine and vault) uses this snapshot, never the router's live value, so a later
    ///      liquidity shift cannot move a market's cap on open positions (v1 baked-cap parity).
    mapping(address => uint256) public marketMaxPayoutCap1e18;
    /// @dev All listed market tokens, append-only.
    address[] private _markets;

    /// @notice Reserved payout attributed per (token, trader): the per-address share cap base.
    mapping(address => mapping(address => uint256)) public addressReserved;

    /// @notice Long-reference EWMA of the settlement mark per market, 1e18 scale: the slow leg
    ///         of the realized-vol proxy (RE-ECON-1). Seeded at the market's first LIVE accrual
    ///         and advanced toward the mark by min(dt, tau) / tau on every LIVE accrual, so it
    ///         is time-integrated by construction: a one-block print moves it by at most one
    ///         block's weight over the tau window, unlike the instantaneous spot-vs-TWAP
    ///         deviation the open surcharge reads (which a single-block spot push could zero).
    mapping(address => uint128) public volRefPrice1e18;

    /// @notice Pull-payment credit for fee recipients whose push transfer failed.
    mapping(address => uint256) public creditOf;
    /// @notice Total outstanding pull-payment credit.
    uint256 public totalCredit;

    /// @notice Minimum gross margin per open, USDG units (launch 10 USDG).
    uint128 public minMargin = 10e6;
    /// @notice Keeper share of the liquidation penalty, bps (launch 20%).
    uint16 public keeperShareBps = 2_000;
    /// @notice LP vault share of the liquidation penalty, bps (launch 40%, economics v2 finding
    ///         A1). The InsuranceFund takes the remainder (launch 40% plus round-down dust).
    ///         keeperShareBps + liqVaultShareBps can never exceed 100%.
    uint16 public liqVaultShareBps = 4_000;
    /// @notice Keeper reward floor, USDG units; shortfall vs the floor is topped up by the
    ///         InsuranceFund, bounded per liquidation (launch 5 USDG).
    uint128 public keeperFloorUsdg = 5e6;
    /// @notice Per-address share of a market's reserve cap, bps (launch 25%, spec 3.5).
    uint16 public perAddressReserveShareBps = 2_500;
    /// @notice New-market reserve throttle: bps of TVL PER DAY (linear ramp, economics v2
    ///         finding A2: launch 1%/day, so day N allows N * rampCapBps of TVL) inside
    ///         rampDuration.
    uint16 public rampCapBps = 100;
    /// @notice New-market throttle duration (launch 14 days, economics v2: was 7).
    uint64 public rampDuration = 14 days;
    /// @notice Skew denominator floor, USDG units (launch 10k USDG, spec 5.2). Single global
    ///         knob: a per-tier floor needs a TierParams field (flagged to the integrator).
    uint128 public skewFloorUsdg = 10_000e6;
    /// @notice Vault NAV drawdown that trips the close-only circuit, bps of window-start NAV.
    uint16 public drawdownCircuitBps = 1_000;
    /// @notice Drawdown observation window (launch 24h).
    uint64 public drawdownWindow = 24 hours;

    /// @notice True while the vault-drawdown circuit is tripped: ALL opens blocked until
    ///         governance resets (spec 6.3; first pass applies to every market, not only
    ///         pool-priced ones, documented simplification).
    bool public drawdownTripped;
    /// @dev Rolling drawdown window anchor.
    uint64 private _navWindowStart;
    /// @dev Vault totalAssets at the window anchor (0 = unseeded).
    uint256 private _navWindowStartAssets;

    // ======================================================================
    // Types
    // ======================================================================

    /// @dev Print classification per spec 2.3.
    enum PrintClass {
        BLOCKED,
        FALLBACK,
        LIVE
    }

    /// @dev Net engine<>vault cash flows accumulated through an operation, flushed once.
    ///      fromVault is the RESERVED price-payout channel (bounded per position by maxPayout);
    ///      fundingCredit is the SEPARATE funding-credit channel (unbounded by maxPayout, B9).
    struct VaultFlows {
        uint256 toVault;
        uint256 fromVault;
        uint256 fundingCredit;
    }

    /// @dev Pre-fetched external context for an open-family operation (all external reads
    ///      happen before any aggregate write, preserving the CEI discipline).
    ///      volSurchargeBps is the economics v2 vol-scaled open-fee surcharge (credited 100% to
    ///      the vault); capUsdg already carries the vol-scaled cap discount on the open path.
    struct OpCtx {
        PerpTypes.TierParams params;
        uint256 pcm;
        uint256 tvl;
        uint256 capUsdg;
        uint256 mark;
        uint256 volSurchargeBps;
    }

    /// @dev Liquidation waterfall outputs (spec 3.2), bundled to relieve stack pressure.
    ///      Economics v2 penalty split: keeper 20% / vault 40% / InsuranceFund 40% plus dust;
    ///      keeperCut + vaultCut + fundCut + residual == pot, wei-exact.
    struct LiqCalc {
        uint256 payToVault;
        uint256 winFromVault;
        uint256 fundingCredit;
        uint256 shortfall;
        uint256 penalty;
        uint256 keeperCut;
        uint256 vaultCut;
        uint256 fundCut;
        uint256 residual;
    }

    /// @dev Open-fee decomposition, bundled to relieve stack pressure. total is the whole fee
    ///      withheld from the gross margin (base + vol surcharge); vol is the surcharge slice
    ///      routed 100% to the vault while (total - vol) splits five ways.
    struct OpenFees {
        uint256 total;
        uint256 vol;
    }

    /// @dev Increase-slice outputs, bundled to relieve stack pressure. openFee is the TOTAL fee
    ///      withheld (base + vol surcharge); volFee is the surcharge slice routed whole to the
    ///      vault while (openFee - volFee) splits five ways.
    struct IncCalc {
        uint256 openFee;
        uint256 volFee;
        uint256 addedNet;
        uint256 addedNotional;
        uint256 addedSize;
        uint256 payoutAdd;
    }

    /// @dev Full-close settlement outputs, bundled to relieve stack pressure.
    struct CloseCalc {
        int256 pnl;
        uint256 payToVault;
        uint256 winFromVault;
        uint256 fundingCredit;
        uint256 shortfall;
        uint256 closedNotional;
        uint256 closeFee;
        uint256 traderNet;
    }

    /// @dev Partial-close outputs (spec 1.5), bundled to relieve stack pressure.
    struct ReduceCalc {
        uint256 closedSize;
        uint256 remainSize;
        int256 realized;
        uint256 lossToVault;
        uint256 winFromVault;
        uint256 newMargin;
        uint256 newMaxPayout;
        uint256 releaseAmt;
        uint256 closedNotional;
        uint256 closeFee;
        uint256 traderNet;
    }

    // ======================================================================
    // Errors
    // ======================================================================

    /// @notice A zero address was supplied where a real address is required.
    error ZeroAddress();
    /// @notice The token is not a listed perp market.
    error NotListed();
    /// @notice The token is already listed.
    error AlreadyListed();
    /// @notice The router refuses the token (isListable false).
    error RouterNotListable();
    /// @notice A pool-priced (B_DEEP / C_MID) token was listed with its spot-vs-TWAP opening
    ///         breaker disarmed (router tierConfig.spotSource == 0): the only execution-time
    ///         manipulation gate for pool-priced markets would be silently nullified (B5).
    error OpeningBreakerDisarmed();
    /// @notice The market (or the whole engine) is in close-only mode for this action.
    error MarketCloseOnly();
    /// @notice The engine or this market is paused by the guardian.
    error EnginePaused();
    /// @notice The vault-drawdown circuit is tripped: opens are blocked until governance reset.
    error DrawdownCircuitActive();
    /// @notice tripDrawdownCircuit called while the drawdown condition does not hold.
    error DrawdownNotBreached();
    /// @notice tripCostToMoveCloseOnly called while the live cost-to-move cap still covers the
    ///         market's outstanding reservations (no real depth collapse to close-only for).
    error CostToMoveNotBreached();
    /// @notice The action requires a LIVE print and the current print is not LIVE.
    error PrintNotLive();
    /// @notice The action requires at least a FALLBACK print and the print is blocked.
    error PrintBlocked();
    /// @notice The router's opening breaker denies this action.
    /// @param reason Router diagnostic code (1 = deviation, 2 = reference unavailable).
    error OpeningDenied(uint8 reason);
    /// @notice Leverage outside [1.1x, tier max].
    error LeverageOutOfRange();
    /// @notice Margin below the minimum or too small to survive the open fee.
    error MarginTooSmall();
    /// @notice The position would exceed the tier's per-position margin cap.
    error PositionMarginCapExceeded();
    /// @notice The market's summed maxPayout would exceed its reserve cap (spec 3.6).
    error MarketReserveCapExceeded();
    /// @notice The trader's share of the market reserve cap would be exceeded (spec 3.5).
    error AddressReserveCapExceeded();
    /// @notice A position already exists on this (token, side); use increasePosition.
    error PositionExists();
    /// @notice No position exists on this (token, trader, side).
    error PositionMissing();
    /// @notice Equity is at or above maintenance margin; nothing to liquidate.
    error NotLiquidatable();
    /// @notice removeMargin would take equity below the initial-margin floor (anti-JELLY).
    error BelowInitialMarginFloor();
    /// @notice Accrued funding and borrow exceed the margin; the position must be liquidated.
    error MarginExhausted();
    /// @notice reducePosition fraction must be in (0, 10000) exclusive.
    error InvalidFraction();
    /// @notice A zero or otherwise invalid amount was supplied.
    error InvalidAmount();
    /// @notice A governance parameter is outside its allowed range.
    error InvalidParam();
    /// @notice No usable mark exists for this view (no fresh print, no cached mark).
    error NoMark();
    /// @notice pushFee may only be called by the engine itself.
    error OnlySelf();
    /// @notice resetDrawdownCircuit caller is neither the timelock owner nor the guardian (B2).
    error NotOwnerOrGuardian();
    /// @notice withdrawCredit called with no credit outstanding.
    error NothingToWithdraw();

    // ======================================================================
    // Events
    // ======================================================================

    /// @notice A new perp market was listed.
    event MarketListed(address indexed token, uint64 at);
    /// @notice Close-only (orderly delisting) toggled for a market.
    event CloseOnlySet(address indexed token, bool on);
    /// @notice A position was opened.
    event PositionOpened(
        bytes32 indexed key,
        address indexed token,
        address indexed trader,
        bool isLong,
        uint256 marginNet,
        uint256 size1e18,
        uint256 entryPrice1e18,
        uint256 maxPayout,
        uint256 openFee
    );
    /// @notice An existing position was increased.
    event PositionIncreased(
        bytes32 indexed key, uint256 addedMarginNet, uint256 addedSize1e18, uint256 newEntryPrice1e18, uint256 openFee
    );
    /// @notice A position was fully closed by its owner.
    event PositionClosed(
        bytes32 indexed key,
        address indexed token,
        address indexed trader,
        bool isLong,
        uint256 mark1e18,
        int256 pnl,
        uint256 traderPayout,
        uint256 closeFee
    );
    /// @notice A position was partially reduced.
    event PositionReduced(
        bytes32 indexed key, uint32 fractionBps, uint256 mark1e18, int256 realizedPnl, uint256 traderPayout, uint256 closeFee
    );
    /// @notice Margin was added to a position.
    event MarginAdded(bytes32 indexed key, uint256 amount, uint256 newMargin, uint256 newMaxPayout);
    /// @notice Margin was removed from a position (initial-margin floor enforced).
    event MarginRemoved(bytes32 indexed key, uint256 amount, uint256 newMargin, uint256 newMaxPayout);
    /// @notice A position was liquidated.
    event Liquidated(
        bytes32 indexed key,
        address indexed token,
        address indexed trader,
        bool isLong,
        address keeper,
        uint256 mark1e18,
        uint256 penalty,
        uint256 keeperReward,
        uint256 traderResidual
    );
    /// @notice A liquidation (or close) gapped through the margin.
    event BadDebt(
        address indexed token, address indexed trader, uint256 shortfall, uint256 coveredByFund, uint256 adlAbsorbed
    );
    /// @notice An opposite-side winner was force-closed at a haircut to absorb bad debt.
    event AdlExecuted(address indexed token, address indexed trader, bool isLong, uint256 haircut, uint256 mark1e18);
    /// @notice Bad debt left after the bounded ADL pass: absorbed by the vault (LP-socialized),
    ///         bounded by the per-market reserve cap (RB6, spec 6.3).
    event AdlResidualSocialized(address indexed token, uint256 remaining);
    /// @notice Funding and borrow indices accrued for a market.
    event FundingAccrued(address indexed token, int256 fundingIndexDelta, uint256 borrowIndexDelta, uint256 mark1e18);
    /// @notice A market was permissionlessly flipped to close-only because its LIVE cost-to-move
    ///         cap fell below its outstanding reservations (the frozen listing cap went stale-HIGH).
    event CostToMoveCloseOnly(address indexed token, uint256 frozenCap1e18, uint256 liveCap1e18, uint256 reservedUsdg);
    /// @notice The vault-drawdown close-only circuit tripped.
    event DrawdownCircuitTripped(uint256 tvlNow, uint256 windowStartTvl);
    /// @notice Governance reset the drawdown circuit.
    event DrawdownCircuitReset();
    /// @notice A fee share could not be pushed and was credited for pull-withdrawal.
    event FeeCredited(address indexed recipient, uint256 amount);
    /// @notice A vol-scaled open-fee surcharge was charged and credited whole to the vault
    ///         (economics v2, finding A2): the premium for the gamma the LP vault just sold.
    event VolSurchargeCharged(address indexed token, address indexed trader, uint256 surchargeBps, uint256 amount);
    /// @notice The best-effort points hook reverted; the trade proceeded regardless.
    event PointsHookFailed(bytes reason);
    /// @notice A governance parameter changed.
    event EngineParamSet(bytes32 indexed name, uint256 value);

    // ======================================================================
    // Constructor
    // ======================================================================

    /// @param initialOwner The timelock (Ownable2Step handover per Deploy.s.sol pattern).
    /// @param usdg_ USDG collateral token.
    /// @param router_ The deployed OracleRouter (consumed through IOracleRouterPerp).
    /// @param vault_ The PitVault counterparty.
    /// @param insuranceFund_ The InsuranceFund backstop.
    /// @param riskConfig_ The PerpRiskConfig tier table.
    /// @param points_ The PitPoints engine (best-effort hooks).
    /// @param guardian_ The PauseGuardian.
    /// @param feeSplit_ The four protocol fee recipients (reused v1 split).
    constructor(
        address initialOwner,
        address usdg_,
        address router_,
        address vault_,
        address insuranceFund_,
        address riskConfig_,
        address points_,
        address guardian_,
        Types.FeeSplit memory feeSplit_
    ) Ownable(initialOwner) {
        if (
            usdg_ == address(0) || router_ == address(0) || vault_ == address(0) || insuranceFund_ == address(0)
                || riskConfig_ == address(0) || points_ == address(0) || guardian_ == address(0)
                || feeSplit_.jackpot == address(0) || feeSplit_.treasury == address(0)
                || feeSplit_.referralPool == address(0) || feeSplit_.buyback == address(0)
        ) revert ZeroAddress();
        // Economics v2 (finding A1): the fifth fee recipient MUST be the counterparty vault
        // itself, asserted at deploy so the immutable LP share can never be misrouted.
        if (feeSplit_.vault != vault_) revert InvalidParam();
        usdg = IERC20(usdg_);
        uint8 dec = IERC20Metadata(usdg_).decimals();
        if (dec > 18) revert InvalidParam();
        usdgScale = 10 ** (18 - dec);
        router = IOracleRouterPerp(router_);
        vault = IPitVault(vault_);
        insuranceFund = IInsuranceFund(insuranceFund_);
        riskConfig = IPerpRiskConfig(riskConfig_);
        points = IPitPoints(points_);
        guardian = PauseGuardian(guardian_);
        feeJackpot = feeSplit_.jackpot;
        feeTreasury = feeSplit_.treasury;
        feeReferralPool = feeSplit_.referralPool;
        feeBuyback = feeSplit_.buyback;
        // The vault PULLS realized trader losses via settleTraderLoss (transferFrom), so the
        // engine max-approves its immutable vault once here (integration seam, IPerpVaultDeps).
        IERC20(usdg_).forceApprove(vault_, type(uint256).max);
    }

    // ======================================================================
    // Trading: open / increase
    // ======================================================================

    /// @inheritdoc IPerpEngine
    function openPosition(address token, bool isLong, uint128 margin, uint32 leverageX100)
        external
        nonReentrant
        returns (bytes32 key)
    {
        if (margin < minMargin) revert MarginTooSmall();
        OpCtx memory ctx = _prepareOpenFamily(token, leverageX100);
        key = _openCore(token, isLong, margin, leverageX100, ctx);
    }

    /// @dev openPosition body after the shared preamble (separate frame for stack relief).
    ///      Atomic compute + write block first; no external call until all state is written.
    function _openCore(address token, bool isLong, uint128 margin, uint32 leverageX100, OpCtx memory ctx)
        private
        returns (bytes32 key)
    {
        key = _positionKey(token, msg.sender, isLong);
        if (_positions[key].size1e18 != 0) revert PositionExists();

        usdg.safeTransferFrom(msg.sender, address(this), margin);

        OpenFees memory fees = _computeOpenFees(uint256(margin) * leverageX100 / LEVERAGE_DENOM, ctx);
        if (fees.total >= margin) revert MarginTooSmall();
        uint256 marginNet = margin - fees.total;
        if (marginNet > ctx.params.maxPositionMargin) revert PositionMarginCapExceeded();
        uint256 size = MarginMathLib.sizeForNotional(marginNet * leverageX100 / LEVERAGE_DENOM, ctx.mark, usdgScale);
        if (size == 0) revert MarginTooSmall();
        uint256 maxPayout = ctx.pcm * marginNet;

        PerpTypes.MarketAggregates storage agg = _agg[token];
        _checkReserveCaps(token, msg.sender, agg.totalMaxPayout, maxPayout, ctx.capUsdg);

        PerpTypes.Position memory pos = PerpTypes.Position({
            trader: msg.sender,
            token: token,
            isLong: isLong,
            size1e18: size.toUint128(),
            margin: marginNet.toUint128(),
            entryPrice1e18: ctx.mark.toUint128(),
            entryFundingX1e18: agg.fundingX1e18,
            entryBorrowX1e18: agg.borrowX1e18,
            maxPayout: maxPayout.toUint128(),
            openedAt: uint64(block.timestamp),
            lastIncreasedAt: uint64(block.timestamp),
            // B7: snapshot the tier's maintenance-margin ratio at open. Liquidation reads THIS,
            // never the live tier, so a later permissionless refreshTier downgrade cannot
            // retroactively raise maintenance on an open position (spec 8.4 grandfathering).
            entryMmrBps: uint32(ctx.params.mmrBps)
        });
        _positions[key] = pos;
        _marketPositionKeys[token].add(key);
        addressReserved[token][msg.sender] += maxPayout;
        PerpTypes.Position memory emptyPos;
        _aggOpenFamily(token, emptyPos, pos);

        // Interactions (the real vault reverts on zero-amount reservations).
        if (maxPayout > 0) vault.reservePayout(token, maxPayout);
        _distributeFee(fees.total - fees.vol, fees.vol);
        if (fees.vol > 0) emit VolSurchargeCharged(token, msg.sender, ctx.volSurchargeBps, fees.vol);
        _pointsOnFill(token, marginNet * leverageX100 / LEVERAGE_DENOM);

        emit PositionOpened(key, token, msg.sender, isLong, marginNet, size, ctx.mark, maxPayout, fees.total);
    }

    /// @dev Shared open/increase preamble: gates, external reads, LIVE print requirement,
    ///      opening breaker, drawdown circuit, and index accrual. Economics v2 (finding A2):
    ///      after the print classifies LIVE, the oracle's spot-vs-TWAP deviation (the very
    ///      reading the opening breaker uses, so bounded by the breaker threshold here) prices
    ///      the vol surcharge and TIGHTENS the reserve cap; both are pure external READS placed
    ///      before the _accrue aggregate write, preserving the CEI discipline. The cap discount
    ///      applies to this OPEN path only: closes, liquidations and addMargin never read it.
    function _prepareOpenFamily(address token, uint32 leverageX100) private returns (OpCtx memory ctx) {
        _requireOpenGates(token);
        ctx.params = riskConfig.paramsFor(token);
        if (leverageX100 < MIN_LEVERAGE_X100 || leverageX100 > ctx.params.maxLeverageX100) {
            revert LeverageOutOfRange();
        }
        ctx.pcm = riskConfig.payoutCapMultiple();
        ctx.tvl = vault.totalAssets();
        ctx.capUsdg = _marketReserveCapUsdg(token, ctx.tvl);
        // B2: the drawdown circuit anchors on the reference NAV (totalAssets + crystallized
        // withdraw liability), so a routine LP exit does not read as a trading drawdown.
        _drawdownGate(vault.drawdownReferenceAssets());
        (uint256 mark, PrintClass cls) = _freshPrint(token);
        if (cls != PrintClass.LIVE) revert PrintNotLive();
        _requireOpeningAllowed(token);
        {
            PerpTypes.VolParams memory vp = riskConfig.volParams();
            uint256 devBps = _recentDeviationBps(token, mark);
            ctx.volSurchargeBps = _volSurchargeBps(token, devBps, vp);
            ctx.capUsdg = _applyVolCapDiscount(ctx.capUsdg, devBps, vp);
        }
        _accrue(token, mark, true, ctx.params, ctx.tvl);
        ctx.mark = mark;
    }

    /// @dev Open-fee decomposition (economics v2): base fee at the tier's openFeeBps plus the
    ///      vol surcharge at ctx.volSurchargeBps, both on the intended notional.
    function _computeOpenFees(uint256 intendedNotional, OpCtx memory ctx)
        private
        pure
        returns (OpenFees memory fees)
    {
        fees.vol = Math.mulDiv(intendedNotional, ctx.volSurchargeBps, BPS_DENOM);
        fees.total = Math.mulDiv(intendedNotional, ctx.params.openFeeBps, BPS_DENOM) + fees.vol;
    }

    /// @dev The realized-vol proxy (economics v2): the spot-vs-TWAP spread in bps, derived from
    ///      the router's own tier config (spotSource) against the LIVE settlement mark, using
    ///      the breaker's exact relative-to-low formula. Best effort by design: a disarmed
    ///      breaker (spotSource zero, majors), an unreadable spot, or a zero price all read as
    ///      zero deviation so this proxy can never brick an open. No router LOGIC is touched.
    function _recentDeviationBps(address token, uint256 twap) private view returns (uint256) {
        if (twap == 0) return 0;
        (,,,,,, address spotSource,) = router.tierConfigOf(token);
        if (spotSource == address(0)) return 0;
        try ISpotSource(spotSource).readSpot(token) returns (uint256 spot, bool ok) {
            if (!ok || spot == 0) return 0;
            uint256 lo = spot < twap ? spot : twap;
            uint256 hi = spot < twap ? twap : spot;
            return (hi - lo) * BPS_DENOM / lo;
        } catch {
            return 0;
        }
    }

    /// @dev volSurchargeBps = min(maxVolSurchargeBps, kVol * deviation + freshMarketSurcharge).
    function _volSurchargeBps(address token, uint256 devBps, PerpTypes.VolParams memory vp)
        private
        view
        returns (uint256)
    {
        uint256 s = uint256(vp.kVolX100) * devBps / 100 + _freshSurchargeBps(token, vp.freshSurchargeStartBps);
        return s > vp.maxVolSurchargeBps ? vp.maxVolSurchargeBps : s;
    }

    /// @dev Fresh-market surcharge: starts at freshSurchargeStartBps at listing and decays
    ///      linearly to zero over the new-market ramp window (brand-new markets carry the
    ///      highest info asymmetry, so they pay the LP vault the most).
    function _freshSurchargeBps(address token, uint16 startBps) private view returns (uint256) {
        uint256 window = rampDuration;
        if (startBps == 0 || window == 0) return 0;
        uint256 age = block.timestamp - uint256(listedAt[token]);
        if (age >= window) return 0;
        return uint256(startBps) * (window - age) / window;
    }

    /// @dev effectiveCap = cap * (1 - volDiscount), volDiscount = min(maxVolDiscountBps,
    ///      kCapVol * deviation). Only ever SHRINKS the cap (a pure tightening of the reserve
    ///      armor); the hard cap on maxVolDiscountBps (< 100%) means it never closes a market.
    function _applyVolCapDiscount(uint256 cap, uint256 devBps, PerpTypes.VolParams memory vp)
        private
        pure
        returns (uint256)
    {
        uint256 d = uint256(vp.kCapVolX100) * devBps / 100;
        if (d > vp.maxVolDiscountBps) d = vp.maxVolDiscountBps;
        if (d == 0) return cap;
        return cap - Math.mulDiv(cap, d, BPS_DENOM);
    }

    /// @inheritdoc IPerpEngine
    function increasePosition(address token, bool isLong, uint128 addedMargin, uint32 leverageX100)
        external
        nonReentrant
    {
        if (addedMargin == 0) revert InvalidAmount();
        OpCtx memory ctx = _prepareOpenFamily(token, leverageX100);
        _increaseCore(token, isLong, addedMargin, leverageX100, ctx);
    }

    /// @dev increasePosition body after the shared preamble (separate frame for stack relief).
    function _increaseCore(address token, bool isLong, uint128 addedMargin, uint32 leverageX100, OpCtx memory ctx)
        private
    {
        bytes32 key = _positionKey(token, msg.sender, isLong);
        PerpTypes.Position memory before = _positions[key];
        if (before.size1e18 == 0) revert PositionMissing();

        usdg.safeTransferFrom(msg.sender, address(this), addedMargin);

        PerpTypes.MarketAggregates storage agg = _agg[token];
        VaultFlows memory flows;
        // Second storage read: a memory-to-memory assignment would ALIAS `before`, zeroing
        // the before/after aggregate delta (the exact GMX-class desync this design guards).
        PerpTypes.Position memory pos = _positions[key];
        {
            uint256 settledMargin;
            (settledMargin, flows.toVault, flows.fundingCredit) =
                _settlePending(pos, agg.fundingX1e18, agg.borrowX1e18, pos.margin);
            pos.margin = settledMargin.toUint128();
        }

        IncCalc memory calc = _computeIncrease(addedMargin, leverageX100, ctx);
        if (uint256(pos.margin) + calc.addedNet > ctx.params.maxPositionMargin) revert PositionMarginCapExceeded();
        _checkReserveCaps(token, msg.sender, agg.totalMaxPayout, calc.payoutAdd, ctx.capUsdg);

        pos.entryPrice1e18 =
            MarginMathLib.weightedEntry1e18(pos.size1e18, pos.entryPrice1e18, calc.addedSize, ctx.mark).toUint128();
        pos.size1e18 = (uint256(pos.size1e18) + calc.addedSize).toUint128();
        pos.margin = (uint256(pos.margin) + calc.addedNet).toUint128();
        pos.entryFundingX1e18 = agg.fundingX1e18;
        pos.entryBorrowX1e18 = agg.borrowX1e18;
        pos.maxPayout = (uint256(pos.maxPayout) + calc.payoutAdd).toUint128();
        pos.lastIncreasedAt = uint64(block.timestamp);
        // B7: on increase keep the STRICTER (higher) of the snapshot and the current tier mmr,
        // so freshly added exposure is never under-margined by a stale (looser) grandfathered
        // ratio, while an existing healthy position is still never retroactively tightened.
        if (uint32(ctx.params.mmrBps) > pos.entryMmrBps) pos.entryMmrBps = uint32(ctx.params.mmrBps);
        _positions[key] = pos;
        addressReserved[token][msg.sender] += calc.payoutAdd;
        _aggOpenFamily(token, before, pos);

        if (calc.payoutAdd > 0) vault.reservePayout(token, calc.payoutAdd);
        _flushVaultFlows(flows);
        _distributeFee(calc.openFee - calc.volFee, calc.volFee);
        if (calc.volFee > 0) emit VolSurchargeCharged(token, msg.sender, ctx.volSurchargeBps, calc.volFee);
        _pointsOnFill(token, calc.addedNotional);

        emit PositionIncreased(key, calc.addedNet, calc.addedSize, pos.entryPrice1e18, calc.openFee);
    }

    /// @dev Increase-slice math: fee on the added intended notional (base plus the vol
    ///      surcharge, economics v2), net margin, added size at the current mark, and the
    ///      reserve addition (spec 1.3 applied to the increment).
    function _computeIncrease(uint128 addedMargin, uint32 leverageX100, OpCtx memory ctx)
        private
        view
        returns (IncCalc memory calc)
    {
        uint256 intendedNotional = uint256(addedMargin) * leverageX100 / LEVERAGE_DENOM;
        calc.volFee = Math.mulDiv(intendedNotional, ctx.volSurchargeBps, BPS_DENOM);
        calc.openFee = Math.mulDiv(intendedNotional, ctx.params.openFeeBps, BPS_DENOM) + calc.volFee;
        if (calc.openFee >= addedMargin) revert MarginTooSmall();
        calc.addedNet = addedMargin - calc.openFee;
        calc.addedNotional = calc.addedNet * leverageX100 / LEVERAGE_DENOM;
        calc.addedSize = MarginMathLib.sizeForNotional(calc.addedNotional, ctx.mark, usdgScale);
        if (calc.addedSize == 0) revert MarginTooSmall();
        calc.payoutAdd = ctx.pcm * calc.addedNet;
    }

    // ======================================================================
    // Trading: close / reduce
    // ======================================================================

    /// @inheritdoc IPerpEngine
    function closePosition(address token, bool isLong) external nonReentrant {
        if (!isListed[token]) revert NotListed();
        OpCtx memory ctx;
        ctx.params = riskConfig.paramsFor(token);
        ctx.tvl = vault.totalAssets();
        (uint256 mark, PrintClass cls) = _freshPrint(token);
        if (cls == PrintClass.BLOCKED) revert PrintBlocked();
        _accrue(token, mark, cls == PrintClass.LIVE, ctx.params, ctx.tvl);
        ctx.mark = mark;
        _closeCore(token, isLong, ctx);
    }

    /// @dev closePosition body after the preamble (separate frame for stack relief).
    function _closeCore(address token, bool isLong, OpCtx memory ctx) private {
        bytes32 key = _positionKey(token, msg.sender, isLong);
        PerpTypes.Position memory pos = _positions[key];
        if (pos.size1e18 == 0) revert PositionMissing();

        CloseCalc memory calc = _computeClose(token, pos, ctx);

        // Effects.
        _removePosition(key, token, pos);
        PerpTypes.Position memory emptyPos;
        _aggCloseFamily(token, pos, emptyPos);

        // Interactions. Vault flows settle BEFORE the reservation is released: the real vault
        // bounds settleTraderWin by the OUTSTANDING totalReserved (wins are paid from reserves),
        // so releasing first would revert any full-payout close in a thinly reserved book
        // (integration seam fix; the engine mocks did not enforce the reserve bound).
        _settleWithVault(calc.payToVault, calc.winFromVault, calc.fundingCredit);
        vault.releasePayout(token, pos.maxPayout);
        uint256 covered = _coverShortfall(token, pos.trader, calc.shortfall);
        if (calc.shortfall > covered) emit BadDebt(token, pos.trader, calc.shortfall, covered, 0);
        if (calc.traderNet > 0) usdg.safeTransfer(pos.trader, calc.traderNet);
        _distributeFee(calc.closeFee, 0);
        _pointsOnSettle(token, calc.closedNotional, calc.pnl);

        emit PositionClosed(key, token, pos.trader, isLong, ctx.mark, calc.pnl, calc.traderNet, calc.closeFee);
    }

    /// @dev Full-close settlement math (spec 1.5): clamped PnL, pending funding + borrow,
    ///      vault flow decomposition, close fee out of the trader pot.
    function _computeClose(address token, PerpTypes.Position memory pos, OpCtx memory ctx)
        private
        view
        returns (CloseCalc memory calc)
    {
        PerpTypes.MarketAggregates storage agg = _agg[token];
        (int256 fund, uint256 bor) = _pendingOwed(pos, agg.fundingX1e18, agg.borrowX1e18);
        calc.pnl = MarginMathLib.clampPnl(
            MarginMathLib.uPnlUsdg(pos.size1e18, pos.entryPrice1e18, ctx.mark, pos.isLong, usdgScale),
            pos.margin,
            pos.maxPayout
        );
        (calc.payToVault, calc.winFromVault, calc.shortfall) = _splitVaultFlow(calc.pnl, fund, bor, pos.margin);
        // B9: the reserved maxPayout bounds the PRICE payout only. A net funding credit that
        // would overshoot it is NOT confiscated (v1 behaviour): it is split onto the separate
        // unbounded funding channel and paid to the trader. The price PnL is already clampPnl-
        // bounded to maxPayout, so the reserved leg never exceeds the cap and the "max PRICE
        // outflow per market <= cost-to-move" invariant is fully preserved.
        (calc.winFromVault, calc.fundingCredit) = _splitReservedWin(calc.winFromVault, pos.maxPayout);
        uint256 pot = uint256(pos.margin) - calc.payToVault + calc.winFromVault + calc.fundingCredit;
        calc.closedNotional = MarginMathLib.notionalUsdg(pos.size1e18, ctx.mark, usdgScale);
        calc.closeFee = Math.mulDiv(calc.closedNotional, ctx.params.closeFeeBps, BPS_DENOM);
        if (calc.closeFee > pot) calc.closeFee = pot;
        calc.traderNet = pot - calc.closeFee;
    }

    /// @inheritdoc IPerpEngine
    function reducePosition(address token, bool isLong, uint32 fractionBps) external nonReentrant {
        if (!isListed[token]) revert NotListed();
        if (fractionBps == 0 || fractionBps >= BPS_DENOM) revert InvalidFraction();
        OpCtx memory ctx;
        ctx.params = riskConfig.paramsFor(token);
        ctx.pcm = riskConfig.payoutCapMultiple();
        ctx.tvl = vault.totalAssets();
        (uint256 mark, PrintClass cls) = _freshPrint(token);
        if (cls == PrintClass.BLOCKED) revert PrintBlocked();
        _accrue(token, mark, cls == PrintClass.LIVE, ctx.params, ctx.tvl);
        ctx.mark = mark;
        _reduceCore(token, isLong, fractionBps, ctx);
    }

    /// @dev reducePosition body after the preamble (separate frame for stack relief).
    function _reduceCore(address token, bool isLong, uint32 fractionBps, OpCtx memory ctx) private {
        bytes32 key = _positionKey(token, msg.sender, isLong);
        PerpTypes.Position memory before = _positions[key];
        if (before.size1e18 == 0) revert PositionMissing();

        PerpTypes.MarketAggregates storage agg = _agg[token];
        VaultFlows memory flows;
        // Second storage read: a memory-to-memory assignment would ALIAS `before`, zeroing
        // the before/after aggregate delta (the exact GMX-class desync this design guards).
        PerpTypes.Position memory pos = _positions[key];
        uint256 settledMargin;
        (settledMargin, flows.toVault, flows.fundingCredit) =
            _settlePending(pos, agg.fundingX1e18, agg.borrowX1e18, pos.margin);

        ReduceCalc memory calc = _computeReduce(pos, settledMargin, fractionBps, ctx);
        flows.toVault += calc.lossToVault;
        // The closed slice's price win is the RESERVED channel (bounded by the slice's maxPayout);
        // the whole-position funding credit already sits in flows.fundingCredit (B9).
        flows.fromVault += calc.winFromVault;

        pos.size1e18 = calc.remainSize.toUint128();
        pos.margin = calc.newMargin.toUint128();
        pos.maxPayout = calc.newMaxPayout.toUint128();
        pos.entryFundingX1e18 = agg.fundingX1e18;
        pos.entryBorrowX1e18 = agg.borrowX1e18;
        _positions[key] = pos;
        _reduceAddressReserved(token, msg.sender, calc.releaseAmt);
        _aggCloseFamily(token, before, pos);

        // Flush before release: the real vault bounds settleTraderWin by the outstanding
        // totalReserved (see _closeCore), so the win slice settles against the pre-release
        // reservation.
        _flushVaultFlows(flows);
        if (calc.releaseAmt > 0) vault.releasePayout(token, calc.releaseAmt);
        if (calc.traderNet > 0) usdg.safeTransfer(msg.sender, calc.traderNet);
        _distributeFee(calc.closeFee, 0);
        _pointsOnSettle(token, calc.closedNotional, calc.realized);

        emit PositionReduced(key, fractionBps, ctx.mark, calc.realized, calc.traderNet, calc.closeFee);
    }

    /// @dev Partial-close math (spec 1.5): the closed slice settles like a close with
    ///      proportional clamp bounds; released margin is limited so the remainder never
    ///      falls below the initial-margin requirement at the current mark; maxPayout is
    ///      recomputed on the remaining margin and can only shrink (never re-reserves).
    function _computeReduce(PerpTypes.Position memory pos, uint256 settledMargin, uint32 fractionBps, OpCtx memory ctx)
        private
        view
        returns (ReduceCalc memory calc)
    {
        calc.closedSize = uint256(pos.size1e18) * fractionBps / BPS_DENOM;
        calc.remainSize = uint256(pos.size1e18) - calc.closedSize;
        if (calc.closedSize == 0 || calc.remainSize == 0) revert InvalidFraction();
        uint256 marginSlice = settledMargin * fractionBps / BPS_DENOM;
        calc.realized = MarginMathLib.clampPnl(
            MarginMathLib.uPnlUsdg(calc.closedSize, pos.entryPrice1e18, ctx.mark, pos.isLong, usdgScale),
            marginSlice,
            uint256(pos.maxPayout) * fractionBps / BPS_DENOM
        );
        calc.lossToVault = calc.realized < 0 ? uint256(-calc.realized) : 0;
        calc.winFromVault = calc.realized > 0 ? uint256(calc.realized) : 0;
        uint256 poolAfter = settledMargin - calc.lossToVault;
        uint256 imReq = MarginMathLib.initialMarginUsdg(calc.remainSize, ctx.mark, ctx.params.maxLeverageX100, usdgScale);
        uint256 maxWithdrawable = poolAfter > imReq ? poolAfter - imReq : 0;
        uint256 releasedMargin = marginSlice < maxWithdrawable ? marginSlice : maxWithdrawable;
        calc.newMargin = poolAfter - releasedMargin;
        if (calc.newMargin == 0) revert MarginExhausted();
        calc.closedNotional = MarginMathLib.notionalUsdg(calc.closedSize, ctx.mark, usdgScale);
        uint256 gross = releasedMargin + calc.winFromVault;
        calc.closeFee = Math.mulDiv(calc.closedNotional, ctx.params.closeFeeBps, BPS_DENOM);
        if (calc.closeFee > gross) calc.closeFee = gross;
        calc.traderNet = gross - calc.closeFee;
        calc.newMaxPayout = ctx.pcm * calc.newMargin;
        if (calc.newMaxPayout > pos.maxPayout) calc.newMaxPayout = pos.maxPayout;
        calc.releaseAmt = uint256(pos.maxPayout) - calc.newMaxPayout;
    }

    // ======================================================================
    // Trading: margin management
    // ======================================================================

    /// @inheritdoc IPerpEngine
    /// @dev Allowed even while opens are breaker-denied and while the market is paused
    ///      (strictly de-risking, spec 1.6). The print is still checked so accrual can be
    ///      classified, but NO print class blocks this action.
    function addMargin(address token, bool isLong, uint128 amount) external nonReentrant {
        if (!isListed[token]) revert NotListed();
        if (amount == 0) revert InvalidAmount();
        OpCtx memory ctx;
        ctx.params = riskConfig.paramsFor(token);
        ctx.pcm = riskConfig.payoutCapMultiple();
        ctx.tvl = vault.totalAssets();
        ctx.capUsdg = _marketReserveCapUsdg(token, ctx.tvl);
        (uint256 mark, PrintClass cls) = _freshPrint(token);
        _accrue(token, mark, cls == PrintClass.LIVE, ctx.params, ctx.tvl);
        ctx.mark = mark;
        _addMarginCore(token, isLong, amount, ctx);
    }

    /// @dev addMargin body after the preamble (separate frame for stack relief).
    function _addMarginCore(address token, bool isLong, uint128 amount, OpCtx memory ctx) private {
        bytes32 key = _positionKey(token, msg.sender, isLong);
        PerpTypes.Position memory before = _positions[key];
        if (before.size1e18 == 0) revert PositionMissing();

        usdg.safeTransferFrom(msg.sender, address(this), amount);

        PerpTypes.MarketAggregates storage agg = _agg[token];
        VaultFlows memory flows;
        // Second storage read: a memory-to-memory assignment would ALIAS `before`, zeroing
        // the before/after aggregate delta (the exact GMX-class desync this design guards).
        PerpTypes.Position memory pos = _positions[key];
        uint256 settledMargin;
        (settledMargin, flows.toVault, flows.fundingCredit) =
            _settlePending(pos, agg.fundingX1e18, agg.borrowX1e18, uint256(pos.margin) + amount);
        if (settledMargin > ctx.params.maxPositionMargin) revert PositionMarginCapExceeded();
        uint256 payoutAdd = ctx.pcm * amount;
        _checkReserveCaps(token, msg.sender, agg.totalMaxPayout, payoutAdd, ctx.capUsdg);

        pos.margin = settledMargin.toUint128();
        pos.maxPayout = (uint256(pos.maxPayout) + payoutAdd).toUint128();
        pos.entryFundingX1e18 = agg.fundingX1e18;
        pos.entryBorrowX1e18 = agg.borrowX1e18;
        _positions[key] = pos;
        addressReserved[token][msg.sender] += payoutAdd;
        _aggOpenFamily(token, before, pos);

        if (payoutAdd > 0) vault.reservePayout(token, payoutAdd);
        _flushVaultFlows(flows);

        emit MarginAdded(key, amount, pos.margin, pos.maxPayout);
    }

    /// @inheritdoc IPerpEngine
    /// @dev Anti-JELLY floor (spec 1.5): equity after withdrawal must clear the initial-margin
    ///      requirement at the current mark, so an owner can never walk a position into
    ///      liquidation via withdrawal. Requires a LIVE print plus the opening breaker (this
    ///      is risk-increasing, so it gets the strictest gate) and is blocked while paused.
    function removeMargin(address token, bool isLong, uint128 amount) external nonReentrant {
        if (!isListed[token]) revert NotListed();
        if (amount == 0) revert InvalidAmount();
        _requireNotPaused(token);
        OpCtx memory ctx;
        ctx.params = riskConfig.paramsFor(token);
        ctx.pcm = riskConfig.payoutCapMultiple();
        ctx.tvl = vault.totalAssets();
        (uint256 mark, PrintClass cls) = _freshPrint(token);
        if (cls != PrintClass.LIVE) revert PrintNotLive();
        _requireOpeningAllowed(token);
        _accrue(token, mark, true, ctx.params, ctx.tvl);
        ctx.mark = mark;
        _removeMarginCore(token, isLong, amount, ctx);
    }

    /// @dev removeMargin body after the preamble (separate frame for stack relief).
    function _removeMarginCore(address token, bool isLong, uint128 amount, OpCtx memory ctx) private {
        bytes32 key = _positionKey(token, msg.sender, isLong);
        PerpTypes.Position memory before = _positions[key];
        if (before.size1e18 == 0) revert PositionMissing();

        PerpTypes.MarketAggregates storage agg = _agg[token];
        VaultFlows memory flows;
        // Second storage read: a memory-to-memory assignment would ALIAS `before`, zeroing
        // the before/after aggregate delta (the exact GMX-class desync this design guards).
        PerpTypes.Position memory pos = _positions[key];
        uint256 settledMargin;
        (settledMargin, flows.toVault, flows.fundingCredit) =
            _settlePending(pos, agg.fundingX1e18, agg.borrowX1e18, pos.margin);
        if (amount >= settledMargin) revert InvalidAmount();
        uint256 newMargin = settledMargin - amount;
        uint256 newMaxPayout = ctx.pcm * newMargin;
        if (newMaxPayout > pos.maxPayout) newMaxPayout = pos.maxPayout;
        uint256 releaseAmt = uint256(pos.maxPayout) - newMaxPayout;

        {
            int256 pnl = MarginMathLib.clampPnl(
                MarginMathLib.uPnlUsdg(pos.size1e18, pos.entryPrice1e18, ctx.mark, pos.isLong, usdgScale),
                newMargin,
                newMaxPayout
            );
            uint256 imReq =
                MarginMathLib.initialMarginUsdg(pos.size1e18, ctx.mark, ctx.params.maxLeverageX100, usdgScale);
            // Pending funding just settled to zero, so equity is margin plus clamped pnl.
            if (int256(newMargin) + pnl < int256(imReq)) revert BelowInitialMarginFloor();
        }

        pos.margin = newMargin.toUint128();
        pos.maxPayout = newMaxPayout.toUint128();
        pos.entryFundingX1e18 = agg.fundingX1e18;
        pos.entryBorrowX1e18 = agg.borrowX1e18;
        _positions[key] = pos;
        _reduceAddressReserved(token, msg.sender, releaseAmt);
        _aggCloseFamily(token, before, pos);

        // Flush before release: a net funding credit settles against the pre-release reservation
        // (the real vault bounds settleTraderWin by the outstanding totalReserved, see _closeCore).
        _flushVaultFlows(flows);
        if (releaseAmt > 0) vault.releasePayout(token, releaseAmt);
        usdg.safeTransfer(msg.sender, amount);

        emit MarginRemoved(key, amount, newMargin, newMaxPayout);
    }

    // ======================================================================
    // Keepers
    // ======================================================================

    /// @inheritdoc IPerpEngine
    function liquidate(address token, address trader, bool isLong) external nonReentrant {
        if (!isListed[token]) revert NotListed();
        _requireNotPaused(token);
        bytes32 key = _positionKey(token, trader, isLong);
        PerpTypes.Position memory pos = _positions[key];
        if (pos.size1e18 == 0) revert PositionMissing();
        PerpTypes.TierParams memory params = riskConfig.paramsFor(token);
        uint256 tvl = vault.totalAssets();
        (uint256 mark, PrintClass cls) = _freshPrint(token);
        if (cls != PrintClass.LIVE) revert PrintNotLive();
        _requireOpeningAllowed(token);
        _accrue(token, mark, true, params, tvl);

        LiqCalc memory calc = _computeLiquidation(token, pos, mark, params);

        // Effects.
        _removePosition(key, token, pos);
        _aggLiquidateFamily(token, pos);

        // Interactions. Settle before release: the real vault bounds settleTraderWin by the
        // outstanding totalReserved (see _closeCore).
        _settleWithVault(calc.payToVault, calc.winFromVault, calc.fundingCredit);
        vault.releasePayout(token, pos.maxPayout);
        if (calc.shortfall > 0) {
            uint256 covered = _coverShortfall(token, trader, calc.shortfall);
            uint256 remaining = calc.shortfall - covered;
            uint256 adlAbsorbed;
            if (remaining > 0) {
                uint256 unabsorbed = _adl(token, isLong, remaining, mark);
                adlAbsorbed = remaining - unabsorbed;
            }
            emit BadDebt(token, trader, calc.shortfall, covered, adlAbsorbed);
        }
        if (calc.keeperCut > 0) usdg.safeTransfer(msg.sender, calc.keeperCut);
        // Economics v2 (finding A1): the vault's penalty share is PULLED by the vault against
        // the engine's standing approval and raises LP NAV (no shares minted). Own contract:
        // it can never freeze, so no credit-on-failure wrapper is needed.
        if (calc.vaultCut > 0) vault.receiveLiquidationRevenue(calc.vaultCut);
        if (calc.fundCut > 0) usdg.safeTransfer(address(insuranceFund), calc.fundCut);
        if (calc.residual > 0) usdg.safeTransfer(trader, calc.residual);
        if (calc.keeperCut < keeperFloorUsdg) {
            // Best effort: an empty fund can never block the liquidation itself.
            try insuranceFund.payKeeperFloor(msg.sender, keeperFloorUsdg - calc.keeperCut) {} catch {}
        }

        emit Liquidated(key, token, trader, isLong, msg.sender, mark, calc.penalty, calc.keeperCut, calc.residual);
    }

    /// @dev Full liquidation calculation (spec 3.2 waterfall): reverts NotLiquidatable when
    ///      equity at the mark still clears maintenance margin.
    function _computeLiquidation(
        address token,
        PerpTypes.Position memory pos,
        uint256 mark,
        PerpTypes.TierParams memory params
    ) private view returns (LiqCalc memory calc) {
        PerpTypes.MarketAggregates storage agg = _agg[token];
        (int256 fund, uint256 bor) = _pendingOwed(pos, agg.fundingX1e18, agg.borrowX1e18);
        int256 pnl = MarginMathLib.clampPnl(
            MarginMathLib.uPnlUsdg(pos.size1e18, pos.entryPrice1e18, mark, pos.isLong, usdgScale),
            pos.margin,
            pos.maxPayout
        );
        uint256 notionalAtMark = MarginMathLib.notionalUsdg(pos.size1e18, mark, usdgScale);
        int256 equity = MarginMathLib.equityUsdg(pos.margin, pnl, fund, bor);
        // B7: maintenance uses the position's GRANDFATHERED mmr snapshot, never the live tier,
        // so a permissionless refreshTier downgrade cannot retroactively raise it (spec 8.4).
        uint256 mm = Math.mulDiv(notionalAtMark, pos.entryMmrBps, BPS_DENOM);
        // B3: a non-negative-PnL position with non-negative equity is never liquidatable. Past
        // the payout cap the clamped equity is frozen while mm keeps growing with the winning
        // move's uncapped notional; without this guard a maximally-winning long trips maintenance
        // and a keeper confiscates the capped payout (pa-liquidation F1). A funding-bankrupt
        // position (equity < 0) is unaffected: it still liquidates through the mm check below.
        if (equity >= int256(mm) || (pnl >= 0 && equity >= 0)) revert NotLiquidatable();
        (calc.payToVault, calc.winFromVault, calc.shortfall) = _splitVaultFlow(pnl, fund, bor, pos.margin);
        // B9: reserved leg bounded by maxPayout (price); funding-credit overflow paid separately.
        (calc.winFromVault, calc.fundingCredit) = _splitReservedWin(calc.winFromVault, pos.maxPayout);
        uint256 pot = uint256(pos.margin) - calc.payToVault + calc.winFromVault + calc.fundingCredit; // == max(equity, 0)
        calc.penalty = Math.mulDiv(notionalAtMark, params.liqPenaltyBps, BPS_DENOM);
        if (calc.penalty > pot) calc.penalty = pot;
        // Economics v2 penalty split (finding A1): keeper 20% / vault 40% / InsuranceFund 40%
        // plus round-down dust. keeperCut + vaultCut + fundCut + residual == pot, wei-exact;
        // the residual-return-to-trader fairness feature is unchanged.
        calc.keeperCut = calc.penalty * keeperShareBps / BPS_DENOM;
        calc.vaultCut = calc.penalty * liqVaultShareBps / BPS_DENOM;
        calc.fundCut = calc.penalty - calc.keeperCut - calc.vaultCut;
        calc.residual = pot - calc.penalty;
    }

    /// @inheritdoc IPerpEngine
    function pokeFunding(address token) external nonReentrant {
        if (!isListed[token]) revert NotListed();
        PerpTypes.TierParams memory params = riskConfig.paramsFor(token);
        uint256 tvl = vault.totalAssets();
        (uint256 mark, PrintClass cls) = _freshPrint(token);
        _accrue(token, mark, cls == PrintClass.LIVE, params, tvl);
    }

    // ======================================================================
    // Governance (timelocked owner)
    // ======================================================================

    /// @inheritdoc IPerpEngine
    function listMarket(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (isListed[token]) revert AlreadyListed();
        if (!router.isListable(token)) revert RouterNotListable();
        PerpTypes.TierParams memory params = riskConfig.paramsFor(token);
        if (params.maxLeverageX100 < MIN_LEVERAGE_X100 || params.mmrBps == 0 || params.maxPositionMargin == 0) {
            revert InvalidParam();
        }
        // B5: a pool-priced (B_DEEP / C_MID) market whose spot-vs-TWAP breaker is disarmed
        // (spotSource == 0) would execute opens and liquidations on TWAP freshness alone, its
        // only manipulation gate silently off. Refuse to list it until the breaker is armed.
        (uint8 tier,,,,,, address spotSource,) = router.tierConfigOf(token);
        bool poolPriced = tier == 1 || tier == 2; // B_DEEP, C_MID
        if (poolPriced && spotSource == address(0)) revert OpeningBreakerDisarmed();
        isListed[token] = true;
        listedAt[token] = uint64(block.timestamp);
        // B1: freeze the router's cost-to-move payout cap at listing; the vault and the engine's
        // reserve-cap math read this snapshot forever after, never the router's live value.
        marketMaxPayoutCap1e18[token] = router.maxMarketPayoutCap1e18(token);
        _markets.push(token);
        _aggAccrue(token, 0, 0, 0); // seeds lastAccrual so the first real accrual has a base
        emit MarketListed(token, uint64(block.timestamp));
    }

    /// @inheritdoc IPerpEngine
    /// @dev Writes only the closeOnly config flag; position accounting fields remain the
    ///      exclusive domain of the four aggregate mutators.
    function setCloseOnly(address token, bool on) external onlyOwner {
        if (!isListed[token]) revert NotListed();
        _agg[token].closeOnly = on;
        emit CloseOnlySet(token, on);
    }

    /// @notice Set the minimum gross margin per open.
    function setMinMargin(uint128 value) external onlyOwner {
        if (value == 0) revert InvalidParam();
        minMargin = value;
        emit EngineParamSet("minMargin", value);
    }

    /// @notice Set the keeper penalty share (bps) and the keeper reward floor (USDG units).
    ///         Combined with the vault's penalty share it can never exceed 100% (conservation).
    function setKeeperParams(uint16 shareBps, uint128 floorUsdg) external onlyOwner {
        if (uint256(shareBps) + liqVaultShareBps > BPS_DENOM) revert InvalidParam();
        keeperShareBps = shareBps;
        keeperFloorUsdg = floorUsdg;
        emit EngineParamSet("keeperShareBps", shareBps);
        emit EngineParamSet("keeperFloorUsdg", floorUsdg);
    }

    /// @notice Set the LP vault share of the liquidation penalty (bps, economics v2). Combined
    ///         with the keeper share it can never exceed 100%; the InsuranceFund takes the rest.
    function setLiqVaultShareBps(uint16 shareBps) external onlyOwner {
        if (uint256(shareBps) + keeperShareBps > BPS_DENOM) revert InvalidParam();
        liqVaultShareBps = shareBps;
        emit EngineParamSet("liqVaultShareBps", shareBps);
    }

    /// @notice Set the per-address share of a market's reserve cap, bps.
    function setPerAddressReserveShareBps(uint16 value) external onlyOwner {
        if (value == 0 || value > BPS_DENOM) revert InvalidParam();
        perAddressReserveShareBps = value;
        emit EngineParamSet("perAddressReserveShareBps", value);
    }

    /// @notice Set the skew denominator floor, USDG units.
    function setSkewFloor(uint128 value) external onlyOwner {
        skewFloorUsdg = value;
        emit EngineParamSet("skewFloorUsdg", value);
    }

    /// @notice Set the new-market reserve ramp (bps of TVL PER DAY, linear, duration seconds).
    function setNewMarketRamp(uint16 capBps, uint64 duration) external onlyOwner {
        if (capBps == 0 || capBps > BPS_DENOM) revert InvalidParam();
        rampCapBps = capBps;
        rampDuration = duration;
        emit EngineParamSet("rampCapBps", capBps);
        emit EngineParamSet("rampDuration", duration);
    }

    /// @notice Set the vault-drawdown circuit (bps of window-start NAV, window seconds).
    function setDrawdownCircuit(uint16 bps, uint64 window) external onlyOwner {
        if (bps == 0 || bps > BPS_DENOM || window == 0) revert InvalidParam();
        drawdownCircuitBps = bps;
        drawdownWindow = window;
        emit EngineParamSet("drawdownCircuitBps", bps);
        emit EngineParamSet("drawdownWindow", window);
    }

    /// @notice Clear a tripped drawdown circuit and re-seed the observation window.
    /// @dev B2: callable by the timelock owner OR the guardian. The guardian is the FAST lever
    ///      (the permissionless latch can otherwise only be cleared by a 2-day timelocked owner
    ///      call, converting any transient dip into a multi-day protocol-wide opens freeze). The
    ///      circuit also auto-expires on a window roll (see _drawdownGate); this is the manual path.
    function resetDrawdownCircuit() external {
        if (msg.sender != owner() && msg.sender != guardian.guardian()) revert NotOwnerOrGuardian();
        drawdownTripped = false;
        _navWindowStartAssets = 0; // re-seeds on the next open
        emit DrawdownCircuitReset();
    }

    // ======================================================================
    // Fee plumbing (ported v1 armor: push with credit-on-failure)
    // ======================================================================

    /// @notice Self-only SafeERC20 push wrapper so fee distribution can try/catch a transfer.
    function pushFee(address to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        usdg.safeTransfer(to, amount);
    }

    /// @notice Withdraw fee shares credited after a failed push.
    function withdrawCredit() external nonReentrant {
        uint256 amount = creditOf[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        creditOf[msg.sender] = 0;
        totalCredit -= amount;
        usdg.safeTransfer(msg.sender, amount);
    }

    /// @dev Split a fee across the five recipients (economics v2: jackpot 25 / referral 10 /
    ///      VAULT 20 / buyback 25 / treasury 20 plus dust), then route any vol surcharge
    ///      (vaultExtra) WHOLE to the vault on top of its split share. Conservation: the five
    ///      shares plus dust sum to `fee` wei-exact, and the vault leg adds exactly vaultExtra.
    ///      External recipients keep the credit-on-failure armor; the vault leg is our own
    ///      contract (pull via receiveFeeRevenue against the standing approval) and cannot
    ///      freeze, so it pays direct.
    function _distributeFee(uint256 fee, uint256 vaultExtra) private {
        uint256 vaultShare = fee * FEE_SHARE_VAULT_BPS / BPS_DENOM + vaultExtra;
        if (fee > 0) {
            uint256 jackpotShare = fee * FEE_SHARE_JACKPOT_BPS / BPS_DENOM;
            uint256 referralShare = fee * FEE_SHARE_REFERRAL_BPS / BPS_DENOM;
            uint256 buybackShare = fee * FEE_SHARE_BUYBACK_BPS / BPS_DENOM;
            uint256 treasuryShare =
                fee - jackpotShare - referralShare - (fee * FEE_SHARE_VAULT_BPS / BPS_DENOM) - buybackShare;
            _payFee(feeJackpot, jackpotShare);
            _payFee(feeReferralPool, referralShare);
            _payFee(feeBuyback, buybackShare);
            _payFee(feeTreasury, treasuryShare);
        }
        if (vaultShare > 0) vault.receiveFeeRevenue(vaultShare);
    }

    /// @dev Push a fee share; on any failure credit it for pull-withdrawal (pure effect,
    ///      keeps escrow solvency: the failed share stays in this contract's balance).
    function _payFee(address recipient, uint256 share) private {
        if (share == 0) return;
        try this.pushFee(recipient, share) {
            return;
        } catch {
            creditOf[recipient] += share;
            totalCredit += share;
            emit FeeCredited(recipient, share);
        }
    }

    // ======================================================================
    // Views (IPerpEngine)
    // ======================================================================

    /// @inheritdoc IPerpEngine
    function getPosition(address token, address trader, bool isLong)
        external
        view
        returns (PerpTypes.Position memory)
    {
        return _positions[_positionKey(token, trader, isLong)];
    }

    /// @inheritdoc IPerpEngine
    function equityOf(address token, address trader, bool isLong) external view returns (int256) {
        PerpTypes.Position memory pos = _positions[_positionKey(token, trader, isLong)];
        if (pos.size1e18 == 0) return 0;
        uint256 mark = _previewMark(token);
        (int128 fundingX, uint128 borrowX) = _previewIndices(token, mark);
        (int256 fund, uint256 bor) = _pendingOwed(pos, fundingX, borrowX);
        int256 pnl = MarginMathLib.clampPnl(
            MarginMathLib.uPnlUsdg(pos.size1e18, pos.entryPrice1e18, mark, pos.isLong, usdgScale),
            pos.margin,
            pos.maxPayout
        );
        return MarginMathLib.equityUsdg(pos.margin, pnl, fund, bor);
    }

    /// @inheritdoc IPerpEngine
    function liquidationPrice(address token, address trader, bool isLong) external view returns (uint256) {
        PerpTypes.Position memory pos = _positions[_positionKey(token, trader, isLong)];
        if (pos.size1e18 == 0) return 0;
        uint256 mark = _previewMark(token);
        (int128 fundingX, uint128 borrowX) = _previewIndices(token, mark);
        (int256 fund, uint256 bor) = _pendingOwed(pos, fundingX, borrowX);
        // B7: the liquidation boundary uses the grandfathered mmr snapshot, not the live tier.
        return MarginMathLib.liquidationPrice1e18(
            pos.size1e18, pos.entryPrice1e18, pos.margin, fund + int256(bor), uint16(pos.entryMmrBps), pos.isLong, usdgScale
        );
    }

    /// @inheritdoc IPerpEngine
    /// @dev Deliberately a plain view with NO reentrancy lock: the vault reads it from inside
    ///      engine-initiated calls (reservePayout during opens reads totalAssets which reads
    ///      this), per the IPerpVaultDeps integration contract.
    function marketState(address token)
        external
        view
        override(IPerpEngine, IPerpMarketList)
        returns (PerpTypes.MarketAggregates memory)
    {
        return _agg[token];
    }

    /// @inheritdoc IPerpEngine
    function liquidatable(address token, address trader, bool isLong) external view returns (bool) {
        PerpTypes.Position memory pos = _positions[_positionKey(token, trader, isLong)];
        if (pos.size1e18 == 0) return false;
        (bool live, uint256 p) = _previewLiveMark(token);
        if (!live) return false;
        (bool allowed,) = router.openingAllowed(token);
        if (!allowed) return false;
        return _isUnderwater(token, pos, p);
    }

    /// @dev View-side LIVE classification: peekable OK price with a clean breaker.
    function _previewLiveMark(address token) private view returns (bool live, uint256 mark) {
        (uint256 p, Types.PriceStatus st) = router.peekPrice(token);
        if (st != Types.PriceStatus.OK || p == 0) return (false, 0);
        (uint64 cooldownUntil, uint8 failedRounds) = router.breakerOf(token);
        if (cooldownUntil != 0 || failedRounds != 0) return (false, 0);
        return (true, p);
    }

    /// @dev Equity-below-maintenance check at a given mark with previewed indices.
    function _isUnderwater(address token, PerpTypes.Position memory pos, uint256 mark) private view returns (bool) {
        (int128 fundingX, uint128 borrowX) = _previewIndices(token, mark);
        (int256 fund, uint256 bor) = _pendingOwed(pos, fundingX, borrowX);
        int256 pnl = MarginMathLib.clampPnl(
            MarginMathLib.uPnlUsdg(pos.size1e18, pos.entryPrice1e18, mark, pos.isLong, usdgScale),
            pos.margin,
            pos.maxPayout
        );
        int256 equity = MarginMathLib.equityUsdg(pos.margin, pnl, fund, bor);
        // B7: grandfathered mmr snapshot, mirroring _computeLiquidation.
        uint256 mm = MarginMathLib.maintenanceMarginUsdg(pos.size1e18, mark, uint16(pos.entryMmrBps), usdgScale);
        // B3: a non-negative-PnL position with non-negative equity is never liquidatable.
        if (pnl >= 0 && equity >= 0) return false;
        return equity < int256(mm);
    }

    // ======================================================================
    // Views (engine surface beyond the frozen interface: vault NAV + keepers + UI)
    // ======================================================================

    /// @inheritdoc IPerpMarketList
    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    /// @inheritdoc IPerpMarketList
    function marketAt(uint256 index) external view returns (address token) {
        return _markets[index];
    }

    /// @notice All listed market tokens.
    function allMarkets() external view returns (address[] memory) {
        return _markets;
    }

    /// @notice All open position keys in a market (test harness, keepers, ADL transparency).
    function positionKeysOf(address token) external view returns (bytes32[] memory) {
        return _marketPositionKeys[token].values();
    }

    /// @notice Deterministic position key for (token, trader, isLong).
    function positionKeyFor(address token, address trader, bool isLong) external pure returns (bytes32) {
        return _positionKey(token, trader, isLong);
    }

    /// @notice The market's live reserve cap in USDG units (spec 3.6 plus the new-market ramp).
    function marketReserveCapUsdg(address token) external view returns (uint256) {
        return _marketReserveCapUsdg(token, vault.totalAssets());
    }

    /// @notice Pending (unsettled) funding and borrow owed by a position at current indices,
    ///         simulated to now when the print previews LIVE.
    function pendingOwedOf(address token, address trader, bool isLong)
        external
        view
        returns (int256 funding, uint256 borrowFee)
    {
        PerpTypes.Position memory pos = _positions[_positionKey(token, trader, isLong)];
        if (pos.size1e18 == 0) return (0, 0);
        // Same mark selection as equityOf: a peekable OK price, else the cached mark.
        (uint256 p, Types.PriceStatus st) = router.peekPrice(token);
        uint256 mark = (st == Types.PriceStatus.OK && p != 0) ? p : _agg[token].cachedMark1e18;
        (int128 fundingX, uint128 borrowX) = _previewIndices(token, mark);
        return _pendingOwed(pos, fundingX, borrowX);
    }

    /// @notice The current realized-vol reading in bps for a market (RE-ECON-1): the best
    ///         available mark's displacement from the slow EWMA reference. Zero before the
    ///         reference is seeded or when no mark is available. Keeper/UI observability for
    ///         the vol-scaled borrow layer.
    function realizedVolBpsOf(address token) external view returns (uint256) {
        (uint256 p, Types.PriceStatus st) = router.peekPrice(token);
        uint256 mark = (st == Types.PriceStatus.OK && p != 0) ? p : _agg[token].cachedMark1e18;
        return _realizedVolBps(volRefPrice1e18[token], mark);
    }

    /// @notice Aggregate clamped trader uPnL for a market at its cached mark, the vault's NAV
    ///         input (spec 4.3). Conservative aggregate clamps: each side's loss is bounded by
    ///         that side's total margin and each side's profit by the market's combined
    ///         totalMaxPayout, which can only OVERSTATE the trader claim (understate NAV),
    ///         the safe direction for depositors.
    /// @return pnlUsdg Signed aggregate trader claim in USDG units.
    /// @return markAt Timestamp of the cached mark used (0 = never marked).
    function marketTraderPnlUsdg(address token) external view returns (int256 pnlUsdg, uint64 markAt) {
        PerpTypes.MarketAggregates storage agg = _agg[token];
        uint256 mark = agg.cachedMark1e18;
        if (mark == 0) return (0, 0);
        int256 longRaw = int256(MarginMathLib.notionalUsdg(agg.totalLongSize1e18, mark, usdgScale))
            - int256(uint256(agg.totalLongCost));
        int256 shortRaw = int256(uint256(agg.totalShortCost))
            - int256(MarginMathLib.notionalUsdg(agg.totalShortSize1e18, mark, usdgScale));
        int256 longClamped = MarginMathLib.clampPnl(longRaw, agg.totalLongMargin, agg.totalMaxPayout);
        int256 shortClamped = MarginMathLib.clampPnl(shortRaw, agg.totalShortMargin, agg.totalMaxPayout);
        return (longClamped + shortClamped, agg.cachedMarkAt);
    }

    // ======================================================================
    // Internal: gates and classification
    // ======================================================================

    /// @dev Shared open/increase gates: listing, guardian pause, close-only. The drawdown latch
    ///      is enforced in _drawdownGate (B2), which also auto-expires it on a window roll.
    function _requireOpenGates(address token) private view {
        if (!isListed[token]) revert NotListed();
        _requireNotPaused(token);
        if (_agg[token].closeOnly) revert MarketCloseOnly();
    }

    /// @dev Guardian pause: the engine's own key doubles as the global perp switch and the
    ///      token address is the per-market key (isPaused internally also checks address(0)).
    function _requireNotPaused(address token) private view {
        if (guardian.isPaused(address(this)) || guardian.isPaused(token)) revert EnginePaused();
    }

    /// @dev The LIVE / FALLBACK / BLOCKED classifier (spec 2.3): a genuine agreeing print
    ///      zeroes cooldownUntil and failedRounds inside the same checkPrice call, so the
    ///      post-call breaker read is an exact classifier.
    function _freshPrint(address token) private returns (uint256 mark, PrintClass cls) {
        (uint256 p, Types.PriceStatus status) = router.checkPrice(token);
        if (status != Types.PriceStatus.OK || p == 0) return (0, PrintClass.BLOCKED);
        (uint64 cooldownUntil, uint8 failedRounds) = router.breakerOf(token);
        cls = (cooldownUntil == 0 && failedRounds == 0) ? PrintClass.LIVE : PrintClass.FALLBACK;
        return (p, cls);
    }

    /// @dev Spot-vs-TWAP opening breaker (reused as-is).
    function _requireOpeningAllowed(address token) private view {
        (bool allowed, uint8 reason) = router.openingAllowed(token);
        if (!allowed) revert OpeningDenied(reason);
    }

    /// @dev Vault-drawdown close-only circuit (spec 6.3): rolling window on vault.totalAssets.
    ///      The gate blocks opens LIVE whenever the window drawdown breaches the threshold
    ///      (a revert cannot persist a latch, so blocking is computed, not stored) and
    ///      tripDrawdownCircuit latches the block until governance review. First pass:
    ///      totalAssets also moves with LP deposits/withdrawals, so a large legit withdrawal
    ///      can trip it early; governance resets. Deliberately dumb and cheap.
    function _drawdownGate(uint256 ref) private {
        // Window roll (or unseeded): re-anchor at the current reference and AUTO-EXPIRE the latch
        // (B2). A fresh anchor makes the live gate clear by construction, so a latched circuit
        // that has outlived its window self-heals here instead of waiting for a governance reset.
        if (block.timestamp >= _navWindowStart + drawdownWindow || _navWindowStartAssets == 0) {
            _navWindowStart = uint64(block.timestamp);
            _navWindowStartAssets = ref;
            if (drawdownTripped) {
                drawdownTripped = false;
                emit DrawdownCircuitReset();
            }
            return;
        }
        // Within the window: a latched circuit blocks opens; even unlatched the live self-healing
        // gate blocks opens for as long as the drawdown condition itself holds.
        if (drawdownTripped) revert DrawdownCircuitActive();
        if (_drawdownBreached(ref)) revert DrawdownCircuitActive();
    }

    /// @dev True while the current reference NAV sits below the window-start drawdown floor.
    function _drawdownBreached(uint256 ref) private view returns (bool) {
        if (_navWindowStartAssets == 0 || block.timestamp >= _navWindowStart + drawdownWindow) return false;
        uint256 floor = _navWindowStartAssets - Math.mulDiv(_navWindowStartAssets, drawdownCircuitBps, BPS_DENOM);
        return ref < floor;
    }

    /// @notice Permissionless latch: while the live drawdown condition holds, ANYONE can
    ///         freeze opens engine-wide until governance resets (spec 6.3: close-only until
    ///         governance review). Even unlatched, opens stay blocked live for as long as
    ///         the drawdown condition itself holds inside the window.
    function tripDrawdownCircuit() external {
        uint256 ref = vault.drawdownReferenceAssets();
        if (!_drawdownBreached(ref)) revert DrawdownNotBreached();
        drawdownTripped = true;
        emit DrawdownCircuitTripped(ref, _navWindowStartAssets);
    }

    /// @notice Permissionless stale-HIGH cost-to-move trip (FIX-3). The per-market payout cap is
    ///         FROZEN at listMarket (B1, the correct fix for the JIT-liquidity drain) but never
    ///         lowers. If a memecoin's real pool depth later collapses, the frozen cap can exceed
    ///         the LIVE cost-to-move/SF, breaking the core inequality max_payout <= costToMove/SF
    ///         for the reservations already open (the absolute loss stays bounded by the live 10%
    ///         -TVL leg, but the cost-to-move armor is holed). Anyone can flip such a market to
    ///         close-only here: new opens/increases are blocked while closes and liquidations keep
    ///         working, so the outstanding over-reservation drains off naturally. Tripping requires
    ///         a REAL, currently-breaching collapse (live cap strictly below the frozen listing cap
    ///         AND below the market's outstanding reservations), so a healthy or empty market can
    ///         never be griefed into close-only, and majors (unbounded cap) are never trippable.
    function tripCostToMoveCloseOnly(address token) external {
        if (!isListed[token]) revert NotListed();
        uint256 frozen1e18 = marketMaxPayoutCap1e18[token];
        if (frozen1e18 == type(uint256).max) revert CostToMoveNotBreached(); // majors: unbounded cap
        uint256 live1e18 = router.maxMarketPayoutCap1e18(token);
        uint256 reservedUsdg = _agg[token].totalMaxPayout;
        // Require BOTH a genuine decline from the frozen snapshot AND an actual breach of the
        // outstanding reservations by the current depth. reservedUsdg == 0 (empty market) can never
        // trip: liveUsdg >= 0 always covers it, which also blocks griefing a healthy-but-empty book.
        uint256 liveUsdg = live1e18 == type(uint256).max ? type(uint256).max : live1e18 / usdgScale;
        if (live1e18 >= frozen1e18 || liveUsdg >= reservedUsdg) revert CostToMoveNotBreached();
        _agg[token].closeOnly = true;
        emit CostToMoveCloseOnly(token, frozen1e18, live1e18, reservedUsdg);
    }

    /// @dev Per-market reserve cap in USDG units (spec 3.6): min of the router's cost-to-move
    ///      cap (scaled) and the TVL percentage leg, throttled further during the ramp window.
    function _marketReserveCapUsdg(address token, uint256 tvl) private view returns (uint256) {
        uint256 cap = Math.mulDiv(tvl, riskConfig.marketReserveCapBps(), BPS_DENOM);
        // B1: the cost-to-move leg is the FROZEN snapshot from listMarket, not the live router.
        uint256 routerCap1e18 = marketMaxPayoutCap1e18[token];
        if (routerCap1e18 != type(uint256).max) {
            uint256 routerCapUsdg = routerCap1e18 / usdgScale;
            if (routerCapUsdg < cap) cap = routerCapUsdg;
        }
        if (block.timestamp < uint256(listedAt[token]) + rampDuration) {
            // Economics v2 ramp (finding A2): LINEAR per day. Day N (1-indexed from listing)
            // allows N * rampCapBps of TVL (launch 1%/day over 14 days); the min() structure
            // means the ramp only ever TIGHTENS the other legs and the anti-drain
            // cost-to-move leg is untouched.
            uint256 daysIn = (block.timestamp - uint256(listedAt[token])) / 1 days + 1;
            uint256 ramp = Math.mulDiv(tvl, uint256(rampCapBps) * daysIn, BPS_DENOM);
            if (ramp < cap) cap = ramp;
        }
        return cap;
    }

    /// @dev Reserve-cap checks for a payout addition (market total + per-address share).
    function _checkReserveCaps(address token, address trader, uint256 totalMaxPayout, uint256 payoutAdd, uint256 capUsdg)
        private
        view
    {
        if (totalMaxPayout + payoutAdd > capUsdg) revert MarketReserveCapExceeded();
        uint256 addrCap = Math.mulDiv(capUsdg, perAddressReserveShareBps, BPS_DENOM);
        if (addressReserved[token][trader] + payoutAdd > addrCap) revert AddressReserveCapExceeded();
    }

    // ======================================================================
    // Internal: funding and settlement math
    // ======================================================================

    /// @dev Accrue funding + borrow indices for a market (spec 2.3): skew cannot be re-priced
    ///      mid-manipulation, so accrual only runs on a LIVE print. B4 accrue-then-freeze: across
    ///      a non-LIVE gap lastAccrual is NOT advanced, so the whole holding interval bills on the
    ///      next LIVE poke rather than being silently swallowed by a single non-LIVE poke (which
    ///      was a permissionless funding dodge + LP-revenue erosion). The cached mark is still
    ///      refreshed on a non-LIVE FALLBACK print (non-zero) for NAV. All external reads (params,
    ///      tvl, mark) happen before the aggregate read/write pair inside _aggAccrue.
    function _accrue(address token, uint256 mark, bool live, PerpTypes.TierParams memory params, uint256 tvl)
        private
    {
        if (!live) {
            _aggCacheMark(token, mark);
            return;
        }
        // RE-ECON-1: the vol knobs are an external read and MUST come before the aggregate
        // read/write pair below (no external call between an aggregate read and its write).
        PerpTypes.VolParams memory vp = riskConfig.volParams();
        PerpTypes.MarketAggregates storage agg = _agg[token];
        uint256 dt = block.timestamp - agg.lastAccrual;
        int256 fundingDelta;
        uint256 borrowDelta;
        if (dt > 0) {
            {
                uint256 oiLong = MarginMathLib.notionalUsdg(agg.totalLongSize1e18, mark, usdgScale);
                uint256 oiShort = MarginMathLib.notionalUsdg(agg.totalShortSize1e18, mark, usdgScale);
                int256 skew = FundingLib.skew1e18(oiLong, oiShort, skewFloorUsdg);
                fundingDelta = FundingLib.fundingIndexDelta1e18(
                    FundingLib.fundingRatePerHour1e18(skew, params.kFPerHour1e18), mark, dt
                );
            }
            // RE-ECON-1 holding-cost convexity price: the borrow rate is scaled by the
            // realized-vol multiplier, so a position that HOLDS through realized volatility
            // pays for the gamma it carries no matter when it opened, on BOTH sides of the
            // book (borrow is unsigned: a delta-neutral straddle pays on both legs). The
            // reading is the settlement mark's displacement from the slow EWMA reference,
            // time-integrated and not suppressible in one block, unlike the instantaneous
            // spot-vs-TWAP deviation the open surcharge prices. FIX-2: the vol MULTIPLIER may
            // span only the most recent `tau` of the unbilled interval; any EXCESS dt bills at
            // the plain base rate. The reading is sampled at the poke endpoint and the whole
            // unbilled dt would otherwise bill at that single (2%/h-ceiling) rate, so a long
            // dormant hold on a thin market could be liquidated by borrow alone. Capping at tau
            // preserves accrue-then-freeze (B4): the tau window where the event lives still bills
            // at the full event rate, so the PATIENT-straddle harvest stays -EV.
            borrowDelta = _volBorrowIndexDelta(token, agg.totalMaxPayout, tvl, mark, params.kBPerHour1e18, vp, dt);
        }
        _updateVolRef(token, mark, dt, vp.volRefTauSeconds);
        _aggAccrue(token, fundingDelta, borrowDelta, mark);
    }

    /// @dev Advance the long-reference EWMA toward the LIVE mark by min(dt, tau) / tau, dt
    ///      being the same unbilled interval the accrual just settled. Seeds to the mark at
    ///      the market's first LIVE accrual. tau == 0 (vol-borrow disarmed: setVolParams
    ///      forbids arming the multiplier without a tau) keeps snapping the reference to the
    ///      mark so a later re-arm can never bill a stale reference gap as phantom vol.
    function _updateVolRef(address token, uint256 mark, uint256 dt, uint32 tau) private {
        uint256 ref = volRefPrice1e18[token];
        if (ref == 0 || tau == 0) {
            volRefPrice1e18[token] = mark.toUint128();
            return;
        }
        if (dt == 0 || mark == ref) return;
        uint256 diff = mark > ref ? mark - ref : ref - mark;
        uint256 step = dt >= tau ? diff : diff * dt / tau;
        volRefPrice1e18[token] = (mark > ref ? ref + step : ref - step).toUint128();
    }

    /// @dev The RE-ECON-1 borrow index delta over `dt`: the utilization base rate scaled by the
    ///      realized-vol multiplier, but with the multiplier constrained to span at most `tau`
    ///      (the EWMA time constant) of the interval (FIX-2). Own frame for stack relief; shared
    ///      by _accrue and the view-side _simulateDeltas so previews match what the next accrual
    ///      books. Splitting rule: when the multiplier is active and the interval is longer than
    ///      tau, the most recent tau bills at the vol-scaled rate and the older excess bills at
    ///      the plain base rate; otherwise the whole interval bills at the (possibly vol-scaled)
    ///      rate exactly as before. Preserves the 2%/h FundingLib ceiling and the accrue-then-
    ///      freeze anti-suppression property (the tau window where a vol event lives is still
    ///      fully event-rated), while bounding the one-shot over-charge on a long dormant slice.
    function _volBorrowIndexDelta(
        address token,
        uint256 reservedUsdg,
        uint256 tvl,
        uint256 mark,
        uint64 kBPerHour1e18,
        PerpTypes.VolParams memory vp,
        uint256 dt
    ) private view returns (uint256) {
        uint256 baseRate = FundingLib.borrowRatePerHour1e18(reservedUsdg, tvl, kBPerHour1e18);
        uint256 volRate = FundingLib.volScaledBorrowRatePerHour1e18(
            baseRate,
            _realizedVolBps(volRefPrice1e18[token], mark),
            vp.volBorrowDeadbandBps,
            vp.kBorrowVolX100,
            vp.maxVolBorrowMultX100
        );
        uint256 tau = vp.volRefTauSeconds;
        if (volRate == baseRate || tau == 0 || dt <= tau) {
            return FundingLib.borrowIndexDelta1e18(volRate, mark, dt);
        }
        return FundingLib.borrowIndexDelta1e18(volRate, mark, tau)
            + FundingLib.borrowIndexDelta1e18(baseRate, mark, dt - tau);
    }

    /// @dev Realized-vol reading in bps: |mark - ref| / ref against the slow EWMA reference.
    ///      Zero before the reference is seeded (a fresh market's convexity is priced by the
    ///      fresh-market surcharge and the reserve ramp instead).
    function _realizedVolBps(uint256 ref, uint256 mark) private pure returns (uint256) {
        if (ref == 0 || mark == 0) return 0;
        uint256 diff = mark > ref ? mark - ref : ref - mark;
        return diff * BPS_DENOM / ref;
    }

    /// @dev Pending funding (signed, positive = trader owes) and borrow (always owed) for a
    ///      position against the given indices.
    function _pendingOwed(PerpTypes.Position memory pos, int128 fundingXNow, uint128 borrowXNow)
        private
        view
        returns (int256 funding, uint256 borrowFee)
    {
        funding = FundingLib.fundingOwedUsdg(
            pos.size1e18, int256(fundingXNow) - int256(pos.entryFundingX1e18), pos.isLong, usdgScale
        );
        borrowFee = FundingLib.borrowOwedUsdg(
            pos.size1e18, uint256(borrowXNow) - uint256(pos.entryBorrowX1e18), usdgScale
        );
    }

    /// @dev Settle pending funding + borrow into a margin pool. Reverts MarginExhausted when
    ///      the owed amount consumes the whole pool (the position must be liquidated instead).
    ///      Returns the settled pool, the debit paid to the vault, and any funding CREDIT. The
    ///      credit rides the separate unbounded channel (B9): routing it through settleTraderWin
    ///      (bounded by totalReserved) let a dominant-reserve position's credit revert modify ops.
    function _settlePending(PerpTypes.Position memory pos, int128 fundingXNow, uint128 borrowXNow, uint256 marginPool)
        private
        view
        returns (uint256 settled, uint256 toVault, uint256 fundingCredit)
    {
        (int256 fund, uint256 bor) = _pendingOwed(pos, fundingXNow, borrowXNow);
        int256 net = fund + int256(bor);
        if (net > 0) {
            if (uint256(net) >= marginPool) revert MarginExhausted();
            return (marginPool - uint256(net), uint256(net), 0);
        }
        if (net < 0) return (marginPool + uint256(-net), 0, uint256(-net));
        return (marginPool, 0, 0);
    }

    /// @dev Decompose a settlement into vault-ward flows. traderToVault = minus pnl + funding
    ///      + borrow; the trader pays at most its margin (isolated), the excess is bad debt.
    function _splitVaultFlow(int256 pnl, int256 fund, uint256 bor, uint256 margin)
        private
        pure
        returns (uint256 payToVault, uint256 winFromVault, uint256 shortfall)
    {
        int256 traderToVault = -pnl + fund + int256(bor);
        if (traderToVault > 0) {
            uint256 owed = uint256(traderToVault);
            payToVault = owed > margin ? margin : owed;
            shortfall = owed - payToVault;
        } else if (traderToVault < 0) {
            winFromVault = uint256(-traderToVault);
        }
    }

    /// @dev Execute accumulated engine<>vault cash flows once per operation.
    function _flushVaultFlows(VaultFlows memory flows) private {
        _settleWithVault(flows.toVault, flows.fromVault, flows.fundingCredit);
    }

    /// @dev Pay a trader loss into the vault, collect a reserved price win, and pay a funding
    ///      credit. The vault PULLS the loss via transferFrom against the engine's standing
    ///      approval. The reserved win is bounded per position by maxPayout (settleTraderWin);
    ///      the funding credit rides the separate unbounded channel (settleFundingCredit, B9).
    function _settleWithVault(uint256 toVault, uint256 fromVault, uint256 fundingCredit) private {
        if (toVault > 0) {
            vault.settleTraderLoss(toVault);
        }
        if (fromVault > 0) {
            vault.settleTraderWin(address(this), fromVault);
        }
        if (fundingCredit > 0) {
            vault.settleFundingCredit(address(this), fundingCredit);
        }
    }

    /// @dev Split a combined vault-ward win into the RESERVED price payout (bounded per position
    ///      by maxPayout, the manipulation-proof cap) and the FUNDING credit that overflows it
    ///      (unbounded: it is money the opposing side already paid the vault as funding, so it is
    ///      neither a price payout nor subject to the reserve cap, B9). Because the price PnL is
    ///      already clampPnl-bounded to maxPayout before the split, any overflow here is purely
    ///      the funding credit, so the "max PRICE outflow per market <= cap" invariant is intact.
    function _splitReservedWin(uint256 winFromVault, uint256 maxPayout)
        private
        pure
        returns (uint256 reservedWin, uint256 fundingCredit)
    {
        if (winFromVault > maxPayout) {
            return (maxPayout, winFromVault - maxPayout);
        }
        return (winFromVault, 0);
    }

    /// @dev Claim a verified bad-debt shortfall from the InsuranceFund, best effort: a
    ///      reverting or empty fund can never block a close or liquidation.
    function _coverShortfall(address token, address trader, uint256 shortfall) private returns (uint256 covered) {
        if (shortfall == 0) return 0;
        try insuranceFund.cover(shortfall, address(vault)) returns (uint256 c) {
            covered = c > shortfall ? shortfall : c;
        } catch {
            covered = 0;
        }
        // Silence the unused-parameter lint while keeping the call site expressive.
        token;
        trader;
    }

    // ======================================================================
    // Internal: ADL (first pass, spec 6.3)
    // ======================================================================

    /// @dev Absorb an uncovered bad-debt remainder by force-closing profitable positions on the
    ///      OPPOSITE side at a profit haircut (the bankruptcy-price close of spec 6.3, expressed in
    ///      USDG; identical conservation). B6 rework + RB6 gas bound:
    ///        (a) absorption is measured from the ACTUAL vault-outflow reduction, not the nominal
    ///            haircut: a victim the vault owes nothing (e.g. its pending funding/borrow debt
    ///            swallows its price profit) is NON-absorbing and is filtered AT COLLECTION, so
    ///            it can neither consume the victim budget nor spin the selection loop;
    ///        (b) the victim budget counts ABSORBING closes only, so same-side / break-even /
    ///            non-absorbing padding cannot starve ADL of victims inside the scan window;
    ///        (c) candidates are ranked by win0 (actual vault-outflow reduction, FIX-4) so the
    ///            highest-ABSORPTION winners deleverage first (not gross price-profit% * leverage);
    ///        (d) RB6: collection examines at most MAX_ADL_SCAN keys (fixed-size arrays) and at
    ///            most MAX_ADL_VICTIMS victims are closed, so the WHOLE pass is O(constant) gas
    ///            no matter how many dust positions an attacker packs into the market. An OOG
    ///            here would revert the enclosing liquidation exactly during gap stress.
    ///      Any remainder past the scan/victim budget stays a vault-absorbed (LP-socialized) loss
    ///      bounded by the reserve-cap invariant, and is emitted as AdlResidualSocialized.
    /// @return remaining The unabsorbed remainder.
    function _adl(address token, bool badWasLong, uint256 shortfall, uint256 mark) private returns (uint256 remaining) {
        remaining = shortfall;
        (bytes32[] memory cand, uint256[] memory score, uint256 c) = _adlCollect(token, badWasLong, mark);

        // Deleverage up to MAX_ADL_VICTIMS victims, highest score first. Every collected
        // candidate is absorbing at the indices this whole pass settles on, so each iteration
        // spends victim budget; the belt-and-suspenders eff==0 skip still cannot spin: each
        // iteration consumes a candidate and c <= MAX_ADL_SCAN.
        uint256 victims;
        while (remaining > 0 && victims < MAX_ADL_VICTIMS) {
            uint256 best = type(uint256).max;
            for (uint256 j = 0; j < c; ++j) {
                if (cand[j] == bytes32(0)) continue; // already consumed
                if (best == type(uint256).max || score[j] > score[best]) best = j;
            }
            if (best == type(uint256).max) break; // no candidates left
            bytes32 vk = cand[best];
            cand[best] = bytes32(0); // consume this candidate
            uint256 eff = _adlCloseVictim(token, vk, _positions[vk], remaining, mark);
            if (eff == 0) continue; // non-absorbing: skip WITHOUT spending the budget
            remaining -= eff;
            ++victims;
        }

        // RB6: whatever the bounded pass could not absorb is an LP loss by design (spec 6.3),
        // bounded by the per-market reserve cap. Never loop past the budget: emit and return.
        if (remaining > 0) emit AdlResidualSocialized(token, remaining);
    }

    /// @dev RB6 bounded collection: examine at most MAX_ADL_SCAN keys and keep ONLY absorbing
    ///      candidates: opposite-side AND price-profitable AND actually owed a vault outflow at
    ///      haircut zero (winFromVault(0) > 0, i.e. a haircut buys the vault a real saving).
    ///      Same-side, break-even/losing and funding-debt-swallowed positions are dropped here
    ///      so the selection loop never spins on non-absorbing candidates.
    function _adlCollect(address token, bool badWasLong, uint256 mark)
        private
        view
        returns (bytes32[] memory cand, uint256[] memory score, uint256 c)
    {
        EnumerableSet.Bytes32Set storage keys = _marketPositionKeys[token];
        uint256 n = keys.length();
        uint256 scan = n > MAX_ADL_SCAN ? MAX_ADL_SCAN : n;
        cand = new bytes32[](scan);
        score = new uint256[](scan);
        for (uint256 i = 0; i < scan; ++i) {
            bytes32 k = keys.at(i);
            PerpTypes.Position memory p = _positions[k];
            if (p.isLong == badWasLong) continue; // same side: never a victim
            (int256 fund, uint256 bor, int256 pnl) = _adlVictimState(token, p, mark);
            if (pnl <= 0) continue; // break-even / losing: not a victim
            (, uint256 win0,) = _splitVaultFlow(pnl, fund, bor, p.margin);
            if (win0 == 0) continue; // non-absorbing: the vault owes it nothing at this mark
            cand[c] = k;
            // B6c + FIX-4: rank by win0, the ACTUAL vault-outflow reduction a haircut on this
            // victim buys (the real deleveraging value), NOT gross price-profit% * leverage. The
            // gross metric over-ranks a tiny high-leverage winner the vault barely owes over a
            // large low-leverage winner that absorbs far more bad debt; ranking by absorption
            // deleverages the highest-value victims first inside the same bounded 32-victim budget.
            score[c] = win0;
            ++c;
        }
    }

    /// @dev Force-close one profitable opposite-side victim at a price-profit haircut of up to
    ///      `remaining`. Returns the EFFECTIVE absorption: the ACTUAL reduction in vault outflow
    ///      the haircut buys (winFromVault(0) - winFromVault(haircut)), NOT the nominal haircut.
    ///      0 means the victim is non-absorbing (the vault owes it nothing at this mark) and the
    ///      caller must skip it without spending the victim budget (B6a).
    function _adlCloseVictim(address token, bytes32 key, PerpTypes.Position memory pos, uint256 remaining, uint256 mark)
        private
        returns (uint256 haircutEffective)
    {
        (int256 fund, uint256 bor, int256 pnl) = _adlVictimState(token, pos, mark);
        if (pnl <= 0) return 0;
        uint256 nominal = uint256(pnl) > remaining ? remaining : uint256(pnl); // bounded by price profit
        uint256 win0;
        {
            (, win0,) = _splitVaultFlow(pnl, fund, bor, pos.margin);
        }
        (uint256 payToH, uint256 winH,) = _splitVaultFlow(pnl - int256(nominal), fund, bor, pos.margin);
        haircutEffective = win0 > winH ? win0 - winH : 0;
        if (haircutEffective == 0) return 0;
        _adlSettleVictim(token, key, pos, payToH, winH);
        emit AdlExecuted(token, pos.trader, pos.isLong, haircutEffective, mark);
    }

    /// @dev Victim's pending funding/borrow and clamped price PnL at the ADL mark (stack relief).
    function _adlVictimState(address token, PerpTypes.Position memory pos, uint256 mark)
        private
        view
        returns (int256 fund, uint256 bor, int256 pnl)
    {
        PerpTypes.MarketAggregates storage agg = _agg[token];
        (fund, bor) = _pendingOwed(pos, agg.fundingX1e18, agg.borrowX1e18);
        pnl = MarginMathLib.clampPnl(
            MarginMathLib.uPnlUsdg(pos.size1e18, pos.entryPrice1e18, mark, pos.isLong, usdgScale),
            pos.margin,
            pos.maxPayout
        );
    }

    /// @dev Book the haircut close of one ADL victim (effects then interactions, stack relief).
    ///      The paid win is split into the reserved price leg and the funding-credit leg (B9).
    function _adlSettleVictim(
        address token,
        bytes32 key,
        PerpTypes.Position memory pos,
        uint256 payToH,
        uint256 winH
    ) private {
        (uint256 reservedWinH, uint256 creditH) = _splitReservedWin(winH, pos.maxPayout);
        uint256 pot = uint256(pos.margin) - payToH + winH;
        _removePosition(key, token, pos);
        _aggLiquidateFamily(token, pos);
        // Interactions (trusted vault + hookless USDG only). Settle before release: the real vault
        // bounds settleTraderWin by the outstanding totalReserved.
        _settleWithVault(payToH, reservedWinH, creditH);
        vault.releasePayout(token, pos.maxPayout);
        if (pot > 0) usdg.safeTransfer(pos.trader, pot);
    }

    // ======================================================================
    // Internal: position bookkeeping
    // ======================================================================

    /// @dev Position key: one position per (token, trader, side).
    function _positionKey(address token, address trader, bool isLong) private pure returns (bytes32) {
        return keccak256(abi.encode(token, trader, isLong));
    }

    /// @dev Delete a position and its per-market and per-address bookkeeping.
    function _removePosition(bytes32 key, address token, PerpTypes.Position memory pos) private {
        delete _positions[key];
        _marketPositionKeys[token].remove(key);
        _reduceAddressReserved(token, pos.trader, pos.maxPayout);
    }

    /// @dev Reduce the per-address reserved-payout attribution, flooring at zero.
    function _reduceAddressReserved(address token, address trader, uint256 amount) private {
        uint256 current = addressReserved[token][trader];
        addressReserved[token][trader] = current > amount ? current - amount : 0;
    }

    // ======================================================================
    // Internal: THE FOUR AGGREGATE MUTATORS (spec 8.3)
    // ======================================================================
    // These four functions are the only writers of position-accounting aggregate state,
    // each entered exclusively from nonReentrant externals, with no external call between
    // any aggregate read and its write. The invariant suite asserts aggregates equal the
    // sum over open positions after every fuzzed operation sequence.

    /// @dev Open family (open / increase / addMargin): apply a before->after position delta.
    function _aggOpenFamily(address token, PerpTypes.Position memory before, PerpTypes.Position memory after_)
        private
    {
        _applyPositionDelta(token, before, after_);
    }

    /// @dev Close family (close / reduce / removeMargin): apply a before->after position delta.
    function _aggCloseFamily(address token, PerpTypes.Position memory before, PerpTypes.Position memory after_)
        private
    {
        _applyPositionDelta(token, before, after_);
    }

    /// @dev Liquidation family (liquidate / ADL force-close): remove a whole position.
    function _aggLiquidateFamily(address token, PerpTypes.Position memory before) private {
        PerpTypes.Position memory emptyPos;
        _applyPositionDelta(token, before, emptyPos);
    }

    /// @dev Accrual: indices, lastAccrual, cached mark. mark == 0 (blocked) skips the cache.
    function _aggAccrue(address token, int256 fundingDelta, uint256 borrowDelta, uint256 mark) private {
        PerpTypes.MarketAggregates storage agg = _agg[token];
        if (fundingDelta != 0) {
            agg.fundingX1e18 = (int256(agg.fundingX1e18) + fundingDelta).toInt128();
        }
        if (borrowDelta != 0) {
            agg.borrowX1e18 = (uint256(agg.borrowX1e18) + borrowDelta).toUint128();
        }
        agg.lastAccrual = uint64(block.timestamp);
        if (mark != 0) {
            agg.cachedMark1e18 = mark.toUint128();
            agg.cachedMarkAt = uint64(block.timestamp);
        }
        if (fundingDelta != 0 || borrowDelta != 0) emit FundingAccrued(token, fundingDelta, borrowDelta, mark);
    }

    /// @dev Refresh ONLY the cached NAV mark (B4 non-LIVE branch): a FALLBACK ring-median keeps
    ///      NAV fresh without advancing lastAccrual or booking any funding/borrow. A BLOCKED
    ///      print (mark == 0) leaves the cache untouched (dropping it would inflate NAV, spec 4.3).
    function _aggCacheMark(address token, uint256 mark) private {
        if (mark == 0) return;
        PerpTypes.MarketAggregates storage agg = _agg[token];
        agg.cachedMark1e18 = mark.toUint128();
        agg.cachedMarkAt = uint64(block.timestamp);
    }

    /// @dev Shared exact-delta applier used by the three position-mutation families. A
    ///      position's cost contribution is always notionalUsdg(size, entry), recomputed
    ///      before and after, so aggregates equal the positional sums exactly (no rounding
    ///      drift across weighted-entry updates).
    function _applyPositionDelta(address token, PerpTypes.Position memory before, PerpTypes.Position memory after_)
        private
    {
        PerpTypes.MarketAggregates storage agg = _agg[token];
        uint256 costBefore =
            before.size1e18 == 0 ? 0 : MarginMathLib.notionalUsdg(before.size1e18, before.entryPrice1e18, usdgScale);
        uint256 costAfter =
            after_.size1e18 == 0 ? 0 : MarginMathLib.notionalUsdg(after_.size1e18, after_.entryPrice1e18, usdgScale);
        bool isLong = before.size1e18 != 0 ? before.isLong : after_.isLong;
        if (isLong) {
            agg.totalLongSize1e18 =
                (uint256(agg.totalLongSize1e18) + after_.size1e18 - before.size1e18).toUint128();
            agg.totalLongCost = (uint256(agg.totalLongCost) + costAfter - costBefore).toUint128();
            agg.totalLongMargin = (uint256(agg.totalLongMargin) + after_.margin - before.margin).toUint128();
        } else {
            agg.totalShortSize1e18 =
                (uint256(agg.totalShortSize1e18) + after_.size1e18 - before.size1e18).toUint128();
            agg.totalShortCost = (uint256(agg.totalShortCost) + costAfter - costBefore).toUint128();
            agg.totalShortMargin = (uint256(agg.totalShortMargin) + after_.margin - before.margin).toUint128();
        }
        agg.totalMaxPayout = (uint256(agg.totalMaxPayout) + after_.maxPayout - before.maxPayout).toUint128();
    }

    // ======================================================================
    // Internal: preview helpers for views
    // ======================================================================

    /// @dev Best available mark for views: a peekable OK price, else the cached mark.
    function _previewMark(address token) private view returns (uint256) {
        (uint256 p, Types.PriceStatus st) = router.peekPrice(token);
        if (st == Types.PriceStatus.OK && p != 0) return p;
        uint256 cached = _agg[token].cachedMark1e18;
        if (cached == 0) revert NoMark();
        return cached;
    }

    /// @dev Indices simulated to now when the preview print classifies LIVE, else stored.
    function _previewIndices(address token, uint256 mark) private view returns (int128, uint128) {
        PerpTypes.MarketAggregates storage agg = _agg[token];
        uint256 dt = block.timestamp - agg.lastAccrual;
        if (dt == 0 || mark == 0) return (agg.fundingX1e18, agg.borrowX1e18);
        (bool live,) = _previewLiveMark(token);
        if (!live) return (agg.fundingX1e18, agg.borrowX1e18);
        (int256 fundingDelta, uint256 borrowDelta) = _simulateDeltas(token, mark, dt);
        return (
            (int256(agg.fundingX1e18) + fundingDelta).toInt128(),
            (uint256(agg.borrowX1e18) + borrowDelta).toUint128()
        );
    }

    /// @dev Funding and borrow index deltas over `dt` at `mark`, mirroring _accrue exactly.
    function _simulateDeltas(address token, uint256 mark, uint256 dt)
        private
        view
        returns (int256 fundingDelta, uint256 borrowDelta)
    {
        PerpTypes.MarketAggregates storage agg = _agg[token];
        PerpTypes.TierParams memory params = riskConfig.paramsFor(token);
        PerpTypes.VolParams memory vp = riskConfig.volParams();
        uint256 oiLong = MarginMathLib.notionalUsdg(agg.totalLongSize1e18, mark, usdgScale);
        uint256 oiShort = MarginMathLib.notionalUsdg(agg.totalShortSize1e18, mark, usdgScale);
        int256 rate = FundingLib.fundingRatePerHour1e18(
            FundingLib.skew1e18(oiLong, oiShort, skewFloorUsdg), params.kFPerHour1e18
        );
        fundingDelta = FundingLib.fundingIndexDelta1e18(rate, mark, dt);
        // RE-ECON-1 + FIX-2: mirror _accrue's tau-capped vol-scaled borrow exactly (same stored
        // reference, same reading-at-now semantics, same tau split) so previews match the amount
        // the next real accrual books.
        borrowDelta =
            _volBorrowIndexDelta(token, agg.totalMaxPayout, vault.totalAssets(), mark, params.kBPerHour1e18, vp, dt);
    }

    // ======================================================================
    // Internal: points hooks (best effort, never blocking)
    // ======================================================================

    /// @dev Points on the fee-bearing open notional. The v1 IPitPoints surface is p2p-shaped
    ///      (maker/taker); the engine maps trader into all party slots. A perp-native hook is
    ///      flagged to the integrator.
    function _pointsOnFill(address token, uint256 notional) private {
        try points.onFill(msg.sender, msg.sender, msg.sender, token, notional) {}
        catch (bytes memory reason) {
            emit PointsHookFailed(reason);
        }
    }

    /// @dev Points on settlement (close/reduce), notional closed and clamped positive PnL.
    function _pointsOnSettle(address token, uint256 notional, int256 pnl) private {
        uint256 pnlToWinner = pnl > 0 ? uint256(pnl) : 0;
        try points.onSettle(msg.sender, msg.sender, token, notional, pnlToWinner) {}
        catch (bytes memory reason) {
            emit PointsHookFailed(reason);
        }
    }
}
