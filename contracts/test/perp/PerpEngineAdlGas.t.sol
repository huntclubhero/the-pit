// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PerpEngineBase} from "./PerpEngineBase.t.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";
import {MarginMathLib} from "../../src/perp/MarginMathLib.sol";

/// @notice RB6: ADL must be HARD-BOUNDED in gas regardless of the market's open-position count.
///         The B6 rework fixed victim starvation but made ADL O(n) in open positions, letting an
///         attacker pack a market with min-size delta-hedged positions and OOG the liquidation
///         (which calls _adl un-try/catch'd) exactly during gap stress. These tests pin:
///         (a) a liquidation over a packed book completes within a fixed gas ceiling,
///         (b) at most MAX_ADL_VICTIMS victims are force-closed per pass,
///         (c) residual bad debt past the bounded pass emits AdlResidualSocialized and the
///             accounting stays wei-exact (adlAbsorbed + residual == shortfall),
///         (d) same-side and NON-ABSORBING opposite-side padding inside the scan window cannot
///             starve a genuine absorbing victim.
contract PerpEngineAdlGasTest is PerpEngineBase {
    /// @dev Generous hard ceiling for the WHOLE liquidate() call over a packed book. Measured:
    ///      the old unbounded collection walked every open key: ~8.50M gas at n=1001 vs ~2.75M
    ///      at n=251 (~7.7k gas per extra key, linear toward hard-OOG at attacker-fundable
    ///      position counts). The RB6-bounded version measured ~3.12M at n=1001 and ~3.07M at
    ///      n=251 (flat: full 256-key scan + 32 victim closes). 5M fails the old code at n=1001
    ///      while leaving the bounded implementation ~60% headroom.
    uint256 internal constant ADL_LIQUIDATION_GAS_CEILING = 5_000_000;

    bytes32 internal constant TOPIC_BAD_DEBT = keccak256("BadDebt(address,address,uint256,uint256,uint256)");
    bytes32 internal constant TOPIC_ADL_RESIDUAL = keccak256("AdlResidualSocialized(address,uint256)");
    bytes32 internal constant TOPIC_ADL_EXECUTED = keccak256("AdlExecuted(address,address,bool,uint256,uint256)");

    address[] internal sybils;

    function _sybil(uint256 salt) internal returns (address s) {
        s = address(uint160(uint256(keccak256(abi.encode("adl-pack", salt)))));
        sybils.push(s);
        usdg.mint(s, 1_000e6);
        vm.prank(s);
        usdg.approve(address(engine), type(uint256).max);
    }

    /// @dev Pack MEME with `pairs` min-size delta-hedged sybil pairs (2 positions each), the
    ///      cheapest way an attacker inflates the open-position count under the reserve caps.
    function _packMarket(uint256 pairs) internal {
        for (uint256 i = 0; i < pairs; i++) {
            address s = _sybil(i);
            open(s, MEME, true, 10e6, 600);
            open(s, MEME, false, 10e6, 600);
        }
    }

    /// @dev Fish the (shortfall, covered, adlAbsorbed) out of the recorded BadDebt log plus the
    ///      AdlResidualSocialized remainder (0 when the event did not fire).
    function _fishAdlLogs(Vm.Log[] memory logs)
        internal
        pure
        returns (uint256 shortfall, uint256 covered, uint256 adlAbsorbed, uint256 residual, bool residualEmitted)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == TOPIC_BAD_DEBT) {
                (shortfall, covered, adlAbsorbed) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            } else if (logs[i].topics[0] == TOPIC_ADL_RESIDUAL) {
                residualEmitted = true;
                residual = abi.decode(logs[i].data, (uint256));
            }
        }
    }

    // ================================ (a) + (b): hard gas bound ================================

    /// @notice A liquidation with uncovered bad debt over a 1000-dust-position packed book must
    ///         complete inside a fixed gas ceiling, close at most MAX_ADL_VICTIMS victims, and
    ///         socialize the (reserve-cap-bounded) residual instead of looping unbounded.
    function test_adl_gasBoundedOnPackedBook() public {
        open(alice, MEME, true, 1_000e6, 600); // dominant long: the funding-drag bad-debt source
        _packMarket(500); // 1000 dust positions on top: n = 1001 keys (reserve cap nearly full)
        ifund.sweep(address(this)); // empty fund forces ADL
        vm.warp(block.timestamp + 60 days); // funding drag bankrupts the dominant long
        oracle.setLive(MEME, 9e17); // shorts profit: plenty of ADL candidates

        uint256 nBefore = engine.positionKeysOf(MEME).length;
        assertEq(nBefore, 1001, "packed book fixture");

        vm.recordLogs();
        vm.prank(keeper);
        uint256 g0 = gasleft();
        engine.liquidate(MEME, alice, true);
        uint256 gasUsed = g0 - gasleft();
        console2.log("packed-book liquidate gas:", gasUsed);

        assertLt(gasUsed, ADL_LIQUIDATION_GAS_CEILING, "ADL gas must be hard-bounded on a packed book");
        assertEq(posOf(MEME, alice, true).size1e18, 0, "liquidation completed");

        // Victim budget: at most MAX_ADL_VICTIMS forced closes (alice's own key also left the set).
        uint256 nAfter = engine.positionKeysOf(MEME).length;
        uint256 victims = nBefore - 1 - nAfter;
        assertLe(victims, engine.MAX_ADL_VICTIMS(), "victim budget respected");
        assertEq(victims, engine.MAX_ADL_VICTIMS(), "fixture: shortfall large enough to spend the whole budget");

        // Residual socialized, wei-exact: adlAbsorbed + residual == shortfall (IF is empty).
        (uint256 shortfall, uint256 covered, uint256 adlAbsorbed, uint256 residual, bool emitted) =
            _fishAdlLogs(vm.getRecordedLogs());
        assertEq(covered, 0, "empty IF");
        assertTrue(emitted, "residual event emitted");
        assertGt(adlAbsorbed, 0, "bounded pass absorbed something");
        assertEq(adlAbsorbed + residual, shortfall, "absorbed + socialized residual == shortfall, wei-exact");
    }

    /// @notice Boundedness is independent of n: the same stress on a book 4x smaller must land in
    ///         the same ceiling (the old code's collection cost scaled linearly with n instead).
    function test_adl_gasBoundedOnSmallerBookSameCeiling() public {
        open(alice, MEME, true, 1_000e6, 600);
        _packMarket(125); // 250 dust positions: n = 251 keys (just under the scan window)
        ifund.sweep(address(this));
        vm.warp(block.timestamp + 60 days);
        oracle.setLive(MEME, 9e17);

        vm.prank(keeper);
        uint256 g0 = gasleft();
        engine.liquidate(MEME, alice, true);
        uint256 gasUsed = g0 - gasleft();
        console2.log("smaller-book liquidate gas:", gasUsed);

        assertLt(gasUsed, ADL_LIQUIDATION_GAS_CEILING, "same ceiling holds on the smaller book");
        assertEq(posOf(MEME, alice, true).size1e18, 0, "liquidation completed");
    }

    // ================================ (c): residual accounting ================================

    /// @notice When the bounded pass cannot cover the shortfall, the remainder is LP-socialized:
    ///         AdlResidualSocialized fires with the exact remainder and the closed system stays
    ///         wei-exact (no USDG created or destroyed).
    function test_adl_residualSocializedEventAndConservation() public {
        open(alice, MEME, true, 2_000e6, 600); // bankrupt-to-be dominant long
        open(bob, MEME, false, 500e6, 200); // the only victim: absorbs far less than the shortfall
        ifund.sweep(address(this));
        vm.warp(block.timestamp + 60 days);
        oracle.setLive(MEME, 9e17);

        uint256 sysBefore = systemBalance();
        vm.recordLogs();
        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        (uint256 shortfall, uint256 covered, uint256 adlAbsorbed, uint256 residual, bool emitted) =
            _fishAdlLogs(vm.getRecordedLogs());
        assertTrue(emitted, "residual event fired");
        assertGt(residual, 0, "fixture: shortfall exceeds the victim's absorbable profit");
        assertGt(adlAbsorbed, 0, "victim absorbed its full profit first");
        assertEq(covered, 0, "empty IF");
        assertEq(adlAbsorbed + residual, shortfall, "absorbed + residual == shortfall, wei-exact");

        assertEq(posOf(MEME, bob, false).size1e18, 0, "victim force-closed");
        assertEq(systemBalance(), sysBefore, "conservation through the residual path");
        assertEq(vault.reservedOf(MEME), 0, "all reserves released");
        assertAggMatchesPositions(MEME);
    }

    /// @notice A fully-covered shortfall emits NO residual event (the event means LP loss only).
    function test_adl_noResidualEventWhenFullyAbsorbed() public {
        // Crank funding + drop the skew floor: a modest dominant long yields a SMALL shortfall
        // that one large winner fully absorbs (same shape as the ranking test).
        PerpTypes.TierParams memory p = memeTierParams();
        p.kFPerHour1e18 = 1e18;
        risk.setParams(MEME, p, 2);
        engine.setSkewFloor(100e6);

        open(alice, MEME, true, 200e6, 600);
        open(bob, MEME, false, 100e6, 200);
        open(carol, MEME, false, 100e6, 600); // high-score winner: absorbs the whole shortfall
        ifund.sweep(address(this));
        vm.warp(block.timestamp + 2 hours);
        oracle.setLive(MEME, 5e17);

        vm.recordLogs();
        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        (uint256 shortfall,, uint256 adlAbsorbed, uint256 residual, bool emitted) = _fishAdlLogs(vm.getRecordedLogs());
        assertFalse(emitted, "no residual event when ADL covers the whole shortfall");
        assertEq(residual, 0);
        assertEq(adlAbsorbed, shortfall, "fully absorbed");
    }

    // ================== FIX-4: rank victims by ACTUAL absorption (win0), not gross price-profit% ==================

    /// @dev The OLD ADL score: gross price-profit% * leverage (what _adlScore ranked by), computed
    ///      from position state at `mark`. Deliberately ignores funding/borrow, exactly as the old
    ///      metric did, so it is the pre-FIX-4 ranking key.
    function _oldAdlScore(address token, address who, bool isLong, uint256 mark) internal view returns (uint256) {
        PerpTypes.Position memory p = posOf(token, who, isLong);
        int256 pnl = MarginMathLib.clampPnl(
            MarginMathLib.uPnlUsdg(p.size1e18, p.entryPrice1e18, mark, p.isLong, SCALE), p.margin, p.maxPayout
        );
        if (pnl <= 0) return 0;
        uint256 upnlPctBps = uint256(pnl) * BPS / p.margin;
        uint256 notionalEntry = MarginMathLib.notionalUsdg(p.size1e18, p.entryPrice1e18, SCALE);
        uint256 leverageX100 = notionalEntry * 100 / p.margin;
        return upnlPctBps * leverageX100;
    }

    /// @notice FIX-4: the 32-victim budget is ranked by win0 (the ACTUAL vault-outflow reduction a
    ///         haircut buys), NOT by gross price-profit% * leverage. Two opposite-side winners with
    ///         DISAGREEING rankings: carol (6x, tiny margin) posts a huge gross uPnL% * leverage but
    ///         a small absolute absorption; bob (2x, large margin) posts a low gross score but a
    ///         large absolute win0. The win0-ranked pass must deleverage bob (highest absorption)
    ///         FIRST, whereas the old gross-score ranking would have picked carol.
    function test_adl_ranksByAbsorptionNotGrossProfitPct() public {
        PerpTypes.TierParams memory p = memeTierParams();
        p.kFPerHour1e18 = 1e18; // hot funding to bankrupt the dominant long fast
        risk.setParams(MEME, p, 2);
        engine.setSkewFloor(100e6);

        open(alice, MEME, true, 1_000e6, 600); // dominant long: the bad-debt source
        open(carol, MEME, false, 100e6, 600); // high-lev tiny short: high OLD score, low win0
        open(bob, MEME, false, 2_000e6, 200); // low-lev large short: low OLD score, high win0
        ifund.sweep(address(this));
        vm.warp(block.timestamp + 3 hours);
        oracle.setLive(MEME, 5e17); // -50%: both shorts profit, the long is funding-bankrupt

        // Fixture disagreement: the OLD metric ranks carol strictly ABOVE bob.
        assertGt(_oldAdlScore(MEME, carol, false, 5e17), _oldAdlScore(MEME, bob, false, 5e17), "old score favors carol");

        vm.recordLogs();
        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        // The FIRST force-close must be bob (the higher-absorption victim), not carol.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address firstVictim;
        uint256 adlCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == TOPIC_ADL_EXECUTED) {
                if (adlCount == 0) firstVictim = address(uint160(uint256(logs[i].topics[2])));
                adlCount++;
            }
        }
        assertGt(adlCount, 0, "at least one victim deleveraged");
        assertEq(firstVictim, bob, "highest-absorption (win0) victim deleveraged first, not the high-gross-score one");
    }

    // ================== (d): padding inside the window cannot starve a real victim ==================

    /// @notice Same-side dust AND non-absorbing opposite-side dust (price winners whose pending
    ///         borrow exceeds their profit, so the vault owes them nothing and a haircut saves
    ///         nothing) occupy the low set indices; the genuine absorbing winner sits behind all
    ///         of them and MUST still be deleveraged, while every padding position survives.
    function test_adl_paddingDoesNotStarveRealVictimWithinWindow() public {
        // Kill funding (huge skew floor) and crank borrow so EARLY-opened dust shorts accrue
        // borrow debt past their price profit (win0 == 0: non-absorbing) while the LATE-opened
        // real winner owes ~nothing.
        engine.setSkewFloor(type(uint128).max);
        PerpTypes.TierParams memory p = memeTierParams();
        p.kBPerHour1e18 = 5e16; // 5%/h at full utilization
        risk.setParams(MEME, p, 2);

        // 40 delta-hedged dust pairs: 40 same-side longs + 40 to-be non-absorbing shorts,
        // holding set indices 0..79.
        _packMarket(40);
        open(alice, MEME, true, 2_000e6, 600); // bad-debt source (borrow drag), index 80
        ifund.sweep(address(this));
        vm.warp(block.timestamp + 60 days);
        open(carol, MEME, false, 500e6, 200); // the real victim, appended at index 81, fresh indices
        oracle.setLive(MEME, 9e17);

        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        // Fixture validity: the dust shorts' accrued borrow really exceeds their price profit.
        PerpTypes.MarketAggregates memory agg = aggOf(MEME);
        uint256 dustSize = uint256(posOf(MEME, sybils[0], false).size1e18);
        uint256 dustBorrow = dustSize * uint256(agg.borrowX1e18) / 1e30;
        uint256 dustPnl = dustSize * 1e17 / 1e30; // 10% price win in USDG units
        assertGt(dustBorrow, dustPnl, "fixture: padding shorts are non-absorbing (borrow > profit)");

        assertEq(posOf(MEME, alice, true).size1e18, 0, "liquidation completed");
        assertEq(posOf(MEME, carol, false).size1e18, 0, "real absorbing victim reached past 80 paddings");
        for (uint256 i = 0; i < sybils.length; i++) {
            assertGt(posOf(MEME, sybils[i], true).size1e18, 0, "same-side padding untouched");
            assertGt(posOf(MEME, sybils[i], false).size1e18, 0, "non-absorbing padding untouched");
        }
    }
}
