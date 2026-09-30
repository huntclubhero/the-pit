// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpEngineBase} from "./PerpEngineBase.t.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";

/// @notice The LIVE / FALLBACK / BLOCKED classifier and the per-action gating matrix
///         (spec 2.3): opens + liquidations require a LIVE print + openingAllowed; closes
///         and reduces work on FALLBACK; addMargin always works; funding freezes on
///         non-LIVE prints. Plus guardian-pause and close-only behavior (spec 3.7).
contract PerpEngineGatingTest is PerpEngineBase {
    uint128 internal constant MARGIN = 1_000e6;
    uint32 internal constant LEV = 600;

    function _openAliceLong() internal returns (bytes32) {
        return open(alice, MEME, true, MARGIN, LEV);
    }

    // ============================ FALLBACK print ============================

    function test_fallback_openReverts_closeWorks() public {
        _openAliceLong();
        open(bob, MEME, false, MARGIN, LEV);
        oracle.setFallback(MEME, 1e18);

        vm.prank(carol);
        vm.expectRevert(PerpEngine.PrintNotLive.selector);
        engine.openPosition(MEME, true, MARGIN, LEV);

        vm.prank(alice);
        vm.expectRevert(PerpEngine.PrintNotLive.selector);
        engine.increasePosition(MEME, true, MARGIN, LEV);

        // Close and reduce are user-initiated de-risking: fallback is acceptable.
        vm.prank(alice);
        engine.closePosition(MEME, true);
        vm.prank(bob);
        engine.reducePosition(MEME, false, 4_000);
        assertAggMatchesPositions(MEME);
    }

    function test_fallback_liquidationPaused() public {
        _openAliceLong();
        oracle.setLive(MEME, 84e16); // below liq price on a LIVE print: liquidatable
        assertTrue(engine.liquidatable(MEME, alice, true));
        oracle.setFallback(MEME, 84e16);
        assertFalse(engine.liquidatable(MEME, alice, true), "view mirrors the pause");
        vm.prank(keeper);
        vm.expectRevert(PerpEngine.PrintNotLive.selector);
        engine.liquidate(MEME, alice, true);
    }

    function test_fallback_removeMarginReverts_addMarginWorks() public {
        _openAliceLong();
        oracle.setFallback(MEME, 1e18);
        vm.prank(alice);
        vm.expectRevert(PerpEngine.PrintNotLive.selector);
        engine.removeMargin(MEME, true, 10e6);
        vm.prank(alice);
        engine.addMargin(MEME, true, 100e6); // strictly de-risking: always allowed
        assertEq(posOf(MEME, alice, true).margin, 994e6 + 100e6);
    }

    // ============================ BLOCKED print ============================

    function test_blocked_everythingButAddMarginReverts() public {
        _openAliceLong();
        oracle.setBlocked(MEME);

        vm.prank(bob);
        vm.expectRevert(PerpEngine.PrintNotLive.selector);
        engine.openPosition(MEME, false, MARGIN, LEV);

        vm.prank(alice);
        vm.expectRevert(PerpEngine.PrintBlocked.selector);
        engine.closePosition(MEME, true);

        vm.prank(alice);
        vm.expectRevert(PerpEngine.PrintBlocked.selector);
        engine.reducePosition(MEME, true, 5_000);

        vm.prank(keeper);
        vm.expectRevert(PerpEngine.PrintNotLive.selector);
        engine.liquidate(MEME, alice, true);

        vm.prank(alice);
        engine.addMargin(MEME, true, 100e6);
        assertEq(posOf(MEME, alice, true).margin, 1_094e6);
    }

    // ============================ opening breaker ============================

    function test_openingBreaker_deniesOpensAndLiquidations() public {
        _openAliceLong();
        oracle.setOpeningDenied(MEME, true, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.OpeningDenied.selector, 1));
        engine.openPosition(MEME, false, MARGIN, LEV);

        oracle.setLive(MEME, 84e16);
        oracle.setOpeningDenied(MEME, true, 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.OpeningDenied.selector, 1));
        engine.liquidate(MEME, alice, true);
        assertFalse(engine.liquidatable(MEME, alice, true));

        // Close still works: the breaker is an opening constraint only.
        vm.prank(alice);
        engine.closePosition(MEME, true);
    }

    // ============================ guardian pause ============================

    function test_pause_blocksOpensAndLiquidationsOnly() public {
        _openAliceLong();
        open(bob, MEME, false, MARGIN, LEV);
        vm.prank(guardianEoa);
        guardian.pause(address(engine)); // engine-global key

        vm.prank(carol);
        vm.expectRevert(PerpEngine.EnginePaused.selector);
        engine.openPosition(MEME, true, MARGIN, LEV);

        oracle.setLive(MEME, 84e16);
        vm.prank(keeper);
        vm.expectRevert(PerpEngine.EnginePaused.selector);
        engine.liquidate(MEME, alice, true);

        vm.prank(alice);
        vm.expectRevert(PerpEngine.EnginePaused.selector);
        engine.removeMargin(MEME, true, 1e6);

        // Positions, closes and addMargin survive the pause.
        vm.prank(alice);
        engine.addMargin(MEME, true, 50e6);
        vm.prank(alice);
        engine.closePosition(MEME, true);
        vm.prank(bob);
        engine.reducePosition(MEME, false, 5_000);

        // Auto-expiry restores everything.
        vm.warp(block.timestamp + 24 hours + 1);
        open(carol, MEME, true, MARGIN, LEV);
    }

    function test_pause_perMarketKey() public {
        vm.prank(guardianEoa);
        guardian.pause(MEME); // token key pauses only that market
        vm.prank(alice);
        vm.expectRevert(PerpEngine.EnginePaused.selector);
        engine.openPosition(MEME, true, MARGIN, LEV);
        open(alice, MAJOR, true, MARGIN, 1_000); // other market unaffected
    }

    // ============================ close-only (delisting) ============================

    function test_closeOnly_orderlyDelist() public {
        _openAliceLong();
        engine.setCloseOnly(MEME, true);

        vm.prank(bob);
        vm.expectRevert(PerpEngine.MarketCloseOnly.selector);
        engine.openPosition(MEME, false, MARGIN, LEV);
        vm.prank(alice);
        vm.expectRevert(PerpEngine.MarketCloseOnly.selector);
        engine.increasePosition(MEME, true, MARGIN, LEV);

        // Liquidations and closes continue (spec 3.7).
        oracle.setLive(MEME, 84e16);
        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);
        assertEq(posOf(MEME, alice, true).size1e18, 0);

        engine.setCloseOnly(MEME, false);
        open(bob, MEME, false, MARGIN, LEV);
    }

    function test_closeOnly_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.setCloseOnly(MEME, true);
    }

    // ============================ funding freeze ============================

    function test_funding_frozenOnNonLivePrints() public {
        _openAliceLong(); // one-sided long: positive skew accrues funding when LIVE
        uint64 accrualAtOpen = aggOf(MEME).lastAccrual;
        oracle.setFallback(MEME, 1e18);
        vm.warp(block.timestamp + 5 hours);
        engine.pokeFunding(MEME);
        PerpTypes.MarketAggregates memory agg = aggOf(MEME);
        assertEq(agg.fundingX1e18, 0, "fallback interval not booked");
        assertEq(agg.borrowX1e18, 0);
        // B4 accrue-then-freeze: lastAccrual does NOT advance across a non-LIVE gap, so a single
        // permissionless poke during a blip can no longer swallow the pending interval; it bills
        // on the next LIVE poke instead. The cached mark is still refreshed for NAV.
        assertEq(agg.lastAccrual, accrualAtOpen, "clock frozen across the non-LIVE gap");
        assertEq(agg.cachedMark1e18, 1e18, "fallback mark still cached for NAV");

        // Back to LIVE: the WHOLE preserved interval (5h + 1h) now accrues; nothing was lost.
        oracle.setLive(MEME, 1e18);
        vm.warp(block.timestamp + 1 hours);
        engine.pokeFunding(MEME);
        agg = aggOf(MEME);
        assertGt(agg.fundingX1e18, 0, "preserved interval accrues on recovery");
        // 6 hours at skew 5964/10000 (floor-damped) of 0.25%/h on a 1.00 mark:
        // rate = 25e14 * 0.5964 = 1.491e15; delta = 1.491e15 * 6.
        assertEq(agg.fundingX1e18, 1_491e12 * 6);
    }

    function test_listMarket_gates() public {
        address newToken = address(0xF00D);
        vm.expectRevert(PerpEngine.RouterNotListable.selector);
        engine.listMarket(newToken);
        oracle.setListable(newToken, true);
        vm.expectRevert(); // no tier assigned in risk config
        engine.listMarket(newToken);
        vm.expectRevert(PerpEngine.AlreadyListed.selector);
        engine.listMarket(MEME);
        vm.prank(alice);
        vm.expectRevert();
        engine.listMarket(newToken); // not owner
    }

    function test_marketRegistry_forVault() public view {
        assertEq(engine.marketCount(), 2);
        assertEq(engine.marketAt(0), MEME);
        assertEq(engine.marketAt(1), MAJOR);
    }

    // ============================ B5: pool-priced breaker must be armed ============================

    /// @notice B5: a pool-priced (B_DEEP / C_MID) token cannot be listed with its spot-vs-TWAP
    ///         opening breaker disarmed (spotSource == 0), which would nullify the only
    ///         execution-time manipulation gate for pool-priced markets (pa-oracle S1).
    function test_listMarket_rejectsPoolPricedWithBreakerDisarmed() public {
        address pool = address(0xB00B);
        oracle.setLive(pool, 1e18);
        oracle.setListable(pool, true);
        risk.setParams(pool, _memeParams(), 2);

        // B_DEEP (tier 1) with a disarmed breaker: rejected.
        oracle.setTierConfig(pool, 1, address(0));
        vm.expectRevert(PerpEngine.OpeningBreakerDisarmed.selector);
        engine.listMarket(pool);

        // C_MID (tier 2) with a disarmed breaker: also rejected.
        oracle.setTierConfig(pool, 2, address(0));
        vm.expectRevert(PerpEngine.OpeningBreakerDisarmed.selector);
        engine.listMarket(pool);

        // Arming the breaker (nonzero spotSource) permits listing.
        oracle.setTierConfig(pool, 1, address(0x5907));
        engine.listMarket(pool);
        assertTrue(engine.isListed(pool));
    }

    /// @notice A major (tier 0, A_MAJOR) needs no spot source: it lists with spotSource == 0.
    function test_listMarket_majorNeedsNoBreaker() public {
        address major = address(0xFEED);
        oracle.setLive(major, 1e18);
        oracle.setListable(major, true);
        risk.setParams(major, _memeParams(), 2);
        oracle.setTierConfig(major, 0, address(0)); // A_MAJOR, no spot source
        engine.listMarket(major);
        assertTrue(engine.isListed(major));
    }

    function _memeParams() internal pure returns (PerpTypes.TierParams memory) {
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
