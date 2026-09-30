// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {IPriceSource} from "../../src/oracle/adapters/IPriceSource.sol";
import {CrossPoolTwapAdapter} from "../../src/oracle/adapters/CrossPoolTwapAdapter.sol";
import {UniV3TwapLib} from "../../src/oracle/UniV3TwapLib.sol";
import {FullMath} from "../../src/oracle/vendor/FullMath.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";
import {IIndependentSource} from "../../src/oracle/adapters/IIndependentSource.sol";

/// @dev Minimal always-settable price source (stands in for a pool-derived read: NOT independent).
contract TierStubSource is IPriceSource {
    uint256 public price;
    bool public ok;

    function set(uint256 price_, bool ok_) external {
        price = price_;
        ok = ok_;
    }

    function read(address) external view returns (uint256, uint256, bool) {
        return (price, block.timestamp, ok);
    }
}

/// @dev Settable price source that DECLARES settlement-pool independence (stands in for a real
///      Chainlink/Pyth feed), so a Tier A_MAJOR listing accepts it as the required independent
///      source.
contract IndependentStubSource is IPriceSource, IIndependentSource {
    uint256 public price;
    bool public ok;

    function set(uint256 price_, bool ok_) external {
        price = price_;
        ok = ok_;
    }

    function read(address) external view returns (uint256, uint256, bool) {
        return (price, block.timestamp, ok);
    }

    function isIndependent(address) external pure returns (bool) {
        return true;
    }
}

/// @dev Minimal USDG stand-in: decimals + settable balances.
contract TierUSDG {
    uint8 internal immutable _dec;
    mapping(address => uint256) public balanceOf;

    constructor(uint8 dec) {
        _dec = dec;
    }

    function decimals() external view returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }
}

