// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {Types} from "../interfaces/Types.sol";
import {IOracleRouter} from "../interfaces/IOracleRouter.sol";
import {IPriceSource} from "./adapters/IPriceSource.sol";
import {ISpotSource} from "./adapters/ISpotSource.sol";
import {IIndependentSource} from "./adapters/IIndependentSource.sol";
import {ISettlementPoolSet} from "./adapters/ISettlementPoolSet.sol";
import {ISettlementWindow} from "./adapters/ISettlementWindow.sol";
import {UniV3TwapLib} from "./UniV3TwapLib.sol";

/// @title OracleRouter: the multi-source price layer of THE PIT
/// @notice PRICE-PATH INVARIANT (and its HONEST trust boundary): no admin function on this router
///         has a code path that writes a price directly. Every price it serves is either (a) the
///         median of at least the tier minimum of fresh, mutually agreeing adapter reads, or (b)
///         the median of the last AGREED_PRINTS prices that previously passed (a). There is no
///         third path.
///
///         WHAT THIS DOES AND DOES NOT GUARANTEE (corrected per wave-2 audit TO-1): the configured
///         sources are independent of EACH OTHER, not of the OWNER. The owner controls setSources
///         here and the config of every adapter (ChainlinkAdapter.setFeed, the TWAP pool
///         registries, ...), so a compromised owner that points ALL sources at owner-controlled
///         adapters can make the median equal any chosen value with deviation zero. This is NOT an
///         impossibility; it is bounded by two DEFENSE-IN-DEPTH measures that the deployment and
///         listing policy enforce, not by the median math:
///           1. The owner is an OZ TimelockController (see Deploy.s.sol), so setSources / setFeed /
///              setTierConfig take effect only after a public delay, giving any live position a
///              window to settle at the honest price before a source swap lands.
///           2. isListable requires at least one configured source that is genuinely INDEPENDENT of
///              the settlement pool (a real external feed) for every value-bearing (non Tier
///              A_MAJOR-with-independent-feed) token, so the owner cannot silently point every
///              source at an owned pool for a listed token (see _hasIndependentSource).
///         The owner still cannot MINT, MOVE, or FREEZE escrowed funds, cannot change a live
///         market's immutable wiring, and cannot bypass the capped-payout invariant.
/// @dev State machine per token (checkPrice mutates it, peekPrice only predicts it):
///      1. Fewer than 3 fresh sources: STALE (some fresh) or UNAVAILABLE (none fresh). Never OK.
///      2. 3+ fresh sources within the pairwise deviation bound: OK. failedRounds and cooldown
///         reset, the median is pushed into a 3-slot ring buffer of agreed prints.
///      3. Deviation bound exceeded: COOLDOWN for 30 minutes. Each check that lands after a full
///         cooldown has elapsed while deviation still fails increments failedRounds and restarts
///         the cooldown. After 3 failed rounds the router returns OK with the FALLBACK price:
///         the median of the ring buffer. Fallback never touches the ring buffer and never
///         resets failedRounds; only a genuinely agreeing print (2) does. If fewer than 3 agreed
///         prints have ever been recorded, the token stays in COOLDOWN indefinitely instead.
///      checkPrice is intentionally permissionless: every transition is driven purely by source
///      data and elapsed time, so an outside caller can only advance the intended machine.
contract OracleRouter is IOracleRouter, Ownable2Step {
    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Minimum number of fresh, agreeing sources required for a live OK print.
    uint256 public constant MIN_SOURCES = 3;
    /// @notice Cooldown length after a deviation guard failure.
    uint256 public constant COOLDOWN_DURATION = 30 minutes;
    /// @notice Failed rounds (full cooldowns elapsed with deviation still failing) before fallback.
    uint8 public constant FALLBACK_AFTER_ROUNDS = 3;
    /// @notice Ring buffer depth of agreed prints backing the fallback price.
    uint8 public constant AGREED_PRINTS = 3;
    /// @notice Default max pairwise deviation for tier A tokens, in bps.
    uint16 public constant TIER_A_DEFAULT_DEVIATION_BPS = 300;
    /// @notice Default max pairwise deviation for tier B tokens, in bps. This wide band is the
    ///         spot-vs-TWAP style guard: it bounds how far the fastest source (spot-like feeds)
    ///         may drift from the slowest source (TWAPs) before settlement pauses.
    uint16 public constant TIER_B_DEFAULT_DEVIATION_BPS = 2500;
    /// @notice Default listing liquidity floor, USDG terms, 1e18 scale.
    uint256 public constant DEFAULT_LIQUIDITY_FLOOR = 25_000e18;
    /// @notice Sanity ceiling on any single source price (1e18 scale). Reads above it are dropped
    ///         as malfunctioning, which also makes all internal deviation math overflow-free.
    uint256 public constant MAX_SOURCE_PRICE = 1e36;
    /// @notice Basis points denominator.
    uint256 internal constant BPS = 10_000;
    /// @notice Fixed-point ONE for the cost-to-move coefficient (see costToMoveEstimate1e18).
    ///         costToMoveCoeff is expressed at this scale: COST_COEFF_ONE means "cost-to-move
    ///         equals aggregate depth"; a larger coefficient means a higher measured cost per unit
    ///         of depth (a longer TWAP window, more independent venues, or a stricter calibration).
    uint256 public constant COST_COEFF_ONE = 1e18;

    /// @notice openingAllowed reason: opening a new position is permitted.
    uint8 public constant OPENING_ALLOWED = 0;
    /// @notice openingAllowed reason: current spot deviates from the settlement TWAP beyond the
    ///         token's deviationBreakerBps, so opening is denied (settlement stays open).
    uint8 public constant OPENING_DENIED_DEVIATION = 1;
    /// @notice openingAllowed reason: the spot or TWAP reference could not be read, so opening is
    ///         denied conservatively (fail-safe: no new position is opened at an unknown price).
    uint8 public constant OPENING_DENIED_REFERENCE_UNAVAILABLE = 2;

    // ===============================================================
    // Types
    // ===============================================================

    /// @notice Deviation tier of a token. A: majors/stables style tight band. B: memecoin band.
    /// @dev This is the PAIRWISE SOURCE-AGREEMENT band used inside checkPrice (how far configured
    ///      sources may disagree before the cooldown machinery engages). It is a DIFFERENT axis
    ///      from the SettlementTier below, which governs listing eligibility, the settlement
    ///      source, and the cost-to-move payout cap. The two are set independently.
    enum Tier {
        A,
        B
    }

    /// @notice Settlement tier of a token: its manipulation-resistance class (increment 1 of the
    ///         safe memecoin settlement layer). Governance asserts this per token.
    /// @dev
    ///      A_MAJOR: at least one configured source is a real feed INDEPENDENT of any AMM pool (a
    ///        Chainlink feed). Settles on the existing median-of-at-least-MIN_SOURCES framework; no
    ///        pool-depth gate and no cost-to-move payout cap (the price is not pool-derived). This
    ///        is the enum zero value, so a token with no tier configured is treated as A_MAJOR and
    ///        keeps the pre-existing >= MIN_SOURCES behavior.
    ///      B_DEEP: no independent feed, but deep and seasoned aggregate multi-pool liquidity.
    ///        Settles on the aggregated multi-pool geometric-mean TWAP (a single aggregating source
    ///        suffices, since the aggregation happens across many pools inside the adapter). Gated
    ///        on aggregate depth, seasoning, and observation cardinality; capped by cost-to-move.
    ///      C_MID: one deep pool, marginal. Same on-chain path as B_DEEP at a smaller cap. Its
    ///        mandatory optimistic backstop is increment 2 (documented, not built here).
    ///      D_THIN: fails depth, seasoning, or cost-to-move at any useful cap. NEVER listable for
    ///        continuous settlement.
    enum SettlementTier {
        A_MAJOR,
        B_DEEP,
        C_MID,
        D_THIN
    }

    /// @notice One configured price source for a token.
    /// @param source The adapter.
    /// @param maxStaleness Max age in seconds of the adapter's updatedAt before it is dropped.
    struct SourceConfig {
        IPriceSource source;
        uint64 maxStaleness;
    }

    /// @notice Per-token configuration. Owner-set only.
    /// @param sources Configured adapters (0 to delist, otherwise at least MIN_SOURCES).
    /// @param tier Deviation tier used when maxPairwiseDeviationBps is 0.
    /// @param maxPairwiseDeviationBps Explicit deviation bound override; 0 means tier default.
    /// @param liquidityFloor Listing floor override (USDG 1e18); 0 means DEFAULT_LIQUIDITY_FLOOR.
    /// @param trackedPools Uniswap v3 pools whose USDG side backs trackedLiquidity.
    struct TokenConfig {
        SourceConfig[] sources;
        Tier tier;
        uint16 maxPairwiseDeviationBps;
        uint256 liquidityFloor;
        address[] trackedPools;
    }

    /// @notice Per-pool quote configuration for trackedLiquidity. A pool with no config (zero
    ///         quoteToken) is USDG-quoted: its contribution is twice its USDG balance. A pool
    ///         configured here is quoted in another asset (WETH in practice): its contribution is
    ///         twice its quote-token balance converted to USD via the configured Chainlink feed.
    /// @param quoteToken The pool's quote asset (WETH); zero means USDG-quoted (default).
    /// @param quoteScale Multiplier converting native quote-token balances to 1e18 scale.
    /// @param feed Chainlink feed pricing the quote asset in USD (ETH/USD for WETH pools).
    /// @param feedMaxStaleness Max age in seconds of the feed's updatedAt; older reads count as 0.
    /// @param feedDecimals Feed decimals cached at registration.
    struct PoolQuoteConfig {
        address quoteToken;
        uint256 quoteScale;
        AggregatorV3Interface feed;
        uint64 feedMaxStaleness;
        uint8 feedDecimals;
    }

    /// @notice Per-pool geometry enabling the manipulation-resistant, time-averaged in-range
    ///         quote-reserve depth measure (see _trackedLiquidity and consultMeanQuoteReserve). A
    ///         pool with a nonzero window has its quote-side depth read as the time-averaged
    ///         in-range reserve over that window instead of its instantaneous balanceOf, so a
    ///         single-block just-in-time LP deposit can no longer raise the listing floor, the
    ///         creation snapshot, or the cost-to-move cap. Required for every tracked pool of a
    ///         value-bearing (B_DEEP / C_MID) token: without it that pool contributes zero depth,
    ///         so the token cannot clear the depth floor.
    /// @param quoteIsToken0 True when the quote asset (USDG or the WETH declared via setPoolQuote)
    ///        is token0 of the pool, so the base token being priced is token1.
    /// @param window Time-averaging lookback in seconds; set to the settlement TWAP window. Zero
    ///        disables the manipulation-resistant path for this pool (legacy balanceOf, only used
    ///        for Tier A_MAJOR pools whose price is set by an independent feed anyway).
    struct PoolGeometry {
        bool quoteIsToken0;
        uint32 window;
    }

    /// @notice Per-token breaker state.
    /// @param cooldownUntil End of the active cooldown window (0 = no cooldown active).
    /// @param failedRounds Completed cooldown rounds that still ended in deviation failure.
    /// @param ringCount Number of agreed prints stored so far (saturates at AGREED_PRINTS).
    /// @param ringIndex Next ring slot to overwrite.
    /// @param lastPrintBlock Block of the most recent ring write (wave-2b R-7): the ring accepts at
    ///        most one agreed print per block, so its median-of-AGREED_PRINTS fallback always spans
    ///        AGREED_PRINTS distinct blocks and can never be three copies of one timing-chosen read.
    /// @param ring Last AGREED_PRINTS prices that passed every guard.
    struct BreakerState {
        uint64 cooldownUntil;
        uint8 failedRounds;
        uint8 ringCount;
        uint8 ringIndex;
        uint64 lastPrintBlock;
        uint256[3] ring;
    }

    /// @notice Per-token settlement-tier configuration (owner-set). Absent config (set = false)
    ///         resolves to Tier A_MAJOR with no depth gate, no seasoning, no cost-to-move cap, and
    ///         no opening breaker, preserving the pre-tier behavior for every already-listed token.
    /// @param tier The settlement tier (A_MAJOR / B_DEEP / C_MID / D_THIN).
    /// @param aggregateDepthFloorUsd1e18 Minimum aggregate tracked depth (USD, 1e18) required to
    ///        list a B_DEEP / C_MID token. Zero falls back to the token's liquidityFloor override
    ///        (and then DEFAULT_LIQUIDITY_FLOOR), so the historical floor still applies by default.
    /// @param seasoningWindow Minimum age in seconds that the token's PRIMARY tracked pool's oldest
    ///        stored observation must reach back (the pool must be able to serve an observe() of
    ///        this lookback). A cheap on-chain proxy for "has existed and traded a while"; combined
    ///        with the depth floor it denies freshly wash-inflated fake depth. Zero disables it.
    /// @param costToMoveCoeff Governance-tunable calibration coefficient (scale COST_COEFF_ONE) that
    ///        maps aggregate 2%-depth to an estimated cost-to-move-the-reference. See
    ///        costToMoveEstimate1e18: the AMM-oracle research (memecoin-price-sourcing-research.md)
    ///        FLAGS the exact closed-form coefficient as unverified and instructs calibrating it
    ///        empirically against the real pool, so it is a governance parameter here, never a
    ///        hardcoded magic number. Only the STRUCTURE (monotonic, increasing in aggregate depth)
    ///        is relied on.
    /// @param safetyFactor Governance-tunable divisor (>= 1) applied to the cost-to-move estimate to
    ///        set the absolute market payout cap: maxMarketPayoutCap = costToMove / safetyFactor.
    ///        Research suggests 5x to 10x, higher for newer/thinner tokens.
    /// @param deviationBreakerBps Opening-side spot-vs-TWAP deviation threshold (bps). When current
    ///        aggregated spot diverges from the settlement TWAP by more than this, openingAllowed
    ///        denies OPENING new positions (settlement/close/forced-unwind are never gated).
    /// @param spotSource Spot aggregator (ISpotSource, in practice the CrossPoolTwapAdapter) used by
    ///        the opening breaker. Zero disables the breaker (openingAllowed always allows), which
    ///        is the correct default for Tier A majors priced by an independent feed.
    /// @param set True once setTierConfig has written this token (distinguishes an explicit A_MAJOR
    ///        from the never-configured default; both behave identically for listing).
    struct TierConfig {
        SettlementTier tier;
        uint256 aggregateDepthFloorUsd1e18;
        uint32 seasoningWindow;
        uint256 costToMoveCoeff;
        uint256 safetyFactor;
        uint16 deviationBreakerBps;
        ISpotSource spotSource;
        bool set;
    }

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice USDG token used as the quote asset and liquidity measuring stick.
    address public immutable usdg;
    /// @notice Multiplier converting native USDG balances to 1e18 scale.
    uint256 public immutable usdgScale;

    mapping(address => TokenConfig) internal _configs;
    mapping(address => BreakerState) internal _breakers;
    mapping(address => TierConfig) internal _tierConfigs;

    /// @notice pool => quote configuration for non USDG-quoted tracked pools. Unset = USDG.
    mapping(address => PoolQuoteConfig) public poolQuotes;

    /// @notice pool => geometry for the manipulation-resistant in-range reserve depth measure.
    ///         Unset (window == 0) leaves a pool on the legacy instantaneous balanceOf measure.
    mapping(address => PoolGeometry) public poolGeometry;

    /// @notice token => liquidity snapshot taken at market creation (USDG 1e18).
    mapping(address => uint256) public liquiditySnapshot;

    // ===============================================================
    // Events
    // ===============================================================

    /// @notice Emitted when a token's source set is replaced.
    event SourcesSet(address indexed token, uint256 count);
    /// @notice Emitted when a token's tier or explicit deviation bound changes.
    event GuardsSet(address indexed token, Tier tier, uint16 maxPairwiseDeviationBps);
    /// @notice Emitted when a token's listing liquidity floor override changes.
    event LiquidityFloorSet(address indexed token, uint256 floor1e18);
    /// @notice Emitted when a token's tracked pool set is replaced.
    event TrackedPoolsSet(address indexed token, uint256 count);
    /// @notice Emitted when a pool's quote configuration is set or cleared (quoteToken = 0).
    event PoolQuoteSet(address indexed pool, address indexed quoteToken, address indexed feed, uint64 feedMaxStaleness);
    /// @notice Emitted when a pool's manipulation-resistant depth geometry is set or cleared.
    event PoolGeometrySet(address indexed pool, bool quoteIsToken0, uint32 window);
    /// @notice Emitted on every agreed print accepted into the ring buffer.
    event PrintAccepted(address indexed token, uint256 price1e18);
    /// @notice Emitted when a deviation failure starts or restarts a cooldown window.
    event CooldownStarted(address indexed token, uint64 cooldownUntil);
    /// @notice Emitted when a full cooldown elapsed and deviation still failed.
    event FailedRoundRecorded(address indexed token, uint8 failedRounds);
    /// @notice Emitted when the fallback (median of agreed prints) is served as OK.
    event FallbackServed(address indexed token, uint256 price1e18);
    /// @notice Emitted when snapshotLiquidity stores a value.
    event LiquiditySnapshotTaken(address indexed token, uint256 liquidityUsd1e18);
    /// @notice Emitted when a token's settlement-tier configuration is set or updated.
    event TierConfigSet(
        address indexed token,
        SettlementTier tier,
        uint256 aggregateDepthFloorUsd1e18,
        uint32 seasoningWindow,
        uint256 costToMoveCoeff,
        uint256 safetyFactor,
        uint16 deviationBreakerBps,
        address spotSource
    );

    // ===============================================================
    // Errors
    // ===============================================================

    /// @dev The token argument was the zero address.
    error TokenZero();
    /// @dev The USDG address was zero.
    error UsdgZero();
    /// @dev USDG reports more than 18 decimals, which this router does not support.
    error UnsupportedUsdgDecimals(uint8 decimals);
    /// @dev Fewer than MIN_SOURCES sources supplied (and not zero to delist).
    error TooFewSources(uint256 supplied);
    /// @dev A supplied source address was zero.
    error SourceZero();
    /// @dev A supplied maxStaleness was zero.
    error StalenessZero();
    /// @dev Deviation bound above 100 percent is meaningless.
    error DeviationTooWide(uint16 bps);
    /// @dev A supplied tracked pool address was zero.
    error PoolZero();
    /// @dev A quote config was supplied with a zero feed address.
    error FeedZero();
    /// @dev The quote token reports more than 18 decimals, which this router does not support.
    error UnsupportedQuoteDecimals(uint8 decimals);
    /// @dev The feed reports more decimals than the router supports (max 30).
    error UnsupportedFeedDecimals(uint8 decimals);
    /// @dev Renouncing ownership is disabled: it would permanently freeze source configuration.
    error RenounceDisabled();
    /// @dev safetyFactor must be at least 1 (it divides the cost-to-move estimate).
    error SafetyFactorZero();
    /// @dev deviationBreakerBps above 100 percent is meaningless.
    error BreakerTooWide(uint16 bps);

    // ===============================================================
    // Construction
    // ===============================================================

    /// @param initialOwner Owner (timelocked multisig).
    /// @param usdg_ The USDG token address; its decimals are read once and cached as a scale.
    constructor(address initialOwner, address usdg_) Ownable(initialOwner) {
        if (usdg_ == address(0)) revert UsdgZero();
        uint8 dec = IERC20Metadata(usdg_).decimals();
        if (dec > 18) revert UnsupportedUsdgDecimals(dec);
        usdg = usdg_;
        usdgScale = 10 ** (18 - dec);
    }

    /// @notice Renouncing ownership is disabled: it would permanently freeze every source,
    ///         guard, tier, liquidity-floor, and tracked-pool setting with no recovery path.
    ///         Ownership can still be transferred to a new multisig (two-step Ownable2Step).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ===============================================================
    // Owner configuration (sources and guards only; NEVER prices)
    // ===============================================================

    /// @notice Replaces the full source set for a token.
    /// @dev Supply an empty array to delist. Otherwise at least the token's tier minimum entries
    ///      are required. For Tier A_MAJOR (the default) that minimum is MIN_SOURCES: no single
    ///      independent source may settle a position. For Tier B_DEEP / C_MID it is 1, because the
    ///      settlement source is itself an aggregate across many pools (the CrossPoolTwapAdapter),
    ///      so a single aggregating source is the intended configuration; set the tier via
    ///      setTierConfig BEFORE calling this for such a token.
    /// @param token The token being configured.
    /// @param sources Adapters plus their per-source staleness bounds.
    function setSources(address token, SourceConfig[] calldata sources) external onlyOwner {
        if (token == address(0)) revert TokenZero();
        uint256 minReq = _minSourcesForTier(_tierConfigs[token].tier);
        if (sources.length != 0 && sources.length < minReq) revert TooFewSources(sources.length);
        delete _configs[token].sources;
        for (uint256 i = 0; i < sources.length; i++) {
            if (address(sources[i].source) == address(0)) revert SourceZero();
            if (sources[i].maxStaleness == 0) revert StalenessZero();
            _configs[token].sources.push(sources[i]);
        }
        emit SourcesSet(token, sources.length);
    }

    /// @notice Sets a token's tier and optional explicit deviation bound.
    /// @param token The token being configured.
    /// @param tier Tier A (tight) or B (wide, memecoins).
    /// @param maxPairwiseDeviationBps Explicit bound in bps; 0 selects the tier default.
    function setGuards(address token, Tier tier, uint16 maxPairwiseDeviationBps) external onlyOwner {
        if (token == address(0)) revert TokenZero();
        if (maxPairwiseDeviationBps > BPS) revert DeviationTooWide(maxPairwiseDeviationBps);
        _configs[token].tier = tier;
        _configs[token].maxPairwiseDeviationBps = maxPairwiseDeviationBps;
        emit GuardsSet(token, tier, maxPairwiseDeviationBps);
    }

    /// @notice Sets a token's listing liquidity floor override (0 restores the default).
    /// @param token The token being configured.
    /// @param floor1e18 Floor in USDG terms, 1e18 scale; 0 means DEFAULT_LIQUIDITY_FLOOR.
    function setLiquidityFloor(address token, uint256 floor1e18) external onlyOwner {
        if (token == address(0)) revert TokenZero();
        _configs[token].liquidityFloor = floor1e18;
        emit LiquidityFloorSet(token, floor1e18);
    }

    /// @notice Replaces the pool set backing trackedLiquidity for a token.
    /// @dev Pools quoted in USDG need no further configuration. Pools quoted in another asset
    ///      (WETH memecoin pools) must ALSO be declared via setPoolQuote, otherwise their USDG
    ///      balance (typically zero) is what gets counted and they contribute nothing.
    /// @param token The token being configured.
    /// @param pools Uniswap v3 pools pairing the token with USDG (or with a configured quote).
    function setTrackedPools(address token, address[] calldata pools) external onlyOwner {
        if (token == address(0)) revert TokenZero();
        delete _configs[token].trackedPools;
        for (uint256 i = 0; i < pools.length; i++) {
            if (pools[i] == address(0)) revert PoolZero();
            _configs[token].trackedPools.push(pools[i]);
        }
        emit TrackedPoolsSet(token, pools.length);
    }

    /// @notice Declares a tracked pool as quoted in `quoteToken` (WETH) instead of USDG, with a
    ///         Chainlink feed converting the quote side to USD. Pass quoteToken = address(0) to
    ///         clear the config and restore the default USDG treatment.
    /// @dev Keyed per pool (not per token) so a pool shared by several tracked sets is declared
    ///      once. This is a parallel owner surface added alongside setTrackedPools because the
    ///      IOracleRouter interface is frozen; it configures liquidity MEASUREMENT only and, like
    ///      every other admin function on this contract, can never set or nudge a price.
    /// @param pool The tracked Uniswap v3 pool being declared.
    /// @param quoteToken The pool's quote asset (WETH), or zero to clear.
    /// @param feed Chainlink feed pricing the quote asset in USD (ETH/USD).
    /// @param feedMaxStaleness Max feed age in seconds; a staler read zeroes the contribution.
    function setPoolQuote(address pool, address quoteToken, address feed, uint64 feedMaxStaleness) external onlyOwner {
        if (pool == address(0)) revert PoolZero();
        if (quoteToken == address(0)) {
            delete poolQuotes[pool];
            emit PoolQuoteSet(pool, address(0), address(0), 0);
            return;
        }
        if (feed == address(0)) revert FeedZero();
        if (feedMaxStaleness == 0) revert StalenessZero();
        uint8 quoteDec = IERC20Metadata(quoteToken).decimals();
        if (quoteDec > 18) revert UnsupportedQuoteDecimals(quoteDec);
        uint8 feedDec = AggregatorV3Interface(feed).decimals();
        if (feedDec > 30) revert UnsupportedFeedDecimals(feedDec);
        poolQuotes[pool] = PoolQuoteConfig({
            quoteToken: quoteToken,
            quoteScale: 10 ** (18 - quoteDec),
            feed: AggregatorV3Interface(feed),
            feedMaxStaleness: feedMaxStaleness,
            feedDecimals: feedDec
        });
        emit PoolQuoteSet(pool, quoteToken, feed, feedMaxStaleness);
    }

    /// @notice Declares a tracked pool's geometry so its depth is measured as the time-averaged
    ///         in-range QUOTE-side reserve (manipulation-resistant) instead of an instantaneous
    ///         balanceOf. Pass window = 0 to clear the geometry and restore the legacy balanceOf
    ///         measure (only appropriate for Tier A_MAJOR pools, whose price is set by an
    ///         independent feed so a same-block balanceOf spike cannot be monetised).
    /// @dev Set the window to the token's settlement TWAP window and quoteIsToken0 to the pool's
    ///      token ordering (matching the CrossPoolTwapAdapter registration for the same pool). Like
    ///      every admin function here this configures liquidity MEASUREMENT only and can never set
    ///      or nudge a price. Required for every tracked pool of a value-bearing B_DEEP / C_MID
    ///      token: _trackedLiquidity skips a geometry-less pool for those tiers, so the token fails
    ///      the depth floor until its pools are declared. WINDOW FLOOR (wave-2b R-9): geometry is
    ///      keyed per POOL while the settlement TWAP window is keyed per TOKEN inside the
    ///      settlement adapter, so the floor is enforced where both are known: in the depth
    ///      measurement itself. For a value-bearing token, a tracked pool whose geometry window is
    ///      SHORTER than the settlement source's reported TWAP window (ISettlementWindow on
    ///      sources[0]) contributes ZERO depth, exactly as if it had no geometry: a short window
    ///      cannot shrink the averaging horizon below the settlement TWAP's own horizon and
    ///      re-weaken the W2-1 manipulation resistance. Fail-safe direction: an under-floored pool
    ///      only ever UNDERSTATES depth (lower listing eligibility and a lower cost-to-move cap).
    /// @param pool The tracked Uniswap v3 pool being declared.
    /// @param quoteIsToken0 True when the quote asset is token0 of the pool.
    /// @param window Time-averaging lookback in seconds (the settlement TWAP window); 0 clears it.
    function setPoolGeometry(address pool, bool quoteIsToken0, uint32 window) external onlyOwner {
        if (pool == address(0)) revert PoolZero();
        poolGeometry[pool] = PoolGeometry({quoteIsToken0: quoteIsToken0, window: window});
        emit PoolGeometrySet(pool, quoteIsToken0, window);
    }

    /// @notice Sets a token's settlement-tier configuration (increment 1 of the safe memecoin
    ///         settlement layer). Owner only, and like every admin function here it configures the
    ///         listing/gate policy MEASUREMENT only and can never set or nudge a price.
    /// @dev Set the tier BEFORE setSources for a B_DEEP / C_MID token: those tiers settle on a
    ///      single aggregating multi-pool TWAP source, so their source-count minimum is 1, whereas
    ///      the default A_MAJOR requires MIN_SOURCES. costToMoveCoeff and safetyFactor are the
    ///      governance-tunable calibration parameters flagged by the price-sourcing research (never
    ///      hardcoded magic numbers); see costToMoveEstimate1e18. deviationBreakerBps plus a nonzero
    ///      spotSource arm the opening-side spot-vs-TWAP breaker (openingAllowed); a zero spotSource
    ///      leaves opening always allowed, which is correct for majors.
    /// @param token The token being configured.
    /// @param tier The settlement tier.
    /// @param aggregateDepthFloorUsd1e18 Aggregate-depth listing floor (USD 1e18) for B/C; 0 falls
    ///        back to the liquidityFloor override then DEFAULT_LIQUIDITY_FLOOR.
    /// @param seasoningWindow Minimum primary-pool observation age in seconds; 0 disables.
    /// @param costToMoveCoeff Calibration coefficient at scale COST_COEFF_ONE.
    /// @param safetyFactor Divisor (>= 1) turning cost-to-move into the absolute payout cap.
    /// @param deviationBreakerBps Opening-side spot-vs-TWAP threshold in bps (<= BPS).
    /// @param spotSource Spot aggregator for the breaker; address(0) disables the breaker.
    function setTierConfig(
        address token,
        SettlementTier tier,
        uint256 aggregateDepthFloorUsd1e18,
        uint32 seasoningWindow,
        uint256 costToMoveCoeff,
        uint256 safetyFactor,
        uint16 deviationBreakerBps,
        address spotSource
    ) external onlyOwner {
        if (token == address(0)) revert TokenZero();
        if (safetyFactor == 0) revert SafetyFactorZero();
        if (deviationBreakerBps > BPS) revert BreakerTooWide(deviationBreakerBps);
        _tierConfigs[token] = TierConfig({
            tier: tier,
            aggregateDepthFloorUsd1e18: aggregateDepthFloorUsd1e18,
            seasoningWindow: seasoningWindow,
            costToMoveCoeff: costToMoveCoeff,
            safetyFactor: safetyFactor,
            deviationBreakerBps: deviationBreakerBps,
            spotSource: ISpotSource(spotSource),
            set: true
        });
        emit TierConfigSet(
            token,
            tier,
            aggregateDepthFloorUsd1e18,
            seasoningWindow,
            costToMoveCoeff,
            safetyFactor,
            deviationBreakerBps,
            spotSource
        );
    }

    // ===============================================================
    // IOracleRouter
    // ===============================================================

    /// @inheritdoc IOracleRouter
    function checkPrice(address token) external returns (uint256 price1e18, Types.PriceStatus status) {
        (uint256 median, Types.PriceStatus gate, bool devFail) = _evaluate(token);
        if (gate != Types.PriceStatus.OK) return (0, gate);

        BreakerState storage b = _breakers[token];

        if (!devFail) {
            b.failedRounds = 0;
            b.cooldownUntil = 0;
            _recordAgreedPrint(token, b, median);
            return (median, Types.PriceStatus.OK);
        }

        // Deviation guard failed.
        if (b.failedRounds >= FALLBACK_AFTER_ROUNDS) {
            (uint256 fb, bool has) = _fallbackPrice(b);
            if (has) {
                emit FallbackServed(token, fb);
                return (fb, Types.PriceStatus.OK);
            }
            // Ring never filled: stay in cooldown forever until sources agree again.
            if (block.timestamp >= b.cooldownUntil) {
                b.cooldownUntil = uint64(block.timestamp + COOLDOWN_DURATION);
                emit CooldownStarted(token, b.cooldownUntil);
            }
            return (0, Types.PriceStatus.COOLDOWN);
        }

        if (b.cooldownUntil == 0) {
            // Enter cooldown.
            b.cooldownUntil = uint64(block.timestamp + COOLDOWN_DURATION);
            emit CooldownStarted(token, b.cooldownUntil);
            return (0, Types.PriceStatus.COOLDOWN);
        }

        if (block.timestamp < b.cooldownUntil) {
            // Still inside the active cooldown window.
            return (0, Types.PriceStatus.COOLDOWN);
        }

        // A full cooldown elapsed and deviation still fails: record a failed round.
        b.failedRounds += 1;
        emit FailedRoundRecorded(token, b.failedRounds);
        if (b.failedRounds >= FALLBACK_AFTER_ROUNDS) {
            (uint256 fb, bool has) = _fallbackPrice(b);
            if (has) {
                emit FallbackServed(token, fb);
                return (fb, Types.PriceStatus.OK);
            }
        }
        b.cooldownUntil = uint64(block.timestamp + COOLDOWN_DURATION);
        emit CooldownStarted(token, b.cooldownUntil);
        return (0, Types.PriceStatus.COOLDOWN);
    }

    /// @notice Permissionlessly seeds a token's agreed-print ring with the current agreeing median,
    ///         advancing the ring by AT MOST ONE print per call and per block (the same discipline
    ///         checkPrice follows), so a freshly listed market can be given a populated fallback by
    ///         priming across AGREED_PRINTS distinct blocks before market creation.
    /// @dev Wave-2 W2-10, hardened by wave-2b R-7. W2-10: without a filled ring, a young market
    ///      that runs into a sustained multi-source deviation before ever recording AGREED_PRINTS
    ///      agreeing prints sticks in permanent COOLDOWN (settle impossible until expiry +
    ///      MAX_SETTLE_DELAY forces a neutral unwind, a free option for a losing party). R-7: the
    ///      original primer filled ALL AGREED_PRINTS slots from ONE instantaneous read, so a caller
    ///      could pick a favorable transient instant and bake three copies of that single median as
    ///      the future fallback (zero temporal diversity), and repeated calls doubled as a breaker
    ///      reset lever. Now a call is a strict behavioral subset of checkPrice (breaker reset plus
    ///      at most one distinct-block ring write on a genuinely agreeing print), so it grants a
    ///      caller nothing checkPrice does not already; the W2-10 guarantee moved to the factory:
    ///      createMarket refuses to create a market for a multi-source token until the ring is FULL
    ///      (see MarketFactory and fallbackSeeded), so the fallback path still exists from block one,
    ///      now backed by prints from AGREED_PRINTS distinct blocks. No-op when sources do not
    ///      currently agree on an OK print: only genuinely agreeing prints ever enter the ring, so
    ///      this cannot inject an off-market fallback. Seeded prints are overwritten by later
    ///      agreeing prints from checkPrice on normal fills and settlements.
    /// @param token The token whose ring is being seeded.
    /// @return ringCount The number of agreed prints stored after seeding (saturates at AGREED_PRINTS).
    function primeFallback(address token) external returns (uint8 ringCount) {
        BreakerState storage b = _breakers[token];
        (uint256 median, Types.PriceStatus gate, bool devFail) = _evaluate(token);
        if (gate == Types.PriceStatus.OK && !devFail) {
            b.failedRounds = 0;
            b.cooldownUntil = 0;
            _recordAgreedPrint(token, b, median);
        }
        return b.ringCount;
    }

    /// @notice True when `token`'s fallback settlement path is guaranteed available (or can never
    ///         be needed). A token with fewer than two configured sources cannot fail the pairwise
    ///         deviation guard (the spread over one read is zero), so it can never enter COOLDOWN
    ///         and never serves the fallback; every other token requires a FULL agreed-print ring.
    /// @dev Wave-2b R-7 companion to the one-print-per-block primeFallback: MarketFactory consults
    ///      this at createMarket so no multi-source market is ever created with an empty or partial
    ///      ring (the W2-10 permanent-COOLDOWN free option), which also closes the
    ///      listed-during-deviation gap (re-listing F1): if sources disagree at creation time the
    ///      ring cannot be completed and creation is refused instead of shipping the free option.
    /// @param token The token whose fallback readiness is queried.
    /// @return seeded True when the token needs no fallback or its ring is fully seeded.
    function fallbackSeeded(address token) external view returns (bool seeded) {
        if (_configs[token].sources.length < 2) return true;
        return _breakers[token].ringCount >= AGREED_PRINTS;
    }

    /// @inheritdoc IOracleRouter
    function peekPrice(address token) external view returns (uint256 price1e18, Types.PriceStatus status) {
        return _peekPrice(token);
    }

    /// @dev Internal peek: the price checkPrice WOULD serve right now (median when sources agree,
    ///      else the predicted fallback ring-median once fallback is due), without mutating state.
    ///      Shared by peekPrice and the opening breaker so the breaker validates spot against the
    ///      price the market would actually use, including during multi-source fallback (W2-14).
    function _peekPrice(address token) internal view returns (uint256 price1e18, Types.PriceStatus status) {
        (uint256 median, Types.PriceStatus gate, bool devFail) = _evaluate(token);
        if (gate != Types.PriceStatus.OK) return (0, gate);
        if (!devFail) return (median, Types.PriceStatus.OK);

        BreakerState storage b = _breakers[token];
        uint8 rounds = b.failedRounds;
        // Predict the increment checkPrice would apply right now.
        if (rounds < FALLBACK_AFTER_ROUNDS && b.cooldownUntil != 0 && block.timestamp >= b.cooldownUntil) {
            rounds += 1;
        }
        if (rounds >= FALLBACK_AFTER_ROUNDS) {
            (uint256 fb, bool has) = _fallbackPrice(b);
            if (has) return (fb, Types.PriceStatus.OK);
        }
        return (0, Types.PriceStatus.COOLDOWN);
    }

    /// @inheritdoc IOracleRouter
    /// @dev Tier-gated listing policy (increment 1):
    ///      - D_THIN: never listable (fails cost-to-move at any useful cap).
    ///      - Every tier requires at least its source minimum (MIN_SOURCES for A_MAJOR, 1 for the
    ///        aggregating B_DEEP / C_MID tiers).
    ///      - A_MAJOR: listable on the source requirement AND at least one configured source that
    ///        DECLARES itself independent of any AMM settlement pool (IIndependentSource, a real
    ///        Chainlink/Pyth feed). A major is priced by such a feed, so pool depth is irrelevant
    ///        to its manipulation resistance and no depth floor, seasoning, or cost-to-move cap
    ///        applies. Enforcing the independent source in code (wave-2 TO-1) stops a compromised
    ///        owner from classifying a pool-only token as A_MAJOR to escape the depth/cost-to-move
    ///        caps while pointing every source at owned pools.
    ///      - B_DEEP / C_MID: additionally require aggregate tracked depth >= the aggregate-depth
    ///        floor AND the primary pool seasoned past seasoningWindow AND that same pool's
    ///        observation buffer able to serve the seasoning lookback (cardinality coverage). The
    ///        depth floor and cost-to-move cap together keep max attacker profit below manipulation
    ///        cost; seasoning plus the depth floor deny freshly wash-inflated fake depth.
    function isListable(address token) external view returns (bool) {
        TierConfig storage tc = _tierConfigs[token];
        SettlementTier tier = tc.tier;
        if (tier == SettlementTier.D_THIN) return false;

        TokenConfig storage cfg = _configs[token];
        if (cfg.sources.length < _minSourcesForTier(tier)) return false;

        // A_MAJOR must carry at least one genuinely settlement-pool-independent source (a real
        // Chainlink/Pyth feed), enforced here rather than merely trusted (wave-2 TO-1).
        if (tier == SettlementTier.A_MAJOR) return _hasIndependentSource(token);

        // B_DEEP / C_MID: aggregate-depth floor, seasoning, and cardinality coverage. The depth is
        // the manipulation-resistant time-averaged in-range reserve; a pool without declared
        // geometry contributes zero, so it cannot be listed on a same-block-inflatable balance.
        uint256 floor = tc.aggregateDepthFloorUsd1e18 != 0
            ? tc.aggregateDepthFloorUsd1e18
            : (cfg.liquidityFloor == 0 ? DEFAULT_LIQUIDITY_FLOOR : cfg.liquidityFloor);
        if (_trackedLiquidity(token) < floor) return false;
        if (!_seasoned(token, tc.seasoningWindow)) return false;
        // W2-13: every tracked (cost-to-move) pool must be one the settlement source actually reads.
        if (!_trackedPoolsCoveredBySource(token)) return false;
        return true;
    }

    /// @dev W2-13 cross-check: every tracked pool sizing the cost-to-move cap must be a pool the
    ///      settlement source (sources[0], the aggregating adapter for a B_DEEP / C_MID token)
    ///      actually reads, so the payout cap is sized to the exact pools an attacker would have to
    ///      move. Enforced only when that source implements ISettlementPoolSet (the production
    ///      CrossPoolTwapAdapter does); a source that does not expose its pool set cannot be
    ///      cross-checked and is treated as covered. Never reverts.
    function _trackedPoolsCoveredBySource(address token) internal view returns (bool) {
        SourceConfig[] storage sources = _configs[token].sources;
        if (sources.length == 0) return false;
        address src = address(sources[0].source);
        address[] storage pools = _configs[token].trackedPools;
        for (uint256 i = 0; i < pools.length; i++) {
            try ISettlementPoolSet(src).readsPool(token, pools[i]) returns (bool reads) {
                if (!reads) return false;
            } catch {
                // Source does not expose a pool set: no cross-check possible, treat as covered.
                return true;
            }
        }
        return true;
    }

    /// @dev True when at least one configured source declares itself independent of any AMM
    ///      settlement pool for `token` (implements IIndependentSource and returns true).
    ///      Pool-derived sources (TWAP adapters) do not implement the marker, so the staticcall
    ///      reverts and is treated as not-independent; any revert or malformed return is likewise
    ///      not-independent. Never reverts.
    function _hasIndependentSource(address token) internal view returns (bool) {
        SourceConfig[] storage sources = _configs[token].sources;
        for (uint256 i = 0; i < sources.length; i++) {
            try IIndependentSource(address(sources[i].source)).isIndependent(token) returns (bool independent) {
                if (independent) return true;
            } catch {
                continue;
            }
        }
        return false;
    }

    /// @notice Estimated cost to move the settlement reference through the settlement window, in
    ///         USD (1e18). A monotonic (here linear) function of aggregate 2%-depth via the
    ///         token's governance-tunable costToMoveCoeff: costToMove = aggregateDepth *
    ///         costToMoveCoeff / COST_COEFF_ONE.
    /// @dev PROXY, and the coefficient is a CALIBRATION PARAMETER, never a magic number. The
    ///      AMM-oracle-manipulation research (docs/audit/wave1/memecoin-price-sourcing-research.md)
    ///      derives that cost-to-move scales with aggregate liquidity, grows with the TWAP window,
    ///      and collapses without external arbitrage; it explicitly FLAGS the exact closed-form
    ///      coefficient as unverified and instructs calibrating it empirically against the real
    ///      pool. This function therefore relies only on the robust STRUCTURE (monotonic increasing
    ///      in aggregate depth) and exposes the coefficient (and the safety factor) as governance
    ///      knobs. aggregate 2%-depth is proxied by trackedLiquidity (twice the summed quote-side
    ///      value across tracked pools), the same manipulation-aware measure used for the floor.
    ///      Returns 0 for a token with no tracked depth or a zero coefficient (nothing to cap
    ///      against). This is a public view for UX/quoting; the cap the factory bakes into a market
    ///      is derived at creation from the immutable liquidity snapshot (see maxMarketPayoutCap1e18
    ///      and MarketFactory.createMarket), never re-read live in the fill path.
    ///
    ///      RECALIBRATION FOR THE W2-1b (wave-3 R-1) BASIS. The depth this coefficient multiplies has
    ///      evolved: wave 1 used the instantaneous quote balanceOf; wave 2 (W2-1) re-based it onto the
    ///      time-averaged in-range VIRTUAL quote reserve; wave 3 (W2-1b) clamps that virtual reserve by
    ///      the pool's real quote balance, i.e. MIN(virtual in-range reserve, real quote balanceOf).
    ///      For an HONEST deep-and-spread pool the real balance comfortably exceeds the in-range
    ///      virtual reserve, so the MIN resolves to the virtual reserve and the basis is IDENTICAL to
    ///      W2-1: the DEFAULT_LIQUIDITY_FLOOR and the per-token aggregateDepthFloorUsd1e18 /
    ///      costToMoveCoeff calibrated for W2-1 carry over unchanged, and an honest deep-but-spread
    ///      pool is NOT under-listed. Only a CONCENTRATED pool (a huge virtual reserve backed by little
    ///      real quote) is clamped down to its genuine capital, which is exactly the intended tightening
    ///      and cannot over-list a thin-but-concentrated pool. Because both reads are quoted in the same
    ///      raw quote-token units, the MIN introduces no unit change and no numeric re-tune of the
    ///      shipped constants; governance calibration stays the empirical per-token exercise the
    ///      price-sourcing research prescribes, now targeting genuine cross-band-bounded capital.
    function costToMoveEstimate1e18(address token) public view returns (uint256) {
        uint256 coeff = _tierConfigs[token].costToMoveCoeff;
        if (coeff == 0) return 0;
        return Math.mulDiv(_trackedLiquidity(token), coeff, COST_COEFF_ONE);
    }

    /// @notice Absolute maximum position payout (USD 1e18) a market on `token` may ever produce:
    ///         costToMoveEstimate1e18(token) / safetyFactor. This is the core inequality of the
    ///         design (max_payout <= costToMove / safetyFactor): the factory bounds a new market's
    ///         OI-derived cap by this value so a manipulator's maximum realizable payout sits a
    ///         safety factor below the cost of moving the price.
    /// @dev Returns type(uint256).max (unbounded) for Tier A_MAJOR and for any tier whose
    ///      costToMoveCoeff is zero: majors are priced by an independent feed and need no
    ///      cost-to-move cap, so their market cap is governed solely by the oiCapBps-of-snapshot
    ///      basis. For B_DEEP / C_MID with a positive coefficient this returns the finite absolute
    ///      cap. Reads live trackedLiquidity for UX; the factory instead derives the market's baked
    ///      cap from the creation snapshot in the same transaction (identical value, then frozen).
    function maxMarketPayoutCap1e18(address token) public view returns (uint256) {
        TierConfig storage tc = _tierConfigs[token];
        if (tc.tier == SettlementTier.A_MAJOR || tc.costToMoveCoeff == 0) return type(uint256).max;
        return costToMoveEstimate1e18(token) / tc.safetyFactor;
    }

    /// @inheritdoc IOracleRouter
    /// @dev Opening-side spot-vs-TWAP deviation breaker. NEVER consulted by settle, close, or the
    ///      forced-unwind path (only Market.fillOffer calls it), so it can only ever DENY OPENING a
    ///      new position, never block a settlement or strand escrow. A token with no spot source
    ///      configured (every Tier A major, and any unconfigured token) is always allowed: its
    ///      independent feed needs no pool spot-vs-TWAP check. Otherwise it reads the settlement
    ///      reference (peekPrice: the price checkPrice WOULD serve now, median-of-sources or the
    ///      fallback ring-median) and the aggregated spot from the configured spot source, and
    ///      denies opening when their absolute deviation exceeds deviationBreakerBps. The comparison
    ///      is division-free and exact, mirroring the pairwise source-deviation guard: deny iff
    ///      (max - min) * BPS > deviationBreakerBps * min. If either reference is unreadable it
    ///      denies conservatively (no opening at an unknown price), which is fail-safe because
    ///      settlement is unaffected. Using peekPrice rather than the raw source median makes the
    ///      breaker validate spot against the SAME price the market would settle at, including
    ///      during a sustained multi-source fallback (wave-2 W2-14).
    function openingAllowed(address token) external view returns (bool allowed, uint8 reason) {
        TierConfig storage tc = _tierConfigs[token];
        ISpotSource spotSource = tc.spotSource;
        if (address(spotSource) == address(0)) return (true, OPENING_ALLOWED);

        (uint256 twap, Types.PriceStatus gate) = _peekPrice(token);
        if (gate != Types.PriceStatus.OK || twap == 0) return (false, OPENING_DENIED_REFERENCE_UNAVAILABLE);

        uint256 spot;
        try spotSource.readSpot(token) returns (uint256 s, bool ok) {
            if (!ok || s == 0 || s > MAX_SOURCE_PRICE) return (false, OPENING_DENIED_REFERENCE_UNAVAILABLE);
            spot = s;
        } catch {
            return (false, OPENING_DENIED_REFERENCE_UNAVAILABLE);
        }

        uint256 lo = spot < twap ? spot : twap;
        uint256 hi = spot < twap ? twap : spot;
        if ((hi - lo) * BPS > uint256(tc.deviationBreakerBps) * lo) {
            return (false, OPENING_DENIED_DEVIATION);
        }
        return (true, OPENING_ALLOWED);
    }

    /// @inheritdoc IOracleRouter
    /// @dev DELIBERATE, MANIPULATION-AWARE APPROXIMATION: this sums, over every tracked pool, twice
    ///      the pool's QUOTE-side value (normalized to 1e18). Doubling the quote side approximates
    ///      total two-sided pool value without ever consulting the priced token's own price, so it
    ///      cannot be skewed through the token leg. USDG-quoted pools (the default) count 2x the
    ///      quote amount directly; WETH-quoted pools declared via setPoolQuote count 2x the quote
    ///      amount converted to USD through the configured Chainlink ETH/USD feed (a failing,
    ///      stale, or non-positive feed conservatively zeroes that pool's contribution). It is used
    ///      ONLY for the LISTING-TIME liquidity floor, the CREATION-TIME OI-cap snapshot, and the
    ///      cost-to-move payout cap, NEVER for pricing or settlement.
    ///
    ///      MANIPULATION RESISTANCE (wave-2 W2-1 fix, hardened wave-3 R-1 / W2-1b). For value-bearing
    ///      (B_DEEP / C_MID) tokens, whose payout cap is DERIVED from this depth, the quote-side amount
    ///      is MIN(time-averaged in-range virtual reserve, real quote balanceOf) over the pool's
    ///      settlement window (UniV3TwapLib.consultMeanQuoteReserve read from the same observation
    ///      buffer the settlement TWAP consults, clamped by the pool's real quote balance), NOT an
    ///      instantaneous balanceOf alone and NOT the virtual reserve alone. A single-sided,
    ///      out-of-range just-in-time v3 deposit inflates only balanceOf, never the time-averaged
    ///      in-range liquidity, so it can no longer raise the listing floor, the creation snapshot, or
    ///      the cost-to-move cap: one block of JIT liquidity earns at most one block of weight over the
    ///      whole window. Concentrating a small amount of REAL quote in a razor-thin tick band inflates
    ///      the virtual reserve ~1000x but not the real quote balance, so the MIN clamps the reported
    ///      depth back to genuine capital (see _concentrationAwareQuoteAmount). A pool of such a token
    ///      that has no geometry declared (setPoolGeometry) or whose buffer cannot cover the window
    ///      contributes zero depth. For Tier A_MAJOR the quote-side amount is the plain balanceOf as in
    ///      wave 1: a major is priced by an independent feed, so inflating its pool balance can raise
    ///      its OI cap but never move its settlement price, and the capped-payout invariant still
    ///      bounds every position by the escrow.
    function trackedLiquidity(address token) external view returns (uint256 liquidityUsd1e18) {
        return _trackedLiquidity(token);
    }

    /// @inheritdoc IOracleRouter
    /// @dev Callable by anyone: it only copies the current publicly computable trackedLiquidity
    ///      into storage, so an idempotent overwrite is harmless. The factory is the sole reader
    ///      and calls it once at market creation.
    function snapshotLiquidity(address token) external returns (uint256 liquidityUsd1e18) {
        liquidityUsd1e18 = _trackedLiquidity(token);
        liquiditySnapshot[token] = liquidityUsd1e18;
        emit LiquiditySnapshotTaken(token, liquidityUsd1e18);
    }

    // ===============================================================
    // Public views for configuration and breaker introspection
    // ===============================================================

    /// @notice Returns the configured sources of a token.
    function sourcesOf(address token) external view returns (SourceConfig[] memory) {
        return _configs[token].sources;
    }

    /// @notice Returns a token's guard configuration, with the deviation bound fully resolved.
    function guardsOf(address token)
        external
        view
        returns (Tier tier, uint16 deviationBps, uint256 liquidityFloor1e18)
    {
        TokenConfig storage cfg = _configs[token];
        tier = cfg.tier;
        deviationBps = uint16(_deviationBps(cfg));
        liquidityFloor1e18 = cfg.liquidityFloor == 0 ? DEFAULT_LIQUIDITY_FLOOR : cfg.liquidityFloor;
    }

    /// @notice Returns the tracked pool set of a token.
    function trackedPoolsOf(address token) external view returns (address[] memory) {
        return _configs[token].trackedPools;
    }

    /// @notice Returns a token's settlement-tier configuration.
    /// @return tier The settlement tier (A_MAJOR when unconfigured).
    /// @return aggregateDepthFloorUsd1e18 The aggregate-depth floor for B/C (0 = fall back).
    /// @return seasoningWindow The minimum primary-pool observation age in seconds (0 = disabled).
    /// @return costToMoveCoeff The cost-to-move calibration coefficient (scale COST_COEFF_ONE).
    /// @return safetyFactor The cost-to-move divisor for the payout cap.
    /// @return deviationBreakerBps The opening-side spot-vs-TWAP threshold in bps.
    /// @return spotSource The spot aggregator for the opening breaker (0 = breaker disabled).
    /// @return set True once setTierConfig has written this token.
    function tierConfigOf(address token)
        external
        view
        returns (
            SettlementTier tier,
            uint256 aggregateDepthFloorUsd1e18,
            uint32 seasoningWindow,
            uint256 costToMoveCoeff,
            uint256 safetyFactor,
            uint16 deviationBreakerBps,
            address spotSource,
            bool set
        )
    {
        TierConfig storage tc = _tierConfigs[token];
        return (
            tc.tier,
            tc.aggregateDepthFloorUsd1e18,
            tc.seasoningWindow,
            tc.costToMoveCoeff,
            tc.safetyFactor,
            tc.deviationBreakerBps,
            address(tc.spotSource),
            tc.set
        );
    }

    /// @notice Returns a token's breaker counters.
    function breakerOf(address token) external view returns (uint64 cooldownUntil, uint8 failedRounds) {
        BreakerState storage b = _breakers[token];
        return (b.cooldownUntil, b.failedRounds);
    }

    /// @notice Returns the ring buffer of agreed prints (raw slots plus fill metadata).
    function agreedPrintsOf(address token)
        external
        view
        returns (uint256[3] memory prints, uint8 count, uint8 nextIndex)
    {
        BreakerState storage b = _breakers[token];
        return (b.ring, b.ringCount, b.ringIndex);
    }

    // ===============================================================
    // Internals
    // ===============================================================

    /// @dev Gathers fresh source reads and computes median plus deviation verdict.
    ///      gate semantics: UNAVAILABLE (zero fresh sources), STALE (some but fewer than
    ///      MIN_SOURCES fresh), or OK meaning "enough fresh sources; consult devFail".
    function _evaluate(address token) internal view returns (uint256 median, Types.PriceStatus gate, bool devFail) {
        SourceConfig[] storage sources = _configs[token].sources;
        uint256 n = sources.length;
        uint256[] memory fresh = new uint256[](n);
        uint256 count = 0;

        for (uint256 i = 0; i < n; i++) {
            SourceConfig storage sc = sources[i];
            try sc.source.read(token) returns (uint256 p, uint256 updatedAt, bool ok) {
                if (!ok) continue;
                if (p == 0 || p > MAX_SOURCE_PRICE) continue;
                if (updatedAt + sc.maxStaleness < block.timestamp) continue;
                fresh[count] = p;
                count += 1;
            } catch {
                continue;
            }
        }

        if (count < _minSourcesForTier(_tierConfigs[token].tier)) {
            return (0, count == 0 ? Types.PriceStatus.UNAVAILABLE : Types.PriceStatus.STALE, false);
        }

        _sortAscending(fresh, count);
        median = count % 2 == 1 ? fresh[count / 2] : (fresh[count / 2 - 1] + fresh[count / 2]) / 2;

        // Max pairwise deviation is by construction the spread between the lowest and highest
        // fresh prints. Compared multiplicatively against the bound without division so the
        // guard is exact to the wei: fail iff (max - min) * 10000 > bps * min.
        uint256 lowest = fresh[0];
        uint256 highest = fresh[count - 1];
        devFail = (highest - lowest) * BPS > _deviationBps(_configs[token]) * lowest;

        return (median, Types.PriceStatus.OK, devFail);
    }

    /// @dev Resolves the effective deviation bound in bps for a token config.
    function _deviationBps(TokenConfig storage cfg) internal view returns (uint256) {
        if (cfg.maxPairwiseDeviationBps != 0) return cfg.maxPairwiseDeviationBps;
        return cfg.tier == Tier.B ? TIER_B_DEFAULT_DEVIATION_BPS : TIER_A_DEFAULT_DEVIATION_BPS;
    }

    /// @dev Minimum fresh, agreeing sources required by a settlement tier. A_MAJOR (the default)
    ///      keeps MIN_SOURCES: no single independent source may settle. The aggregating tiers
    ///      B_DEEP / C_MID require 1, because their lone source is itself an aggregate across every
    ///      registered pool. D_THIN is never listable, so its value only guards a defensive
    ///      settlement read; MIN_SOURCES is the conservative choice.
    function _minSourcesForTier(SettlementTier tier) internal pure returns (uint256) {
        if (tier == SettlementTier.B_DEEP || tier == SettlementTier.C_MID) return 1;
        return MIN_SOURCES;
    }

    /// @dev Seasoning gate: the token's PRIMARY tracked pool (trackedPools[0]) must be able to
    ///      serve an observe() lookback of `seasoningWindow` seconds, i.e. its oldest stored
    ///      observation reaches at least that far back. A window of 0 disables the gate. A token
    ///      with no tracked pool cannot be seasoned. Because the observation buffer that backs the
    ///      seasoning lookback is the very same buffer the settlement TWAP reads, and governance
    ///      sets seasoningWindow at or above the settlement TWAP window, a pass here also proves the
    ///      pool's observation cardinality covers the TWAP window (otherwise observe would revert
    ///      "OLD"). This is the cheap on-chain proxy for "has existed and traded a while".
    function _seasoned(address token, uint32 seasoningWindow) internal view returns (bool) {
        if (seasoningWindow == 0) return true;
        address[] storage pools = _configs[token].trackedPools;
        if (pools.length == 0) return false;
        return _poolCoversWindow(pools[0], seasoningWindow);
    }

    /// @dev True when `pool` can serve a Uniswap v3 observe() over `window` seconds without
    ///      reverting (its oldest stored observation predates the window). Never reverts: a pool
    ///      whose buffer is too shallow, or any other observe failure, yields false.
    function _poolCoversWindow(address pool, uint32 window) internal view returns (bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        try IUniswapV3Pool(pool).observe(secondsAgos) returns (int56[] memory, uint160[] memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Pushes an agreed print into the ring, AT MOST ONCE PER BLOCK (wave-2b R-7). The ring
    ///      backs the FALLBACK settlement price and its median is only meaningful when the stored
    ///      prints carry temporal diversity: without this gate a single transaction could invoke
    ///      checkPrice (or primeFallback) AGREED_PRINTS times and bake three copies of one
    ///      timing-chosen median as the future fallback. Skipping the duplicate write never skips
    ///      the caller's breaker reset or served price: an agreeing print remains genuine evidence;
    ///      only its REDUNDANT same-block copy is refused. The ringCount != 0 term keeps the very
    ///      first print of a token's life acceptable even at lastPrintBlock's zero default.
    function _recordAgreedPrint(address token, BreakerState storage b, uint256 median) internal {
        if (b.ringCount != 0 && b.lastPrintBlock == uint64(block.number)) return;
        b.lastPrintBlock = uint64(block.number);
        b.ring[b.ringIndex] = median;
        b.ringIndex = (b.ringIndex + 1) % AGREED_PRINTS;
        if (b.ringCount < AGREED_PRINTS) b.ringCount += 1;
        emit PrintAccepted(token, median);
    }

    /// @dev Median of the agreed-print ring buffer; has = false until 3 prints ever happened.
    function _fallbackPrice(BreakerState storage b) internal view returns (uint256 price, bool has) {
        if (b.ringCount < AGREED_PRINTS) return (0, false);
        uint256 a = b.ring[0];
        uint256 c = b.ring[1];
        uint256 d = b.ring[2];
        // Median of three without sorting storage.
        if (a > c) (a, c) = (c, a);
        if (c > d) (c, d) = (d, c);
        if (a > c) (a, c) = (c, a);
        return (c, true);
    }

    /// @dev In-place insertion sort of the first `count` elements.
    function _sortAscending(uint256[] memory arr, uint256 count) internal pure {
        for (uint256 i = 1; i < count; i++) {
            uint256 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                j -= 1;
            }
            arr[j] = key;
        }
    }

    /// @dev Sum over tracked pools of twice the normalized quote-side USD value. The quote-side
    ///      AMOUNT is manipulation-resistant AND concentration-aware for value-bearing (B_DEEP /
    ///      C_MID) tokens (MIN(time-averaged in-range virtual reserve, real quote balanceOf), see
    ///      _poolQuoteAmount and _concentrationAwareQuoteAmount) and a plain balanceOf for Tier
    ///      A_MAJOR pools (priced by an independent feed, so a same-block balance spike cannot be
    ///      monetised). USDG-quoted pools contribute 2 x amount. Pools declared via setPoolQuote
    ///      contribute 2 x amount x feedPrice, all normalized to 1e18. See trackedLiquidity.
    function _trackedLiquidity(address token) internal view returns (uint256 total) {
        address[] storage pools = _configs[token].trackedPools;
        bool manipResistant = _isPoolPricedTier(_tierConfigs[token].tier);
        uint32 windowFloor = manipResistant ? _settlementWindowOf(token) : 0;
        for (uint256 i = 0; i < pools.length; i++) {
            address pool = pools[i];
            PoolQuoteConfig storage q = poolQuotes[pool];
            uint256 quoteAmount = _poolQuoteAmount(pool, q, manipResistant, windowFloor);
            if (quoteAmount == 0) continue;
            if (q.quoteToken == address(0)) {
                total += quoteAmount * usdgScale * 2;
            } else {
                total += _quoteAmountUsd(quoteAmount, q) * 2;
            }
        }
    }

    /// @dev The token's settlement TWAP window as reported by its settlement source (sources[0],
    ///      the aggregating adapter for a B_DEEP / C_MID token), used as the FLOOR on every tracked
    ///      pool's geometry window (wave-2b R-9). A source that does not expose ISettlementWindow
    ///      (or reverts) yields 0 (no floor beyond nonzero), matching the W2-13 convention for
    ///      sources that cannot be cross-checked. Never reverts.
    function _settlementWindowOf(address token) internal view returns (uint32) {
        SourceConfig[] storage sources = _configs[token].sources;
        if (sources.length == 0) return 0;
        try ISettlementWindow(address(sources[0].source)).twapWindow(token) returns (uint32 window) {
            return window;
        } catch {
            return 0;
        }
    }

    /// @dev Raw quote-side amount of one tracked pool, in raw quote-token units.
    ///      manipResistant (value-bearing B_DEEP / C_MID tiers): the CONCENTRATION-AWARE depth
    ///      measure, MIN(time-averaged in-range virtual quote reserve, real quote-token balanceOf).
    ///      See _concentrationAwareQuoteAmount for the full W2-1b derivation. A pool without geometry,
    ///      or one whose observation buffer cannot cover the window, contributes 0, so a just-in-time
    ///      single-sided LP deposit cannot raise it and a geometry-less value-bearing token cannot
    ///      clear the depth floor. windowFloor (wave-2b R-9): the token's settlement TWAP window; a
    ///      pool whose declared geometry window is SHORTER also contributes 0, so a short window can
    ///      never shrink the averaging horizon below the horizon the settlement TWAP itself uses (a
    ///      near-instantaneous window would re-open the W2-1 single-block inflation this measure
    ///      exists to resist). Otherwise (Tier A_MAJOR, priced by an independent feed): the
    ///      instantaneous quote balanceOf, unchanged from wave 1.
    function _poolQuoteAmount(address pool, PoolQuoteConfig storage q, bool manipResistant, uint32 windowFloor)
        internal
        view
        returns (uint256)
    {
        if (manipResistant) {
            PoolGeometry storage g = poolGeometry[pool];
            if (g.window == 0) return 0;
            if (g.window < windowFloor) return 0;
            (uint256 reserve, bool ok) =
                UniV3TwapLib.consultMeanQuoteReserve(IUniswapV3Pool(pool), g.window, g.quoteIsToken0);
            if (!ok) return 0;
            return _concentrationAwareQuoteAmount(pool, q, reserve);
        }
        address quoteTok = q.quoteToken == address(0) ? usdg : q.quoteToken;
        return IERC20(quoteTok).balanceOf(pool);
    }

    /// @dev CONCENTRATION-AWARE quote-depth cap (wave-3 R-1, alias W2-1b). Returns the smaller of the
    ///      time-averaged in-range VIRTUAL quote reserve and the pool's REAL quote-token balance, both
    ///      in raw quote-token units, so an attacker cannot make the reported depth exceed the genuine
    ///      quote capital that resists a settlement-sized move.
    ///
    ///      WHY THE VIRTUAL RESERVE ALONE IS NOT ENOUGH. The wave-2 W2-1 fix re-based depth onto the
    ///      time-averaged in-range virtual quote reserve, which defeats single-sided out-of-range JIT
    ///      and single-block spikes. But the virtual in-range reserve is L * sqrtP (or L / sqrtP), and
    ///      L can be made enormous by concentrating a SMALL amount of REAL two-sided quote in a
    ///      razor-thin tick band: for quote Q packed into a band of half-width d, L ~ 2Q / (sqrtP * d),
    ///      so the reported virtual reserve ~ 2Q / d. At d = 0.1 percent, ~$10k of real quote reports
    ///      as ~$10M of depth (~1000x). The virtual reserve measures LOCAL depth at the current tick;
    ///      the cost-to-move cap (linear in depth) assumes that depth extends across the settlement
    ///      move, but concentrated liquidity does not: once price crosses the thin band, the resisting
    ///      depth collapses to ~0, so holding the reference displaced across the TWAP window is nearly
    ///      free. That defeats the payout cap ~200x for a pool-priced (B_DEEP / C_MID) market.
    ///
    ///      WHY MIN WITH THE REAL BALANCE CLOSES IT. Concentration inflates the virtual reserve but
    ///      NOT the real quote-token balance: packing $10k of quote into a thin band leaves the pool
    ///      holding $10k of quote, not $10M. The real balance is a hard physical ceiling on the quote
    ///      an attacker could ever extract while moving the price, hence a ceiling on genuine
    ///      cross-band depth. Taking the MIN clamps the concentration-inflatable virtual reserve down
    ///      to genuine capital, so the cheap capital-efficient concentration attack (its whole premise
    ///      being to report far more depth than the capital committed) can no longer inflate the cap.
    ///
    ///      DIRECTIONAL / FAIL-SAFE ANALYSIS. The two reads are gameable in OPPOSITE, non-overlapping
    ///      ways, and MIN is the fail-safe combiner of both:
    ///        - virtual reserve: manipulation-resistant to single-block moves (time-averaged from the
    ///          settlement TWAP's own observation buffer) but INFLATABLE UPWARD by sustained thin-band
    ///          concentration;
    ///        - real balanceOf: NOT inflatable by concentration, and single-block-inflatable upward
    ///          only by actually PLACING quote in the pool (a same-block out-of-range mint), which
    ///          means the reported depth never exceeds quote that was genuinely in the pool at the
    ///          snapshot instant.
    ///      MIN understates depth whenever EITHER read is smaller, and can only be driven up by
    ///      raising BOTH, which forces the concentration attacker to additionally commit (or flash) the
    ///      FULL nominal quote, collapsing the capital efficiency the attack depends on. MIN therefore
    ///      only ever UNDERSTATES genuine depth, never overstates it, the required direction for a
    ///      listing floor and a cost-to-move cap. This also bounds the theoretical degenerate-average
    ///      overflow (re-jit note 2): a near-unbounded virtual reserve is clamped to a realistic token
    ///      balance before the *2 / *usdgScale in _trackedLiquidity.
    ///
    ///      WHY NOT INTEGRATE ACROSS THE BAND (Option B). Measuring liquidity across the +/-K tick band
    ///      the move spans requires reading the instantaneous per-tick liquidityNet distribution
    ///      (pool.ticks), which is itself single-block manipulable (mint/burn across ticks in one
    ///      block), re-opening exactly the single-block inflation W2-1 removed. The MIN needs no
    ///      per-tick data and its only inflation vector is committing real capital equal to the
    ///      reported depth, so it is both simpler and strictly more manipulation-resistant.
    /// @param pool The tracked Uniswap v3 pool.
    /// @param q The pool's quote configuration (zero quoteToken means USDG-quoted).
    /// @param virtualReserve The time-averaged in-range virtual quote reserve from consultMeanQuoteReserve.
    /// @return The MIN of the virtual reserve and the real quote balance, in raw quote-token units.
    function _concentrationAwareQuoteAmount(address pool, PoolQuoteConfig storage q, uint256 virtualReserve)
        internal
        view
        returns (uint256)
    {
        address quoteTok = q.quoteToken == address(0) ? usdg : q.quoteToken;
        uint256 realQuoteBalance = IERC20(quoteTok).balanceOf(pool);
        return virtualReserve < realQuoteBalance ? virtualReserve : realQuoteBalance;
    }

    /// @dev USD value (1e18) of `quoteAmount` of a non-USDG quote asset via the configured feed;
    ///      0 on any feed failure so a broken feed can only understate liquidity (conservative for
    ///      floors and caps).
    function _quoteAmountUsd(uint256 quoteAmount, PoolQuoteConfig storage q) internal view returns (uint256) {
        if (quoteAmount == 0) return 0;
        try q.feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) return 0;
            if (updatedAt + q.feedMaxStaleness < block.timestamp) return 0;
            uint256 price1e18 = _feedTo1e18(uint256(answer), q.feedDecimals);
            if (price1e18 > MAX_SOURCE_PRICE) return 0;
            return (quoteAmount * q.quoteScale) * price1e18 / 1e18;
        } catch {
            return 0;
        }
    }

    /// @dev True for the value-bearing, pool-priced settlement tiers (B_DEEP / C_MID) whose payout
    ///      cap is derived from pool depth. For these the depth measure MUST be manipulation
    ///      resistant, so _trackedLiquidity reads the time-averaged in-range reserve, never a
    ///      single-block-inflatable balanceOf.
    function _isPoolPricedTier(SettlementTier tier) internal pure returns (bool) {
        return tier == SettlementTier.B_DEEP || tier == SettlementTier.C_MID;
    }

    /// @dev Rescales a raw feed answer from `dec` decimals to 18 decimals.
    function _feedTo1e18(uint256 raw, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return raw;
        if (dec < 18) return raw * 10 ** (18 - dec);
        return raw / 10 ** (dec - 18);
    }
}
