// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Types} from "../../src/interfaces/Types.sol";
import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {IPriceSource} from "../../src/oracle/adapters/IPriceSource.sol";
import {FullMath} from "../../src/oracle/vendor/FullMath.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";

/// @dev Controllable price source used to drive the router state machine in tests.
contract StubSource is IPriceSource {
    uint256 public price;
    uint256 public updatedAt;
    bool public ok;
    bool public revertOnRead;

    function set(uint256 price_, uint256 updatedAt_, bool ok_) external {
        price = price_;
        updatedAt = updatedAt_;
        ok = ok_;
    }

    function setRevertOnRead(bool value) external {
        revertOnRead = value;
    }

    function read(address) external view returns (uint256, uint256, bool) {
        require(!revertOnRead, "STUB_REVERT");
        return (price, updatedAt, ok);
    }
}

/// @dev Minimal USDG stand-in: decimals + settable balances, nothing more.
contract TestUSDG {
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

contract OracleRouterTest is Test {
    address internal constant TOKEN = address(0xBEEF);
    uint64 internal constant STALENESS = 1 hours;
    uint256 internal constant COOLDOWN = 30 minutes;
    uint32 internal constant DEPTH_WINDOW = 600;

    OracleRouter internal router;
    TestUSDG internal usdg;
    StubSource[] internal stubs;

    function setUp() public {
        usdg = new TestUSDG(18);
        router = new OracleRouter(address(this), address(usdg));
        for (uint256 i = 0; i < 7; i++) {
            stubs.push(new StubSource());
        }
        vm.warp(10_000_000);
    }

    // ===============================================================
    // Helpers
    // ===============================================================

    function _configure(uint256 n) internal {
        OracleRouter.SourceConfig[] memory cfg = new OracleRouter.SourceConfig[](n);
        for (uint256 i = 0; i < n; i++) {
            cfg[i] = OracleRouter.SourceConfig({source: IPriceSource(address(stubs[i])), maxStaleness: STALENESS});
        }
        router.setSources(TOKEN, cfg);
    }

    function _setPrices3(uint256 a, uint256 b, uint256 c) internal {
        stubs[0].set(a, block.timestamp, true);
        stubs[1].set(b, block.timestamp, true);
        stubs[2].set(c, block.timestamp, true);
    }

    function _assertStatus(Types.PriceStatus actual, Types.PriceStatus expected) internal pure {
        assertEq(uint8(actual), uint8(expected));
    }

    /// @dev Configure a mock pool as a manipulation-resistant USDG-quoted (quoteIsToken0 = false)
    ///      tracked pool for TOKEN with a mean in-range liquidity of `targetL` at tick 0, so
    ///      trackedLiquidity contributes exactly 2 * (returned mean L) (USDG is 18-decimal here).
    function _trackMeanDepthPool(MockV3Pool pool, uint256 targetL) internal returns (uint256 meanL) {
        pool.setTickCumulative(DEPTH_WINDOW, 0);
        pool.setTickCumulative(0, 0); // mean tick 0: sqrtP = 1, reserve == mean in-range liquidity
        uint160 delta = uint160(FullMath.mulDiv(DEPTH_WINDOW, uint256(1) << 128, targetL));
        pool.setSecondsPerLiquidityCumulative(DEPTH_WINDOW, 0);
        pool.setSecondsPerLiquidityCumulative(0, delta);
        pool.setRevertOnObserve(false);
        // Wave-3 R-1 / W2-1b: the depth measure is MIN(virtual in-range reserve, real quote balance).
        // An HONEST pool genuinely holds real quote, so back it with AMPLE real USDG; the MIN then
        // resolves to the virtual reserve (only a CONCENTRATED pool, with a huge reserve but little
        // real quote, is clamped). The backing must strictly exceed meanL, which the mulDiv round-trip
        // can push a few wei above targetL, so it cannot be exactly targetL.
        usdg.mint(address(pool), type(uint128).max);
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        router.setTrackedPools(TOKEN, pools);
        router.setPoolGeometry(address(pool), false, DEPTH_WINDOW);
        meanL = FullMath.mulDiv(DEPTH_WINDOW, uint256(1) << 128, delta);
    }

    // ===============================================================
    // Construction and configuration
    // ===============================================================

    function test_constructor_rejectsZeroUsdg() public {
        vm.expectRevert(OracleRouter.UsdgZero.selector);
        new OracleRouter(address(this), address(0));
    }

    function test_constructor_rejectsUsdgAbove18Decimals() public {
        TestUSDG bad = new TestUSDG(19);
        vm.expectRevert(abi.encodeWithSelector(OracleRouter.UnsupportedUsdgDecimals.selector, 19));
        new OracleRouter(address(this), address(bad));
    }

    function test_setSources_rejectsFewerThanThree() public {
        OracleRouter.SourceConfig[] memory cfg = new OracleRouter.SourceConfig[](2);
        cfg[0] = OracleRouter.SourceConfig({source: IPriceSource(address(stubs[0])), maxStaleness: STALENESS});
        cfg[1] = OracleRouter.SourceConfig({source: IPriceSource(address(stubs[1])), maxStaleness: STALENESS});
        vm.expectRevert(abi.encodeWithSelector(OracleRouter.TooFewSources.selector, 2));
        router.setSources(TOKEN, cfg);
    }

    function test_setSources_rejectsZeroSourceAndZeroStaleness() public {
        OracleRouter.SourceConfig[] memory cfg = new OracleRouter.SourceConfig[](3);
        cfg[0] = OracleRouter.SourceConfig({source: IPriceSource(address(0)), maxStaleness: STALENESS});
        cfg[1] = OracleRouter.SourceConfig({source: IPriceSource(address(stubs[1])), maxStaleness: STALENESS});
        cfg[2] = OracleRouter.SourceConfig({source: IPriceSource(address(stubs[2])), maxStaleness: STALENESS});
        vm.expectRevert(OracleRouter.SourceZero.selector);
        router.setSources(TOKEN, cfg);

        cfg[0] = OracleRouter.SourceConfig({source: IPriceSource(address(stubs[0])), maxStaleness: 0});
        vm.expectRevert(OracleRouter.StalenessZero.selector);
        router.setSources(TOKEN, cfg);
    }

    function test_setSources_emptyDelists() public {
        _configure(3);
        router.setSources(TOKEN, new OracleRouter.SourceConfig[](0));
        assertEq(router.sourcesOf(TOKEN).length, 0);
        assertFalse(router.isListable(TOKEN));
    }

    function test_setGuards_rejectsAbove100Percent() public {
        vm.expectRevert(abi.encodeWithSelector(OracleRouter.DeviationTooWide.selector, uint16(10_001)));
        router.setGuards(TOKEN, OracleRouter.Tier.B, 10_001);
    }

    function test_config_onlyOwner() public {
        vm.startPrank(address(0xDEAD));
        bytes memory err =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD));
        vm.expectRevert(err);
        router.setSources(TOKEN, new OracleRouter.SourceConfig[](0));
        vm.expectRevert(err);
        router.setGuards(TOKEN, OracleRouter.Tier.A, 0);
        vm.expectRevert(err);
        router.setLiquidityFloor(TOKEN, 1e18);
        vm.expectRevert(err);
        router.setTrackedPools(TOKEN, new address[](0));
        vm.stopPrank();
    }

    function test_ownable2Step_handshake() public {
        address next = address(0xABCD);
        router.transferOwnership(next);
        // Pending owner cannot configure before accepting.
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        router.setGuards(TOKEN, OracleRouter.Tier.B, 0);
        vm.prank(next);
        router.acceptOwnership();
        vm.prank(next);
        router.setGuards(TOKEN, OracleRouter.Tier.B, 0);
        (OracleRouter.Tier tier,,) = router.guardsOf(TOKEN);
        assertEq(uint8(tier), uint8(OracleRouter.Tier.B));
    }

    // ===============================================================
    // Median math
    // ===============================================================

    function testFuzz_medianMatchesReference(uint256 nSeed, uint256 baseSeed, uint256[7] memory offsetSeeds) public {
        uint256 n = bound(nSeed, 3, 7);
        uint256 base = bound(baseSeed, 1e6, 1e30);
        _configure(n);

        uint256[] memory prices = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            // Offsets up to 2 percent of base keep the set inside the 3 percent tier A bound.
            prices[i] = base + bound(offsetSeeds[i], 0, base / 50);
            stubs[i].set(prices[i], block.timestamp, true);
        }

        uint256 expected = _referenceMedian(prices);
        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.OK);
        assertEq(p, expected);

        // peek agrees with check.
        (uint256 peeked, Types.PriceStatus peekStatus) = router.peekPrice(TOKEN);
        _assertStatus(peekStatus, Types.PriceStatus.OK);
        assertEq(peeked, expected);
    }

    function test_median_evenCountAveragesMiddleTwo() public {
        _configure(4);
        stubs[0].set(100e18, block.timestamp, true);
        stubs[1].set(101e18, block.timestamp, true);
        stubs[2].set(102e18, block.timestamp, true);
        stubs[3].set(100.5e18, block.timestamp, true);
        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.OK);
        // Sorted: 100, 100.5, 101, 102: average of the two middle values.
        assertEq(p, (100.5e18 + 101e18) / 2);
    }

    function test_median_ignoresNotOkSources() public {
        _configure(5);
        stubs[0].set(100e18, block.timestamp, true);
        stubs[1].set(101e18, block.timestamp, true);
        stubs[2].set(102e18, block.timestamp, true);
        stubs[3].set(1, block.timestamp, false); // not ok, dropped
        stubs[4].setRevertOnRead(true); // reverts, dropped
        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.OK);
        assertEq(p, 101e18);
    }

    function _referenceMedian(uint256[] memory prices) internal pure returns (uint256) {
        uint256 n = prices.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (prices[j] < prices[i]) (prices[i], prices[j]) = (prices[j], prices[i]);
            }
        }
        return n % 2 == 1 ? prices[n / 2] : (prices[n / 2 - 1] + prices[n / 2]) / 2;
    }

    // ===============================================================
    // Deviation guard boundary
    // ===============================================================

    function test_deviation_tierA_exactThresholdPasses_oneWeiOverFails() public {
        _configure(3);
        // 300 bps of 1e18 is exactly 0.03e18.
        _setPrices3(1e18, 1e18, 1.03e18);
        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.OK);
        assertEq(p, 1e18);

        _setPrices3(1e18, 1e18, 1.03e18 + 1);
        (p, status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.COOLDOWN);
        assertEq(p, 0);
    }

    function test_deviation_tierB_exactThresholdPasses_oneWeiOverFails() public {
        _configure(3);
        router.setGuards(TOKEN, OracleRouter.Tier.B, 0);
        // 2500 bps of 1e18 is exactly 0.25e18.
        _setPrices3(1e18, 1e18, 1.25e18);
        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.OK);
        assertEq(p, 1e18);

        _setPrices3(1e18, 1e18, 1.25e18 + 1);
        (p, status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.COOLDOWN);
        assertEq(p, 0);
    }

    function testFuzz_deviation_boundaryExact(uint256 minSeed, uint16 bps) public {
        uint256 min = bound(minSeed, 1e10, 1e30);
        bps = uint16(bound(bps, 1, 10_000));
        _configure(3);
        router.setGuards(TOKEN, OracleRouter.Tier.A, bps);

        // Largest max that still passes: (max - min) * 10000 <= bps * min.
        uint256 maxPass = min + (uint256(bps) * min) / 10_000;
        _setPrices3(min, min, maxPass);
        (, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.OK);

        // One wei past the exact bound must fail whenever bps*min is divisible by 10000,
        // and in general maxPass + 1 fails iff (maxPass + 1 - min) * 10000 > bps * min.
        uint256 overshoot = maxPass + 1;
        _setPrices3(min, min, overshoot);
        (, Types.PriceStatus status2) = router.checkPrice(TOKEN);
        if ((overshoot - min) * 10_000 > uint256(bps) * min) {
            _assertStatus(status2, Types.PriceStatus.COOLDOWN);
        } else {
            _assertStatus(status2, Types.PriceStatus.OK);
        }
    }

    // ===============================================================
    // Staleness
    // ===============================================================

    function test_staleSourceDropped_belowThreeGivesStale() public {
        _configure(3);
        _setPrices3(100e18, 100e18, 100e18);
        stubs[2].set(100e18, block.timestamp - STALENESS - 1, true);
        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.STALE);
        assertEq(p, 0);
    }

    function test_exactStalenessBoundaryStillFresh() public {
        _configure(3);
        stubs[0].set(100e18, block.timestamp - STALENESS, true);
        stubs[1].set(100e18, block.timestamp, true);
        stubs[2].set(100e18, block.timestamp, true);
        (, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.OK);
    }

    function test_allStaleGivesUnavailable() public {
        _configure(3);
        uint256 old = block.timestamp - STALENESS - 1;
        stubs[0].set(100e18, old, true);
        stubs[1].set(100e18, old, true);
        stubs[2].set(100e18, old, true);
        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.UNAVAILABLE);
        assertEq(p, 0);
    }

    function test_noSourcesGivesUnavailable() public {
        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.UNAVAILABLE);
        assertEq(p, 0);
    }

    function test_zeroAndAbsurdPricesDropped() public {
        _configure(3);
        _setPrices3(100e18, 100e18, 100e18);
        stubs[0].set(0, block.timestamp, true); // zero price dropped
        stubs[1].set(1e36 + 1, block.timestamp, true); // above sanity cap dropped
        (, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.STALE);
    }

    function testFuzz_neverOkBelowThreeFresh(uint256 staleCountSeed) public {
        uint256 staleCount = bound(staleCountSeed, 1, 3);
        _configure(3);
        _setPrices3(100e18, 100e18, 100e18);
        for (uint256 i = 0; i < staleCount; i++) {
            stubs[i].set(100e18, block.timestamp - STALENESS - 1, true);
        }
        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        assertTrue(status != Types.PriceStatus.OK);
        assertEq(p, 0);
        (p, status) = router.peekPrice(TOKEN);
        assertTrue(status != Types.PriceStatus.OK);
        assertEq(p, 0);
    }

    // ===============================================================
    // Cooldown state machine and fallback
    // ===============================================================

    function _printThreeAgreedRounds() internal {
        // Ring writes are capped at one per block (wave-2b R-7), so agreed prints must span
        // distinct blocks to fill the ring, exactly as they do on a live chain.
        _setPrices3(100e18, 100e18, 100e18);
        (uint256 p,) = router.checkPrice(TOKEN);
        assertEq(p, 100e18);
        skip(60);
        vm.roll(block.number + 1);
        _setPrices3(101e18, 101e18, 101e18);
        (p,) = router.checkPrice(TOKEN);
        assertEq(p, 101e18);
        skip(60);
        vm.roll(block.number + 1);
        _setPrices3(102e18, 102e18, 102e18);
        (p,) = router.checkPrice(TOKEN);
        assertEq(p, 102e18);
    }

    function test_cooldownStateMachine_fullWalk() public {
        _configure(3);
        _printThreeAgreedRounds();

        (uint256[3] memory prints, uint8 count,) = router.agreedPrintsOf(TOKEN);
        assertEq(count, 3);
        assertEq(prints[0], 100e18);
        assertEq(prints[1], 101e18);
        assertEq(prints[2], 102e18);

        // Introduce a deviation: one source runs away.
        skip(60);
        _setPrices3(102e18, 102e18, 300e18);

        // Round 0: enters cooldown.
        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.COOLDOWN);
        assertEq(p, 0);
        (uint64 cooldownUntil, uint8 failedRounds) = router.breakerOf(TOKEN);
        assertEq(cooldownUntil, block.timestamp + COOLDOWN);
        assertEq(failedRounds, 0);

        // Inside the window: still COOLDOWN, no round counted.
        skip(COOLDOWN / 2);
        _setPrices3(102e18, 102e18, 300e18);
        (, status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.COOLDOWN);
        (, failedRounds) = router.breakerOf(TOKEN);
        assertEq(failedRounds, 0);

        // Rounds 1 and 2: full cooldown elapsed, deviation persists.
        for (uint8 r = 1; r <= 2; r++) {
            (cooldownUntil,) = router.breakerOf(TOKEN);
            vm.warp(cooldownUntil);
            _setPrices3(102e18, 102e18, 300e18);
            // peek predicts COOLDOWN because rounds stay below 3.
            (, status) = router.peekPrice(TOKEN);
            _assertStatus(status, Types.PriceStatus.COOLDOWN);
            (p, status) = router.checkPrice(TOKEN);
            _assertStatus(status, Types.PriceStatus.COOLDOWN);
            assertEq(p, 0);
            (, failedRounds) = router.breakerOf(TOKEN);
            assertEq(failedRounds, r);
        }

        // Round 3: fallback kicks in with the median of the agreed prints.
        (cooldownUntil,) = router.breakerOf(TOKEN);
        vm.warp(cooldownUntil);
        _setPrices3(102e18, 102e18, 300e18);
        (uint256 peekP, Types.PriceStatus peekStatus) = router.peekPrice(TOKEN);
        _assertStatus(peekStatus, Types.PriceStatus.OK);
        assertEq(peekP, 101e18);
        (p, status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.OK);
        assertEq(p, 101e18);
        (, failedRounds) = router.breakerOf(TOKEN);
        assertEq(failedRounds, 3);

        // Fallback persists on subsequent deviating checks without touching the ring.
        skip(60);
        _setPrices3(102e18, 102e18, 400e18);
        (p, status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.OK);
        assertEq(p, 101e18);
        (prints, count,) = router.agreedPrintsOf(TOKEN);
        assertEq(count, 3);
        assertEq(prints[0], 100e18);
        assertEq(prints[1], 101e18);
        assertEq(prints[2], 102e18);

        // Sources re-agree: breaker resets and the new print enters the ring (fresh block, since
        // the ring accepts one print per block).
        skip(60);
        vm.roll(block.number + 1);
        _setPrices3(105e18, 105e18, 105e18);
        (p, status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.OK);
        assertEq(p, 105e18);
        (cooldownUntil, failedRounds) = router.breakerOf(TOKEN);
        assertEq(cooldownUntil, 0);
        assertEq(failedRounds, 0);
        (prints, count,) = router.agreedPrintsOf(TOKEN);
        assertEq(count, 3);
        assertEq(prints[0], 105e18); // oldest slot overwritten
        assertEq(prints[1], 101e18);
        assertEq(prints[2], 102e18);
    }

    function test_fallbackImpossibleWithoutThreePrints() public {
        _configure(3);
        // Deviate from the very first check: ring is empty forever.
        _setPrices3(100e18, 100e18, 300e18);
        for (uint256 round = 0; round < 5; round++) {
            _setPrices3(100e18, 100e18, 300e18);
            (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
            _assertStatus(status, Types.PriceStatus.COOLDOWN);
            assertEq(p, 0);
            (uint64 cooldownUntil,) = router.breakerOf(TOKEN);
            vm.warp(cooldownUntil);
        }
        (, uint8 failedRounds) = router.breakerOf(TOKEN);
        assertEq(failedRounds, 3);
    }

    function test_fallbackImpossibleWithOnlyTwoPrints() public {
        _configure(3);
        _setPrices3(100e18, 100e18, 100e18);
        router.checkPrice(TOKEN);
        skip(60);
        vm.roll(block.number + 1);
        _setPrices3(101e18, 101e18, 101e18);
        router.checkPrice(TOKEN);

        skip(60);
        for (uint256 round = 0; round < 5; round++) {
            _setPrices3(101e18, 101e18, 300e18);
            (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
            _assertStatus(status, Types.PriceStatus.COOLDOWN);
            assertEq(p, 0);
            (uint64 cooldownUntil,) = router.breakerOf(TOKEN);
            vm.warp(cooldownUntil);
        }
    }

    function test_primeFallback_seedsRingAcrossBlocksAndSelfHeals() public {
        _configure(3);
        assertFalse(router.fallbackSeeded(TOKEN), "multi-source token starts unseeded");
        // Sources currently agree: each prime advances the ring by exactly ONE print (wave-2b
        // R-7), so filling it takes AGREED_PRINTS distinct blocks.
        _setPrices3(100e18, 100e18, 100e18);
        assertEq(router.primeFallback(TOKEN), 1);
        vm.roll(block.number + 1);
        assertEq(router.primeFallback(TOKEN), 2);
        assertFalse(router.fallbackSeeded(TOKEN), "two of three prints is not seeded");
        vm.roll(block.number + 1);
        assertEq(router.primeFallback(TOKEN), 3);
        assertTrue(router.fallbackSeeded(TOKEN));
        (uint256[3] memory prints, uint8 count,) = router.agreedPrintsOf(TOKEN);
        assertEq(count, 3);
        assertEq(prints[0], 100e18);
        // Priming started no cooldown and left failedRounds at zero.
        (uint64 cd, uint8 fr) = router.breakerOf(TOKEN);
        assertEq(cd, 0);
        assertEq(fr, 0);

        // A sustained deviation from the very first check now SELF-HEALS to the fallback median in
        // <= 3 rounds (would stick in permanent cooldown without a pre-seeded ring: W2-10).
        bool served;
        for (uint256 round = 0; round < 5; round++) {
            _setPrices3(100e18, 100e18, 300e18);
            (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
            if (status == Types.PriceStatus.OK) {
                assertEq(p, 100e18); // fallback ring-median
                served = true;
                break;
            }
            (uint64 cooldownUntil,) = router.breakerOf(TOKEN);
            vm.warp(cooldownUntil);
        }
        assertTrue(served, "fallback served after priming");
    }

    function test_primeFallback_atMostOnePrintPerBlock() public {
        _configure(3);
        _setPrices3(100e18, 100e18, 100e18);
        // Same-block repeats cannot advance the ring (R-7: no baking three copies of one
        // timing-chosen median), whether through primeFallback or checkPrice.
        assertEq(router.primeFallback(TOKEN), 1);
        assertEq(router.primeFallback(TOKEN), 1);
        router.checkPrice(TOKEN);
        assertEq(router.primeFallback(TOKEN), 1);
        (uint256[3] memory prints, uint8 count,) = router.agreedPrintsOf(TOKEN);
        assertEq(count, 1);
        assertEq(prints[0], 100e18);
        assertEq(prints[1], 0);
        assertFalse(router.fallbackSeeded(TOKEN));
    }

    function test_checkPrice_ringAcceptsOnePrintPerBlock() public {
        _configure(3);
        _setPrices3(100e18, 100e18, 100e18);
        // Three same-block agreeing checks still serve OK each time, but write the ring ONCE.
        for (uint256 i = 0; i < 3; i++) {
            (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
            _assertStatus(status, Types.PriceStatus.OK);
            assertEq(p, 100e18);
        }
        (, uint8 count,) = router.agreedPrintsOf(TOKEN);
        assertEq(count, 1);
    }

    function test_primeFallback_noOpWhenSourcesDisagree() public {
        _configure(3);
        _setPrices3(100e18, 100e18, 300e18); // deviating: no OK agreeing print to seed
        uint8 ringCount = router.primeFallback(TOKEN);
        assertEq(ringCount, 0);
        (, uint8 count,) = router.agreedPrintsOf(TOKEN);
        assertEq(count, 0);
        assertFalse(router.fallbackSeeded(TOKEN));
    }

    function test_fallbackSeeded_vacuousForSingleSourceToken() public {
        // A single-source (aggregating-tier) token can never fail the pairwise deviation guard,
        // never enters COOLDOWN, and never serves fallback: seeded vacuously, empty ring or not.
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 1, 0, address(0));
        OracleRouter.SourceConfig[] memory cfg = new OracleRouter.SourceConfig[](1);
        cfg[0] = OracleRouter.SourceConfig({source: IPriceSource(address(stubs[0])), maxStaleness: STALENESS});
        router.setSources(TOKEN, cfg);
        (, uint8 count,) = router.agreedPrintsOf(TOKEN);
        assertEq(count, 0);
        assertTrue(router.fallbackSeeded(TOKEN));
    }

    function test_peekNeverMutates() public {
        _configure(3);
        _printThreeAgreedRounds();
        skip(60);
        _setPrices3(102e18, 102e18, 300e18);
        router.peekPrice(TOKEN);
        (uint64 cooldownUntil, uint8 failedRounds) = router.breakerOf(TOKEN);
        assertEq(cooldownUntil, 0);
        assertEq(failedRounds, 0);
        (, uint8 count,) = router.agreedPrintsOf(TOKEN);
        assertEq(count, 3);
    }

    function test_staleDuringCooldownDoesNotAdvanceRounds() public {
        _configure(3);
        _setPrices3(100e18, 100e18, 300e18);
        router.checkPrice(TOKEN); // enters cooldown
        (uint64 cooldownUntil,) = router.breakerOf(TOKEN);
        vm.warp(cooldownUntil + STALENESS + 1);
        // Sources are now stale: gate closes before deviation is evaluated.
        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        _assertStatus(status, Types.PriceStatus.UNAVAILABLE);
        assertEq(p, 0);
        (, uint8 failedRounds) = router.breakerOf(TOKEN);
        assertEq(failedRounds, 0);
    }

    // ===============================================================
    // Manipulation resistance
    // ===============================================================

    function testFuzz_singleMaliciousSourceCannotMovePricePastHonestBounds(
        uint256 honestSeed,
        uint256 honestDeltaSeed,
        uint256 attackerSeed,
        uint256 attackerSlotSeed
    ) public {
        _configure(3);
        uint256 h1 = bound(honestSeed, 1e12, 1e30);
        // Second honest source within 1 percent of the first.
        uint256 h2 = bound(honestDeltaSeed, h1 - h1 / 100, h1 + h1 / 100);
        uint256 attacker = bound(attackerSeed, 1, 1e36);
        uint256 slot = bound(attackerSlotSeed, 0, 2);

        uint256[3] memory prices;
        prices[slot] = attacker;
        prices[(slot + 1) % 3] = h1;
        prices[(slot + 2) % 3] = h2;
        _setPrices3(prices[0], prices[1], prices[2]);

        (uint256 p, Types.PriceStatus status) = router.checkPrice(TOKEN);
        uint256 lo = h1 < h2 ? h1 : h2;
        uint256 hi = h1 < h2 ? h2 : h1;
        if (status == Types.PriceStatus.OK) {
            // Settlement price is always bounded by the two honest sources.
            assertGe(p, lo);
            assertLe(p, hi);
        } else {
            assertEq(p, 0);
        }
    }

    // ===============================================================
    // Liquidity tracking, listing, snapshots
    // ===============================================================

    function test_trackedLiquidity_doublesUsdgSide() public {
        address poolA = address(0xAA01);
        address poolB = address(0xAA02);
        address[] memory pools = new address[](2);
        pools[0] = poolA;
        pools[1] = poolB;
        router.setTrackedPools(TOKEN, pools);
        usdg.mint(poolA, 10_000e18);
        usdg.mint(poolB, 2_500e18);
        assertEq(router.trackedLiquidity(TOKEN), 25_000e18);
    }

    function test_trackedLiquidity_normalizesUsdgDecimals() public {
        TestUSDG usdg6 = new TestUSDG(6);
        OracleRouter router6 = new OracleRouter(address(this), address(usdg6));
        address poolA = address(0xAA03);
        address[] memory pools = new address[](1);
        pools[0] = poolA;
        router6.setTrackedPools(TOKEN, pools);
        usdg6.mint(poolA, 12_500e6);
        assertEq(router6.trackedLiquidity(TOKEN), 25_000e18);
    }

    function test_isListable_requiresSourcesAndFloor() public {
        // The aggregate-depth floor is a Tier B_DEEP / C_MID gate (majors are priced by an
        // independent feed and need no pool depth): configure the token as B_DEEP so the floor
        // applies. The depth is the manipulation-resistant time-averaged in-range reserve, never a
        // single-block-inflatable balanceOf.
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 1, 0, address(0));
        MockV3Pool pool = new MockV3Pool();
        _trackMeanDepthPool(pool, 20_000e18); // tracked = 2 * mean L, well above the default floor
        uint256 tracked = router.trackedLiquidity(TOKEN);
        assertGt(tracked, router.DEFAULT_LIQUIDITY_FLOOR());

        // Liquidity fine but no sources yet (B_DEEP still requires at least one source).
        assertFalse(router.isListable(TOKEN));
        _configure(3);
        assertTrue(router.isListable(TOKEN));

        // A floor one wei above the measured depth fails; exactly at the depth passes.
        router.setLiquidityFloor(TOKEN, tracked);
        assertTrue(router.isListable(TOKEN));
        router.setLiquidityFloor(TOKEN, tracked + 1);
        assertFalse(router.isListable(TOKEN));
    }

    function test_isListable_customFloor() public {
        // The floor override gates B_DEEP / C_MID tokens; configure the token as B_DEEP. A zero
        // aggregateDepthFloor makes the Tier B gate fall back to the liquidityFloor override.
        router.setTierConfig(TOKEN, OracleRouter.SettlementTier.B_DEEP, 0, 0, 1e18, 1, 0, address(0));
        _configure(3);
        MockV3Pool pool = new MockV3Pool();
        _trackMeanDepthPool(pool, 500e18); // tracked = 2 * mean L ~ 1_000e18
        uint256 tracked = router.trackedLiquidity(TOKEN);

        assertFalse(router.isListable(TOKEN)); // below default 25_000e18 floor
        router.setLiquidityFloor(TOKEN, tracked); // custom floor at the measured depth
        assertTrue(router.isListable(TOKEN));
        router.setLiquidityFloor(TOKEN, 0); // restore default
        assertFalse(router.isListable(TOKEN));
    }

    function test_snapshotLiquidity_storesAndOverwrites() public {
        address poolA = address(0xAA06);
        address[] memory pools = new address[](1);
        pools[0] = poolA;
        router.setTrackedPools(TOKEN, pools);
        usdg.mint(poolA, 100e18);

        // Callable by anyone.
        vm.prank(address(0xD00D));
        uint256 snap = router.snapshotLiquidity(TOKEN);
        assertEq(snap, 200e18);
        assertEq(router.liquiditySnapshot(TOKEN), 200e18);

        usdg.mint(poolA, 100e18);
        snap = router.snapshotLiquidity(TOKEN);
        assertEq(snap, 400e18);
        assertEq(router.liquiditySnapshot(TOKEN), 400e18);
    }
}
