// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpEngineBase} from "./PerpEngineBase.t.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";
import {MockPitVault} from "./mocks/MockPitVault.sol";

/// @notice The reincarnated capped-payout invariant (spec 3.6): per-market reserve cap =
///         min(cost-to-move / safetyFactor, TVL percentage), re-read at every open and
///         addMargin; per-address share; new-market ramp; utilization; drawdown circuit.
contract PerpEngineCapsTest is PerpEngineBase {
    function setUp() public override {
        super.setUp();
        vault.setTotalAssetsOverride(1_000_000e6); // freeze TVL: caps are deterministic
    }

    function test_capComputation_tvlLeg() public view {
        // No router cap set (majors path): 10% of 1M = 100k.
        assertEq(engine.marketReserveCapUsdg(MEME), 100_000e6);
    }

    function test_capComputation_costToMoveLegWins() public {
        // B1: the cost-to-move cap is FROZEN at listing, so it must be set before listMarket.
        address m = listFreshMeme(40_000e18); // cost-to-move cap 40k USD, frozen
        assertEq(engine.marketReserveCapUsdg(m), 40_000e6, "min(frozen cost-to-move, TVL leg)");
    }

    function test_open_revertsPastMarketReserveCap() public {
        engine.setPerAddressReserveShareBps(10_000); // isolate the MARKET cap leg
        address m = listFreshMeme(20_000e18); // market cap 20k USDG of reserves, frozen at listing
        // 9x payout: alice 17,892 fits; bob then would push 17,892 + more past 20k.
        open(alice, m, true, 2_000e6, 600);
        vm.prank(bob);
        vm.expectRevert(PerpEngine.MarketReserveCapExceeded.selector);
        engine.openPosition(m, true, 1_000e6, 600);
        // A small position that still fits goes through: the cap binds exactly.
        open(bob, m, true, 200e6, 600); // adds 9 * 198.8 = 1789.2: total 19,681.2
        assertLe(vault.reservedOf(m), 20_000e6);
    }

    function test_addMargin_alsoPushesAgainstTheCap() public {
        engine.setPerAddressReserveShareBps(10_000);
        address m = listFreshMeme(20_000e18);
        open(alice, m, true, 2_000e6, 600); // 17,892 reserved
        vm.prank(alice);
        vm.expectRevert(PerpEngine.MarketReserveCapExceeded.selector);
        engine.addMargin(m, true, 300e6); // +2,700 would cross 20k
        vm.prank(alice);
        engine.addMargin(m, true, 200e6); // +1,800: 19,692 fits
    }

    /// @notice B1: the frozen cost-to-move cap does NOT move when the live router value shifts, in
    ///         EITHER direction, so a later liquidity pump (the H1 vault-drain vector) cannot
    ///         inflate a market's reserve cap on open positions, nor can a drop shrink it.
    function test_frozenCapUnaffectedByLiveOracleShift() public {
        engine.setPerAddressReserveShareBps(10_000); // isolate the market cap leg
        address m = listFreshMeme(40_000e18); // frozen at 40k
        assertEq(engine.marketReserveCapUsdg(m), 40_000e6);
        open(alice, m, true, 2_000e6, 600); // 17,892 reserved under the frozen 40k cap
        // A live oracle DECREASE must not change the frozen cap.
        oracle.setPayoutCap1e18(m, 5_000e18);
        assertEq(engine.marketReserveCapUsdg(m), 40_000e6, "frozen cap ignores a live decrease");
        // A live oracle INCREASE (pump liquidity to inflate the cap) is also ignored: the H1 fix.
        oracle.setPayoutCap1e18(m, 500_000e18);
        assertEq(engine.marketReserveCapUsdg(m), 40_000e6, "frozen cap ignores a live increase");
        // Existing position lives on; the vault reservation still mirrors the engine.
        assertEq(vault.reservedOf(m), aggOf(m).totalMaxPayout);
        vm.prank(alice);
        engine.closePosition(m, true); // exit always works
    }

    // ================================ FIX-3: stale-HIGH cost-to-move trip ================================

    /// @notice The frozen cost-to-move cap is correct at listing but never LOWERS. If a memecoin's
    ///         real pool depth later collapses so the LIVE router cap falls below the outstanding
    ///         reservations, the core inequality (max_payout <= costToMove/SF) breaks. A
    ///         permissionless trip flips the market to close-only: opens blocked, closes still work.
    function test_costToMoveTrip_blocksOpensAfterDepthCollapse() public {
        engine.setPerAddressReserveShareBps(10_000); // isolate the market cap leg
        address m = listFreshMeme(20_000e18); // frozen cost-to-move cap 20k USDG
        open(alice, m, true, 2_000e6, 600); // reserves 17,892 USDG under the frozen cap
        uint256 reserved = aggOf(m).totalMaxPayout;
        assertGt(reserved, 0, "outstanding reservations exist");

        // Depth collapses: the LIVE router cap drops to 3k USDG, far below the 17,892 outstanding.
        oracle.setPayoutCap1e18(m, 3_000e18);
        // Anyone can trip it (permissionless).
        vm.prank(bob);
        engine.tripCostToMoveCloseOnly(m);
        assertTrue(aggOf(m).closeOnly, "market flipped to close-only");

        // Opens and increases are now blocked; closes/liquidations still work.
        vm.prank(bob);
        vm.expectRevert(PerpEngine.MarketCloseOnly.selector);
        engine.openPosition(m, true, 100e6, 600);
        vm.prank(alice);
        vm.expectRevert(PerpEngine.MarketCloseOnly.selector);
        engine.increasePosition(m, true, 100e6, 600);
        vm.prank(alice);
        engine.closePosition(m, true); // exit always works
        assertEq(posOf(m, alice, true).size1e18, 0, "close succeeded in close-only mode");
    }

    /// @notice A healthy market cannot be tripped: neither an untouched cap, nor a live decrease
    ///         that still covers the outstanding reservations, nor an empty market, nor a major.
    function test_costToMoveTrip_healthyMarketCannotBeTripped() public {
        engine.setPerAddressReserveShareBps(10_000);
        address m = listFreshMeme(20_000e18);
        open(alice, m, true, 2_000e6, 600); // reserves 17,892 USDG

        // (1) Live cap unchanged (>= frozen): not breached.
        vm.expectRevert(PerpEngine.CostToMoveNotBreached.selector);
        engine.tripCostToMoveCloseOnly(m);

        // (2) Live cap drops but still covers the outstanding reservations (20k -> 18k >= 17,892).
        oracle.setPayoutCap1e18(m, 18_000e18);
        vm.expectRevert(PerpEngine.CostToMoveNotBreached.selector);
        engine.tripCostToMoveCloseOnly(m);
        assertFalse(aggOf(m).closeOnly, "healthy market stays open");

        // (3) An empty market (no reservations) can never be tripped, even at a collapsed cap.
        address empty = listFreshMeme(20_000e18);
        oracle.setPayoutCap1e18(empty, 1e18);
        vm.expectRevert(PerpEngine.CostToMoveNotBreached.selector);
        engine.tripCostToMoveCloseOnly(empty);

        // (4) A major (frozen cap type(uint256).max) can never be tripped.
        vm.expectRevert(PerpEngine.CostToMoveNotBreached.selector);
        engine.tripCostToMoveCloseOnly(MAJOR);

        // (5) Unlisted token reverts NotListed.
        vm.expectRevert(PerpEngine.NotListed.selector);
        engine.tripCostToMoveCloseOnly(address(0xDEAD));
    }

    function test_perAddressShare_forcesSybilSplit() public {
        // Address cap = 25% of 100k = 25k of reserved payout.
        open(alice, MEME, true, 2_000e6, 600); // 17,892
        vm.prank(alice);
        vm.expectRevert(PerpEngine.AddressReserveCapExceeded.selector);
        engine.openPosition(MEME, false, 1_000e6, 600); // +8,946 crosses alice's 25k
        // A different address still has full room: the cap is per address.
        open(bob, MEME, false, 1_000e6, 600);
        assertAggMatchesPositions(MEME);
    }

    /// @notice Economics v2 linear ramp: a fresh market's cap grows 1%/day of TVL over 14
    ///         days (day N allows N * rampCapBps), replacing the old flat 2%-for-7-days
    ///         throttle, so a new market cannot reach full capacity without price history.
    function test_newMarketRamp_linearOnePercentPerDay() public {
        engine.setPerAddressReserveShareBps(10_000);
        address fresh = address(0xFEE1);
        oracle.setLive(fresh, 1e18);
        oracle.setListable(fresh, true);
        risk.setParams(fresh, _memeTierParams(), 2);
        engine.listMarket(fresh);
        // Day one: cap = 1% of 1M = 10k, not 100k.
        assertEq(engine.marketReserveCapUsdg(fresh), 10_000e6);
        vm.prank(alice);
        vm.expectRevert(PerpEngine.MarketReserveCapExceeded.selector);
        engine.openPosition(fresh, true, 1_200e6, 600); // 9 * 1192.8 = 10,735 > 10k
        open(alice, fresh, true, 1_000e6, 600); // 8,946 fits under day one
        // Day four (3 full days elapsed): 4% of TVL.
        vm.warp(block.timestamp + 3 days);
        assertEq(engine.marketReserveCapUsdg(fresh), 40_000e6);
        // Day ten: the linear ramp (10%) meets the full TVL leg; past the window it is gone.
        vm.warp(block.timestamp + 11 days);
        assertEq(engine.marketReserveCapUsdg(fresh), 100_000e6);
    }

    function test_vaultUtilizationCap_backstops() public {
        // The VAULT enforces global utilization in reservePayout (integration contract).
        vault.setMaxUtilizationBps(100); // 1% of 1M = 10k max reserved
        vm.prank(alice);
        vm.expectRevert(MockPitVault.UtilizationExceeded.selector);
        engine.openPosition(MEME, true, 2_000e6, 600); // 17,892 > 10k
    }

    function test_drawdownCircuit_tripsAndBlocksOpens() public {
        open(alice, MEME, true, 500e6, 600); // seeds the 24h window at 1M TVL
        vault.setTotalAssetsOverride(850_000e6); // 15% drawdown inside the window

        // Live condition blocks opens even before the latch.
        vm.prank(bob);
        vm.expectRevert(PerpEngine.DrawdownCircuitActive.selector);
        engine.openPosition(MEME, true, 500e6, 600);

        // Anyone can latch while the condition holds; the latch then outlives a TVL bounce.
        vm.prank(keeper);
        engine.tripDrawdownCircuit();
        assertTrue(engine.drawdownTripped());
        vault.setTotalAssetsOverride(1_000_000e6);
        vm.prank(bob);
        vm.expectRevert(PerpEngine.DrawdownCircuitActive.selector);
        engine.openPosition(MEME, true, 500e6, 600);

        // Closes still work while tripped (close-only semantics).
        vm.prank(alice);
        engine.closePosition(MEME, true);

        // Only the owner can reset; after reset opens work again (window re-seeds).
        vm.prank(alice);
        vm.expectRevert();
        engine.resetDrawdownCircuit();
        engine.resetDrawdownCircuit();
        open(bob, MEME, true, 500e6, 600);
    }

    function test_drawdownLatch_requiresLiveBreach() public {
        open(alice, MEME, true, 500e6, 600);
        vm.expectRevert(PerpEngine.DrawdownNotBreached.selector);
        engine.tripDrawdownCircuit();
    }

    function test_drawdownCircuit_windowRollsWithoutTrip() public {
        open(alice, MEME, true, 500e6, 600);
        vm.warp(block.timestamp + 25 hours); // window expired
        vault.setTotalAssetsOverride(850_000e6);
        open(bob, MEME, true, 500e6, 600); // re-seeds at the new level, no trip
        assertFalse(engine.drawdownTripped());
    }

    // ============================ B2: drawdown defanged ============================

    /// @notice B2b: the GUARDIAN can clear the latch immediately (the fast lever), not only the
    ///         2-day timelocked owner.
    function test_drawdownCircuit_guardianCanReset() public {
        open(alice, MEME, true, 500e6, 600);
        vault.setTotalAssetsOverride(850_000e6);
        vm.prank(keeper);
        engine.tripDrawdownCircuit();
        assertTrue(engine.drawdownTripped());
        vault.setTotalAssetsOverride(1_000_000e6);
        // A random address cannot reset; the guardian can.
        vm.prank(bob);
        vm.expectRevert(PerpEngine.NotOwnerOrGuardian.selector);
        engine.resetDrawdownCircuit();
        vm.prank(guardianEoa);
        engine.resetDrawdownCircuit();
        assertFalse(engine.drawdownTripped());
        open(bob, MEME, true, 500e6, 600); // opens work again
    }

    /// @notice B2c: the latch AUTO-EXPIRES on a window roll when the live gate is clear, so a
    ///         transient dip cannot freeze opens for the full 2-day timelock.
    function test_drawdownCircuit_autoExpiresOnWindowRoll() public {
        open(alice, MEME, true, 500e6, 600); // seed window at 1M
        vault.setTotalAssetsOverride(850_000e6); // breach
        vm.prank(keeper);
        engine.tripDrawdownCircuit();
        assertTrue(engine.drawdownTripped());
        // Recover and roll the window: the next open self-heals the latch.
        vault.setTotalAssetsOverride(1_000_000e6);
        vm.warp(block.timestamp + 25 hours);
        open(bob, MEME, true, 500e6, 600); // window rolls, latch auto-clears, open succeeds
        assertFalse(engine.drawdownTripped(), "latch auto-expired on window roll");
    }

    /// @notice B2a: the drawdown reference excludes crystallized LP-withdraw liability, so a
    ///         routine LP exit (totalAssets falls, liability rises) is NOT read as a trading
    ///         drawdown and cannot trip the circuit.
    function test_drawdownCircuit_excludesLpWithdrawLiability() public {
        open(alice, MEME, true, 500e6, 600); // seed the window at reference 1M
        // Simulate an LP exit crystallizing 200k: totalAssets drops to 800k but the reference
        // (totalAssets + claim liability) holds at 1M.
        vault.setTotalAssetsOverride(800_000e6);
        vault.setClaimLiabilityOverride(200_000e6); // reference = 1,000,000
        // Not breached against the 900k floor: the LP exit did not read as a loss.
        open(bob, MEME, true, 500e6, 600);
        vm.prank(keeper);
        vm.expectRevert(PerpEngine.DrawdownNotBreached.selector);
        engine.tripDrawdownCircuit();
    }

    function testFuzz_reserveCapNeverExceeded(uint256 seed) public {
        oracle.setPayoutCap1e18(MEME, 30_000e18); // bounded market: cap 30k USDG
        uint256 cap = engine.marketReserveCapUsdg(MEME);
        address[3] memory actors = [alice, bob, carol];
        for (uint256 i = 0; i < 12; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address who = actors[r % 3];
            bool isLong = (r >> 8) % 2 == 0;
            uint128 margin = uint128(bound((r >> 16) % 1e10, 10e6, 2_000e6));
            uint32 lev = uint32(bound((r >> 64) % 1000, 110, 600));
            vm.prank(who);
            try engine.openPosition(MEME, isLong, margin, lev) {}
                catch {
                // cap or duplicate-position revert: both fine, the bound is what matters
            }
            assertLe(vault.reservedOf(MEME), cap, "reserve cap invariant");
            assertLe(vault.maxReservedEverOf(MEME), cap, "high-water mark under cap");
        }
        assertAggMatchesPositions(MEME);
    }

    function _memeTierParams() internal pure returns (PerpTypes.TierParams memory) {
        return PerpTypes.TierParams({
            maxLeverageX100: 600,
            mmrBps: 1_000,
            openFeeBps: 10,
            closeFeeBps: 10,
            kFPerHour1e18: 25e14,
            kBPerHour1e18: 1e14,
            liqPenaltyBps: 100,
            maxPositionMargin: 10_000e6
        });
    }
}
