// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {IPriceSource} from "../../src/oracle/adapters/IPriceSource.sol";
import {FullMath} from "../../src/oracle/vendor/FullMath.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";

/// @dev Minimal token stand-in: decimals + settable balances, nothing more.
contract QuoteToken {
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
}

/// @dev Always-fresh price source used to satisfy the 3-source listing minimum.
contract FreshSource is IPriceSource {
    function read(address) external view returns (uint256, uint256, bool) {
        return (1e18, block.timestamp, true);
    }
}

/// @title RouterPoolQuoteTest: trackedLiquidity with mixed USDG and WETH quoted pools
contract RouterPoolQuoteTest is Test {
    address internal constant TOKEN = address(0xBEEF);
    address internal constant POOL_USDG = address(0xAAA1);
    address internal constant POOL_WETH = address(0xAAA2);
    uint64 internal constant FEED_STALENESS = 1 days;

    OracleRouter internal router;
    QuoteToken internal usdg;
    QuoteToken internal weth;
    MockChainlinkFeed internal ethFeed;

    function setUp() public {
        usdg = new QuoteToken(6);
        weth = new QuoteToken(18);
        router = new OracleRouter(address(this), address(usdg));
        ethFeed = new MockChainlinkFeed(8);
        vm.warp(10_000_000);
        ethFeed.setAnswer(2000e8, block.timestamp);
    }

    function _trackBoth() internal {
        address[] memory pools = new address[](2);
        pools[0] = POOL_USDG;
        pools[1] = POOL_WETH;
        router.setTrackedPools(TOKEN, pools);
        router.setPoolQuote(POOL_WETH, address(weth), address(ethFeed), FEED_STALENESS);
    }

    // ===============================================================
    // setPoolQuote configuration surface
    // ===============================================================

    function test_setPoolQuote_storesAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit OracleRouter.PoolQuoteSet(POOL_WETH, address(weth), address(ethFeed), FEED_STALENESS);
        router.setPoolQuote(POOL_WETH, address(weth), address(ethFeed), FEED_STALENESS);
        (address quoteToken, uint256 quoteScale,, uint64 staleness, uint8 dec) = router.poolQuotes(POOL_WETH);
        assertEq(quoteToken, address(weth));
        assertEq(quoteScale, 1); // 18-decimal quote token.
        assertEq(staleness, FEED_STALENESS);
        assertEq(dec, 8);
    }

    function test_setPoolQuote_clearRestoresUsdgTreatment() public {
        _trackBoth();
        weth.mint(POOL_WETH, 5e18);
        usdg.mint(POOL_WETH, 100e6); // A stray USDG balance on the WETH pool.
        assertEq(router.trackedLiquidity(TOKEN), 2 * 5 * 2000 * 1e18);

        router.setPoolQuote(POOL_WETH, address(0), address(0), 0);
        // Cleared: the pool now counts its USDG side again (2 x 100 USDG).
        assertEq(router.trackedLiquidity(TOKEN), 200e18);
    }

    function test_setPoolQuote_revertsOnZeroPool() public {
        vm.expectRevert(OracleRouter.PoolZero.selector);
        router.setPoolQuote(address(0), address(weth), address(ethFeed), FEED_STALENESS);
    }

    function test_setPoolQuote_revertsOnZeroFeed() public {
        vm.expectRevert(OracleRouter.FeedZero.selector);
        router.setPoolQuote(POOL_WETH, address(weth), address(0), FEED_STALENESS);
    }

    function test_setPoolQuote_revertsOnZeroStaleness() public {
        vm.expectRevert(OracleRouter.StalenessZero.selector);
        router.setPoolQuote(POOL_WETH, address(weth), address(ethFeed), 0);
    }

    function test_setPoolQuote_revertsOnQuoteDecimalsAbove18() public {
        QuoteToken weird = new QuoteToken(19);
        vm.expectRevert(abi.encodeWithSelector(OracleRouter.UnsupportedQuoteDecimals.selector, 19));
        router.setPoolQuote(POOL_WETH, address(weird), address(ethFeed), FEED_STALENESS);
    }

    function test_setPoolQuote_revertsOnFeedDecimalsAbove30() public {
        ethFeed.setDecimals(31);
        vm.expectRevert(abi.encodeWithSelector(OracleRouter.UnsupportedFeedDecimals.selector, 31));
        router.setPoolQuote(POOL_WETH, address(weth), address(ethFeed), FEED_STALENESS);
    }

    function test_setPoolQuote_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD)));
        router.setPoolQuote(POOL_WETH, address(weth), address(ethFeed), FEED_STALENESS);
    }

    // ===============================================================
    // trackedLiquidity with mixed quote kinds
    // ===============================================================

    function test_trackedLiquidity_mixedQuoteKindsSum() public {
        _trackBoth();
        usdg.mint(POOL_USDG, 12_500e6); // 2x => 25_000e18.
        weth.mint(POOL_WETH, 5e18); // 2 x 5 WETH x 2000 USD => 20_000e18.
        assertEq(router.trackedLiquidity(TOKEN), 45_000e18);
    }

    function test_trackedLiquidity_wethOnlyPoolIgnoresItsUsdgDust() public {
        _trackBoth();
        weth.mint(POOL_WETH, 1e18);
        usdg.mint(POOL_WETH, 999e6); // Must NOT be double counted once quote-configured.
        assertEq(router.trackedLiquidity(TOKEN), 4000e18);
    }

    function test_trackedLiquidity_staleFeedZeroesWethContribution() public {
        _trackBoth();
        usdg.mint(POOL_USDG, 1000e6);
        weth.mint(POOL_WETH, 5e18);
        ethFeed.setAnswer(2000e8, block.timestamp - FEED_STALENESS - 1);
        assertEq(router.trackedLiquidity(TOKEN), 2000e18);
    }

    function test_trackedLiquidity_revertingFeedZeroesWethContribution() public {
        _trackBoth();
        usdg.mint(POOL_USDG, 1000e6);
        weth.mint(POOL_WETH, 5e18);
        ethFeed.setRevertOnRead(true);
        assertEq(router.trackedLiquidity(TOKEN), 2000e18);
    }

    function test_trackedLiquidity_nonPositiveFeedZeroesWethContribution() public {
        _trackBoth();
        weth.mint(POOL_WETH, 5e18);
        ethFeed.setAnswer(0, block.timestamp);
        assertEq(router.trackedLiquidity(TOKEN), 0);
        ethFeed.setAnswer(-1, block.timestamp);
        assertEq(router.trackedLiquidity(TOKEN), 0);
    }

    function test_trackedLiquidity_normalizesFeedDecimals() public {
        ethFeed.setDecimals(18);
        _trackBoth();
        ethFeed.setAnswer(2000e18, block.timestamp);
        weth.mint(POOL_WETH, 3e18);
        assertEq(router.trackedLiquidity(TOKEN), 12_000e18);
    }

    function test_trackedLiquidity_scalesLowDecimalQuoteToken() public {
        QuoteToken weth8 = new QuoteToken(8);
        address[] memory pools = new address[](1);
        pools[0] = POOL_WETH;
        router.setTrackedPools(TOKEN, pools);
        router.setPoolQuote(POOL_WETH, address(weth8), address(ethFeed), FEED_STALENESS);
        weth8.mint(POOL_WETH, 5e8); // 5 units at 8 decimals.
        assertEq(router.trackedLiquidity(TOKEN), 2 * 5 * 2000 * 1e18);
    }

    function test_snapshotLiquidity_usesQuoteConfig() public {
        _trackBoth();
        weth.mint(POOL_WETH, 5e18);
        assertEq(router.snapshotLiquidity(TOKEN), 20_000e18);
        assertEq(router.liquiditySnapshot(TOKEN), 20_000e18);
    }

    // ===============================================================
    // isListable with a WETH-quoted floor
    // ===============================================================

    function test_isListable_wethQuotedPoolCrossesFloor() public {
        // The aggregate-depth floor is a Tier B_DEEP gate; configure the token as B_DEEP so the
        // WETH-quoted floor crossing is exercised (a zero aggregateDepthFloor falls back to the
        // default 25_000e18 floor). Depth is the manipulation-resistant time-averaged in-range WETH
        // reserve, converted to USD through the ETH/USD feed, never a single-block balanceOf.
        uint32 window = 600;
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 1, 0, address(0));
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](3);
        for (uint256 i = 0; i < 3; i++) {
            sources[i] = OracleRouter.SourceConfig({source: IPriceSource(address(new FreshSource())), maxStaleness: 1 hours});
        }
        router.setSources(TOKEN, sources);

        MockV3Pool pool = new MockV3Pool();
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        router.setTrackedPools(TOKEN, pools);
        router.setPoolQuote(address(pool), address(weth), address(ethFeed), FEED_STALENESS);
        router.setPoolGeometry(address(pool), false, window); // WETH is token1: quoteIsToken0 = false

        // meanL = 6e18 WETH at tick 0: depth = 2 x 6 WETH x 2000 USD = 24_000e18 < 25_000e18 floor.
        _setMeanDepth(pool, window, 6e18);
        assertLt(router.trackedLiquidity(TOKEN), router.DEFAULT_LIQUIDITY_FLOOR());
        assertFalse(router.isListable(TOKEN));

        // meanL = 7e18 WETH: depth = 2 x 7 WETH x 2000 USD = 28_000e18 > 25_000e18 floor.
        _setMeanDepth(pool, window, 7e18);
        assertGt(router.trackedLiquidity(TOKEN), router.DEFAULT_LIQUIDITY_FLOOR());
        assertTrue(router.isListable(TOKEN));
    }

    /// @dev Set a mock pool's observation buffer so its time-averaged in-range quote reserve equals
    ///      `targetL` at tick 0 (sqrtP = 1), for a WETH-quoted (18-decimal) pool.
    function _setMeanDepth(MockV3Pool pool, uint32 window, uint256 targetL) internal {
        pool.setTickCumulative(window, 0);
        pool.setTickCumulative(0, 0);
        uint160 delta = uint160(FullMath.mulDiv(window, uint256(1) << 128, targetL));
        pool.setSecondsPerLiquidityCumulative(window, 0);
        pool.setSecondsPerLiquidityCumulative(0, delta);
        pool.setRevertOnObserve(false);
        // Wave-3 R-1 / W2-1b: depth is MIN(virtual in-range reserve, real quote balance). Back the
        // honest reserve with AMPLE real WETH (this fixture's pools are WETH-quoted), so the MIN
        // resolves to the virtual reserve rather than clamping an honest pool to zero. The backing
        // must strictly exceed meanL, which the mulDiv round-trip can push a few wei above targetL.
        weth.mint(address(pool), type(uint128).max);
    }
}