/// @title SettlementTierTest: tier config, tier-gated listing, aggregated-TWAP settlement,
///        cost-to-move caps, the seasoning gate, and the opening-side deviation breaker.
contract SettlementTierTest is Test {
    address internal constant TOKEN = address(0xBEEF);
    uint64 internal constant STALENESS = 1 hours;
    uint32 internal constant WINDOW = 600;

    OracleRouter internal router;
    TierUSDG internal usdg;
    CrossPoolTwapAdapter internal cross;
    MockV3Pool internal poolA;
    MockV3Pool internal poolB;

    function setUp() public {
        vm.warp(10_000_000);
        usdg = new TierUSDG(18);
        router = new OracleRouter(address(this), address(usdg));
        cross = new CrossPoolTwapAdapter(address(this));
        poolA = new MockV3Pool();
        poolB = new MockV3Pool();
    }

    // ===============================================================
    // Helpers (mirror CrossPoolTwapAdapter.t.sol so expectations match the double-flooring)
    // ===============================================================

    function _setMeanTick(MockV3Pool pool, int56 meanTick) internal {
        pool.setTickCumulative(WINDOW, 0);
        pool.setTickCumulative(0, meanTick * int56(uint56(WINDOW)));
    }

    function _setMeanLiquidity(MockV3Pool pool, uint256 targetL) internal returns (uint256 meanL) {
        uint256 delta = FullMath.mulDiv(WINDOW, uint256(1) << 128, targetL);
        pool.setSecondsPerLiquidityCumulative(WINDOW, 0);
        pool.setSecondsPerLiquidityCumulative(0, uint160(delta));
        meanL = FullMath.mulDiv(WINDOW, uint256(1) << 128, delta);
        // Wave-3 R-1 / W2-1b: the depth measure is MIN(virtual in-range reserve, real quote balance).
        // Back the honest in-range reserve with AMPLE real USDG so the MIN resolves to the virtual
        // reserve (an honest deep pool holds real quote; only a CONCENTRATED pool, huge reserve but
        // little real quote, is clamped). The backing must strictly exceed meanL, which the mulDiv
        // round-trip can push a few wei above targetL, so it cannot be exactly targetL.
        usdg.mint(address(pool), type(uint128).max);
    }

    /// @dev Register both mock pools on the cross-pool adapter, returning the exact weights it uses.
    function _registerCross(uint256 liqA, uint256 liqB) internal returns (uint256 wA, uint256 wB) {
        wA = _setMeanLiquidity(poolA, liqA);
        wB = _setMeanLiquidity(poolB, liqB);
        CrossPoolTwapAdapter.PoolConfig[] memory pools = new CrossPoolTwapAdapter.PoolConfig[](2);
        pools[0] = CrossPoolTwapAdapter.PoolConfig({pool: IUniswapV3Pool(address(poolA)), quoteIsToken0: false});
        pools[1] = CrossPoolTwapAdapter.PoolConfig({pool: IUniswapV3Pool(address(poolB)), quoteIsToken0: false});
        cross.setPools(TOKEN, pools, WINDOW);
    }

    /// @dev Configure TOKEN as Tier B_DEEP settling on the cross-pool adapter (the aggregated TWAP)
    ///      and using it as the spot source for the opening breaker.
    function _configureTierB(uint16 breakerBps, uint32 seasoning) internal {
        router.setTierConfig(
            TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, seasoning, 1e18, 5, breakerBps, address(cross)
        );
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](1);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(cross)), maxStaleness: STALENESS});
        router.setSources(TOKEN, sources);
    }

    // ===============================================================
    // Tier config set / get / access control
    // ===============================================================

    function test_setTierConfig_storesAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit OracleRouter.TierConfigSet(
            TOKEN, OracleRouter.SettlementTier.B_DEEP, 2_000_000e18, 1 days, 3e18, 8, 500, address(cross)
        );
        router.setTierConfig(
            TOKEN, OracleRouter.SettlementTier.B_DEEP, 2_000_000e18, 1 days, 3e18, 8, 500, address(cross)
        );

        (
            OracleRouter.SettlementTier tier,
            uint256 floor,
            uint32 seasoning,
            uint256 coeff,
            uint256 sf,
            uint16 breakerBps,
            address spot,
            bool set
        ) = router.tierConfigOf(TOKEN);
        assertEq(uint8(tier), uint8(OracleRouter.SettlementTier.B_DEEP));
        assertEq(floor, 2_000_000e18);
        assertEq(seasoning, 1 days);
        assertEq(coeff, 3e18);
        assertEq(sf, 8);
        assertEq(breakerBps, 500);
        assertEq(spot, address(cross));
        assertTrue(set);
    }

    function test_setTierConfig_rejectsZeroSafetyFactor() public {
        vm.expectRevert(OracleRouter.SafetyFactorZero.selector);
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 0, 500, address(cross));
    }

    function test_setTierConfig_rejectsBreakerAbove100Percent() public {
        vm.expectRevert(abi.encodeWithSelector(OracleRouter.BreakerTooWide.selector, uint16(10_001)));
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 5, 10_001, address(cross));
    }

    function test_setTierConfig_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD)));
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 5, 500, address(cross));
    }

    function test_defaultTierIsAMajor() public view {
        (OracleRouter.SettlementTier tier,,,,,,, bool set) = router.tierConfigOf(TOKEN);
        assertEq(uint8(tier), uint8(OracleRouter.SettlementTier.A_MAJOR));
        assertFalse(set);
    }

    // ===============================================================
    // Source-count minimum per tier
    // ===============================================================

    function test_tierAMajor_stillRequiresThreeSources() public {
        OracleRouter.SourceConfig[] memory one = new OracleRouter.SourceConfig[](1);
        one[0] = OracleRouter.SourceConfig({source: IPriceSource(address(cross)), maxStaleness: STALENESS});
        // Default A_MAJOR: one source is too few.
        vm.expectRevert(abi.encodeWithSelector(OracleRouter.TooFewSources.selector, 1));
        router.setSources(TOKEN, one);
    }

    function test_tierBDeep_acceptsSingleAggregatingSource() public {
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 5, 0, address(0));
        OracleRouter.SourceConfig[] memory one = new OracleRouter.SourceConfig[](1);
        one[0] = OracleRouter.SourceConfig({source: IPriceSource(address(cross)), maxStaleness: STALENESS});
        router.setSources(TOKEN, one); // no revert
        assertEq(router.sourcesOf(TOKEN).length, 1);
    }

    // ===============================================================
    // Tier A path unchanged: majors settle via the median of >= 3 independent sources
    // ===============================================================

    function test_tierAMajor_settlesViaMedianOfThree() public {
        TierStubSource s0 = new TierStubSource();
        TierStubSource s1 = new TierStubSource();
        TierStubSource s2 = new TierStubSource();
        s0.set(100e18, true);
        s1.set(101e18, true);
        s2.set(102e18, true);
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](3);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(s0)), maxStaleness: STALENESS});
        sources[1] = OracleRouter.SourceConfig({source: IPriceSource(address(s1)), maxStaleness: STALENESS});
        sources[2] = OracleRouter.SourceConfig({source: IPriceSource(address(s2)), maxStaleness: STALENESS});
        router.setSources(TOKEN, sources);

        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        assertEq(uint8(status), uint8(Types.PriceStatus.OK));
        assertEq(p, 101e18); // the median, exactly as before the tier feature
    }

    // ===============================================================
    // Tier B: settlement price is the aggregated multi-pool geometric-mean TWAP
    // ===============================================================

    function test_tierBDeep_settlesOnAggregatedTwap() public {
        _setMeanTick(poolA, 0); // price 1e18
        _setMeanTick(poolB, 6931); // price ~2e18
        (uint256 wA, uint256 wB) = _registerCross(1000, 3000);
        _configureTierB(0, 0);

        uint256 pA = UniV3TwapLib.quoteAtTick(0, false);
        uint256 pB = UniV3TwapLib.quoteAtTick(6931, false);
        uint256 expected = FullMath.mulDiv(pA, wA, wA + wB) + FullMath.mulDiv(pB, wB, wA + wB);

        // The router's settlement price equals the adapter's aggregated TWAP exactly.
        (uint256 adapterPrice,, bool ok) = cross.read(TOKEN);
        assertTrue(ok);
        assertEq(adapterPrice, expected);

        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        assertEq(uint8(status), uint8(Types.PriceStatus.OK));
        assertEq(p, expected);
        // Strictly between the two pool prices, closer to the heavier pool B.
        assertGt(p, pA);
        assertLt(p, pB);
    }

    // ===============================================================
    // Opening-side deviation breaker (spot vs settlement TWAP)
    // ===============================================================

    /// @dev Set both pools' slot0 tick so aggregated spot equals aggregated TWAP (no dislocation).
    function _setSpotEqualsTwap() internal {
        poolA.setSlot0(0, 0, 0, 1);
        poolB.setSlot0(0, 6931, 0, 1);
    }

    function test_openingAllowed_withinBand() public {
        _setMeanTick(poolA, 0);
        _setMeanTick(poolB, 6931);
        _registerCross(1000, 3000);
        _configureTierB(500, 0); // 5 percent breaker
        _setSpotEqualsTwap();

        (bool allowed, uint8 reason) = router.openingAllowed(TOKEN);
        assertTrue(allowed);
        assertEq(reason, router.OPENING_ALLOWED());
    }

    function test_openingDenied_whenSpotDeviatesBeyondBand() public {
        _setMeanTick(poolA, 0);
        _setMeanTick(poolB, 6931);
        _registerCross(1000, 3000);
        _configureTierB(500, 0); // 5 percent breaker

        // Push both pools' spot ticks far above their mean ticks: spot dislocates upward well
        // beyond 5 percent while the TWAP (from tickCumulatives) is unchanged.
        poolA.setSlot0(0, 20000, 0, 1);
        poolB.setSlot0(0, 26931, 0, 1);

        (bool allowed, uint8 reason) = router.openingAllowed(TOKEN);
        assertFalse(allowed);
        assertEq(reason, router.OPENING_DENIED_DEVIATION());
    }

    function test_openingDenied_whenReferenceUnavailable() public {
        _setMeanTick(poolA, 0);
        _setMeanTick(poolB, 6931);
        _registerCross(1000, 3000);
        _configureTierB(500, 0);

        // TWAP source reverts on observe: the settlement reference is unreadable, deny opening.
        poolA.setRevertOnObserve(true);
        poolB.setRevertOnObserve(true);
        (bool allowed, uint8 reason) = router.openingAllowed(TOKEN);
        assertFalse(allowed);
        assertEq(reason, router.OPENING_DENIED_REFERENCE_UNAVAILABLE());
    }

    function test_openingAlwaysAllowed_forTierAMajor() public {
        // Default A_MAJOR, no spot source: the breaker is inert.
        (bool allowed, uint8 reason) = router.openingAllowed(TOKEN);
        assertTrue(allowed);
        assertEq(reason, router.OPENING_ALLOWED());
    }

    // ===============================================================
    // isListable tier matrix
    // ===============================================================

    /// @dev Configure TOKEN with the given tier, one fresh source, one tracked mock pool whose
    ///      manipulation-resistant in-range quote reserve is `depth` (so trackedLiquidity = 2 *
    ///      depth: at tick 0 the reserve equals the mean in-range liquidity, USDG is 18-decimal so
    ///      usdgScale is 1, and quoteIsToken0 = false), and `seasoning` window. The reserve is read
    ///      from the pool's observation buffer, never its raw balanceOf, so a just-in-time balance
    ///      spike cannot move it.
    function _listingFixture(OracleRouter.SettlementTier tier, uint256 depth, uint32 seasoning, uint256 floor)
        internal
    {
        router.setTierConfig(TOKEN, tier, floor, seasoning, 1e18, 5, 0, address(0));
        TierStubSource s = new TierStubSource();
        s.set(1e18, true);
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](1);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(s)), maxStaleness: STALENESS});
        router.setSources(TOKEN, sources);
        address[] memory pools = new address[](1);
        pools[0] = address(poolA);
        router.setTrackedPools(TOKEN, pools);
        _setMeanTick(poolA, 0); // price 1e18, sqrtP = 1, so quote reserve == mean in-range liquidity
        _setMeanLiquidity(poolA, depth);
        router.setPoolGeometry(address(poolA), false, WINDOW);
        poolA.setRevertOnObserve(false); // seasoned buffer by default
    }

    function test_isListable_aMajor_requiresIndependentSource() public {
        // A_MAJOR needs MIN_SOURCES; three pool-derived (non-independent) sources is NOT enough
        // after the wave-2 TO-1 fix: a major must carry at least one settlement-pool-independent
        // feed, so a compromised owner cannot classify a pool-only token as A_MAJOR.
        TierStubSource s0 = new TierStubSource();
        TierStubSource s1 = new TierStubSource();
        TierStubSource s2 = new TierStubSource();
        s0.set(1e18, true);
        s1.set(1e18, true);
        s2.set(1e18, true);
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](3);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(s0)), maxStaleness: STALENESS});
        sources[1] = OracleRouter.SourceConfig({source: IPriceSource(address(s1)), maxStaleness: STALENESS});
        sources[2] = OracleRouter.SourceConfig({source: IPriceSource(address(s2)), maxStaleness: STALENESS});
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.A_MAJOR, 0, 0, 0, 1, 0, address(0));
        router.setSources(TOKEN, sources);
        // Three non-independent sources: not listable.
        assertFalse(router.isListable(TOKEN));

        // Swap one source for a genuinely independent feed: now listable on the source requirement
        // alone (no tracked pools, no depth: a major needs neither).
        IndependentStubSource indy = new IndependentStubSource();
        indy.set(1e18, true);
        sources[2] = OracleRouter.SourceConfig({source: IPriceSource(address(indy)), maxStaleness: STALENESS});
        router.setSources(TOKEN, sources);
        assertTrue(router.isListable(TOKEN));
    }

    function test_isListable_bDeep_gatedOnDepthSeasoningCardinality() public {
        // Depth above the 25_000e18 default floor, seasoned pool: listable.
        _listingFixture(OracleRouter.SettlementTier.B_DEEP, 20_000e18, 1 days, 0); // 2*20k = 40k >= 25k
        assertTrue(router.isListable(TOKEN));

        // Depth below floor (time-averaged in-range liquidity halved): not listable.
        _setMeanLiquidity(poolA, 10_000e18); // now 2*10k = 20k < 25k
        assertFalse(router.isListable(TOKEN));

        // Restore depth, but the pool's observation buffer cannot serve the window (observe
        // reverts): the depth is unreadable AND seasoning fails, so it is not listable.
        _setMeanLiquidity(poolA, 20_000e18); // back to 40k
        assertTrue(router.isListable(TOKEN));
        poolA.setRevertOnObserve(true);
        assertFalse(router.isListable(TOKEN));
    }

    function test_isListable_cMid_sameGatesAsBDeep() public {
        _listingFixture(OracleRouter.SettlementTier.C_MID, 20_000e18, 1 days, 0);
        assertTrue(router.isListable(TOKEN));
        poolA.setRevertOnObserve(true); // buffer cannot cover the window
        assertFalse(router.isListable(TOKEN));
    }

    function test_isListable_dThin_neverListable() public {
        // Build a fully listable B_DEEP token (abundant depth, a source, a seasoned pool), then
        // flip only the tier to D_THIN: it becomes unlistable regardless of everything else.
        _listingFixture(OracleRouter.SettlementTier.B_DEEP, 10_000_000e18, 1 days, 0);
        assertTrue(router.isListable(TOKEN));
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.D_THIN, 0, 1 days, 1e18, 5, 0, address(0));
        assertFalse(router.isListable(TOKEN));
    }

    // ===============================================================
    // Seasoning gate isolated
    // ===============================================================

    function test_seasoning_youngBufferFails_seasonedPasses() public {
        _listingFixture(OracleRouter.SettlementTier.B_DEEP, 1_000_000e18, 30 minutes, 0);
        // Seasoned (observe serves the window): passes.
        assertTrue(router.isListable(TOKEN));
        // Young buffer (observe reverts "OLD"): fails BOTH the seasoning gate and the manipulation-
        // resistant depth read (which consults the same buffer), so it is not listable.
        poolA.setRevertOnObserve(true);
        assertFalse(router.isListable(TOKEN));
        // Disabling seasoning is not enough while the buffer cannot serve the window: the in-range
        // depth itself is unreadable, so it stays unlistable (correct, stricter behavior on the
        // time-averaged-reserve basis).
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 5, 0, address(0));
        assertFalse(router.isListable(TOKEN));
        // A seasoned buffer restores the depth read and (vacuously) seasoning: listable again.
        poolA.setRevertOnObserve(false);
        assertTrue(router.isListable(TOKEN));
    }

    // ===============================================================
    // Cost-to-move estimate and max market payout cap
    // ===============================================================

    function test_costToMove_monotonicInDepthAndCoeff() public {
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 5, 0, address(0));
        address[] memory pools = new address[](1);
        pools[0] = address(poolA);
        router.setTrackedPools(TOKEN, pools);

        // Manipulation-resistant depth: at tick 0 the in-range quote reserve equals the mean
        // in-range liquidity, USDG is 18-decimal, quoteIsToken0 = false, so trackedLiquidity is
        // exactly 2 * meanL. Use the actual returned mean to keep the assertions wei-exact.
        _setMeanTick(poolA, 0);
        uint256 mL = _setMeanLiquidity(poolA, 1_000_000e18);
        router.setPoolGeometry(address(poolA), false, WINDOW);
        uint256 tracked = 2 * mL;
        assertEq(router.trackedLiquidity(TOKEN), tracked);

        // coeff 1e18 => cost == depth.
        assertEq(router.costToMoveEstimate1e18(TOKEN), tracked);
        // maxPayoutCap = cost / safetyFactor(5).
        assertEq(router.maxMarketPayoutCap1e18(TOKEN), tracked / 5);

        // Larger coefficient raises the estimate monotonically.
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 3e18, 5, 0, address(0));
        assertEq(router.costToMoveEstimate1e18(TOKEN), tracked * 3);
        assertEq(router.maxMarketPayoutCap1e18(TOKEN), tracked * 3 / 5);

        // More depth raises it monotonically.
        uint256 mL2 = _setMeanLiquidity(poolA, 2_000_000e18);
        assertEq(router.costToMoveEstimate1e18(TOKEN), 2 * mL2 * 3);
    }

    // ===============================================================
    // W2-13: tracked (cost-to-move) pools must be read by the settlement source
    // ===============================================================

    function test_isListable_bDeep_requiresTrackedPoolsReadBySource() public {
        // Settlement source is the cross adapter, registered to read poolB ONLY.
        _setMeanTick(poolB, 0);
        _setMeanLiquidity(poolB, 1_000_000e18);
        CrossPoolTwapAdapter.PoolConfig[] memory cp = new CrossPoolTwapAdapter.PoolConfig[](1);
        cp[0] = CrossPoolTwapAdapter.PoolConfig({pool: IUniswapV3Pool(address(poolB)), quoteIsToken0: false});
        cross.setPools(TOKEN, cp, WINDOW);

        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 5, 0, address(0));
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](1);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(cross)), maxStaleness: STALENESS});
        router.setSources(TOKEN, sources);

        // Track poolA (deep) which the settlement source does NOT read: depth clears the floor, but
        // the cost-to-move pool is decoupled from the settlement source, so it is NOT listable.
        _setMeanTick(poolA, 0);
        _setMeanLiquidity(poolA, 1_000_000e18);
        address[] memory tracked = new address[](1);
        tracked[0] = address(poolA);
        router.setTrackedPools(TOKEN, tracked);
        router.setPoolGeometry(address(poolA), false, WINDOW);
        assertGt(router.trackedLiquidity(TOKEN), router.DEFAULT_LIQUIDITY_FLOOR());
        assertFalse(router.isListable(TOKEN));

        // Track poolB instead (the pool the settlement source actually reads): now listable.
        tracked[0] = address(poolB);
        router.setTrackedPools(TOKEN, tracked);
        router.setPoolGeometry(address(poolB), false, WINDOW);
        assertGt(router.trackedLiquidity(TOKEN), router.DEFAULT_LIQUIDITY_FLOOR());
        assertTrue(router.isListable(TOKEN));
    }

    function test_maxPayoutCap_unboundedForMajors() public {
        // Default A_MAJOR: no cost-to-move cap.
        assertEq(router.maxMarketPayoutCap1e18(TOKEN), type(uint256).max);
        // Explicit A_MAJOR with a coefficient set is still unbounded (feed-priced, no pool cap).
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.A_MAJOR, 0, 0, 5e18, 5, 0, address(0));
        assertEq(router.maxMarketPayoutCap1e18(TOKEN), type(uint256).max);
    }

    function test_geometryWindowFlooredAtSettlementTwapWindow() public {
        // Wave-2b R-9: for a value-bearing token, a tracked pool's geometry window may not be
        // shorter than the settlement source's TWAP window: a shorter window would average the
        // in-range reserve over LESS time than the settlement TWAP it defends, re-weakening the
        // W2-1 manipulation resistance. An under-floored pool contributes ZERO depth (fail-safe).
        _setMeanTick(poolB, 0);
        _setMeanLiquidity(poolB, 1_000_000e18);
        CrossPoolTwapAdapter.PoolConfig[] memory cp = new CrossPoolTwapAdapter.PoolConfig[](1);
        cp[0] = CrossPoolTwapAdapter.PoolConfig({pool: IUniswapV3Pool(address(poolB)), quoteIsToken0: false});
        cross.setPools(TOKEN, cp, WINDOW); // settlement TWAP window: the floor

        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 5, 0, address(0));
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](1);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(cross)), maxStaleness: STALENESS});
        router.setSources(TOKEN, sources);
        address[] memory tracked = new address[](1);
        tracked[0] = address(poolB);
        router.setTrackedPools(TOKEN, tracked);

        // Geometry window one second SHORT of the settlement window: zero depth, not listable.
        router.setPoolGeometry(address(poolB), false, WINDOW - 1);
        assertEq(router.trackedLiquidity(TOKEN), 0);
        assertFalse(router.isListable(TOKEN));

        // Exactly at the settlement window: full depth, listable.
        router.setPoolGeometry(address(poolB), false, WINDOW);
        assertGt(router.trackedLiquidity(TOKEN), router.DEFAULT_LIQUIDITY_FLOOR());
        assertTrue(router.isListable(TOKEN));

        // Longer than the settlement window is allowed (a LONGER averaging horizon only hardens
        // the measure; the mock buffer serves any lookback).
        router.setPoolGeometry(address(poolB), false, WINDOW * 2);
        assertGt(router.trackedLiquidity(TOKEN), 0);
        assertTrue(router.isListable(TOKEN));
    }
}
