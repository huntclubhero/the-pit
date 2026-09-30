// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Types} from "../interfaces/Types.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {IOracleRouter} from "../interfaces/IOracleRouter.sol";
import {IPitPoints} from "../interfaces/IPitPoints.sol";
import {PauseGuardian} from "./PauseGuardian.sol";

/// @title Market: per-token peer to peer capped-payout long/short market for THE PIT
/// @notice Holds the USDG escrow for resting offers and open positions on a single
///         underlying token. Makers post collateralized offers at a chosen payoff
///         multiple AND a chosen payoff ratio (the ODDS): a maker may post more (or equal)
///         collateral than the taker so the taker wins a larger multiple of its own stake.
///         Takers fill slices of an offer, escrow the PROPORTIONAL taker collateral, and
///         take the opposite side. At fill time an entry fee of ENTRY_FEE_BPS (10 bps) of
///         each side's OWN notional is charged to BOTH sides, so opening a position always
///         has a real cost even on a gas-free chain. Positions settle at the oracle
///         composite price: the winner wins up to the LOSER's stake and the loser loses up
///         to its OWN stake, so neither side can ever lose more than it escrowed and the
///         winner can never take more than the total position escrow.
/// @dev Deployed exclusively by MarketFactory; every protocol parameter is immutable per
///      market instance. All state-mutating externals are nonReentrant and follow strict
///      checks-effects-interactions. Points hooks are best-effort: a reverting points
///      engine can never block a fill or a settlement. A 1:1 offer (payoffRatioBps ==
///      BPS_DENOM) reproduces the old symmetric equal-collateral behavior EXACTLY.
contract Market is IMarket, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ======================================================================
    // Constants (fixed in v1, see IMarket params note)
    // ======================================================================

    /// @notice Minimum time after open before either party can settle.
    uint256 public constant MIN_HOLD = 30 minutes;
    /// @notice After expiry plus this delay, a position with a broken oracle is
    ///         force-unwound: both sides refunded exactly their own stake, zero fee.
    uint256 public constant MAX_SETTLE_DELAY = 24 hours;
    /// @notice Hard ceiling on the settlement fee, in basis points of the loser's notional (1%).
    ///         The per-market settlementFeeBps is validated against this at construction and can
    ///         NEVER exceed it, so the factory owner can never bake an exorbitant settlement fee
    ///         into a market: user protection that the governance-tunable rate cannot override.
    uint256 public constant MAX_FEE_BPS = 100;
    /// @notice Entry fee in basis points of notional, charged to EACH side at fill
    ///         time and deducted from that side's own gross fill collateral. The stake
    ///         each side escrows is its gross fill collateral minus its own entry fee.
    ///         Fixed (anti-wash), never governance-tunable, unlike the settlement fee.
    uint256 public constant ENTRY_FEE_BPS = 10;
    /// @notice Basis point denominator. Also the 1:1 (symmetric) payoff ratio.
    uint256 public constant BPS_DENOM = 10_000;
    /// @notice Jackpot share of every fee (entry and settlement), in basis points of the fee.
    uint256 public constant FEE_SHARE_JACKPOT_BPS = 2_500;
    /// @notice Referral pool share of every fee, in basis points of the fee.
    uint256 public constant FEE_SHARE_REFERRAL_BPS = 1_000;
    /// @notice Buyback-and-burn share of every fee, in basis points of the fee. Accrues to the
    ///         buyback recipient in USDG; the separate Buyback executor later swaps it for $PIT and
    ///         burns it. Treasury takes the remaining share (2_600 bps) plus the round-down dust.
    uint256 public constant FEE_SHARE_BUYBACK_BPS = 3_900;
    /// @notice Minimum position duration.
    uint256 public constant MIN_DURATION = 1 hours;
    /// @notice Maximum position duration.
    uint256 public constant MAX_DURATION = 30 days;
    /// @notice Maximum payoff multiple (price-move sensitivity).
    uint256 public constant MAX_MULTIPLE = 10;
    /// @notice Maximum payoff ratio (maker collateral per taker collateral), in basis points.
    /// @dev 200_000 bps = 20:1. A maker may post at most 20x the taker's stake, so a taker
    ///      winning at maximum odds turns its stake into at most ~21x (its own stake plus the
    ///      maker's up-to-20x stake, minus fee): a Hyperliquid-class upside hook while keeping the
    ///      maker's liability, the total position escrow, and hence the maximum single-position
    ///      payout firmly bounded by the cost-to-move and OI caps. Bounding the ratio also prevents
    ///      a maker from concentrating almost the entire OI cap into one taker's max-payout claim
    ///      from a negligible stake. BPS_DENOM (10_000, 1:1) is the floor: a maker never posts less
    ///      than the taker, so the maker always offers the odds and the taker always takes them.
    uint256 public constant MAX_PAYOFF_RATIO_BPS = 200_000;

    /// @notice Hard ceiling on the anti-monopolization open bond, in basis points of a fill's total
    ///         open interest (5%). The per-market openBondBps is validated against this at
    ///         construction and can NEVER exceed it, so the factory owner can never bake a punitive
    ///         open cost into a market: user protection the governance-tunable rate cannot override.
    uint256 public constant MAX_OPEN_BOND_BPS = 500;

    // ======================================================================
    // Immutable configuration (set once by the factory)
    // ======================================================================

    /// @notice USDG collateral token.
    IERC20 public immutable usdg;
    /// @notice Oracle router used for entry and settlement prices, OI liquidity, and
    ///         the liquidity floor.
    IOracleRouter public immutable router;
    /// @notice Points engine; every call to it is wrapped in try/catch.
    IPitPoints public immutable points;
    /// @notice Pause guardian consulted before fills and settlement.
    PauseGuardian public immutable guardian;
    /// @notice Jackpot fee recipient (FEE_SHARE_JACKPOT_BPS, 25% of every fee).
    address public immutable feeJackpot;
    /// @notice Treasury fee recipient (26% of every fee plus the round-down dust).
    address public immutable feeTreasury;
    /// @notice Referral pool fee recipient (FEE_SHARE_REFERRAL_BPS, 10% of every fee).
    address public immutable feeReferralPool;
    /// @notice Buyback fee recipient (FEE_SHARE_BUYBACK_BPS, 39% of every fee). Only RECEIVES USDG
    ///         here; the separate Buyback executor swaps it for $PIT and burns it at launch time.
    address public immutable feeBuyback;
    /// @notice Settlement fee in basis points of the loser's notional, charged out of realized
    ///         winnings only. Baked immutable at creation and bounded by MAX_FEE_BPS. Governance
    ///         (the factory owner) can change the value used by FUTURE markets, but a live market's
    ///         rate is fixed for its lifetime.
    /// @dev STAKING-TIER HOOK (economics increment E2, future): once the $PIT staking contract
    ///      exists, the settlement fee can become a function of the settling trader's staked tier.
    ///      That per-trader fee-rate hook plugs in at fee computation in _settleDecisive (replace the
    ///      flat settlementFeeBps read with a tiered rate keyed on the trader's stake); this flat
    ///      immutable is the tier-0 (unstaked) rate. The token, staking, and Buyback executor are all
    ///      later launch-time artifacts and are intentionally not built here.
    uint256 public immutable settlementFeeBps;
    /// @notice Open interest cap in basis points of the creation liquidity snapshot (1_000 = 10%).
    uint16 public immutable oiCapBps;
    /// @notice Per-address open-interest sub-cap, in basis points of the market OI cap
    ///         (2_500 = 25%). Bounds the open escrow (own posted stake) a single participant may
    ///         hold as maker or as taker, so two colluding addresses cannot monopolize the whole OI
    ///         cap.
    uint16 public immutable perAddressOiCapBps;
    /// @notice Anti-monopolization open bond, in basis points of a fill's total open interest
    ///         (makerStake + takerStake), charged NONREFUNDABLY to the taker at fill and routed to
    ///         the treasury. Zero (the default) disables it. Because the cost scales with the OI a
    ///         fill consumes REGARDLESS of how many addresses split it, it puts a real, unavoidable
    ///         price on consuming the market OI cap (wave-2 W2-9: a per-address bps sub-cap alone
    ///         cannot stop N free Sybil addresses from monopolizing the cap on a gas-free chain).
    ///         An honest single trader opening a small position pays only this small bps of its own
    ///         (small) OI; a Sybil monopolizing the whole cap pays it on the whole cap. Bounded by
    ///         MAX_OPEN_BOND_BPS and immutable per market; governance sets the value for future
    ///         markets and arms it on thin/new markets where monopolization is cheapest.
    uint16 public immutable openBondBps;
    /// @notice Tracked liquidity snapshot (1e18 USDG terms) taken at market creation. This is the
    ///         SOLE liquidity-derived basis for the OI cap: it is captured once and is immutable, so
    ///         single-block just-in-time liquidity movement can neither raise the cap nor block
    ///         fills.
    uint256 public immutable liquiditySnapshot1e18;
    /// @notice Absolute cost-to-move payout cap (1e18 USD) baked at creation by the factory from
    ///         the oracle router's tier config: maxMarketPayoutCap = costToMove / safetyFactor. The
    ///         effective OI cap is the MIN of the oiCapBps-of-snapshot cap and this absolute cap, so
    ///         the maximum payout any single position can ever produce is bounded by it (see
    ///         _checkedNewOpenInterest for the OI-to-payout mapping). type(uint256).max means
    ///         "no absolute cap": majors (Tier A) are priced by an independent feed and need no
    ///         cost-to-move bound, so their cap is governed solely by oiCapBps.
    uint256 public immutable maxPayoutCap1e18;
    /// @notice Multiplier converting native USDG collateral units to 1e18 scale, used
    ///         only when comparing open interest against 1e18-scaled liquidity.
    uint256 public immutable collateralScale;

    /// @dev Underlying token address; exposed via token().
    address private immutable _underlying;

    // ======================================================================
    // Storage
    // ======================================================================

    /// @notice Next offer id to be assigned; ids start at 0.
    uint256 public nextOfferId;
    /// @notice Next position id to be assigned; ids start at 0.
    uint256 public nextPositionId;

    /// @dev Total escrowed collateral (native USDG units) of OPEN positions, both
    ///      legs, NET of entry fees: always sum(longStake + shortStake) over open
    ///      positions, because entry fees leave escrow in the fill transaction and
    ///      are never part of open interest (the NET convention, applied everywhere).
    ///      Because it counts TOTAL per-position escrow, any single position's own
    ///      longStake + shortStake is at most this accumulator, which is the basis of the
    ///      cost-to-move max-payout bound (see _checkedNewOpenInterest).
    uint256 private _openInterest;

    /// @dev Open escrow (native USDG units, NET of entry fees) attributable to each address as a
    ///      position party: the sum of that address's OWN posted stake over its OPEN positions,
    ///      counting only the side it holds. Incremented for both parties at fill (each by its own
    ///      stake), decremented for both parties at settle or forced unwind. Enforced against the
    ///      per-address OI sub-cap. Summed over all addresses it equals _openInterest exactly.
    mapping(address participant => uint256 openCollateral) private _addressOpenCollateral;

    /// @dev Withdrawable USDG (native units) credited to an address by settlement or forced
    ///      unwind. Settlement and unwind CREDIT here instead of pushing, so a frozen or blocked
    ///      recipient can never revert the settlement or strand the counterparty; each address
    ///      pulls its own balance via withdraw().
    mapping(address account => uint256 amount) private _credit;

    /// @dev Sum of all unwithdrawn credit balances. Lets the escrow-solvency invariant account
    ///      for settled-but-unwithdrawn payouts still held by the market.
    uint256 private _totalCredit;

    mapping(uint256 offerId => Types.Offer) private _offers;
    mapping(uint256 positionId => Types.Position) private _positions;

    /// @dev Scratch bundle for the asymmetric-collateral fill math, kept in memory so fillOffer
    ///      stays within the stack limit. All fields are derived purely from the offer terms and
    ///      the requested maker-collateral fill; see fillOffer NatSpec for the formulas.
    struct FillMath {
        uint256 takerGross; // gross taker collateral posted (== fillCollateral at 1:1)
        uint256 feeMaker; // maker entry fee on its own gross notional
        uint256 feeTaker; // taker entry fee on its own gross notional
        uint128 makerStake; // maker net stake (fillCollateral - feeMaker)
        uint128 takerStake; // taker net stake (takerGross - feeTaker)
    }

    // ======================================================================
    // Errors
    // ======================================================================

    /// @notice A zero address was supplied for a required parameter.
    error ZeroAddress();
    /// @notice The OI cap must be in (0, 10_000] basis points.
    error InvalidOiCap();
    /// @notice The per-address OI sub-cap must be in (0, 10_000] basis points of the OI cap.
    error InvalidPerAddressOiCap();
    /// @notice The settlement fee exceeds MAX_FEE_BPS, the hard cap protecting users.
    error SettlementFeeTooHigh();
    /// @notice The open bond exceeds MAX_OPEN_BOND_BPS, the hard cap protecting users.
    error OpenBondTooHigh();
    /// @notice USDG reports more than 18 decimals, which the OI scaling cannot handle.
    error UnsupportedDecimals();
    /// @notice Offer collateral must be nonzero.
    error ZeroCollateral();
    /// @notice minFill must be nonzero and at most the offer collateral.
    error InvalidMinFill();
    /// @notice multiple must be an integer in 1..10.
    error InvalidMultiple();
    /// @notice payoffRatioBps must be in [BPS_DENOM, MAX_PAYOFF_RATIO_BPS] (1:1 up to the ceiling).
    error InvalidPayoffRatio();
    /// @notice duration must be within [1 hour, 30 days].
    error InvalidDuration();
    /// @notice offerExpiry must be strictly in the future.
    error ExpiryInPast();
    /// @notice Caller is not the maker of the offer.
    error NotMaker();
    /// @notice The offer is cancelled, expired, or does not exist.
    error OfferNotLive();
    /// @notice The offer was already cancelled.
    error OfferAlreadyCancelled();
    /// @notice fillCollateral is below the offer's minFill.
    error FillBelowMin();
    /// @notice fillCollateral exceeds the offer's remaining collateral.
    error FillExceedsRemaining();
    /// @notice The fill is dust: one side's 10 bps entry fee rounds down to zero (or, in the
    ///         defensive limit, would consume that side's entire stake), so no position with a
    ///         real fee-paying escrow on both sides can be created from it.
    error EntryFeeExceedsCollateral();

    error SelfFill();
    /// @notice The oracle did not return an OK status.
    error OracleNotOk(Types.PriceStatus status);
    /// @notice The oracle returned a zero price, which cannot be used as an entry.
    error ZeroPrice();
    /// @notice The oracle entry price violates the maker's limitEntry1e18.
    error LimitEntryViolated(uint256 entryPrice1e18, uint128 limitEntry1e18);
    /// @notice The fill would push open interest above the OI cap.
    error OiCapExceeded(uint256 newOpenInterest, uint256 cap);
    /// @notice The fill would push a single participant's open escrow above the per-address OI
    ///         sub-cap (native USDG units scaled to 1e18 versus the 1e18 sub-cap).
    error PerAddressOiCapExceeded(address participant, uint256 openCollateral1e18, uint256 subCap1e18);
    /// @notice The market is paused (individually or globally).
    error MarketPaused();
    /// @notice Opening a NEW position is paused because the oracle's spot-vs-TWAP deviation breaker
    ///         tripped: current spot has dislocated from the settlement TWAP beyond the token's
    ///         threshold. This gates OPENING ONLY; settlement, close, and forced unwind are never
    ///         blocked by it. The reason code mirrors IOracleRouter.openingAllowed.
    error OpeningPausedByDeviation(uint8 reason);
    /// @notice The position does not exist.
    error UnknownPosition();
    /// @notice The position was already settled.
    error PositionAlreadySettled();
    /// @notice Before expiry, only the long or short party may settle.
    error NotPositionParty();
    /// @notice Position parties must wait MIN_HOLD after open before settling.
    error MinHoldNotReached(uint256 settleableAt);
    /// @notice withdraw() was called by an address with no credited balance.
    error NothingToWithdraw();
    /// @notice pushFee was called by an address other than this contract.
    error OnlySelf();

    // ======================================================================
    // Events
    // ======================================================================

    /// @notice A maker posted a new offer and escrowed collateral.
    event OfferPosted(
        uint256 indexed offerId,
        address indexed maker,
        Types.Side makerSide,
        uint128 collateral,
        uint128 minFill,
        uint16 multiple,
        uint32 payoffRatioBps,
        uint32 duration,
        uint64 offerExpiry,
        uint128 limitEntry1e18
    );

    /// @notice A maker cancelled an offer; remaining collateral was refunded.
    event OfferCancelled(uint256 indexed offerId, address indexed maker, uint128 refunded);

    /// @notice A taker filled a slice of an offer, creating a position. `fillCollateral` is the
    ///         MAKER collateral consumed; `takerCollateral` is the gross collateral the taker
    ///         posted (equal at 1:1, smaller under asymmetric odds).
    event OfferFilled(
        uint256 indexed offerId,
        uint256 indexed positionId,
        address indexed taker,
        address maker,
        uint128 fillCollateral,
        uint128 takerCollateral,
        uint128 entryPrice1e18
    );

    /// @notice Entry fees charged on a fill, one per side on that side's own gross notional. The
    ///         maker paid `feeMaker` out of the consumed offer collateral and opened with
    ///         `makerStake`; the taker paid `feeTaker` out of its posted collateral and opened with
    ///         `takerStake`. An indexer reconstructs the exact fee flow as: total entry fee =
    ///         feeMaker + feeTaker, transferred out in the fill transaction with the standard 25%
    ///         jackpot / 10% referral / 39% buyback / 26% treasury split (round-down shares, dust
    ///         remainder to treasury, identical to the settlement fee split).
    event EntryFeeCharged(
        uint256 indexed offerId,
        uint256 indexed positionId,
        uint256 feeMaker,
        uint256 feeTaker,
        uint128 makerStake,
        uint128 takerStake
    );

    /// @notice A position settled at an oracle price. On a flat settlement (zero clamped PnL)
    ///         winner and loser are both address(0), the fee is zero, `pnl` is 0, and the two payout
    ///         fields carry each side's own stake refund (winnerPayout = longStake,
    ///         loserPayout = shortStake). On a decisive settlement `pnl` is the amount transferred
    ///         from the loser to the winner (winnings), `winnerPayout` is the winner's total credit,
    ///         and `loserPayout` is the loser's remaining stake.
    event PositionSettled(
        uint256 indexed positionId,
        address indexed winner,
        address loser,
        uint256 exitPrice1e18,
        uint256 pnl,
        uint256 fee,
        uint256 winnerPayout,
        uint256 loserPayout
    );

    /// @notice A position past expiry plus MAX_SETTLE_DELAY with a broken oracle was
    ///         neutrally unwound: each party refunded its own stake, zero fee.
    event ForcedUnwind(
        uint256 indexed positionId, address longParty, address shortParty, uint256 longRefund, uint256 shortRefund
    );

    /// @notice A settlement or forced unwind credited `amount` USDG to `account`'s withdrawable
    ///         balance. Payouts are credited, never pushed, so a frozen recipient can never revert
    ///         the settlement or strand the counterparty. The credit is realized via withdraw().
    event PayoutCredited(uint256 indexed positionId, address indexed account, uint256 amount);

    /// @notice An account pulled its full credited balance out of the market.
    event Withdrawn(address indexed account, uint256 amount);

    /// @notice A fee-split push to a protocol recipient failed (frozen or blocked recipient), so the
    ///         share was credited to the recipient's withdrawable balance instead (wave-2 W2-12).
    ///         The recipient realizes it via withdraw(); the four shares still sum exactly to the fee.
    event FeeCredited(address indexed recipient, uint256 amount);

    /// @notice A nonrefundable anti-monopolization open bond was charged to the taker at fill and
    ///         routed to the treasury (wave-2 W2-9). Zero-bond markets never emit this.
    event OpenBondCharged(uint256 indexed positionId, address indexed payer, uint256 amount);

    /// @notice A points hook reverted; the fill or settlement proceeded regardless.
    event PointsHookFailed(bytes reason);

    // ======================================================================
    // Constructor
    // ======================================================================

    /// @param underlying_ Underlying ERC-20 whose price the market speculates on.
    /// @param usdg_ USDG collateral token.
    /// @param router_ Oracle router.
    /// @param points_ Points engine.
    /// @param feeSplit_ Protocol fee recipients (jackpot 25%, referral 10%, buyback 39%, treasury
    ///        26% plus dust), applied to every entry and settlement fee.
    /// @param oiCapBps_ Open interest cap in basis points of the creation liquidity snapshot.
    /// @param perAddressOiCapBps_ Per-address OI sub-cap in basis points of the market OI cap.
    /// @param guardian_ PauseGuardian consulted for fills and settlement.
    /// @param liquiditySnapshot1e18_ Tracked liquidity snapshot at market creation.
    /// @param maxPayoutCap1e18_ Absolute cost-to-move payout cap (1e18 USD); type(uint256).max for
    ///        an unbounded (Tier A) market. The effective OI cap is min(oiCapBps-of-snapshot cap,
    ///        this), which bounds the maximum single-position payout by this value.
    /// @param settlementFeeBps_ Settlement fee for THIS market, in basis points of the loser's
    ///        notional. Baked immutable and validated at or below MAX_FEE_BPS; the factory owner sets
    ///        the value used by future markets.
    /// @param openBondBps_ Anti-monopolization open bond, basis points of a fill's total OI, charged
    ///        nonrefundably to the taker at fill (0 disables). Validated at or below
    ///        MAX_OPEN_BOND_BPS; the factory owner sets the value used by future markets.
    constructor(
        address underlying_,
        address usdg_,
        address router_,
        address points_,
        Types.FeeSplit memory feeSplit_,
        uint16 oiCapBps_,
        uint16 perAddressOiCapBps_,
        address guardian_,
        uint256 liquiditySnapshot1e18_,
        uint256 maxPayoutCap1e18_,
        uint256 settlementFeeBps_,
        uint16 openBondBps_
    ) {
        if (
            underlying_ == address(0) || usdg_ == address(0) || router_ == address(0) || points_ == address(0)
                || feeSplit_.jackpot == address(0) || feeSplit_.treasury == address(0)
                || feeSplit_.referralPool == address(0) || feeSplit_.buyback == address(0) || guardian_ == address(0)
        ) revert ZeroAddress();
        if (oiCapBps_ == 0 || oiCapBps_ > BPS_DENOM) revert InvalidOiCap();
        if (perAddressOiCapBps_ == 0 || perAddressOiCapBps_ > BPS_DENOM) revert InvalidPerAddressOiCap();
        if (settlementFeeBps_ > MAX_FEE_BPS) revert SettlementFeeTooHigh();
        if (openBondBps_ > MAX_OPEN_BOND_BPS) revert OpenBondTooHigh();

        uint8 decimals = IERC20Metadata(usdg_).decimals();
        if (decimals > 18) revert UnsupportedDecimals();

        _underlying = underlying_;
        usdg = IERC20(usdg_);
        router = IOracleRouter(router_);
        points = IPitPoints(points_);
        guardian = PauseGuardian(guardian_);
        feeJackpot = feeSplit_.jackpot;
        feeTreasury = feeSplit_.treasury;
        feeReferralPool = feeSplit_.referralPool;
        feeBuyback = feeSplit_.buyback;
        settlementFeeBps = settlementFeeBps_;
        oiCapBps = oiCapBps_;
        perAddressOiCapBps = perAddressOiCapBps_;
        openBondBps = openBondBps_;
        liquiditySnapshot1e18 = liquiditySnapshot1e18_;
        maxPayoutCap1e18 = maxPayoutCap1e18_;
        collateralScale = 10 ** (18 - decimals);
    }

    // ======================================================================
    // Book
    // ======================================================================

    /// @inheritdoc IMarket
    /// @notice Post a resting offer at chosen odds. The maker escrows `collateral` USDG immediately.
    /// @dev Validation: multiple in 1..10, payoffRatioBps in [BPS_DENOM, MAX_PAYOFF_RATIO_BPS],
    ///      duration in [1 hour, 30 days], offerExpiry in the future, 0 < minFill <= collateral,
    ///      collateral > 0. payoffRatioBps == BPS_DENOM (1:1) is the symmetric case.
    function postOffer(
        Types.Side makerSide,
        uint128 collateral,
        uint128 minFill,
        uint16 multiple,
        uint32 payoffRatioBps,
        uint32 duration,
        uint64 offerExpiry,
        uint128 limitEntry1e18
    ) external nonReentrant returns (uint256 offerId) {
        if (collateral == 0) revert ZeroCollateral();
        if (minFill == 0 || minFill > collateral) revert InvalidMinFill();
        if (multiple == 0 || multiple > MAX_MULTIPLE) revert InvalidMultiple();
        if (payoffRatioBps < BPS_DENOM || payoffRatioBps > MAX_PAYOFF_RATIO_BPS) revert InvalidPayoffRatio();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();
        if (offerExpiry <= block.timestamp) revert ExpiryInPast();

        offerId = nextOfferId++;
        _offers[offerId] = Types.Offer({
            maker: msg.sender,
            token: _underlying,
            makerSide: makerSide,
            collateralRemaining: collateral,
            minFill: minFill,
            multiple: multiple,
            payoffRatioBps: payoffRatioBps,
            duration: duration,
            offerExpiry: offerExpiry,
            limitEntry1e18: limitEntry1e18,
            cancelled: false
        });

        emit OfferPosted(
            offerId,
            msg.sender,
            makerSide,
            collateral,
            minFill,
            multiple,
            payoffRatioBps,
            duration,
            offerExpiry,
            limitEntry1e18
        );

        usdg.safeTransferFrom(msg.sender, address(this), collateral);
    }

    /// @inheritdoc IMarket
    /// @notice Cancel an offer and refund its remaining collateral to the maker.
    /// @dev Maker only. A fully filled offer can still be cancelled (zero refund) to
    ///      mark it dead. Cancelling twice reverts.
    function cancelOffer(uint256 offerId) external nonReentrant {
        Types.Offer storage offer = _offers[offerId];
        if (offer.maker != msg.sender) revert NotMaker();
        if (offer.cancelled) revert OfferAlreadyCancelled();

        uint128 refund = offer.collateralRemaining;
        offer.cancelled = true;
        offer.collateralRemaining = 0;

        emit OfferCancelled(offerId, msg.sender, refund);

        if (refund > 0) {
            usdg.safeTransfer(msg.sender, refund);
        }
    }

    /// @inheritdoc IMarket
    /// @notice Fill a slice of a live offer. `fillCollateral` is the amount of MAKER collateral to
    ///         consume; the taker posts the PROPORTIONAL taker collateral for the offer's odds and
    ///         takes the side opposite the maker's. An entry fee of ENTRY_FEE_BPS (10 bps) of each
    ///         side's OWN gross notional is charged to that side at fill and leaves escrow
    ///         immediately; each side opens with its stake net of its own fee.
    /// @dev Gates (fills only, never settlement): market not paused; oracle status OK
    ///      with a nonzero price; maker's limitEntry respected (LONG maker: entry at or
    ///      below limit, SHORT maker: entry at or above limit); post-fill total open
    ///      interest within oiCapBps of the CREATION liquidity snapshot (never a live
    ///      liquidity read, so single-block JIT liquidity cannot raise the cap); and each
    ///      party's own open escrow (its posted stake) within perAddressOiCapBps of that market OI
    ///      cap. A remainder below minFill may stay on the book and can be cancelled by the maker.
    ///
    ///      Asymmetric-collateral fill math (native USDG units, GROSS notionals):
    ///        takerGross  = ceil(fillCollateral * BPS_DENOM / payoffRatioBps)   (== fillCollateral at 1:1)
    ///        feeMaker    = fillCollateral * multiple * ENTRY_FEE_BPS / 10_000
    ///        feeTaker    = takerGross     * multiple * ENTRY_FEE_BPS / 10_000
    ///        makerStake  = fillCollateral - feeMaker
    ///        takerStake  = takerGross     - feeTaker
    ///      Because payoffRatioBps >= BPS_DENOM the taker never posts more than the maker consumes,
    ///      so takerGross <= fillCollateral (fits uint128). multiple is capped at MAX_MULTIPLE (10)
    ///      and ENTRY_FEE_BPS is 10, so each side's fee is at most 1 percent of that side's gross,
    ///      and each stake is always at least 99 percent of it. Dust fills where EITHER side's fee
    ///      rounds down to zero revert with EntryFeeExceedsCollateral: a zero-fee side would mint
    ///      points at zero cost, which is exactly the wash-trading vector the entry fee exists to
    ///      kill. The companion stake == 0 checks are defensive: with each fee capped at 1 percent
    ///      they are unreachable, and only bind for dust fills if the fee constants are ever raised.
    ///      Rounding takerGross UP makes the advertised odds a CEILING on taker upside (the maker
    ///      never gives more than advertised) and keeps the taker fully collateralized.
    ///
    ///      Escrow accounting (the NET convention, applied everywhere): the maker's feeMaker is
    ///      carved out of the consumed offer collateral (collateralRemaining still decreases by the
    ///      gross fillCollateral) and the taker transfers in the gross takerGross; the combined
    ///      feeMaker + feeTaker is paid out to the fee recipients in the same transaction with the
    ///      standard 25/10/39/26 jackpot/referral/buyback/treasury split (dust to treasury), so the
    ///      position escrows exactly makerStake + takerStake. Open interest, the OI cap check, and the
    ///      points-hook notional
    ///      use the net stakes: open interest grows by makerStake + takerStake (the TOTAL escrow,
    ///      which is also the position's maximum payout) and the points hook sees
    ///      notional = takerStake * multiple, so points scale with the taker's post-fee escrow and
    ///      farming cost scales with points minted.
    function fillOffer(uint256 offerId, uint128 fillCollateral) external nonReentrant returns (uint256 positionId) {
        Types.Offer storage offer = _offers[offerId];
        address maker = offer.maker;
        if (maker == address(0) || offer.cancelled || block.timestamp > offer.offerExpiry) revert OfferNotLive();
        // A maker filling their own offer would create a self-position whose only
        // effect is minting points (a wash-farming vector on a gas-free chain).
        if (msg.sender == maker) revert SelfFill();
        if (fillCollateral < offer.minFill) revert FillBelowMin();
        if (fillCollateral > offer.collateralRemaining) revert FillExceedsRemaining();
        if (guardian.isPaused(address(this))) revert MarketPaused();

        // OPENING-SIDE deviation breaker (never gates settlement/close/forced unwind): deny opening
        // a new position while current spot has dislocated from the settlement TWAP beyond the
        // token's threshold, which is exactly where a manipulator would capture profit. Consulted
        // ONLY here in the opening path; settle() and _forcedUnwind() never call it.
        _requireOpeningAllowed();

        // Asymmetric-collateral fill math (kept in a memory struct so this frame stays within the
        // stack limit). Each side's fee is at most 1 percent of that side's gross (multiple <= 10,
        // ENTRY_FEE_BPS = 10), so the subtractions inside are safe and the stake == 0 checks below
        // are defensive only. Fills where either side's fee rounds down to zero are dust and revert:
        // every side that mints points must pay a real, nonzero entry fee.
        FillMath memory fm = _fillMath(fillCollateral, offer.multiple, offer.payoffRatioBps);
        if (fm.feeMaker == 0 || fm.feeTaker == 0 || fm.makerStake == 0 || fm.takerStake == 0) {
            revert EntryFeeExceedsCollateral();
        }

        // Entry price gate (oracle status, zero price, maker limit) and OI plus liquidity-floor
        // gates, factored into helpers. Open interest counts the NET TOTAL escrow of the new
        // position (makerStake + takerStake): the two entry fees leave the market in this
        // transaction.
        uint128 entryPrice = _validatedEntryPrice(offer.makerSide, offer.limitEntry1e18);
        (uint256 newOpenInterest, uint256 cap1e18) =
            _checkedNewOpenInterest(uint256(fm.makerStake) + uint256(fm.takerStake));

        // Effects. The offer is consumed by the GROSS fill amount: the maker's feeMaker comes out of
        // the consumed offer collateral.
        offer.collateralRemaining -= fillCollateral;
        _openInterest = newOpenInterest;
        // Per-address OI sub-cap: charge each party its OWN posted stake and enforce the sub-cap, so
        // no single participant, and hence no colluding pair of addresses, can monopolize the market
        // OI cap with market-neutral self-trades. Reverts before any external interaction, so
        // checks-effects-interactions holds.
        _accrueAddressOpenInterest(maker, fm.makerStake, cap1e18);
        _accrueAddressOpenInterest(msg.sender, fm.takerStake, cap1e18);

        positionId = nextPositionId++;
        bool makerIsLong = offer.makerSide == Types.Side.LONG;
        _positions[positionId] = Types.Position({
            longParty: makerIsLong ? maker : msg.sender,
            shortParty: makerIsLong ? msg.sender : maker,
            token: _underlying,
            longStake: makerIsLong ? fm.makerStake : fm.takerStake,
            shortStake: makerIsLong ? fm.takerStake : fm.makerStake,
            multiple: offer.multiple,
            openedAt: uint64(block.timestamp),
            duration: offer.duration,
            entryPrice1e18: entryPrice,
            settled: false
        });

        // forge-lint: disable-next-line(unsafe-typecast)
        emit OfferFilled(offerId, positionId, msg.sender, maker, fillCollateral, uint128(fm.takerGross), entryPrice);
        emit EntryFeeCharged(offerId, positionId, fm.feeMaker, fm.feeTaker, fm.makerStake, fm.takerStake);

        // Interactions: the taker escrows its gross fill, the combined entry fees
        // (feeMaker + feeTaker) leave escrow through the shared 25/10/39/26 split helper,
        // then the best-effort points hook runs on the taker's post-fee notional.
        usdg.safeTransferFrom(msg.sender, address(this), fm.takerGross);
        _distributeFee(fm.feeMaker + fm.feeTaker);
        _chargeOpenBond(positionId, uint256(fm.makerStake) + uint256(fm.takerStake));

        Types.Position storage position = _positions[positionId];
        uint256 notional = uint256(fm.takerStake) * offer.multiple;
        try points.onFill(position.longParty, position.shortParty, maker, _underlying, notional) {}
        catch (bytes memory reason) {
            emit PointsHookFailed(reason);
        }
    }

    /// @dev Pure asymmetric-collateral fill math. takerGross is the taker's gross collateral for
    ///      consuming `fillCollateral` of maker collateral at the offer's odds (ceil so the taker is
    ///      never under-collateralized; == fillCollateral at 1:1). Each side's entry fee is 10 bps
    ///      of its own gross notional (gross * multiple), and each stake is its gross minus its own
    ///      fee. Casts are safe: payoffRatioBps >= BPS_DENOM so takerGross <= fillCollateral <=
    ///      type(uint128).max, and each fee is at most 1 percent of that side's gross.
    function _fillMath(uint128 fillCollateral, uint16 multiple, uint32 payoffRatioBps)
        private
        pure
        returns (FillMath memory fm)
    {
        fm.takerGross = Math.ceilDiv(uint256(fillCollateral) * BPS_DENOM, payoffRatioBps);
        fm.feeMaker = uint256(fillCollateral) * multiple * ENTRY_FEE_BPS / BPS_DENOM;
        fm.feeTaker = fm.takerGross * multiple * ENTRY_FEE_BPS / BPS_DENOM;
        // forge-lint: disable-next-line(unsafe-typecast)
        fm.makerStake = fillCollateral - uint128(fm.feeMaker);
        // forge-lint: disable-next-line(unsafe-typecast)
        fm.takerStake = uint128(fm.takerGross) - uint128(fm.feeTaker);
    }

    // ======================================================================
    // Settlement
    // ======================================================================

    /// @inheritdoc IMarket
    /// @notice Settle a position at the oracle composite price.
    /// @dev Authorization: the long or short party may settle once MIN_HOLD (30 minutes)
    ///      has elapsed since open; anyone may settle once the position duration has
    ///      elapsed. Settlement is blocked while the market is paused (pauses auto
    ///      expire after at most 24 hours, so settlement is always eventually possible).
    ///
    ///      Pricing: the router must return status OK, otherwise settle reverts and can
    ///      simply be retried (the router internally manages cooldown and fallback
    ///      transitions). Exception: once block.timestamp exceeds
    ///      openedAt + duration + MAX_SETTLE_DELAY and the status is still not OK, the
    ///      position is neutrally unwound: each side is refunded exactly its own stake,
    ///      zero fee. Funds can therefore never be locked forever.
    ///
    ///      Asymmetric-collateral settlement math (prices 1e18, collateral in native USDG units;
    ///      each stake is already NET of the 10 bps per-side entry fee charged at fill, so
    ///      settlement math never sees or touches entry fees). Let winnerStake and loserStake be the
    ///      two sides' stakes, decided by the price direction (long wins when exit > entry, short
    ///      wins when exit < entry):
    ///        loserNotional = loserStake * multiple
    ///        raw           = loserNotional * |exit - entry| / entry (exact integer via 512-bit mulDiv)
    ///        transfer      = clamp(raw, 0, loserStake)   (the winnings, bounded by the loser's stake)
    ///        fee           = min(loserNotional * settlementFeeBps / 10_000, transfer), from winnings only
    ///        winnerPayout  = winnerStake + transfer - fee
    ///        loserPayout   = loserStake  - transfer
    ///      settlementFeeBps is the immutable per-market rate (50 bps at launch, at or below the
    ///      MAX_FEE_BPS 1% cap). The winner wins UP TO the loser's stake; the loser loses UP TO its
    ///      own stake. Neither side can lose more than it escrowed, and the winner can never take more
    ///      than the total escrow. Conservation holds EXACTLY and independently of the fee and of
    ///      rounding:
    ///        winnerPayout + loserPayout + fee
    ///          = (winnerStake + transfer - fee) + (loserStake - transfer) + fee
    ///          = winnerStake + loserStake = longStake + shortStake (the total escrow).
    ///      The fee splits 25% jackpot, 10% referral pool, 39% buyback, 26% treasury, round-down with
    ///      the dust remainder to treasury. When the clamped transfer is zero (exit == entry, or a move too
    ///      small to round to one unit) there is no winner and no fee, and each side is refunded its
    ///      own stake. At a 1:1 offer winnerStake == loserStake, reproducing the old symmetric math
    ///      EXACTLY.
    ///
    ///      Payouts (winner and loser, or both sides on a flat settlement or forced unwind)
    ///      are CREDITED to a per-address withdrawable balance, never pushed. Each party then
    ///      pulls its balance with withdraw(). This makes settlement immune to a frozen or
    ///      blocked recipient: a party that cannot receive USDG can never revert settlement or
    ///      strand the counterparty's escrow. Only the fee split is pushed, and solely to the
    ///      trusted immutable fee recipients set at construction.
    function settle(uint256 positionId) external nonReentrant {
        Types.Position storage position = _positions[positionId];
        if (position.longParty == address(0)) revert UnknownPosition();
        if (position.settled) revert PositionAlreadySettled();
        if (guardian.isPaused(address(this))) revert MarketPaused();

        uint256 openedAt = position.openedAt;
        uint256 expiry = openedAt + position.duration;
        if (block.timestamp < expiry) {
            if (msg.sender != position.longParty && msg.sender != position.shortParty) revert NotPositionParty();
            if (block.timestamp < openedAt + MIN_HOLD) revert MinHoldNotReached(openedAt + MIN_HOLD);
        }

        (uint256 exitPrice1e18, Types.PriceStatus status) = router.checkPrice(_underlying);
        if (status != Types.PriceStatus.OK) {
            if (block.timestamp > expiry + MAX_SETTLE_DELAY) {
                _forcedUnwind(positionId, position);
                return;
            }
            revert OracleNotOk(status);
        }

        _settleAtPrice(positionId, position, exitPrice1e18);
    }

    /// @dev Neutral unwind: refund each side exactly its own stake, zero fee. Reached
    ///      only after expiry + MAX_SETTLE_DELAY with a persistently broken oracle. The
    ///      points hook is not invoked: nothing was won or lost. Refunds are CREDITED, never
    ///      pushed, so a frozen or blocked party can never revert this last-resort liveness
    ///      path or strand the counterparty: each side pulls its refund via withdraw().
    function _forcedUnwind(uint256 positionId, Types.Position storage position) private {
        uint256 longStake = position.longStake;
        uint256 shortStake = position.shortStake;
        address longParty = position.longParty;
        address shortParty = position.shortParty;

        position.settled = true;
        _openInterest -= (longStake + shortStake);
        _addressOpenCollateral[longParty] -= longStake;
        _addressOpenCollateral[shortParty] -= shortStake;

        emit ForcedUnwind(positionId, longParty, shortParty, longStake, shortStake);

        _creditPayout(positionId, longParty, longStake);
        _creditPayout(positionId, shortParty, shortStake);
    }

    /// @dev Normal settlement at an OK oracle price. See settle() NatSpec for the math. Party
    ///      payouts are credited (pull-payment); only the fee split is pushed, to trusted
    ///      immutable recipients.
    function _settleAtPrice(uint256 positionId, Types.Position storage position, uint256 exitPrice1e18) private {
        (address winner, address loser, uint256 winnerStake, uint256 loserStake, uint256 transferAmt) =
            _resolve(position, exitPrice1e18);

        // Effects: mark settled and clear the open-interest and per-address ledgers using each
        // side's own stake (read straight from storage to keep this frame within the stack limit).
        position.settled = true;
        _openInterest -= (uint256(position.longStake) + uint256(position.shortStake));
        _addressOpenCollateral[position.longParty] -= position.longStake;
        _addressOpenCollateral[position.shortParty] -= position.shortStake;

        if (winner == address(0)) {
            // Flat settlement (exit == entry, or a move too small to round to one unit
            // of transfer): each side credited exactly its own stake, no winner, no fee, no
            // points hook. The payout fields carry longStake and shortStake respectively.
            emit PositionSettled(
                positionId, address(0), address(0), exitPrice1e18, 0, 0, position.longStake, position.shortStake
            );
            _creditPayout(positionId, position.longParty, position.longStake);
            _creditPayout(positionId, position.shortParty, position.shortStake);
            return;
        }

        _settleDecisive(
            positionId, position.multiple, exitPrice1e18, winner, loser, winnerStake, loserStake, transferAmt
        );
    }

    /// @dev Decisive (non-flat) branch of settlement: compute the fee and both payouts from the
    ///      resolved winner/loser stakes and the clamped winnings, credit the parties (pull-payment),
    ///      push the fee split to the trusted immutable recipients, and run the best-effort points
    ///      hook. Split out of _settleAtPrice purely to keep both frames within the stack limit.
    ///      Conservation holds EXACTLY: winnerPayout + loserPayout + fee == winnerStake + loserStake.
    function _settleDecisive(
        uint256 positionId,
        uint16 multiple,
        uint256 exitPrice1e18,
        address winner,
        address loser,
        uint256 winnerStake,
        uint256 loserStake,
        uint256 transferAmt
    ) private {
        // The winnings came from the loser's notional exposure; the fee is settlementFeeBps of that
        // notional (the immutable per-market rate, at or below MAX_FEE_BPS), capped at the winnings
        // so the winner is never paid less than its own stake. STAKING-TIER HOOK (E2, future): a
        // per-trader tiered rate keyed on the settling trader's $PIT stake would replace the flat
        // settlementFeeBps read here; see the settlementFeeBps NatSpec.
        uint256 loserNotional = loserStake * multiple;
        uint256 fee = Math.min(loserNotional * settlementFeeBps / BPS_DENOM, transferAmt);
        uint256 winnerPayout = winnerStake + transferAmt - fee;
        uint256 loserPayout = loserStake - transferAmt;

        emit PositionSettled(positionId, winner, loser, exitPrice1e18, transferAmt, fee, winnerPayout, loserPayout);

        // Credit the party payouts (pull-payment).
        _creditPayout(positionId, winner, winnerPayout);
        if (loserPayout > 0) {
            _creditPayout(positionId, loser, loserPayout);
        }

        // Interactions: push the exact fee split (dust to treasury) to the trusted immutable fee
        // recipients, then the best-effort points hook on the loser's notional and the winnings.
        _distributeFee(fee);

        try points.onSettle(winner, loser, _underlying, loserNotional, transferAmt) {}
        catch (bytes memory reason) {
            emit PointsHookFailed(reason);
        }
    }

    /// @dev Winning party, losing party, their stakes, and the absolute clamped winnings
    ///      (transfer) for a settlement price. Long wins when exit exceeds entry, short wins when
    ///      exit is below entry; the winnings are the loser's notional times the relative price move,
    ///      clamped to the loser's stake. When the price is flat or the clamped winnings round to
    ///      zero there is no winner: winner, loser, stakes, and transfer are all zero.
    function _resolve(Types.Position storage position, uint256 exitPrice1e18)
        private
        view
        returns (address winner, address loser, uint256 winnerStake, uint256 loserStake, uint256 transferAmt)
    {
        uint256 entry = position.entryPrice1e18;
        uint256 absMove;
        if (exitPrice1e18 > entry) {
            winner = position.longParty;
            loser = position.shortParty;
            winnerStake = position.longStake;
            loserStake = position.shortStake;
            absMove = exitPrice1e18 - entry;
        } else if (exitPrice1e18 < entry) {
            winner = position.shortParty;
            loser = position.longParty;
            winnerStake = position.shortStake;
            loserStake = position.longStake;
            absMove = entry - exitPrice1e18;
        } else {
            return (address(0), address(0), 0, 0, 0);
        }

        transferAmt = _absPnl(loserStake * position.multiple, absMove, entry, loserStake);
        if (transferAmt == 0) {
            return (address(0), address(0), 0, 0, 0);
        }
    }

    /// @dev Split a protocol fee (the entry fee total at fill, or the settlement fee) four ways:
    ///      25% jackpot, 10% referral pool, 39% buyback, and the remainder (26% base plus the
    ///      round-down dust) to treasury. The jackpot, referral, and buyback shares use round-down
    ///      division; treasury takes fee minus those three, so the four shares always sum EXACTLY to
    ///      `fee` and no wei is ever created or lost regardless of `fee` (split arithmetic
    ///      UNCHANGED). Each share is delivered via _payFee: a push that CREDITS-on-failure to a pull
    ///      balance, so a single frozen or blocked fee recipient (USDG is freeze-capable) can no
    ///      longer revert a fill or a decisive settlement market-wide (wave-2 W2-12). The four
    ///      shares still sum to `fee` whether pushed or credited.
    function _distributeFee(uint256 fee) private {
        uint256 jackpotShare = fee * FEE_SHARE_JACKPOT_BPS / BPS_DENOM;
        uint256 referralShare = fee * FEE_SHARE_REFERRAL_BPS / BPS_DENOM;
        uint256 buybackShare = fee * FEE_SHARE_BUYBACK_BPS / BPS_DENOM;
        uint256 treasuryShare = fee - jackpotShare - referralShare - buybackShare;
        _payFee(feeJackpot, jackpotShare);
        _payFee(feeReferralPool, referralShare);
        _payFee(feeBuyback, buybackShare);
        _payFee(feeTreasury, treasuryShare);
    }

    /// @dev Deliver one fee share to a protocol recipient. Attempts a SafeERC20 push via the
    ///      self-only pushFee wrapper (so a revert is catchable); on ANY failure (a frozen or
    ///      blocked recipient, or a non-standard token return) it CREDITS the share to the
    ///      recipient's pull balance instead, which the recipient later realizes via withdraw().
    ///      This is a pure effect on failure (no external call), preserving checks-effects-
    ///      interactions and the pull-payment safety of the wave-1 D1 party payouts, and it keeps
    ///      the escrow-solvency invariant intact: a failed push leaves the share in the contract's
    ///      balance, exactly matching the credit it records.
    function _payFee(address recipient, uint256 share) private {
        if (share == 0) return;
        try this.pushFee(recipient, share) {
            return;
        } catch {
            _credit[recipient] += share;
            _totalCredit += share;
            emit FeeCredited(recipient, share);
        }
    }

    /// @notice Self-only external SafeERC20 push wrapper so _distributeFee can try/catch a transfer
    ///         that reverts and credit-on-failure instead. Reverts if called by anyone but this
    ///         contract; it moves only fee shares the contract already holds.
    /// @dev Not nonReentrant by design: it is invoked via an internal try/catch from within an
    ///      already-nonReentrant fill or settlement, and USDG has no transfer callback, so no
    ///      untrusted reentrancy is possible. The msg.sender guard prevents any external use.
    function pushFee(address to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        usdg.safeTransfer(to, amount);
    }

    /// @dev Charge the nonrefundable anti-monopolization open bond (wave-2 W2-9): openBondBps of the
    ///      fill's total open interest, pulled from the taker and routed to the treasury via _payFee
    ///      (credit-on-failure, so a frozen treasury cannot brick the fill). No-op when openBondBps
    ///      is zero. The bond is NOT part of the position escrow or open interest: it leaves in the
    ///      fill transaction, so it never touches settlement math or the capped-payout invariant. It
    ///      makes consuming the OI cap cost openBondBps of the OI consumed REGARDLESS of how many
    ///      Sybil addresses split the positions, which a per-address bps sub-cap cannot.
    function _chargeOpenBond(uint256 positionId, uint256 totalStake) private {
        if (openBondBps == 0) return;
        uint256 bond = Math.mulDiv(totalStake, openBondBps, BPS_DENOM);
        if (bond == 0) return;
        usdg.safeTransferFrom(msg.sender, address(this), bond);
        _payFee(feeTreasury, bond);
        emit OpenBondCharged(positionId, msg.sender, bond);
    }

    /// @dev Fill gate (opening only): consult the oracle router's spot-vs-TWAP deviation breaker
    ///      and revert OpeningPausedByDeviation when opening is denied. Factored out of fillOffer so
    ///      the breaker's return values never occupy the fill frame. NEVER called by settle() or
    ///      _forcedUnwind(): the breaker is an opening constraint only and can never block a
    ///      settlement, close, or the forced-unwind liveness path.
    function _requireOpeningAllowed() private view {
        (bool allowed, uint8 reason) = router.openingAllowed(_underlying);
        if (!allowed) revert OpeningPausedByDeviation(reason);
    }

    /// @dev Fill gate: fetch the oracle entry price and validate it. Non-OK statuses
    ///      and zero prices can never open positions. LONG makers cap the entry from
    ///      above with limitEntry1e18; SHORT makers cap it from below.
    function _validatedEntryPrice(Types.Side makerSide, uint128 limit) private returns (uint128) {
        (uint256 price1e18, Types.PriceStatus status) = router.checkPrice(_underlying);
        if (status != Types.PriceStatus.OK) revert OracleNotOk(status);
        if (price1e18 == 0) revert ZeroPrice();
        if (limit != 0) {
            if (makerSide == Types.Side.LONG) {
                if (price1e18 > limit) revert LimitEntryViolated(price1e18, limit);
            } else {
                if (price1e18 < limit) revert LimitEntryViolated(price1e18, limit);
            }
        }
        return price1e18.toUint128();
    }

    /// @dev Fill gate: the global open-interest cap, measured against the IMMUTABLE creation
    ///      liquidity snapshot (never a live tracked-liquidity read) and additionally bounded by the
    ///      IMMUTABLE absolute cost-to-move payout cap. Open interest (native USDG units) counts the
    ///      NET TOTAL escrow of each open position, makerStake + takerStake per fill (== 2 x
    ///      effectiveCollateral at 1:1): entry fees leave escrow at fill and are never part of open
    ///      interest. It is scaled to 1e18 before comparing against the 1e18-scaled cap. Basing the
    ///      cap on the creation snapshot closes the just-in-time inflation vector: single-block
    ///      liquidity movement can neither raise the cap nor (there being no live floor read) block
    ///      fills. The one-shot listing liquidity floor still applies at market creation via
    ///      router.isListable. This gate applies to NEW fills only, never to settlement.
    ///
    ///      COST-TO-MOVE BOUND (safe memecoin settlement, increment 1; RE-BASED on total escrow for
    ///      asymmetric odds). The effective cap is the MIN of the oiCapBps-of-snapshot cap and
    ///      maxPayoutCap1e18 (= costToMove / safetyFactor, type(uint256).max meaning "no absolute
    ///      cap" for majors). This bounds the maximum payout any single position can produce, by
    ///      construction. Mapping OI-cap-in-collateral to max-payout: total open interest is
    ///      sum(longStake + shortStake) over open positions and is held at or below cap1e18 (scaled),
    ///      so any single position's own longStake + shortStake is itself <= cap1e18. That position's
    ///      winner receives winnerStake + transfer - fee, with the clamped transfer <= loserStake and
    ///      fee >= 0, hence winnerPayout <= winnerStake + loserStake = longStake + shortStake
    ///      <= cap1e18. Therefore max single-position payout <= cap1e18 <= maxPayoutCap1e18 =
    ///      costToMove / safetyFactor, so the manipulator's maximum realizable payout sits a safety
    ///      factor below the cost of moving the price, REGARDLESS of how the escrow is split between
    ///      the two sides. (Attacker PROFIT, transfer - fee <= loserStake <= cap1e18, is bounded even
    ///      more tightly.)
    /// @param totalStake The NET total escrow (makerStake + takerStake) added by this fill.
    /// @return newOpenInterest The market open interest after this fill (native USDG units).
    /// @return cap1e18 The effective market OI cap in 1e18 scale, reused for the per-address sub-cap.
    function _checkedNewOpenInterest(uint256 totalStake)
        private
        view
        returns (uint256 newOpenInterest, uint256 cap1e18)
    {
        newOpenInterest = _openInterest + totalStake;
        cap1e18 = Math.min(Math.mulDiv(liquiditySnapshot1e18, oiCapBps, BPS_DENOM), maxPayoutCap1e18);
        if (newOpenInterest * collateralScale > cap1e18) {
            revert OiCapExceeded(newOpenInterest, cap1e18);
        }
    }

    /// @dev Fill effect and gate: add `addedCollateral` (the participant's OWN posted stake) to a
    ///      participant's open escrow and enforce the per-address OI sub-cap (perAddressOiCapBps of
    ///      the market OI cap). Reverts before any external interaction. Counting POSTED STAKE (not
    ///      max-payout exposure) makes the per-address ledger a clean partition of the global OI
    ///      accumulator: summed over all addresses it equals _openInterest exactly. The sub-cap
    ///      bounds any single address, so a colluding pair caps at 2 x perAddressOiCapBps of the
    ///      market OI cap: at the default 2_500 bps, two addresses can occupy at most half the cap,
    ///      always leaving room for honest traders, while adding no price risk to honest independent
    ///      participants. A participant's max-payout exposure (the counterparty's stake) is itself
    ///      bounded because that counterparty's stake is capped by ITS own sub-cap, and the total
    ///      extractable across any participant's positions is bounded by the global OI cap.
    /// @param who The participant (maker or taker) whose side escrow is growing.
    /// @param addedCollateral The participant's own posted stake added by this fill (native USDG units).
    /// @param cap1e18 The market OI cap in 1e18 scale (from _checkedNewOpenInterest).
    function _accrueAddressOpenInterest(address who, uint128 addedCollateral, uint256 cap1e18) private {
        uint256 open = _addressOpenCollateral[who] + addedCollateral;
        _addressOpenCollateral[who] = open;
        uint256 subCap1e18 = Math.mulDiv(cap1e18, perAddressOiCapBps, BPS_DENOM);
        uint256 open1e18 = open * collateralScale;
        if (open1e18 > subCap1e18) {
            revert PerAddressOiCapExceeded(who, open1e18, subCap1e18);
        }
    }

    /// @dev Credits `amount` USDG to `account`'s withdrawable balance (pull-payment). No external
    ///      call, so this is a pure effect: a frozen recipient cannot revert it. Zero amounts are
    ///      skipped so no spurious event or accounting entry is created.
    function _creditPayout(uint256 positionId, address account, uint256 amount) private {
        if (amount == 0) return;
        _credit[account] += amount;
        _totalCredit += amount;
        emit PayoutCredited(positionId, account, amount);
    }

    /// @dev Absolute PnL (the winnings transfer) clamped to the loser's stake. When the absolute
    ///      price move is at least the entry price the unclamped PnL is at least the loser's
    ///      notional, which is itself at least the loser's stake, so the clamp short-circuits without
    ///      any division. Otherwise mulDiv computes notional * move / entry with a 512-bit
    ///      intermediate, so the math can never overflow for any uint128 inputs.
    function _absPnl(uint256 notional, uint256 absMove, uint256 entry, uint256 loserStake)
        private
        pure
        returns (uint256)
    {
        if (absMove >= entry) return loserStake;
        return Math.min(Math.mulDiv(notional, absMove, entry), loserStake);
    }

    // ======================================================================
    // Withdrawals (pull-payment)
    // ======================================================================

    /// @inheritdoc IMarket
    /// @notice Pull the caller's full credited USDG balance, accrued by settlements and forced
    ///         unwinds. Reverts with NothingToWithdraw when the balance is zero.
    /// @dev nonReentrant with strict checks-effects-interactions: the balance is zeroed BEFORE the
    ///      transfer, so a reentrant or blocking token can never double-spend or wedge another
    ///      account's withdrawal. Each account's failure is isolated to itself.
    /// @return amount The USDG amount transferred to the caller.
    function withdraw() external nonReentrant returns (uint256 amount) {
        amount = _credit[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        // Effects.
        _credit[msg.sender] = 0;
        _totalCredit -= amount;

        emit Withdrawn(msg.sender, amount);

        // Interaction.
        usdg.safeTransfer(msg.sender, amount);
    }

    // ======================================================================
    // Views
    // ======================================================================

    /// @notice The USDG (native units) credited to `account` and awaiting withdrawal.
    function withdrawable(address account) external view returns (uint256) {
        return _credit[account];
    }

    /// @notice Total unwithdrawn credited USDG (native units) still held by the market.
    function totalUnwithdrawnCredit() external view returns (uint256) {
        return _totalCredit;
    }

    /// @notice Open escrow (native USDG units, NET of entry fees) attributable to `participant`
    ///         across its OPEN positions, counting only the side it holds (its own posted stake).
    ///         Bounded by the per-address OI sub-cap.
    function openCollateralOf(address participant) external view returns (uint256) {
        return _addressOpenCollateral[participant];
    }

    /// @inheritdoc IMarket
    function offers(uint256 offerId) external view returns (Types.Offer memory) {
        return _offers[offerId];
    }

    /// @inheritdoc IMarket
    function positions(uint256 positionId) external view returns (Types.Position memory) {
        return _positions[positionId];
    }

    /// @inheritdoc IMarket
    function openInterest() external view returns (uint256 totalEscrowedCollateral) {
        return _openInterest;
    }

    /// @inheritdoc IMarket
    function token() external view returns (address) {
        return _underlying;
    }
}
