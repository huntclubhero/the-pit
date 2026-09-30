// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpEngineBase} from "./PerpEngineBase.t.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";
import {FundingLib} from "../../src/perp/FundingLib.sol";
import {MockSpotSource} from "./mocks/MockSpotSource.sol";

/// @notice RE-ECON-1 unit suite: the vol-scaled borrow layer at the engine level. The realized
///         vol reading (settlement mark vs the slow EWMA reference), the borrow-rate scaling,
///         the retro accrue-then-freeze billing, the deadband, the 2%/h ceiling, the one-block
///         non-suppressibility (the property the instantaneous spot-vs-TWAP deviation lacked),
///         and wei-exact closed-system conservation with the layer armed.
contract PerpVolBorrowTest is PerpEngineBase {
    MockSpotSource internal spot;

    uint16 internal constant K_BORROW_VOL = 400;
    uint16 internal constant DEADBAND = 300;
    uint32 internal constant MAX_MULT = 2_000_000;
    uint32 internal constant TAU = 12 hours;

    function setUp() public override {
        super.setUp();
        spot = new MockSpotSource();
        vault.setTotalAssetsOverride(VAULT_SEED); // deterministic utilization for exact math
    }

    /// @dev Arm the full economics v2 vol params at the real launch defaults.
    function _arm() internal {
        risk.setVolParams(
            PerpTypes.VolParams({
                kVolX100: 100,
                maxVolSurchargeBps: 50,
                freshSurchargeStartBps: 25,
                kCapVolX100: 2500,
                maxVolDiscountBps: 5000,
                kBorrowVolX100: K_BORROW_VOL,
                volBorrowDeadbandBps: DEADBAND,
                maxVolBorrowMultX100: MAX_MULT,
                volRefTauSeconds: TAU
            })
        );
    }

    /// @dev Expected borrow index delta over dt at the CURRENT stored reference and the given
    ///      mark, recomputed through the public FundingLib surface (wiring mirror). FIX-2: the vol
    ///      MULTIPLIER may only span the most recent `tau` of the interval; any excess dt bills at
    ///      the plain base rate, so this mirror splits the delta exactly like the engine.
    function _expectedBorrowDelta(address token, uint256 mark, uint256 dt) internal view returns (uint256) {
        PerpTypes.VolParams memory vp = risk.volParams();
        uint256 ref = engine.volRefPrice1e18(token);
        uint256 diff = mark > ref ? mark - ref : ref - mark;
        uint256 reading = ref == 0 ? 0 : diff * BPS / ref;
        uint256 baseRate = FundingLib.borrowRatePerHour1e18(aggOf(token).totalMaxPayout, vault.totalAssets(), 1e14);
        uint256 volRate = FundingLib.volScaledBorrowRatePerHour1e18(
            baseRate, reading, vp.volBorrowDeadbandBps, vp.kBorrowVolX100, vp.maxVolBorrowMultX100
        );
        uint256 tau = vp.volRefTauSeconds;
        if (volRate == baseRate || tau == 0 || dt <= tau) {
            return FundingLib.borrowIndexDelta1e18(volRate, mark, dt);
        }
        return FundingLib.borrowIndexDelta1e18(volRate, mark, tau)
            + FundingLib.borrowIndexDelta1e18(baseRate, mark, dt - tau);
    }

    // ============================ reference EWMA ============================

    function test_volRef_seedsAtFirstLiveAccrual() public {
        _arm();
        assertEq(engine.volRefPrice1e18(MEME), 0, "unseeded before the first accrual");
        engine.pokeFunding(MEME);
        assertEq(engine.volRefPrice1e18(MEME), 1e18, "seeded to the first LIVE mark");
        assertEq(engine.realizedVolBpsOf(MEME), 0, "reading zero at the seed");
    }

    function test_volRef_ewmaAdvancesByDtOverTau() public {
        _arm();
        engine.pokeFunding(MEME); // seed at 1e18
        vm.warp(block.timestamp + 3 hours);
        oracle.setLive(MEME, 1.2e18);
        engine.pokeFunding(MEME);
        // step = 0.2e18 * 3h / 12h = 0.05e18.
        assertEq(engine.volRefPrice1e18(MEME), 1.05e18, "reference advanced by dt/tau of the gap");
    }

    function test_volRef_snapsWhenDtExceedsTau() public {
        _arm();
        engine.pokeFunding(MEME);
        vm.warp(block.timestamp + TAU + 1 hours);
        oracle.setLive(MEME, 1.5e18);
        engine.pokeFunding(MEME);
        assertEq(engine.volRefPrice1e18(MEME), 1.5e18, "dt >= tau snaps the reference to the mark");
        assertEq(engine.realizedVolBpsOf(MEME), 0, "reading resolves after the snap");
    }

    function test_volRef_disarmedTauSnapsEveryAccrual() public {
        // Mock defaults: every knob zero (tau zero), so the reference tracks the mark and can
        // never later bill a stale gap as phantom vol on a re-arm.
        engine.pokeFunding(MEME);
        vm.warp(block.timestamp + 2 hours);
        oracle.setLive(MEME, 1.4e18);
        engine.pokeFunding(MEME);
        assertEq(engine.volRefPrice1e18(MEME), 1.4e18, "tau 0 snaps to every LIVE mark");
    }

    // ============================ borrow scaling ============================

    function test_disarmed_borrowMatchesBaseExactly() public {
        open(alice, MEME, true, 1_000e6, 600);
        uint256 borrowBefore = aggOf(MEME).borrowX1e18;
        vm.warp(block.timestamp + 10 hours);
        oracle.setLive(MEME, 1.2e18); // a 20% move, but the layer is disarmed (mock defaults)
        uint256 expected = FundingLib.borrowIndexDelta1e18(
            FundingLib.borrowRatePerHour1e18(aggOf(MEME).totalMaxPayout, vault.totalAssets(), 1e14),
            1.2e18,
            10 hours
        );
        engine.pokeFunding(MEME);
        assertEq(aggOf(MEME).borrowX1e18 - borrowBefore, expected, "disarmed: plain utilization borrow");
    }

    function test_armed_borrowScalesWithRealizedVol() public {
        _arm();
        open(alice, MEME, true, 1_000e6, 600); // accrual seeds the reference at 1e18
        assertEq(engine.volRefPrice1e18(MEME), 1e18, "seeded at open");
        uint256 borrowBefore = aggOf(MEME).borrowX1e18;
        vm.warp(block.timestamp + 10 hours);
        oracle.setLive(MEME, 1.2e18); // reading 2000 bps, excess 1700, multiplier 6800x
        uint256 expected = _expectedBorrowDelta(MEME, 1.2e18, 10 hours);
        uint256 baseOnly = FundingLib.borrowIndexDelta1e18(
            FundingLib.borrowRatePerHour1e18(aggOf(MEME).totalMaxPayout, vault.totalAssets(), 1e14),
            1.2e18,
            10 hours
        );
        engine.pokeFunding(MEME);
        assertEq(aggOf(MEME).borrowX1e18 - borrowBefore, expected, "vol-scaled borrow booked exactly");
        assertGt(expected, baseOnly * 6_000, "multiplier landed (6800x at a 2000 bps reading)");
    }

    function test_armed_deadbandKeepsCalmMarketsAtBase() public {
        _arm();
        open(alice, MEME, true, 1_000e6, 600);
        uint256 borrowBefore = aggOf(MEME).borrowX1e18;
        vm.warp(block.timestamp + 10 hours);
        oracle.setLive(MEME, 1.02e18); // 200 bps reading: inside the 300 bps deadband
        uint256 baseOnly = FundingLib.borrowIndexDelta1e18(
            FundingLib.borrowRatePerHour1e18(aggOf(MEME).totalMaxPayout, vault.totalAssets(), 1e14),
            1.02e18,
            10 hours
        );
        engine.pokeFunding(MEME);
        assertEq(aggOf(MEME).borrowX1e18 - borrowBefore, baseOnly, "inside the deadband: base rate exactly");
    }

    function test_armed_ceilingBindsAtTwoPercentPerHour() public {
        _arm();
        open(alice, MEME, true, 1_000e6, 600);
        // Full utilization (tvl == reserved) so the base rate is the whole kB, then a 10x move:
        // the multiplier would push far past 2%/h and the FundingLib ceiling must bind.
        vault.setTotalAssetsOverride(aggOf(MEME).totalMaxPayout);
        uint256 borrowBefore = aggOf(MEME).borrowX1e18;
        vm.warp(block.timestamp + 5 hours);
        oracle.setLive(MEME, 10e18);
        uint256 ceiling = FundingLib.borrowIndexDelta1e18(0.02e18, 10e18, 5 hours);
        engine.pokeFunding(MEME);
        assertEq(aggOf(MEME).borrowX1e18 - borrowBefore, ceiling, "effective rate pinned at 2%/h");
    }

    // ============================ retro billing + preview parity ============================

    /// @notice Accrue-then-freeze parity (B4) with the FIX-2 tau cap: an interval nobody poked
    ///         bills the MOST RECENT tau at the reading of the settling accrual (so a patient hold
    ///         that ends inside a vol event still pays event rates over the tau window where the
    ///         convexity lives), while any excess dt beyond tau bills at the plain base rate. The
    ///         view previews the exact amount the settlement then books.
    function test_retroBilling_tauSliceAtEventRateExcessAtBase() public {
        _arm();
        open(alice, MEME, true, 1_000e6, 600);
        vm.warp(block.timestamp + 24 hours); // patient, unpoked hold (dt = 24h > tau = 12h)
        oracle.setLive(MEME, 1.3e18); // the event: reading 3000 bps against the 1e18 reference
        uint256 expectedDelta = _expectedBorrowDelta(MEME, 1.3e18, 24 hours);
        uint256 expectedOwed = FundingLib.borrowOwedUsdg(posOf(MEME, alice, true).size1e18, expectedDelta, SCALE);
        (, uint256 previewOwed) = engine.pendingOwedOf(MEME, alice, true);
        assertEq(previewOwed, expectedOwed, "preview equals the retro tau-capped bill");

        // The uncapped (old) charge billed the WHOLE 24h at the event rate; capture it BEFORE the
        // poke, while the reference is still at 1e18 and the reading is the full 3000 bps.
        PerpTypes.VolParams memory vp = risk.volParams();
        uint256 volRate = FundingLib.volScaledBorrowRatePerHour1e18(
            FundingLib.borrowRatePerHour1e18(aggOf(MEME).totalMaxPayout, vault.totalAssets(), 1e14),
            engine.realizedVolBpsOf(MEME),
            vp.volBorrowDeadbandBps,
            vp.kBorrowVolX100,
            vp.maxVolBorrowMultX100
        );
        uint256 uncapped = FundingLib.borrowIndexDelta1e18(volRate, 1.3e18, 24 hours);

        uint256 borrowBefore = aggOf(MEME).borrowX1e18;
        engine.pokeFunding(MEME);
        assertEq(aggOf(MEME).borrowX1e18 - borrowBefore, expectedDelta, "tau at event rate + excess at base");
        assertGt(expectedOwed, 100e6, "the charge is material (not dust) on a 5,964 USDG notional");
        assertLt(expectedDelta, uncapped, "tau cap reduces the bill vs the old whole-interval charge");
    }

    /// @notice FIX-2 core: a LONG DORMANT slice on a thin market must NOT bill the whole unbilled
    ///         interval at the (2%/h-ceiling) vol rate. A 48h unpoked hold that ends on a drift is
    ///         capped: only the most recent tau (12h) carries the multiplier; the other 36h bill at
    ///         plain base borrow, so the total lands far below the old whole-interval vol charge and
    ///         nowhere near the 2%/h peak that could liquidate an honest holder by borrow alone.
    function test_volBorrow_dormantSliceCapsMultiplierAtTau() public {
        _arm();
        open(alice, MEME, true, 1_000e6, 600); // seeds the reference at 1e18
        uint256 borrowBefore = aggOf(MEME).borrowX1e18;
        vm.warp(block.timestamp + 48 hours); // long dormant hold, dt = 48h = 4 * tau
        oracle.setLive(MEME, 1.2e18); // a slow drift: reading 2000 bps against the 1e18 reference

        uint256 expectedDelta = _expectedBorrowDelta(MEME, 1.2e18, 48 hours);
        engine.pokeFunding(MEME);
        uint256 billed = aggOf(MEME).borrowX1e18 - borrowBefore;
        assertEq(billed, expectedDelta, "dormant slice billed as tau-at-vol + excess-at-base");

        // The billed amount equals exactly volRate*tau + baseRate*(48h - tau), NOT volRate*48h.
        PerpTypes.VolParams memory vp = risk.volParams();
        uint256 baseRate = FundingLib.borrowRatePerHour1e18(aggOf(MEME).totalMaxPayout, vault.totalAssets(), 1e14);
        uint256 volRate = FundingLib.volScaledBorrowRatePerHour1e18(
            baseRate, 2_000, vp.volBorrowDeadbandBps, vp.kBorrowVolX100, vp.maxVolBorrowMultX100
        );
        uint256 tauSlice = FundingLib.borrowIndexDelta1e18(volRate, 1.2e18, TAU);
        uint256 baseSlice = FundingLib.borrowIndexDelta1e18(baseRate, 1.2e18, 48 hours - TAU);
        assertEq(billed, tauSlice + baseSlice, "exact split: vol over tau, base over the excess");

        // And it is a small fraction of the uncapped whole-interval-at-vol-rate charge (the hazard).
        uint256 uncapped = FundingLib.borrowIndexDelta1e18(volRate, 1.2e18, 48 hours);
        assertLt(billed * 2, uncapped, "capped bill is well under half the uncapped 48h vol charge");
        assertGt(uncapped, billed, "uncapped charge is strictly larger");
    }

    // ============================ one-block non-suppressibility ============================

    /// @notice THE property the instantaneous deviation lacked (RE-ECON-1): a one-block action
    ///         zeroes the spot-vs-TWAP deviation (killing the OPEN surcharge) but cannot move
    ///         the realized-vol reading, and any attempt to converge the reference by poking
    ///         first books the full retro bill at the elevated reading: suppression is
    ///         self-defeating.
    function test_reading_notSuppressibleInOneBlock() public {
        _arm();
        oracle.setTierConfig(MEME, 2, address(spot));
        open(alice, MEME, true, 1_000e6, 600); // seeds the reference at 1e18
        vm.warp(block.timestamp + 1 hours);
        oracle.setLive(MEME, 1.2e18); // vol event

        // One-block spot manipulation: slot0 pushed flush with the mark. The OPEN-time lever
        // reads zero deviation (bob's open pays NO vol surcharge: the old dodge)...
        spot.setSpot(MEME, 1.2e18, true);
        open(bob, MEME, true, 1_000e6, 600);
        // 10 bps base open fee on 6,000 intended notional only: no surcharge.
        assertEq(posOf(MEME, bob, true).margin, 994e6, "instantaneous deviation lever dodged in one block");

        // ...but the realized-vol reading is untouched by the same action: bob's open itself
        // accrued (a poke), which BOOKED the elevated hour and moved the reference by only
        // dt/tau; the reading remains far above the deadband.
        uint256 reading = engine.realizedVolBpsOf(MEME);
        assertGt(reading, 1_700, "reading survives the one-block spot manipulation and the poke");

        // The poke that tried to converge the reference paid for the privilege: the hour since
        // the last accrual was billed at the full 2000 bps reading (multiplier 6800x).
        vm.warp(block.timestamp + 1 hours);
        uint256 expectedDelta = _expectedBorrowDelta(MEME, 1.2e18, 1 hours);
        uint256 borrowBefore = aggOf(MEME).borrowX1e18;
        engine.pokeFunding(MEME);
        assertEq(aggOf(MEME).borrowX1e18 - borrowBefore, expectedDelta, "elevated slice still bills after the poke");
        uint256 baseOnly = FundingLib.borrowIndexDelta1e18(
            FundingLib.borrowRatePerHour1e18(aggOf(MEME).totalMaxPayout, vault.totalAssets(), 1e14), 1.2e18, 1 hours
        );
        assertGt(expectedDelta, baseOnly * 4_000, "still thousands of times the base rate");
    }

    /// @notice The reading decays over ~tau and the market returns to the plain base borrow:
    ///         the layer taxes the vol event, never the recovered market (honest-trader UX).
    function test_reading_decaysBackToBaseAfterTheEvent() public {
        _arm();
        open(alice, MEME, true, 1_000e6, 600);
        vm.warp(block.timestamp + 1 hours);
        oracle.setLive(MEME, 1.2e18);
        engine.pokeFunding(MEME);
        assertGt(engine.realizedVolBpsOf(MEME), DEADBAND, "elevated during the event");
        // The mark holds its new level; after a full tau of accruals the reference converges.
        vm.warp(block.timestamp + TAU);
        engine.pokeFunding(MEME);
        assertEq(engine.volRefPrice1e18(MEME), 1.2e18, "reference converged to the new level");
        assertEq(engine.realizedVolBpsOf(MEME), 0, "reading fully decayed");
        uint256 borrowBefore = aggOf(MEME).borrowX1e18;
        vm.warp(block.timestamp + 10 hours);
        uint256 baseOnly = FundingLib.borrowIndexDelta1e18(
            FundingLib.borrowRatePerHour1e18(aggOf(MEME).totalMaxPayout, vault.totalAssets(), 1e14), 1.2e18, 10 hours
        );
        engine.pokeFunding(MEME);
        assertEq(aggOf(MEME).borrowX1e18 - borrowBefore, baseOnly, "post-event market pays base borrow again");
    }

    // ============================ conservation ============================

    /// @notice Wei-exact closed-system conservation through a full straddle cycle WITH the
    ///         vol-scaled borrow armed: no USDG minted or destroyed, aggregates stay equal to
    ///         the position sums, and the vault reservation ledger stays in sync. The borrow
    ///         is a pure re-rating of an existing vault INFLOW channel.
    function test_conservation_closedSystemWithVolBorrowArmed() public {
        _arm();
        vault.setTotalAssetsOverride(0); // real balances so conservation is honest
        uint256 sysBefore = systemBalance();
        open(alice, MEME, true, 1_000e6, 600);
        open(bob, MEME, false, 1_000e6, 600);
        assertAggMatchesPositions(MEME);
        vm.warp(block.timestamp + 24 hours);
        oracle.setLive(MEME, 1.3e18); // vol event: short deep under water, long capped winner
        assertEq(systemBalance(), sysBefore, "conservation before settlement");
        vm.prank(keeper);
        engine.liquidate(MEME, bob, false);
        assertEq(systemBalance(), sysBefore, "conservation after the vol-billed liquidation");
        vm.prank(alice);
        engine.closePosition(MEME, true);
        assertEq(systemBalance(), sysBefore, "conservation after the vol-billed close");
        assertAggMatchesPositions(MEME);
        assertEq(vault.totalReserved(), 0, "reservations fully released");
    }
}
