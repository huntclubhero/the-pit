// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {CasinoTestBase} from "./CasinoTestBase.t.sol";

/// @title Win streak and daily activity streak state machine walks
contract StreaksTest is CasinoTestBase {
    address internal alice;
    address internal bob;

    function setUp() public override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    // ===============================================================
    // Win streak multiplier table
    // ===============================================================

    function test_winStreak_multiplierTable() public {
        // Wins are spaced past the advance throttle (audit fix L3) so each one advances the streak.
        assertEq(points.winMultiplierOf(alice), 10_000, "streak 0: 1.0x");
        win(alice);
        assertEq(points.winMultiplierOf(alice), 10_000, "streak 1: 1.0x");
        warpPastWinThrottle();
        win(alice);
        assertEq(points.winMultiplierOf(alice), 12_000, "streak 2: 1.2x");
        warpPastWinThrottle();
        win(alice);
        assertEq(points.winMultiplierOf(alice), 15_000, "streak 3: 1.5x");
        warpPastWinThrottle();
        win(alice);
        assertEq(points.winMultiplierOf(alice), 20_000, "streak 4: 2x");
        warpPastWinThrottle();
        win(alice);
        assertEq(points.winMultiplierOf(alice), 30_000, "streak 5: 3x");
        warpPastWinThrottle();
        win(alice);
        assertEq(points.winMultiplierOf(alice), 50_000, "streak 6: 5x cap");
        warpPastWinThrottle();
        win(alice);
        assertEq(points.winMultiplierOf(alice), 50_000, "streak 7: still 5x");
    }

    /// @dev L3: a burst of wins with no time between them advances the streak only once, so a
    ///      selective self-settle farm cannot compress a 5x multiplier into one block.
    function test_winStreak_burstAdvancesOnce() public {
        win(alice);
        win(alice);
        win(alice);
        win(alice);
        (uint64 wins,,) = points.winStreakOf(alice);
        assertEq(wins, 1, "same-timestamp burst advances the streak only once");
        assertEq(points.winMultiplierOf(alice), 10_000, "no farmed multiplier from a burst");
    }

    // ===============================================================
    // Shield state machine
    // ===============================================================

    function test_shield_absorbsFirstLoss() public {
        win(alice);
        warpPastWinThrottle();
        win(alice);
        warpPastWinThrottle();
        win(alice);
        lose(alice);
        (uint64 wins, uint64 shieldConsumedAt, bool shieldAvailable) = points.winStreakOf(alice);
        assertEq(wins, 3, "streak preserved by shield");
        assertEq(shieldConsumedAt, uint64(block.timestamp), "shield consumed now");
        assertFalse(shieldAvailable, "shield spent for 24h");
    }

    function test_shield_secondLossInsideWindowResets() public {
        win(alice);
        warpPastWinThrottle();
        win(alice);
        warpPastWinThrottle();
        win(alice);
        lose(alice);
        vm.warp(block.timestamp + 23 hours);
        lose(alice);
        (uint64 wins,,) = points.winStreakOf(alice);
        assertEq(wins, 0, "double loss inside window resets streak");
    }

    function test_shield_refreshesAfter24h() public {
        win(alice);
        warpPastWinThrottle();
        win(alice);
        warpPastWinThrottle();
        win(alice);
        lose(alice);
        vm.warp(block.timestamp + 24 hours);
        (,, bool shieldAvailable) = points.winStreakOf(alice);
        assertTrue(shieldAvailable, "shield refreshed 24h after consumption");

        lose(alice);
        (uint64 wins,,) = points.winStreakOf(alice);
        assertEq(wins, 3, "refreshed shield absorbs again");

        vm.warp(block.timestamp + 1 hours);
        lose(alice);
        (wins,,) = points.winStreakOf(alice);
        assertEq(wins, 0, "second loss inside new window resets");
    }

    function test_shield_notConsumedAtZeroStreak() public {
        lose(alice);
        (uint64 wins, uint64 shieldConsumedAt, bool shieldAvailable) = points.winStreakOf(alice);
        assertEq(wins, 0);
        assertEq(shieldConsumedAt, 0, "shield untouched at streak 0");
        assertTrue(shieldAvailable);
    }

    function test_winStreak_rebuildsAfterReset() public {
        win(alice);
        warpPastWinThrottle();
        win(alice);
        warpPastWinThrottle();
        win(alice);
        lose(alice);
        lose(alice); // reset
        // After a reset the throttle is cleared, so the first rebuild win advances immediately.
        win(alice);
        warpPastWinThrottle();
        win(alice);
        assertEq(points.winMultiplierOf(alice), 12_000, "streak rebuilt to 2");
    }

    // ===============================================================
    // Daily activity streak
    // ===============================================================

    function takerEarnFromFill(address taker, uint256 notional) internal returns (uint256) {
        uint256 before = points.pointsOf(taker);
        fill(taker, bob, bob, tokenB, notional);
        return points.pointsOf(taker) - before;
    }

    function test_dailyStreak_progressionAndMultiplier() public {
        assertEq(takerEarnFromFill(alice, 100e6), 10e18, "day 1: 1.0x");
        vm.warp(block.timestamp + 1 days);
        assertEq(takerEarnFromFill(alice, 100e6), 10.5e18, "day 2: 1.05x");
        vm.warp(block.timestamp + 1 days);
        assertEq(takerEarnFromFill(alice, 100e6), 11e18, "day 3: 1.1x");
    }

    function test_dailyStreak_sameDayDoesNotAdvance() public {
        takerEarnFromFill(alice, 100e6);
        vm.warp(block.timestamp + 2 hours);
        assertEq(takerEarnFromFill(alice, 100e6), 10e18, "same UTC day stays 1.0x");
        (, uint64 count) = points.dailyStreakOf(alice);
        assertEq(count, 1);
    }

    function test_dailyStreak_gapResets() public {
        takerEarnFromFill(alice, 100e6);
        vm.warp(block.timestamp + 1 days);
        takerEarnFromFill(alice, 100e6);
        (, uint64 count) = points.dailyStreakOf(alice);
        assertEq(count, 2);

        vm.warp(block.timestamp + 2 days); // missed a day
        assertEq(takerEarnFromFill(alice, 100e6), 10e18, "gap resets to 1.0x");
        (, count) = points.dailyStreakOf(alice);
        assertEq(count, 1, "streak reset to 1");
    }

    function test_dailyStreak_capAt150() public {
        for (uint256 i = 0; i < 10; i++) {
            takerEarnFromFill(alice, 100e6);
            vm.warp(block.timestamp + 1 days);
        }
        // Day 11 of the streak: multiplier capped at 1.5x.
        assertEq(takerEarnFromFill(alice, 100e6), 15e18, "day 11: 1.5x cap");
        vm.warp(block.timestamp + 1 days);
        assertEq(takerEarnFromFill(alice, 100e6), 15e18, "day 12: still capped");
    }

    function test_dailyMultiplierOf_projectsNextFill() public {
        takerEarnFromFill(alice, 100e6);
        assertEq(points.dailyMultiplierOf(alice), 10_000, "today already counted");
        vm.warp(block.timestamp + 1 days);
        assertEq(points.dailyMultiplierOf(alice), 10_500, "acting now would be day 2");
        vm.warp(block.timestamp + 2 days);
        assertEq(points.dailyMultiplierOf(alice), 10_000, "gap projects a reset");
    }

    function test_dailyStreak_touchesAllFillParticipants() public {
        address carol = makeAddr("carol");
        // carol is maker, alice long taker, bob short: all three touched.
        vm.prank(market);
        points.onFill(alice, bob, carol, tokenB, 100e6);
        (, uint64 countAlice) = points.dailyStreakOf(alice);
        (, uint64 countBob) = points.dailyStreakOf(bob);
        (, uint64 countCarol) = points.dailyStreakOf(carol);
        assertEq(countAlice, 1);
        assertEq(countBob, 1);
        assertEq(countCarol, 1);
    }

    function test_settleDoesNotTouchDailyStreak() public {
        win(alice);
        (, uint64 count) = points.dailyStreakOf(alice);
        assertEq(count, 0, "settle is not daily activity");
    }
}
