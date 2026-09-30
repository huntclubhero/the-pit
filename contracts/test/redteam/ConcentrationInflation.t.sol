// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {MarketFactory} from "../../src/core/MarketFactory.sol";
import {PauseGuardian} from "../../src/core/PauseGuardian.sol";
import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {IPriceSource} from "../../src/oracle/adapters/IPriceSource.sol";
import {FullMath} from "../../src/oracle/vendor/FullMath.sol";
import {MockPitPoints} from "../mocks/MockPitPoints.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";

/// @dev Minimal functional 6-decimal USDG. mint models depositing real quote into a pool (the pool's
///      balanceOf is a plain ERC20 balance), and supports escrow transfers for the OI-capacity test.
contract ConcUSDG {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Always-OK price stub satisfying the B_DEEP single-source minimum and an OK entry price.
contract ConcSource is IPriceSource {
    function read(address) external view returns (uint256, uint256, bool) {
        return (1e18, block.timestamp, true);
    }
}

/// @title Concentration inflation of the cost-to-move depth, DEFEATED (wave-3 R-1 / W2-1b)
/// @notice Regression suite for the R-1 finding: the wave-2 W2-1 fix re-based cost-to-move depth onto
///         the time-averaged in-range VIRTUAL quote reserve (L * sqrtP), which is ~1000x inflatable by
///         concentrating a SMALL amount of REAL quote into a razor-thin tick band (at +/-0.1 percent,
///         ~$10k of real quote reports as ~$10M of virtual depth). The virtual reserve measures LOCAL
///         depth at the current tick, but the cost-to-move cap assumes depth extends across the
///         settlement-sized move, so concentration defeats the cap ~200x. The fix clamps the virtual
///         reserve by the pool's real quote balanceOf: concentration inflates the virtual reserve but
///         NOT the real capital, so the reported depth (and the baked payout cap) track genuine
///         cross-band capital, not the concentrated tick.
contract ConcentrationInflationTest is Test {
    ConcUSDG internal usdg;
    OracleRouter internal router;
    MockPitPoints internal points;
    PauseGuardian internal guardian;
    MarketFactory internal factory;
    ConcSource internal source;

    address internal owner = makeAddr("owner");

    // The CONCENTRATED token: a thin band of REAL quote reports as a huge virtual reserve.
    address internal concToken = makeAddr("concentratedMemecoin");
    MockV3Pool internal concPool;

    // The HONEST-DEEP twin: the SAME virtual reserve, but genuinely backed by that much real quote.
    address internal deepToken = makeAddr("honestDeepMemecoin");
    MockV3Pool internal deepPool;

    // Real quote capital genuinely committed to the concentrated thin band: ~$10k.
    uint256 internal constant GENUINE_QUOTE = 10_000e6;
    // Virtual in-range reserve the concentration reports: ~$10M (~1000x the committed capital).
    uint256 internal constant VIRTUAL_RESERVE = 10_000_000e6;

    uint256 internal constant USDG_SCALE = 1e12; // 18 - 6 decimals
    // Genuine two-sided USD depth = 2 x genuine quote, normalized to 1e18: 2 * 10_000e6 * 1e12 = $20k.
    uint256 internal constant GENUINE_DEPTH_1E18 = 2 * GENUINE_QUOTE * USDG_SCALE; // 20_000e18
    // Depth the concentration WOULD have reported without the fix: 2 * 10_000_000e6 * 1e12 = $20M.
    uint256 internal constant VIRTUAL_DEPTH_1E18 = 2 * VIRTUAL_RESERVE * USDG_SCALE; // 20_000_000e18

    // Tier B_DEEP knobs: coeff = ONE (costToMove == aggregate depth), safetyFactor 5, OI cap 10%.
    uint256 internal constant COEFF = 1e18;
    uint256 internal constant SAFETY = 5;
    uint256 internal constant DEPTH_FLOOR = 15_000e18; // genuine $20k clears; the fix must not under-list it
    uint16 internal constant OI_CAP_BPS = 1_000;
    uint32 internal constant WINDOW = 1_800;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new ConcUSDG();
        router = new OracleRouter(owner, address(usdg));
        points = new MockPitPoints();
        guardian = new PauseGuardian(makeAddr("guardianMultisig"));
        factory = new MarketFactory(
            address(usdg),
            address(router),
            address(points),
            Types.FeeSplit({
                jackpot: makeAddr("jackpot"),
                treasury: makeAddr("treasury"),
                referralPool: makeAddr("referral"),
                buyback: makeAddr("buyback"),
                vault: address(0)
            }),
            OI_CAP_BPS,
            10_000, // per-address sub-cap 100% (not under test here)
            50,
            address(guardian),
            owner
        );
        source = new ConcSource();

        concPool = new MockV3Pool();
        deepPool = new MockV3Pool();

        _configureBDeep(concToken, concPool);
        _configureBDeep(deepToken, deepPool);

        // Both pools report the SAME virtual in-range reserve (VIRTUAL_RESERVE) at tick 0.
        _setVirtualReserve(concPool, VIRTUAL_RESERVE);
        _setVirtualReserve(deepPool, VIRTUAL_RESERVE);

        // The concentrated pool holds only GENUINE_QUOTE of real quote (thin band); the honest-deep
        // twin genuinely holds the full VIRTUAL_RESERVE of real quote (spread liquidity).
        usdg.mint(address(concPool), GENUINE_QUOTE);
        usdg.mint(address(deepPool), VIRTUAL_RESERVE);
    }

    /// @dev Wire a token as a listable Tier B_DEEP memecoin on a single USDG-quoted tracked pool with
    ///      declared geometry, seasoning disabled.
    function _configureBDeep(address token, MockV3Pool pool) internal {
        vm.startPrank(owner);
        router.setTierConfig(token, OracleRouter.SettlementTier.B_DEEP, DEPTH_FLOOR, 0, COEFF, SAFETY, 0, address(0));
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](1);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(source)), maxStaleness: 1 hours});
        router.setSources(token, sources);
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        router.setTrackedPools(token, pools);
        router.setPoolGeometry(address(pool), false, WINDOW); // USDG is token1: quoteIsToken0 = false
        vm.stopPrank();
    }

    /// @dev Seed the pool's observation buffer so consultMeanQuoteReserve(window) returns
    ///      `virtualReserve` at tick 0 (mean tick 0 => sqrtP = 1 => reserve == mean in-range
    ///      liquidity). This models an arbitrarily large virtual reserve achieved by concentrating
    ///      liquidity in a thin band, INDEPENDENT of how much real quote the pool holds.
    function _setVirtualReserve(MockV3Pool p, uint256 virtualReserve) internal {
        p.setTickCumulative(WINDOW, 0);
        p.setTickCumulative(0, 0);
        uint160 delta = uint160(FullMath.mulDiv(WINDOW, uint256(1) << 128, virtualReserve));
        p.setSecondsPerLiquidityCumulative(WINDOW, 0);
        p.setSecondsPerLiquidityCumulative(0, delta);
        p.setRevertOnObserve(false);
    }

    /// @notice The core R-1 claim, DEFEATED: two pools with the IDENTICAL time-averaged in-range
    ///         virtual reserve report VERY different depth. The reported depth tracks the pool's real
    ///         quote capital, not the concentrated tick, so concentration cannot inflate it.
    function test_concentration_depthTracksRealCapitalNotVirtualReserve() public view {
        uint256 concDepth = router.trackedLiquidity(concToken);
        uint256 deepDepth = router.trackedLiquidity(deepToken);

        // The concentrated pool reports genuine capital (~$20k), NOT the ~$20M virtual reserve.
        assertEq(concDepth, GENUINE_DEPTH_1E18, "concentrated depth == genuine 2x real quote");

        // The honest-deep twin, with the SAME virtual reserve but real quote backing it, reports the
        // full ~$20M: identical virtual reserve, radically different real capital => different depth.
        assertEq(deepDepth, VIRTUAL_DEPTH_1E18, "honest-deep depth == full backed reserve");

        // Concentration is deflated back to genuine capital by >100x (here exactly 1000x): the
        // reported depth does NOT inflate proportionally to the concentrated virtual reserve.
        assertLt(concDepth * 100, VIRTUAL_DEPTH_1E18, "concentration deflated >100x vs its virtual reserve");
        assertEq(VIRTUAL_DEPTH_1E18 / concDepth, 1_000, "exactly 1000x deflation at +/-0.1% concentration");
    }

    /// @notice The baked market caps track genuine cross-band depth: the concentrated pool bakes a
    ///         payout cap of genuine-costToMove / safetyFactor, ~1000x below the cap its virtual
    ///         reserve would have unlocked. Proves max realizable payout <= costToMove / safetyFactor
    ///         holds under a concentrated pool.
    function test_concentration_bakedCapBoundedByCostToMoveOverSafety() public {
        // Listable at the genuine depth: the fix must not UNDER-list an honest-capital pool.
        assertTrue(router.isListable(concToken), "concentrated token listable at its genuine depth");

        uint256 reportedDepth = router.trackedLiquidity(concToken);
        uint256 costToMove = router.costToMoveEstimate1e18(concToken);
        uint256 payoutCap = router.maxMarketPayoutCap1e18(concToken);

        // The core inequality, on the GENUINE basis: costToMove == genuine depth (coeff ONE), and the
        // absolute payout cap == costToMove / safetyFactor.
        assertEq(costToMove, reportedDepth, "coeff ONE: cost == genuine depth");
        assertEq(payoutCap, costToMove / SAFETY, "payout cap == costToMove / safetyFactor");
        assertEq(payoutCap, GENUINE_DEPTH_1E18 / SAFETY, "payout cap on genuine capital = $20k / 5 = $4k");

        // ~1000x below the cap the concentrated virtual reserve alone would have unlocked ($4M).
        uint256 wouldBeInflatedCap = VIRTUAL_DEPTH_1E18 / SAFETY;
        assertLt(payoutCap * 100, wouldBeInflatedCap, "baked cap is >100x below the inflated would-be cap");

        // Create the market and confirm the immutables freeze the GENUINE caps, not the inflated ones.
        Market mkt = Market(factory.createMarket(concToken));
        assertEq(mkt.liquiditySnapshot1e18(), GENUINE_DEPTH_1E18, "snapshot baked at genuine depth");
        assertEq(mkt.maxPayoutCap1e18(), GENUINE_DEPTH_1E18 / SAFETY, "payout cap baked at genuine depth / 5");

        // The effective OI cap = min(oiCapBps-of-snapshot, absolute payout cap) is bounded by
        // costToMove / safetyFactor, the design invariant, computed on genuine capital.
        uint256 effectiveOiCap = _min(mkt.liquiditySnapshot1e18() * OI_CAP_BPS / 10_000, mkt.maxPayoutCap1e18());
        assertLe(effectiveOiCap, costToMove / SAFETY, "effective OI cap <= costToMove / safetyFactor");
    }

    /// @notice The concentrated market accepts NO oversized open interest: its frozen cap tracks the
    ///         thin-band genuine capital, so an OI far above genuine depth (but well within the
    ///         concentration-inflated would-be cap) is rejected.
    function test_concentration_marketRejectsOversizedOI() public {
        Market mkt = Market(factory.createMarket(concToken));

        // A fill escrowing ~$100k: far above the genuine ~$2k effective OI cap, far below the ~$4M
        // cap the concentration WOULD have unlocked without the fix.
        uint128 fill = 100_000e6;
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        _fund(alice, mkt, fill);
        vm.prank(alice);
        uint256 offerId =
            mkt.postOffer(Types.Side.LONG, fill, 1_000e6, 1, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);

        _fund(bob, mkt, fill);
        vm.prank(bob);
        vm.expectRevert();
        mkt.fillOffer(offerId, fill);

        assertEq(mkt.openInterest(), 0, "concentrated market opened no oversized OI");
    }

    function _fund(address who, Market m, uint128 amount) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(address(m), type(uint256).max);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
