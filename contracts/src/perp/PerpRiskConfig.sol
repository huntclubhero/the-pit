// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Types} from "../interfaces/Types.sol";
import {IOracleRouter} from "../interfaces/IOracleRouter.sol";
import {PerpTypes} from "./interfaces/PerpTypes.sol";
import {IPerpRiskConfig} from "./interfaces/IPerpRiskConfig.sol";

/// @title PerpRiskConfig: mcap-tiered risk parameters + anti-manipulation tier assignment
/// @notice Implements IPerpRiskConfig (spec sections 3.1, 8.4, 10). Six FDV tiers with a LOCKED
///         maximum-leverage schedule (4x / 6x / 6x / 8x / 10x / 15x). Governance (the 2-day
///         TimelockController, via Ownable2Step) assigns a token's tier at listing with an
///         on-chain FDV sanity assert (FDV = totalSupply * peekPrice must sit inside the asserted
///         band at execution). refreshTier is permissionless and hysteresis bounded (launch 20%
///         past a band edge): DOWNGRADES (less leverage) apply immediately for new opens with NO
///         cooldown (an emergency de-risk must never wait, and a queued upgrade must never delay
///         it); UPGRADES (more leverage) are rate limited to one per token per refreshCooldown
///         (launch 24h), only queue, and require the timelock owner to apply them, so pumping a
///         coin's price can never raise its own leverage cap inside an attack window.
/// @dev Majors (Tier A oracle tokens) receive their tighter MMR / fee / kF / position-cap values
///      through setTokenOverride at listing (suggested: mmr 500 or 333 bps, fees 5/5 bps,
///      kF 0.05%/h, maxPositionMargin 250k USDG). An override can never raise leverage above the
///      LOCKED schedule of the token's CURRENT tier: paramsFor clamps at read time, so a later
///      downgrade also clamps an existing override.
contract PerpRiskConfig is IPerpRiskConfig, Ownable2Step {
    // ================================ constants: tier bands (FDV, USD 1e18) ================================

    /// @notice Number of mcap tiers (index 0 = smallest band = lowest leverage).
    uint8 public constant TIER_COUNT = 6;
    /// @notice Lower FDV edge of tier 1 ($500K).
    uint256 public constant TIER1_FDV_FLOOR_USD1E18 = 500_000e18;
    /// @notice Lower FDV edge of tier 2 ($2M).
    uint256 public constant TIER2_FDV_FLOOR_USD1E18 = 2_000_000e18;
    /// @notice Lower FDV edge of tier 3 ($5M).
    uint256 public constant TIER3_FDV_FLOOR_USD1E18 = 5_000_000e18;
    /// @notice Lower FDV edge of tier 4 ($10M).
    uint256 public constant TIER4_FDV_FLOOR_USD1E18 = 10_000_000e18;
    /// @notice Lower FDV edge of tier 5 ($50M).
    uint256 public constant TIER5_FDV_FLOOR_USD1E18 = 50_000_000e18;

    // ================================ constants: LOCKED leverage schedule ================================

    /// @notice LOCKED max leverage, tier 0 (< $500K): 4x.
    uint32 public constant LOCKED_MAX_LEVERAGE_T0_X100 = 400;
    /// @notice LOCKED max leverage, tier 1 ($500K to $2M): 6x.
    uint32 public constant LOCKED_MAX_LEVERAGE_T1_X100 = 600;
    /// @notice LOCKED max leverage, tier 2 ($2M to $5M): 6x.
    uint32 public constant LOCKED_MAX_LEVERAGE_T2_X100 = 600;
    /// @notice LOCKED max leverage, tier 3 ($5M to $10M): 8x.
    uint32 public constant LOCKED_MAX_LEVERAGE_T3_X100 = 800;
    /// @notice LOCKED max leverage, tier 4 ($10M to $50M): 10x.
    uint32 public constant LOCKED_MAX_LEVERAGE_T4_X100 = 1000;
    /// @notice LOCKED max leverage, tier 5 (> $50M): 15x.
    uint32 public constant LOCKED_MAX_LEVERAGE_T5_X100 = 1500;

    // ================================ constants: launch parameter defaults ================================

    /// @notice Pool-priced MMR defaults per tier, bps of notional (spec 3.1 table).
    uint16 public constant DEFAULT_MMR_T0_BPS = 1500;
    uint16 public constant DEFAULT_MMR_T1_BPS = 1000;
    uint16 public constant DEFAULT_MMR_T2_BPS = 1000;
    uint16 public constant DEFAULT_MMR_T3_BPS = 800;
    uint16 public constant DEFAULT_MMR_T4_BPS = 600;
    uint16 public constant DEFAULT_MMR_T5_BPS = 400;
    /// @notice Pool-priced open/close fee default (10 bps of notional; majors override to 5).
    uint16 public constant DEFAULT_POOL_TRADE_FEE_BPS = 10;
    /// @notice Pool-priced funding coefficient at 100% skew: 0.25% per hour (1e18 scale).
    uint64 public constant DEFAULT_POOL_KF_PER_HOUR_1E18 = 0.0025e18;
    /// @notice Borrow coefficient at 100% utilization: 0.01% per hour (1e18 scale), both sides pay.
    uint64 public constant DEFAULT_KB_PER_HOUR_1E18 = 0.0001e18;
    /// @notice Liquidation penalty default: 100 bps (1%) of notional.
    uint16 public constant DEFAULT_LIQ_PENALTY_BPS = 100;
    /// @notice Per-position margin caps, USDG units (spec 3.5 / 10; majors override to 250k).
    uint128 public constant DEFAULT_MAX_POSITION_MARGIN_T0 = 5_000e6;
    uint128 public constant DEFAULT_MAX_POSITION_MARGIN_T1 = 10_000e6;
    uint128 public constant DEFAULT_MAX_POSITION_MARGIN_T2 = 10_000e6;
    uint128 public constant DEFAULT_MAX_POSITION_MARGIN_T3 = 25_000e6;
    uint128 public constant DEFAULT_MAX_POSITION_MARGIN_T4 = 50_000e6;
    uint128 public constant DEFAULT_MAX_POSITION_MARGIN_T5 = 50_000e6;
    /// @notice Launch payout cap: max payout = 9 * margin (Gains 900% precedent, spec 3.6).
    uint256 public constant DEFAULT_PAYOUT_CAP_MULTIPLE = 9;
    /// @notice Launch global vault utilization cap: 80% of TVL (spec 4.5).
    uint16 public constant DEFAULT_MAX_UTILIZATION_BPS = 8000;
    /// @notice Launch per-market reserve cap: 10% of TVL (spec 3.6).
    uint16 public constant DEFAULT_MARKET_RESERVE_CAP_BPS = 1000;
    /// @notice Launch tier-refresh epoch: one tier change per token per 24h (spec 8.4).
    uint64 public constant DEFAULT_REFRESH_COOLDOWN = 24 hours;
    /// @notice Launch tier-refresh hysteresis: FDV must clear a band edge by 20% (spec 8.4).
    uint16 public constant DEFAULT_HYSTERESIS_BPS = 2000;
    /// @notice Economics v2 vol-pricing launch defaults (finding A2): kVol 1.0 (1 bp surcharge
    ///         per 1 bp of spot-vs-TWAP deviation), surcharge clamp 50 bps, fresh-market
    ///         surcharge 25 bps at listing decaying over the ramp window, kCapVol 25 (25 bps of
    ///         cap discount per bp of deviation: a 200 bps reading, roughly 2x a normal 100 bps
    ///         memecoin deviation, halves capacity), discount clamp 50%.
    uint16 public constant DEFAULT_K_VOL_X100 = 100;
    uint16 public constant DEFAULT_MAX_VOL_SURCHARGE_BPS = 50;
    uint16 public constant DEFAULT_FRESH_SURCHARGE_START_BPS = 25;
    uint16 public constant DEFAULT_K_CAP_VOL_X100 = 2500;
    uint16 public constant DEFAULT_MAX_VOL_DISCOUNT_BPS = 5000;
    /// @notice RE-ECON-1 vol-scaled borrow launch defaults: deadband 300 bps (ordinary
    ///         short-vs-long displacement pays no multiplier, so calm directional traders see
    ///         the plain utilization borrow), slope 4.00x of the base borrow rate per bps of
    ///         reading past the deadband, multiplier clamp 20,000x, and a 12h EWMA time
    ///         constant on the engine's long reference mark. Sizing: a representative
    ///         just-past-breakeven vol event (about 30% displacement, 3,000 bps reading) on a
    ///         reserve-utilized market scales borrow to roughly 1%/h, which over a patient
    ///         multi-hour hold exceeds the straddle's convexity edge on both legs combined;
    ///         the effective rate is additionally hard-capped at 2%/h inside FundingLib no
    ///         matter what governance sets here.
    uint16 public constant DEFAULT_K_BORROW_VOL_X100 = 400;
    uint16 public constant DEFAULT_VOL_BORROW_DEADBAND_BPS = 300;
    uint32 public constant DEFAULT_MAX_VOL_BORROW_MULT_X100 = 2_000_000;
    uint32 public constant DEFAULT_VOL_REF_TAU = 12 hours;

    // ================================ constants: parameter validation bounds ================================

    uint256 private constant BPS = 10_000;
    /// @dev Leverage fixed-point scale: leverageX100 of 100 = 1x.
    uint256 private constant LEVERAGE_SCALE = 100;
    /// @dev Smallest configurable max leverage: 1.1x (the engine's dust floor).
    uint32 private constant MIN_MAX_LEVERAGE_X100 = 110;
    /// @dev Open/close fees can never exceed 1% of notional.
    uint16 private constant MAX_TRADE_FEE_BPS = 100;
    /// @dev Liquidation penalty can never exceed 3% of notional (2x the dYdX ceiling).
    uint16 private constant MAX_LIQ_PENALTY_BPS = 300;
    /// @dev Funding/borrow coefficients can never exceed 2% per hour.
    uint64 private constant MAX_RATE_PER_HOUR_1E18 = 0.02e18;
    /// @dev payoutCapMultiple sane range (spec calibration range is 5x to 15x).
    uint256 private constant MIN_PAYOUT_CAP_MULTIPLE = 2;
    uint256 private constant MAX_PAYOUT_CAP_MULTIPLE = 20;
    /// @dev refreshCooldown sane range.
    uint64 private constant MIN_REFRESH_COOLDOWN = 1 hours;
    uint64 private constant MAX_REFRESH_COOLDOWN = 7 days;
    /// @dev Hysteresis can never exceed 50% of a band edge.
    uint16 private constant MAX_HYSTERESIS_BPS = 5000;
    /// @dev HARD caps on the vol-pricing knobs (timelock tunes only inside these): surcharge
    ///      slope at most 10 bps per bp of deviation, total surcharge at most 2% of notional,
    ///      fresh surcharge at most 1%, cap-discount slope at most 100 bps per bp, and the cap
    ///      discount can never exceed 90% (the market never fully closes to new opens).
    uint16 private constant MAX_K_VOL_X100 = 1000;
    uint16 private constant MAX_MAX_VOL_SURCHARGE_BPS = 200;
    uint16 private constant MAX_FRESH_SURCHARGE_START_BPS = 100;
    uint16 private constant MAX_K_CAP_VOL_X100 = 10_000;
    uint16 private constant MAX_MAX_VOL_DISCOUNT_BPS = 9000;
    /// @dev HARD caps on the RE-ECON-1 vol-scaled borrow knobs: slope at most 20x per bps of
    ///      excess reading, deadband at most 10% (a wider deadband would disarm the layer for
    ///      every realistic event), multiplier clamp at most 50,000x (the 2%/h absolute rate
    ///      ceiling in FundingLib binds long before), and the EWMA time constant, when set,
    ///      inside [1h, 7d] (a shorter tau converges the reference within one event and lets a
    ///      harvester wait it out; a longer one taxes honest traders for days after a genuine
    ///      repricing). Arming the multiplier (kBorrowVolX100 != 0) requires a nonzero tau: a
    ///      zero tau snaps the reference to every accrual mark, which would let per-slice
    ///      poking suppress the reading (the exact dodge this layer closes).
    uint16 private constant MAX_K_BORROW_VOL_X100 = 2_000;
    uint16 private constant MAX_VOL_BORROW_DEADBAND_BPS = 1_000;
    uint32 private constant MAX_MAX_VOL_BORROW_MULT_X100 = 5_000_000;
    uint32 private constant MIN_VOL_REF_TAU = 1 hours;
    uint32 private constant MAX_VOL_REF_TAU = 7 days;

    // ================================ storage ================================

    /// @notice Per-token tier assignment state.
    /// @param assigned True once governance has assigned a tier (paramsFor reverts before that).
    /// @param tier Current tier index (0 = smallest band).
    /// @param lastChangeAt Timestamp of the last tier CHANGE (assign, downgrade, queue, apply);
    ///        refreshTier UPGRADES are rate limited against it (downgrades are exempt).
    /// @param upgradePending True while a permissionless upgrade waits for the timelock owner.
    /// @param pendingUpgradeTier The queued (higher) tier, meaningful only while upgradePending.
    struct TierState {
        bool assigned;
        uint8 tier;
        uint64 lastChangeAt;
        bool upgradePending;
        uint8 pendingUpgradeTier;
    }

    /// @notice The oracle router used for the FDV sanity price (peekPrice, view only).
    IOracleRouter public immutable ROUTER;

    /// @inheritdoc IPerpRiskConfig
    uint256 public override payoutCapMultiple = DEFAULT_PAYOUT_CAP_MULTIPLE;
    /// @inheritdoc IPerpRiskConfig
    uint16 public override maxUtilizationBps = DEFAULT_MAX_UTILIZATION_BPS;
    /// @inheritdoc IPerpRiskConfig
    uint16 public override marketReserveCapBps = DEFAULT_MARKET_RESERVE_CAP_BPS;
    /// @notice Minimum interval between tier UPGRADES of one token via refreshTier (downgrades
    ///         are emergency de-risk moves and are exempt).
    uint64 public refreshCooldown = DEFAULT_REFRESH_COOLDOWN;
    /// @notice Hysteresis in bps: FDV must clear a band edge by this fraction before a refresh.
    uint16 public hysteresisBps = DEFAULT_HYSTERESIS_BPS;
    /// @dev Vol-pricing knobs (economics v2), initialized to the launch defaults in the constructor.
    PerpTypes.VolParams private _volParams;

    mapping(uint8 tier => PerpTypes.TierParams) private _tierDefaults;
    mapping(address token => TierState) private _tierStates;
    mapping(address token => PerpTypes.TierParams) private _overrides;
    /// @notice True when a token has per-token override params (majors do).
    mapping(address token => bool) public hasOverride;

    // ================================ events ================================

    event TierAssigned(address indexed token, uint8 tier, uint256 fdvUsd1e18);
    event TierDowngraded(address indexed token, uint8 fromTier, uint8 toTier, uint256 fdvUsd1e18);
    event TierUpgradeQueued(address indexed token, uint8 fromTier, uint8 toTier, uint256 fdvUsd1e18);
    event TierUpgraded(address indexed token, uint8 fromTier, uint8 toTier, uint256 fdvUsd1e18);
    event TierUpgradeCancelled(address indexed token);
    event TierParamsSet(uint8 indexed tier, PerpTypes.TierParams params);
    event TokenOverrideSet(address indexed token, PerpTypes.TierParams params);
    event TokenOverrideCleared(address indexed token);
    event PayoutCapMultipleSet(uint256 value);
    event MaxUtilizationBpsSet(uint16 value);
    event MarketReserveCapBpsSet(uint16 value);
    event RefreshCooldownSet(uint64 value);
    event HysteresisBpsSet(uint16 value);
    event VolParamsSet(PerpTypes.VolParams params);

    // ================================ errors ================================

    error TierOutOfRange(uint8 tier);
    error TierNotAssigned(address token);
    error PriceUnavailable(address token);
    error FdvOutsideTierBand(address token, uint8 tier, uint256 fdvUsd1e18);
    error NoTierChange(address token);
    error RefreshCooldownActive(address token);
    error HysteresisNotCleared(address token);
    error NoUpgradePending(address token);
    error UpgradeNoLongerSupported(address token);
    error LeverageAboveLockedSchedule(uint8 tier, uint32 maxLeverageX100);
    error InvalidTierParams();
    error ParamOutOfBounds();

    // ================================ constructor ================================

    /// @param router_ The shipped OracleRouter (peekPrice source for FDV asserts).
    /// @param initialOwner The 2-day TimelockController (Ownable2Step handover pattern).
    constructor(IOracleRouter router_, address initialOwner) Ownable(initialOwner) {
        if (address(router_) == address(0)) revert ParamOutOfBounds();
        ROUTER = router_;
        _volParams = PerpTypes.VolParams({
            kVolX100: DEFAULT_K_VOL_X100,
            maxVolSurchargeBps: DEFAULT_MAX_VOL_SURCHARGE_BPS,
            freshSurchargeStartBps: DEFAULT_FRESH_SURCHARGE_START_BPS,
            kCapVolX100: DEFAULT_K_CAP_VOL_X100,
            maxVolDiscountBps: DEFAULT_MAX_VOL_DISCOUNT_BPS,
            kBorrowVolX100: DEFAULT_K_BORROW_VOL_X100,
            volBorrowDeadbandBps: DEFAULT_VOL_BORROW_DEADBAND_BPS,
            maxVolBorrowMultX100: DEFAULT_MAX_VOL_BORROW_MULT_X100,
            volRefTauSeconds: DEFAULT_VOL_REF_TAU
        });
        _tierDefaults[0] = PerpTypes.TierParams({
            maxLeverageX100: LOCKED_MAX_LEVERAGE_T0_X100,
            mmrBps: DEFAULT_MMR_T0_BPS,
            openFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            closeFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            kFPerHour1e18: DEFAULT_POOL_KF_PER_HOUR_1E18,
            kBPerHour1e18: DEFAULT_KB_PER_HOUR_1E18,
            liqPenaltyBps: DEFAULT_LIQ_PENALTY_BPS,
            maxPositionMargin: DEFAULT_MAX_POSITION_MARGIN_T0
        });
        _tierDefaults[1] = PerpTypes.TierParams({
            maxLeverageX100: LOCKED_MAX_LEVERAGE_T1_X100,
            mmrBps: DEFAULT_MMR_T1_BPS,
            openFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            closeFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            kFPerHour1e18: DEFAULT_POOL_KF_PER_HOUR_1E18,
            kBPerHour1e18: DEFAULT_KB_PER_HOUR_1E18,
            liqPenaltyBps: DEFAULT_LIQ_PENALTY_BPS,
            maxPositionMargin: DEFAULT_MAX_POSITION_MARGIN_T1
        });
        _tierDefaults[2] = PerpTypes.TierParams({
            maxLeverageX100: LOCKED_MAX_LEVERAGE_T2_X100,
            mmrBps: DEFAULT_MMR_T2_BPS,
            openFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            closeFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            kFPerHour1e18: DEFAULT_POOL_KF_PER_HOUR_1E18,
            kBPerHour1e18: DEFAULT_KB_PER_HOUR_1E18,
            liqPenaltyBps: DEFAULT_LIQ_PENALTY_BPS,
            maxPositionMargin: DEFAULT_MAX_POSITION_MARGIN_T2
        });
        _tierDefaults[3] = PerpTypes.TierParams({
            maxLeverageX100: LOCKED_MAX_LEVERAGE_T3_X100,
            mmrBps: DEFAULT_MMR_T3_BPS,
            openFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            closeFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            kFPerHour1e18: DEFAULT_POOL_KF_PER_HOUR_1E18,
            kBPerHour1e18: DEFAULT_KB_PER_HOUR_1E18,
            liqPenaltyBps: DEFAULT_LIQ_PENALTY_BPS,
            maxPositionMargin: DEFAULT_MAX_POSITION_MARGIN_T3
        });
        _tierDefaults[4] = PerpTypes.TierParams({
            maxLeverageX100: LOCKED_MAX_LEVERAGE_T4_X100,
            mmrBps: DEFAULT_MMR_T4_BPS,
            openFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            closeFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            kFPerHour1e18: DEFAULT_POOL_KF_PER_HOUR_1E18,
            kBPerHour1e18: DEFAULT_KB_PER_HOUR_1E18,
            liqPenaltyBps: DEFAULT_LIQ_PENALTY_BPS,
            maxPositionMargin: DEFAULT_MAX_POSITION_MARGIN_T4
        });
        _tierDefaults[5] = PerpTypes.TierParams({
            maxLeverageX100: LOCKED_MAX_LEVERAGE_T5_X100,
            mmrBps: DEFAULT_MMR_T5_BPS,
            openFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            closeFeeBps: DEFAULT_POOL_TRADE_FEE_BPS,
            kFPerHour1e18: DEFAULT_POOL_KF_PER_HOUR_1E18,
            kBPerHour1e18: DEFAULT_KB_PER_HOUR_1E18,
            liqPenaltyBps: DEFAULT_LIQ_PENALTY_BPS,
            maxPositionMargin: DEFAULT_MAX_POSITION_MARGIN_T5
        });
    }

    // ================================ tier band views ================================

    /// @notice LOCKED maximum leverage for a tier (schedule is a launch decision, not governance).
    function lockedMaxLeverageX100(uint8 tier) public pure returns (uint32) {
        if (tier == 0) return LOCKED_MAX_LEVERAGE_T0_X100;
        if (tier == 1) return LOCKED_MAX_LEVERAGE_T1_X100;
        if (tier == 2) return LOCKED_MAX_LEVERAGE_T2_X100;
        if (tier == 3) return LOCKED_MAX_LEVERAGE_T3_X100;
        if (tier == 4) return LOCKED_MAX_LEVERAGE_T4_X100;
        if (tier == 5) return LOCKED_MAX_LEVERAGE_T5_X100;
        revert TierOutOfRange(tier);
    }

    /// @notice Lower FDV edge of a tier band (USD 1e18). Tier 0 starts at zero.
    function tierLowerBoundUsd1e18(uint8 tier) public pure returns (uint256) {
        if (tier == 0) return 0;
        if (tier == 1) return TIER1_FDV_FLOOR_USD1E18;
        if (tier == 2) return TIER2_FDV_FLOOR_USD1E18;
        if (tier == 3) return TIER3_FDV_FLOOR_USD1E18;
        if (tier == 4) return TIER4_FDV_FLOOR_USD1E18;
        if (tier == 5) return TIER5_FDV_FLOOR_USD1E18;
        revert TierOutOfRange(tier);
    }

    /// @notice Upper FDV edge of a tier band (USD 1e18). The top tier is unbounded.
    function tierUpperBoundUsd1e18(uint8 tier) public pure returns (uint256) {
        if (tier >= TIER_COUNT) revert TierOutOfRange(tier);
        if (tier == TIER_COUNT - 1) return type(uint256).max;
        return tierLowerBoundUsd1e18(tier + 1);
    }

    /// @notice Raw band mapping from FDV to tier (no hysteresis).
    function tierForFdv(uint256 fdvUsd1e18) public pure returns (uint8) {
        if (fdvUsd1e18 >= TIER5_FDV_FLOOR_USD1E18) return 5;
        if (fdvUsd1e18 >= TIER4_FDV_FLOOR_USD1E18) return 4;
        if (fdvUsd1e18 >= TIER3_FDV_FLOOR_USD1E18) return 3;
        if (fdvUsd1e18 >= TIER2_FDV_FLOOR_USD1E18) return 2;
        if (fdvUsd1e18 >= TIER1_FDV_FLOOR_USD1E18) return 1;
        return 0;
    }

    /// @notice On-chain FDV: totalSupply * peekPrice, normalized to USD 1e18. Reverts unless the
    ///         router serves an OK, nonzero price (the manipulation-resistant settlement reference).
    function fdvOf(address token) public view returns (uint256 fdvUsd1e18) {
        (uint256 price1e18, Types.PriceStatus status) = ROUTER.peekPrice(token);
        if (status != Types.PriceStatus.OK || price1e18 == 0) revert PriceUnavailable(token);
        uint256 supply = IERC20(token).totalSupply();
        uint256 unit = 10 ** IERC20Metadata(token).decimals();
        fdvUsd1e18 = Math.mulDiv(supply, price1e18, unit);
    }

    /// @notice Full tier state for a token (assignment flag, tier, rate-limit anchor, pending upgrade).
    function tierStateOf(address token) external view returns (TierState memory) {
        return _tierStates[token];
    }

    /// @notice Tier default parameters (before any per-token override).
    function tierDefaults(uint8 tier) external view returns (PerpTypes.TierParams memory) {
        if (tier >= TIER_COUNT) revert TierOutOfRange(tier);
        return _tierDefaults[tier];
    }

    // ================================ IPerpRiskConfig views ================================

    /// @inheritdoc IPerpRiskConfig
    /// @dev Returns the per-token override when one exists, else the tier defaults. In both cases
    ///      maxLeverageX100 is clamped to the LOCKED schedule of the token's CURRENT tier, so an
    ///      override written while the token sat in a higher tier can never leak extra leverage
    ///      after a downgrade.
    function paramsFor(address token) external view returns (PerpTypes.TierParams memory) {
        TierState storage st = _tierStates[token];
        if (!st.assigned) revert TierNotAssigned(token);
        PerpTypes.TierParams memory p = hasOverride[token] ? _overrides[token] : _tierDefaults[st.tier];
        uint32 lockedMax = lockedMaxLeverageX100(st.tier);
        if (p.maxLeverageX100 > lockedMax) p.maxLeverageX100 = lockedMax;
        return p;
    }

    /// @inheritdoc IPerpRiskConfig
    function mcapTierOf(address token) external view returns (uint8) {
        TierState storage st = _tierStates[token];
        if (!st.assigned) revert TierNotAssigned(token);
        return st.tier;
    }

    /// @inheritdoc IPerpRiskConfig
    function volParams() external view returns (PerpTypes.VolParams memory) {
        return _volParams;
    }

    // ================================ tier assignment + refresh ================================

    /// @notice Governance (timelock) assigns the initial tier at listing. The on-chain sanity
    ///         assert requires the live FDV to fall inside the asserted tier's band at execution
    ///         (spec 8.4), so a stale or fat-fingered listing proposal cannot grant leverage a
    ///         token's live market cap does not support.
    function assignTier(address token, uint8 tier) external onlyOwner {
        if (tier >= TIER_COUNT) revert TierOutOfRange(tier);
        uint256 fdv = fdvOf(token);
        if (fdv < tierLowerBoundUsd1e18(tier) || fdv >= tierUpperBoundUsd1e18(tier)) {
            revert FdvOutsideTierBand(token, tier, fdv);
        }
        _tierStates[token] = TierState({
            assigned: true,
            tier: tier,
            lastChangeAt: uint64(block.timestamp),
            upgradePending: false,
            pendingUpgradeTier: 0
        });
        emit TierAssigned(token, tier, fdv);
    }

    /// @inheritdoc IPerpRiskConfig
    /// @dev Permissionless. A call only succeeds when it CHANGES state (downgrade applied or
    ///      upgrade queued); a no-change call reverts with NoTierChange and does NOT consume the
    ///      epoch, so nobody can grief the rate limit by spamming no-ops. Hysteresis: the FDV must
    ///      clear the CURRENT tier's band edge by hysteresisBps before any change. Downgrades
    ///      apply immediately with NO cooldown (a token whose FDV craters must lose leverage NOW;
    ///      the hysteresis + monotone-downward direction makes the exemption ungriefable, and a
    ///      queued upgrade consuming lastChangeAt can no longer delay an emergency downgrade); the
    ///      engine reads paramsFor at every open, so new opens see the lower leverage in the same
    ///      block. Upgrades are rate limited to one per refreshCooldown per token, only queue, and
    ///      wait for applyTierUpgrade by the timelock owner. A downgrade still stamps lastChangeAt,
    ///      so a fresh downgrade also pushes the next upgrade out a full cooldown (conservative).
    function refreshTier(address token) external {
        TierState storage st = _tierStates[token];
        if (!st.assigned) revert TierNotAssigned(token);
        uint256 fdv = fdvOf(token);
        uint8 cur = st.tier;
        uint8 target = tierForFdv(fdv);
        if (target == cur) revert NoTierChange(token);
        if (target < cur) {
            uint256 edge = tierLowerBoundUsd1e18(cur);
            if (fdv >= Math.mulDiv(edge, BPS - hysteresisBps, BPS)) revert HysteresisNotCleared(token);
            st.tier = target;
            st.lastChangeAt = uint64(block.timestamp);
            if (st.upgradePending) {
                st.upgradePending = false;
                st.pendingUpgradeTier = 0;
                emit TierUpgradeCancelled(token);
            }
            emit TierDowngraded(token, cur, target, fdv);
        } else {
            if (block.timestamp < st.lastChangeAt + refreshCooldown) revert RefreshCooldownActive(token);
            // target > cur implies cur < TIER_COUNT - 1, so the upper edge is finite.
            uint256 edge = tierUpperBoundUsd1e18(cur);
            if (fdv <= edge + Math.mulDiv(edge, hysteresisBps, BPS)) revert HysteresisNotCleared(token);
            st.upgradePending = true;
            st.pendingUpgradeTier = target;
            st.lastChangeAt = uint64(block.timestamp);
            emit TierUpgradeQueued(token, cur, target, fdv);
        }
    }

    /// @notice Apply a queued tier upgrade. Owner-only, so the 2-day timelock IS the queue delay.
    ///         Re-asserts at execution that the live FDV still supports at least the queued tier
    ///         (a pump that faded during the delay cannot land its upgrade).
    function applyTierUpgrade(address token) external onlyOwner {
        TierState storage st = _tierStates[token];
        if (!st.assigned) revert TierNotAssigned(token);
        if (!st.upgradePending) revert NoUpgradePending(token);
        uint8 pend = st.pendingUpgradeTier;
        uint256 fdv = fdvOf(token);
        if (tierForFdv(fdv) < pend) revert UpgradeNoLongerSupported(token);
        uint8 old = st.tier;
        st.tier = pend;
        st.upgradePending = false;
        st.pendingUpgradeTier = 0;
        st.lastChangeAt = uint64(block.timestamp);
        emit TierUpgraded(token, old, pend, fdv);
    }

    /// @notice Cancel a queued tier upgrade (governance housekeeping).
    function cancelTierUpgrade(address token) external onlyOwner {
        TierState storage st = _tierStates[token];
        if (!st.assigned) revert TierNotAssigned(token);
        if (!st.upgradePending) revert NoUpgradePending(token);
        st.upgradePending = false;
        st.pendingUpgradeTier = 0;
        emit TierUpgradeCancelled(token);
    }

    // ================================ governance parameter setters ================================

    /// @notice Update a tier's default parameters. Leverage can be LOWERED below the locked
    ///         schedule (emergency de-risking) but never raised above it.
    function setTierParams(uint8 tier, PerpTypes.TierParams calldata params) external onlyOwner {
        if (tier >= TIER_COUNT) revert TierOutOfRange(tier);
        _validateParams(params, lockedMaxLeverageX100(tier), tier);
        _tierDefaults[tier] = params;
        emit TierParamsSet(tier, params);
    }

    /// @notice Set per-token override params (majors get their tighter MMR / 5 bps fees / lower kF
    ///         and higher position cap here). Validated against the LOCKED leverage of the token's
    ///         current tier; paramsFor additionally clamps at read time after any later downgrade.
    function setTokenOverride(address token, PerpTypes.TierParams calldata params) external onlyOwner {
        TierState storage st = _tierStates[token];
        if (!st.assigned) revert TierNotAssigned(token);
        _validateParams(params, lockedMaxLeverageX100(st.tier), st.tier);
        _overrides[token] = params;
        hasOverride[token] = true;
        emit TokenOverrideSet(token, params);
    }

    /// @notice Remove a per-token override (token falls back to its tier defaults).
    function clearTokenOverride(address token) external onlyOwner {
        delete _overrides[token];
        hasOverride[token] = false;
        emit TokenOverrideCleared(token);
    }

    /// @notice Set the payout cap multiple (max payout = multiple * margin). Launch 9.
    function setPayoutCapMultiple(uint256 value) external onlyOwner {
        if (value < MIN_PAYOUT_CAP_MULTIPLE || value > MAX_PAYOUT_CAP_MULTIPLE) revert ParamOutOfBounds();
        payoutCapMultiple = value;
        emit PayoutCapMultipleSet(value);
    }

    /// @notice Set the global vault utilization cap in bps of TVL. Launch 8000.
    function setMaxUtilizationBps(uint16 value) external onlyOwner {
        if (value == 0 || value > BPS) revert ParamOutOfBounds();
        maxUtilizationBps = value;
        emit MaxUtilizationBpsSet(value);
    }

    /// @notice Set the per-market reserve cap in bps of TVL. Launch 1000.
    function setMarketReserveCapBps(uint16 value) external onlyOwner {
        if (value == 0 || value > BPS) revert ParamOutOfBounds();
        marketReserveCapBps = value;
        emit MarketReserveCapBpsSet(value);
    }

    /// @notice Set the tier-refresh rate limit. Launch 24h.
    function setRefreshCooldown(uint64 value) external onlyOwner {
        if (value < MIN_REFRESH_COOLDOWN || value > MAX_REFRESH_COOLDOWN) revert ParamOutOfBounds();
        refreshCooldown = value;
        emit RefreshCooldownSet(value);
    }

    /// @notice Set the tier-refresh hysteresis in bps. Launch 2000 (20%).
    function setHysteresisBps(uint16 value) external onlyOwner {
        if (value > MAX_HYSTERESIS_BPS) revert ParamOutOfBounds();
        hysteresisBps = value;
        emit HysteresisBpsSet(value);
    }

    /// @notice Set the vol-pricing knobs (economics v2), timelock-only, each bounded by a HARD
    ///         cap. Zeros are legal (a zero knob disables that lever); the hard caps ensure the
    ///         surcharge can never become punitive (2% max) and the cap discount can never fully
    ///         close a market to new opens (90% max).
    function setVolParams(PerpTypes.VolParams calldata p) external onlyOwner {
        if (
            p.kVolX100 > MAX_K_VOL_X100 || p.maxVolSurchargeBps > MAX_MAX_VOL_SURCHARGE_BPS
                || p.freshSurchargeStartBps > MAX_FRESH_SURCHARGE_START_BPS || p.kCapVolX100 > MAX_K_CAP_VOL_X100
                || p.maxVolDiscountBps > MAX_MAX_VOL_DISCOUNT_BPS
        ) revert ParamOutOfBounds();
        // RE-ECON-1 vol-scaled borrow knobs: bounded slopes/clamps, tau (when set) inside its
        // window, and the multiplier can never be armed without a tau (a zero tau snaps the
        // engine's reference to every accrual mark, reintroducing the per-slice suppression
        // dodge this layer exists to close).
        if (
            p.kBorrowVolX100 > MAX_K_BORROW_VOL_X100 || p.volBorrowDeadbandBps > MAX_VOL_BORROW_DEADBAND_BPS
                || p.maxVolBorrowMultX100 > MAX_MAX_VOL_BORROW_MULT_X100
        ) revert ParamOutOfBounds();
        if (p.volRefTauSeconds != 0 && (p.volRefTauSeconds < MIN_VOL_REF_TAU || p.volRefTauSeconds > MAX_VOL_REF_TAU)) {
            revert ParamOutOfBounds();
        }
        if (p.kBorrowVolX100 != 0 && p.volRefTauSeconds == 0) revert ParamOutOfBounds();
        _volParams = p;
        emit VolParamsSet(p);
    }

    // ================================ internal ================================

    /// @dev Full sanity validation of a TierParams struct against a tier's locked leverage:
    ///      leverage inside [1.1x, locked schedule]; MMR nonzero, below 100%, and strictly below
    ///      the initial margin at max leverage (mmr < 1 / L so a fresh max-leverage position
    ///      always opens with real distance to liquidation); fees and penalty bounded; funding and
    ///      borrow coefficients bounded; nonzero position cap.
    function _validateParams(PerpTypes.TierParams calldata p, uint32 lockedMax, uint8 tier) private pure {
        if (p.maxLeverageX100 > lockedMax) revert LeverageAboveLockedSchedule(tier, p.maxLeverageX100);
        if (p.maxLeverageX100 < MIN_MAX_LEVERAGE_X100) revert InvalidTierParams();
        if (p.mmrBps == 0 || p.mmrBps >= BPS) revert InvalidTierParams();
        // mmr < 1 / L  <=>  mmrBps * maxLeverageX100 < BPS * LEVERAGE_SCALE
        if (uint256(p.mmrBps) * uint256(p.maxLeverageX100) >= BPS * LEVERAGE_SCALE) revert InvalidTierParams();
        if (p.openFeeBps > MAX_TRADE_FEE_BPS || p.closeFeeBps > MAX_TRADE_FEE_BPS) revert InvalidTierParams();
        if (p.liqPenaltyBps > MAX_LIQ_PENALTY_BPS) revert InvalidTierParams();
        if (p.kFPerHour1e18 > MAX_RATE_PER_HOUR_1E18 || p.kBPerHour1e18 > MAX_RATE_PER_HOUR_1E18) {
            revert InvalidTierParams();
        }
        if (p.maxPositionMargin == 0) revert InvalidTierParams();
    }
}
