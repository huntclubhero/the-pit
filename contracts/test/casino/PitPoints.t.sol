// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {CasinoTestBase} from "./CasinoTestBase.t.sol";
import {PitPoints} from "../../src/casino/PitPoints.sol";

/// @notice A SpinVRF stand-in that always reverts, for never-revert coverage.
contract RevertingSpinSink {
    function requestSpin(address, uint256, address) external pure {
        revert("RevertingSpinSink: boom");
    }
}

/// @title PitPoints unit, fuzz, and never-revert tests
contract PitPointsTest is CasinoTestBase {
    uint256 internal constant BASE_RATE = 1e11;

    // ===============================================================
    // Access control
    // ===============================================================

    function test_unregisteredMarket_cannotCallHooks() public {
        address rando = makeAddr("rando");
        vm.startPrank(rando);
        vm.expectRevert(abi.encodeWithSelector(PitPoints.NotMarket.selector, rando));
        points.onFill(rando, rando, rando, tokenA, 1e8);
        vm.expectRevert(abi.encodeWithSelector(PitPoints.NotMarket.selector, rando));
        points.onSettle(rando, rando, tokenA, 1e8, 1);
        vm.expectRevert(abi.encodeWithSelector(PitPoints.NotMarket.selector, rando));
        points.onMarketCreated(rando, tokenA);
        vm.stopPrank();
    }

    function test_registerMarket_onlyOwnerOrRegistrar() public {
        address rando = makeAddr("rando");
        address newMarket = makeAddr("newMarket");

        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(PitPoints.NotRegistrar.selector, rando));
        points.registerMarket(newMarket);

        points.setRegistrar(rando);
        vm.prank(rando);
        points.registerMarket(newMarket);
        assertTrue(points.isMarket(newMarket));
    }

    function test_mintSpinBonus_onlySpinVRF() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(PitPoints.NotSpinVRF.selector, rando));
        points.mintSpinBonus(rando, 1e18, tokenA);
    }

    function test_renounceOwnership_reverts() public {
        vm.expectRevert(PitPoints.RenounceDisabled.selector);
        points.renounceOwnership();
    }

    // ===============================================================
    // Base points math
    // ===============================================================

    function test_baseScaling_100UsdgIs10Points() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        // 100 USDG notional in native 6 decimals; bob is maker so alice is taker.
        fill(alice, bob, bob, tokenB, 100e6);
        assertEq(points.pointsOf(alice), 10e18, "taker: 10 points per 100 USDG");
        assertEq(points.pointsOf(bob), 20e18, "maker: 2x taker base");
        assertEq(points.totalPoints(), 30e18);
    }

    function testFuzz_basePointsScaling(uint256 notional) public {
        notional = bound(notional, 1, 1e30);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        fill(alice, bob, bob, tokenB, notional);
        assertEq(points.pointsOf(alice), notional * BASE_RATE, "taker base");
        assertEq(points.pointsOf(bob), 2 * notional * BASE_RATE, "maker 2x base");
    }

    function test_notionalCap_noOverflowAtMaxUint() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        fill(alice, bob, bob, tokenB, type(uint256).max);
        assertEq(points.pointsOf(alice), points.NOTIONAL_CAP() * BASE_RATE, "clamped at cap");
    }

    function test_takerIsWhicheverPartyIsNotMaker() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        // Maker is the long party here, so the short party is the taker.
        fill(alice, bob, alice, tokenB, 100e6);
        assertEq(points.pointsOf(bob), 10e18, "short party took");
        assertEq(points.pointsOf(alice), 20e18, "long party made");
    }

    // ===============================================================
    // Multiplier stacking (win streak x daily streak) exact values
    // ===============================================================

    function test_multiplierStacking_exact() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // Day 1 and day 2 activity builds the daily streak.
        fill(alice, bob, bob, tokenB, 100e6);
        vm.warp(block.timestamp + 1 days);
        fill(alice, bob, bob, tokenB, 100e6);
        vm.warp(block.timestamp + 1 days);

        // Two wins spaced past the L3 advance throttle: win multiplier 1.2x. Settles do not touch
        // daily activity, and the 1-hour spacing stays within day 3.
        win(alice);
        warpPastWinThrottle();
        win(alice);

        // Day 3 fill: daily count becomes 3 (1.1x), win streak 2 (1.2x).
        uint256 before = points.pointsOf(alice);
        fill(alice, bob, bob, tokenB, 100e6);
        uint256 earned = points.pointsOf(alice) - before;
        // base 10e18 x 1.2 x 1.1 = 13.2e18
        assertEq(earned, 13.2e18, "stacked taker earn");
    }

    function test_makerUsesOwnMultipliers() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        // Give the maker (bob) a 3-win streak: 1.5x (wins spaced past the L3 throttle). Alice fresh.
        win(bob);
        warpPastWinThrottle();
        win(bob);
        warpPastWinThrottle();
        win(bob);
        fill(alice, bob, bob, tokenB, 100e6);
        assertEq(points.pointsOf(alice), 10e18, "taker fresh 1.0x");
        assertEq(points.pointsOf(bob), 30e18, "maker 2 x base x 1.5");
    }

    // ===============================================================
    // Creator share
    // ===============================================================

    function test_creatorShare_onFill_exact() public {
        address creator = makeAddr("creator");
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        createMarket(creator, tokenA);

        fill(alice, bob, bob, tokenA, 100e6);
        // 5% of taker 10e18 plus 5% of maker 20e18 = 1.5e18.
        assertEq(points.pointsOf(creator), 1.5e18, "creator 5% of all fill mints");
    }

    function test_creatorShare_onRebateAndSpinBonus() public {
        address creator = makeAddr("creator");
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        createMarket(creator, tokenA);

        // Rebate: loser bob gets 25% of base (2.5e18); creator gets 5% of that.
        settle(alice, bob, tokenA, 100e6, 7);
        assertEq(points.pointsOf(creator), 0.125e18, "creator share of rebate");

        // Spin bonus: fill then fulfill a 5x spin; bonus = 4 x takerEarn.
        uint256 creatorBefore = points.pointsOf(creator);
        uint256 aliceBefore = points.pointsOf(alice);
        fill(alice, bob, bob, tokenA, 100e6);
        uint256 takerEarn = points.pointsOf(alice) - aliceBefore;
        uint256 requestId = coordinator.requestCount();
        uint256 creatorAfterFill = points.pointsOf(creator);
        fulfillSpin(requestId, 8500);
        uint256 bonus = takerEarn * 4;
        assertEq(points.pointsOf(alice) - aliceBefore, takerEarn + bonus, "bonus minted");
        assertEq(points.pointsOf(creator) - creatorAfterFill, bonus * 500 / 10_000, "creator share of bonus");
        // Sanity: creator also earned on the fill itself.
        assertGt(creatorAfterFill, creatorBefore);
    }

    function test_creator_firstWriterWins() public {
        address creator1 = makeAddr("creator1");
        address creator2 = makeAddr("creator2");
        createMarket(creator1, tokenA);
        createMarket(creator2, tokenA);
        assertEq(points.creatorOf(tokenA), creator1, "creator cannot be replaced");
    }

    /// @dev C4: creator-share points are lifetime/cosmetic only and carry ZERO epoch weight, so a
    ///      first-writer creator gains no jackpot-draw win probability from the passive 5% share.
    function test_creatorShare_excludedFromEpochWeighting() public {
        address creator = makeAddr("creator");
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        createMarket(creator, tokenA);
        uint256 epoch = points.currentEpoch();

        fill(alice, bob, bob, tokenA, 100e6);

        // Lifetime credit accrues (5% of taker 10e18 + 5% of maker 20e18 = 1.5e18).
        assertEq(points.pointsOf(creator), 1.5e18, "creator keeps lifetime credit");
        // But zero epoch weight, and the epoch total / checkpoints count only the traders.
        assertEq(points.epochPointsOf(creator, epoch), 0, "creator share excluded from epoch weight");
        assertEq(points.epochTotal(epoch), 30e18, "epoch total excludes creator share");
        assertEq(points.checkpointCount(epoch), 2, "only taker and maker checkpoints");
        // The creator covers no weight range: a weighted draw can never select them.
        for (uint256 t = 0; t < 30e18; t += 5e18) {
            assertTrue(points.selectByWeight(epoch, t) != creator, "creator never covers any weight");
        }
    }

    // ===============================================================
    // Settle behavior
    // ===============================================================

    function test_settle_rebateIgnoresMultipliers() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        // Give the loser big multipliers (wins spaced past the L3 throttle); the rebate must still
        // be flat 25% of base.
        win(bob);
        warpPastWinThrottle();
        win(bob);
        warpPastWinThrottle();
        win(bob);
        warpPastWinThrottle();
        win(bob);
        fill(bob, alice, alice, tokenB, 100e6); // daily activity for bob
        uint256 before = points.pointsOf(bob);
        settle(alice, bob, tokenB, 100e6, 3);
        assertEq(points.pointsOf(bob) - before, 2.5e18, "flat 25% rebate, no multipliers");
    }

    function test_settle_flatIsNeutral() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        win(alice);
        win(alice);
        (uint64 winsBefore,,) = points.winStreakOf(alice);
        uint256 balBefore = points.pointsOf(bob);

        settle(alice, bob, tokenB, 100e6, 0);

        (uint64 winsAfter,,) = points.winStreakOf(alice);
        assertEq(winsAfter, winsBefore, "no streak change on flat");
        assertEq(points.pointsOf(bob), balBefore, "no rebate on flat");
    }

    function test_settle_selfMatchIsNeutral() public {
        address alice = makeAddr("alice");
        settle(alice, alice, tokenB, 100e6, 5);
        (uint64 wins,,) = points.winStreakOf(alice);
        assertEq(wins, 0);
        assertEq(points.pointsOf(alice), 0);
    }

    // ===============================================================
    // Epoch accounting and weighted selection
    // ===============================================================

    function test_epochAccounting_rollsAtBoundary() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 epoch1 = points.currentEpoch();
        fill(alice, bob, bob, tokenB, 100e6);
        assertEq(points.epochPointsOf(alice, epoch1), 10e18);
        assertEq(points.epochTotal(epoch1), 30e18);

        vm.warp(block.timestamp + 7 days);
        uint256 epoch2 = points.currentEpoch();
        assertEq(epoch2, epoch1 + 1, "epoch advanced");
        fill(alice, bob, bob, tokenB, 200e6);
        assertEq(points.epochPointsOf(alice, epoch2), 20e18);
        assertEq(points.epochTotal(epoch2), 60e18);
        assertEq(points.epochTotal(epoch1), 30e18, "old epoch frozen");
    }

    function referenceSelect(uint256 epoch, uint256 target) internal view returns (address) {
        uint256 n = points.checkpointCount(epoch);
        for (uint256 i = 0; i < n; i++) {
            (address user, uint256 cumulative) = points.checkpointAt(epoch, i);
            if (cumulative > target) return user;
        }
        return address(0);
    }

    function testFuzz_selectByWeight_matchesLinearScan(uint256 targetSeed) public {
        address maker = makeAddr("maker");
        for (uint256 i = 0; i < 8; i++) {
            address taker = address(uint160(0x5000 + i));
            fill(taker, maker, maker, tokenB, (i + 1) * 37e6);
        }
        uint256 epoch = points.currentEpoch();
        uint256 total = points.epochTotal(epoch);
        assertGt(total, 0);
        uint256 target = targetSeed % total;
        assertEq(points.selectByWeight(epoch, target), referenceSelect(epoch, target), "binary == linear");
    }

    function test_selectByWeight_emptyAndOutOfRange() public {
        uint256 epoch = points.currentEpoch();
        assertEq(points.selectByWeight(epoch, 0), address(0), "empty epoch");
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        fill(alice, bob, bob, tokenB, 100e6);
        uint256 total = points.epochTotal(epoch);
        assertEq(points.selectByWeight(epoch, total), address(0), "target == total is out of range");
        assertEq(points.selectByWeight(epoch, 0), alice, "first checkpoint covers 0");
    }

    function test_selectByWeight_1000Users() public {
        address maker = makeAddr("bigMaker");
        for (uint256 i = 0; i < 1000; i++) {
            address taker = address(uint160(0x100000 + i));
            fill(taker, maker, maker, tokenB, ((i % 13) + 1) * 1e6);
        }
        uint256 epoch = points.currentEpoch();
        uint256 total = points.epochTotal(epoch);
        assertEq(points.checkpointCount(epoch), 2000, "one checkpoint per mint");

        // Deterministic spread of targets, including both edges.
        for (uint256 j = 0; j < 20; j++) {
            uint256 target = uint256(keccak256(abi.encode("target", j))) % total;
            assertEq(points.selectByWeight(epoch, target), referenceSelect(epoch, target));
        }
        assertEq(points.selectByWeight(epoch, 0), referenceSelect(epoch, 0));
        assertEq(points.selectByWeight(epoch, total - 1), referenceSelect(epoch, total - 1));
    }

    // ===============================================================
    // Never-revert guarantee
    // ===============================================================

    function testFuzz_hooksNeverRevert(
        address a,
        address b,
        address m,
        address t,
        uint256 notional,
        uint256 pnl,
        uint16 warpDays,
        bool coordinatorReverts
    ) public {
        coordinator.setRevertOnRequest(coordinatorReverts);
        vm.warp(START_TIME + uint256(warpDays) * 1 days);
        vm.startPrank(market);
        points.onFill(a, b, m, t, notional);
        points.onSettle(a, b, t, notional, pnl);
        points.onMarketCreated(m, t);
        points.onFill(b, a, a, t, notional);
        points.onSettle(b, a, t, notional, pnl);
        points.onFill(a, a, a, t, notional);
        vm.stopPrank();
    }

    function test_hooksSurvive_revertingSpinVRF() public {
        RevertingSpinSink bad = new RevertingSpinSink();
        points.setSpinVRF(address(bad));
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        fill(alice, bob, bob, tokenB, 100e6);
        assertEq(points.pointsOf(alice), 10e18, "fill earns even when spin sink reverts");
    }

    function test_hooksSurvive_spinVRFSetToEOA() public {
        points.setSpinVRF(makeAddr("someEOA"));
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        fill(alice, bob, bob, tokenB, 100e6);
        assertEq(points.pointsOf(alice), 10e18);
    }
}
