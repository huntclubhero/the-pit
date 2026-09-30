// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FundingLib} from "../../src/perp/FundingLib.sol";

/// @notice Standalone unit + fuzz suite for FundingLib. USDG 6 decimals (scale 1e12).
contract FundingLibTest is Test {
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant ONE = 1e18;

    uint256 internal constant MAX_OI = 1e15; // 1B USDG
    uint256 internal constant MAX_SIZE = 1e33;
    uint256 internal constant MAX_PRICE = 1e24;
    uint64 internal constant KF_MEME = 25e14; // 0.25%/h at full skew
    uint64 internal constant KF_MAJOR = 5e14; // 0.05%/h
    uint64 internal constant KB = 1e14; // 0.01%/h at 100% utilization

    // ================================ skew ================================

    function test_skew_balancedIsZero() public pure {
        assertEq(FundingLib.skew1e18(100e6, 100e6, 10_000e6), 0);
    }

    function test_skew_allLongAboveFloorIsOne() public pure {
        assertEq(FundingLib.skew1e18(50_000e6, 0, 10_000e6), int256(ONE));
    }

    function test_skew_floorDampensEmptyMarket() public pure {
        // 100 USDG one-sided OI against a 10k floor: skew = 100/10000 = 1%.
        assertEq(FundingLib.skew1e18(100e6, 0, 10_000e6), int256(ONE) / 100);
    }

    function test_skew_emptyMarketNoFloorIsZero() public pure {
        assertEq(FundingLib.skew1e18(0, 0, 0), 0);
    }

    function testFuzz_skew_boundedAndAntiSymmetric(uint256 oiLong, uint256 oiShort, uint256 floorUsdg)
        public
        pure
    {
        oiLong = bound(oiLong, 0, MAX_OI);
        oiShort = bound(oiShort, 0, MAX_OI);
        floorUsdg = bound(floorUsdg, 0, MAX_OI);
        int256 s = FundingLib.skew1e18(oiLong, oiShort, floorUsdg);
        assertGe(s, -int256(ONE));
        assertLe(s, int256(ONE));
        assertEq(s, -FundingLib.skew1e18(oiShort, oiLong, floorUsdg));
    }

    // ================================ funding rate ================================

    function test_fundingRate_fullSkewEqualsKf() public pure {
        assertEq(FundingLib.fundingRatePerHour1e18(int256(ONE), KF_MEME), int256(uint256(KF_MEME)));
        assertEq(FundingLib.fundingRatePerHour1e18(-int256(ONE), KF_MEME), -int256(uint256(KF_MEME)));
    }

    function testFuzz_fundingRate_cappedAtKf(int256 skew, uint64 kF) public pure {
        skew = bound(skew, -int256(ONE), int256(ONE));
        kF = uint64(bound(kF, 0, 5e15));
        int256 rate = FundingLib.fundingRatePerHour1e18(skew, kF);
        assertLe(rate, int256(uint256(kF)));
        assertGe(rate, -int256(uint256(kF)));
    }

    // ================================ index deltas ================================

    function test_fundingIndexDelta_oneHourFullSkew() public pure {
        // rate 0.25%/h, mark 1.00, one hour: delta = 0.0025e18.
        assertEq(FundingLib.fundingIndexDelta1e18(int256(uint256(KF_MEME)), 1e18, 3600), int256(25e14));
    }

    function test_fundingIndexDelta_signFollowsRate() public pure {
        assertEq(FundingLib.fundingIndexDelta1e18(-int256(uint256(KF_MEME)), 1e18, 3600), -int256(25e14));
        assertEq(FundingLib.fundingIndexDelta1e18(0, 1e18, 3600), 0);
        assertEq(FundingLib.fundingIndexDelta1e18(int256(uint256(KF_MEME)), 1e18, 0), 0);
    }

    function testFuzz_fundingIndexDelta_linearInTime(int256 rate, uint256 mark, uint256 dt) public pure {
        rate = bound(rate, -5e15, 5e15);
        mark = bound(mark, 1e6, MAX_PRICE);
        dt = bound(dt, 1, 30 days);
        int256 one = FundingLib.fundingIndexDelta1e18(rate, mark, dt);
        int256 two = FundingLib.fundingIndexDelta1e18(rate, mark, 2 * dt);
        // Doubling time doubles the accrual within rounding dust.
        assertApproxEqAbs(two, 2 * one, 2);
    }

    // ================================ borrow ================================

    function test_borrowRate_fullUtilizationEqualsKb() public pure {
        assertEq(FundingLib.borrowRatePerHour1e18(1000e6, 1000e6, KB), uint256(KB));
    }

    function test_borrowRate_halfUtilization() public pure {
        assertEq(FundingLib.borrowRatePerHour1e18(500e6, 1000e6, KB), uint256(KB) / 2);
    }

    function test_borrowRate_zeroTvlIsZero() public pure {
        assertEq(FundingLib.borrowRatePerHour1e18(500e6, 0, KB), 0);
    }

    function test_borrowRate_overUtilizationCapped() public pure {
        assertEq(FundingLib.borrowRatePerHour1e18(2000e6, 1000e6, KB), uint256(KB));
    }

    function testFuzz_borrowRate_monotoneInReserved(uint256 r1, uint256 r2, uint256 tvl) public pure {
        tvl = bound(tvl, 1e6, MAX_OI);
        r1 = bound(r1, 0, tvl);
        r2 = bound(r2, r1, tvl);
        assertLe(FundingLib.borrowRatePerHour1e18(r1, tvl, KB), FundingLib.borrowRatePerHour1e18(r2, tvl, KB));
    }

    // ================================ vol-scaled borrow (RE-ECON-1) ================================

    uint16 internal constant K_BORROW_VOL = 400; // 4.00x per bps past the deadband (launch)
    uint16 internal constant DEADBAND = 300; // launch deadband
    uint32 internal constant MAX_MULT = 2_000_000; // 20,000x clamp (launch)

    function test_volBorrow_zeroBaseStaysZero() public pure {
        assertEq(FundingLib.volScaledBorrowRatePerHour1e18(0, 10_000, DEADBAND, K_BORROW_VOL, MAX_MULT), 0);
    }

    function test_volBorrow_insideDeadbandIsBaseExactly() public pure {
        uint256 base = 1e12;
        assertEq(FundingLib.volScaledBorrowRatePerHour1e18(base, 0, DEADBAND, K_BORROW_VOL, MAX_MULT), base);
        assertEq(FundingLib.volScaledBorrowRatePerHour1e18(base, DEADBAND, DEADBAND, K_BORROW_VOL, MAX_MULT), base);
    }

    function test_volBorrow_disarmedSlopeIsBaseExactly() public pure {
        uint256 base = 1e12;
        assertEq(FundingLib.volScaledBorrowRatePerHour1e18(base, 50_000, DEADBAND, 0, MAX_MULT), base);
    }

    function test_volBorrow_linearPastDeadband() public pure {
        // Reading 1300 bps, deadband 300: excess 1000, mult = 400 * 1000 / 100 = 4000x.
        uint256 base = 1e9;
        uint256 expected = base + base * (uint256(K_BORROW_VOL) * 1000) / 100;
        assertEq(FundingLib.volScaledBorrowRatePerHour1e18(base, 1300, DEADBAND, K_BORROW_VOL, MAX_MULT), expected);
    }

    function test_volBorrow_multiplierClamps() public pure {
        // Excess 100,000 bps -> raw multX100 40,000,000 clamps at MAX_MULT (2,000,000 = 20,000x).
        uint256 base = 1e8;
        uint256 expected = base + base * uint256(MAX_MULT) / 100;
        assertEq(
            FundingLib.volScaledBorrowRatePerHour1e18(base, 100_000 + DEADBAND, DEADBAND, K_BORROW_VOL, MAX_MULT),
            expected
        );
    }

    function test_volBorrow_absoluteCeilingTwoPercentPerHour() public pure {
        // A large base with a huge reading pins at the 2%/h ceiling regardless of knobs.
        assertEq(
            FundingLib.volScaledBorrowRatePerHour1e18(1e14, 1_000_000, DEADBAND, 2_000, 5_000_000), 0.02e18
        );
        // The ceiling also clamps a pathological standalone base above 2%/h.
        assertEq(FundingLib.volScaledBorrowRatePerHour1e18(0.05e18, 0, DEADBAND, K_BORROW_VOL, MAX_MULT), 0.02e18);
    }

    function testFuzz_volBorrow_neverBelowBaseNeverAboveCeiling(
        uint256 base,
        uint256 volBps,
        uint16 deadband,
        uint16 k,
        uint32 maxMult
    ) public pure {
        base = bound(base, 0, 0.02e18); // config bounds base at 2%/h (kB cap * util <= 1)
        volBps = bound(volBps, 0, 1e14); // far past any sane reading (price ratio 1e10)
        uint256 rate = FundingLib.volScaledBorrowRatePerHour1e18(base, volBps, deadband, k, maxMult);
        assertGe(rate, base == 0 ? 0 : base, "never below base");
        assertLe(rate, 0.02e18, "never above the 2%/h ceiling");
    }

    function testFuzz_volBorrow_monotoneInReading(uint256 base, uint256 v1, uint256 v2) public pure {
        base = bound(base, 1, 0.02e18);
        v1 = bound(v1, 0, 1e9);
        v2 = bound(v2, v1, 1e9);
        assertLe(
            FundingLib.volScaledBorrowRatePerHour1e18(base, v1, DEADBAND, K_BORROW_VOL, MAX_MULT),
            FundingLib.volScaledBorrowRatePerHour1e18(base, v2, DEADBAND, K_BORROW_VOL, MAX_MULT),
            "rate is monotone in the realized-vol reading"
        );
    }

    // ================================ owed amounts ================================

    function test_fundingOwed_signConvention() public pure {
        // Positive index delta: longs pay, shorts receive, symmetric magnitudes.
        int256 delta = int256(25e14); // 0.25% of a 1.00 mark over an hour
        uint256 size = 1000e18; // 1000 tokens
        int256 longOwed = FundingLib.fundingOwedUsdg(size, delta, true, SCALE);
        int256 shortOwed = FundingLib.fundingOwedUsdg(size, delta, false, SCALE);
        assertEq(longOwed, int256(25e5)); // 2.5 USDG owed
        assertEq(shortOwed, -int256(25e5)); // 2.5 USDG received
    }

    function test_fundingOwed_negativeDeltaFlips() public pure {
        int256 delta = -int256(25e14);
        uint256 size = 1000e18;
        assertEq(FundingLib.fundingOwedUsdg(size, delta, true, SCALE), -int256(25e5));
        assertEq(FundingLib.fundingOwedUsdg(size, delta, false, SCALE), int256(25e5));
    }

    function test_borrowOwed_bothSidesPay() public pure {
        uint256 delta = 1e14; // 0.01% of a 1.00 mark over an hour
        assertEq(FundingLib.borrowOwedUsdg(1000e18, delta, SCALE), 1e5); // 0.10 USDG
    }

    /// @notice THE zero-sum property (spec 5.1): total funding paid by the majority equals
    ///         total received by the minority plus the residual on the NET OI, and the
    ///         residual always has the sign that pays the VAULT.
    function testFuzz_funding_zeroSumWithVaultResidual(
        uint256 longSize,
        uint256 shortSize,
        uint256 mark,
        uint256 dt
    ) public pure {
        longSize = bound(longSize, 0, MAX_SIZE);
        shortSize = bound(shortSize, 0, MAX_SIZE);
        mark = bound(mark, 1e12, MAX_PRICE);
        dt = bound(dt, 1, 7 days);

        uint256 oiLong = longSize * mark / (ONE * SCALE);
        uint256 oiShort = shortSize * mark / (ONE * SCALE);
        int256 skew = FundingLib.skew1e18(oiLong, oiShort, 10_000e6);
        int256 rate = FundingLib.fundingRatePerHour1e18(skew, KF_MEME);
        int256 delta = FundingLib.fundingIndexDelta1e18(rate, mark, dt);

        int256 longOwed = FundingLib.fundingOwedUsdg(longSize, delta, true, SCALE);
        int256 shortOwed = FundingLib.fundingOwedUsdg(shortSize, delta, false, SCALE);
        int256 residualToVault = longOwed + shortOwed;

        // Residual is never negative: the vault never pays the imbalance, it collects it.
        assertGe(residualToVault, 0);

        // Exact reference: residual = |netSize * delta| within 2 units of rounding dust.
        uint256 netSize = longSize > shortSize ? longSize - shortSize : shortSize - longSize;
        uint256 deltaMag = delta >= 0 ? uint256(delta) : uint256(-delta);
        uint256 expected = netSize * deltaMag / (ONE * SCALE);
        assertApproxEqAbs(residualToVault, int256(expected), 2);
    }

    /// @notice Accrual composability: two consecutive intervals accrue the same owed amount
    ///         as one combined interval when rate and mark are unchanged (index linearity).
    function testFuzz_indexAccrual_composes(uint256 size, uint256 mark, uint256 dt1, uint256 dt2) public pure {
        size = bound(size, 1e18, MAX_SIZE);
        mark = bound(mark, 1e12, MAX_PRICE);
        dt1 = bound(dt1, 1, 3 days);
        dt2 = bound(dt2, 1, 3 days);
        int256 rate = int256(uint256(KF_MAJOR));
        int256 dA = FundingLib.fundingIndexDelta1e18(rate, mark, dt1);
        int256 dB = FundingLib.fundingIndexDelta1e18(rate, mark, dt2);
        int256 dAB = FundingLib.fundingIndexDelta1e18(rate, mark, dt1 + dt2);
        assertApproxEqAbs(dA + dB, dAB, 2);
        int256 owedSplit = FundingLib.fundingOwedUsdg(size, dA + dB, true, SCALE);
        int256 owedWhole = FundingLib.fundingOwedUsdg(size, dAB, true, SCALE);
        // A 1-unit index dust scales by size / (1e18 * usdgScale) in owed units, plus 2 floors.
        uint256 owedTolerance = size / (ONE * SCALE) + 2;
        assertApproxEqAbs(owedSplit, owedWhole, owedTolerance);
    }
}
