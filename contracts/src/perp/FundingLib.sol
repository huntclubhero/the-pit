// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FundingLib: skew funding and borrow index math for THE PIT v2 perps engine
/// @notice Implements the GMX-v2-family skew funding rate (spec 5.1) and the utilization
///         borrow rate (spec 5.3), both accrued through per-market cumulative indices.
/// @dev Index semantics: an index accumulates ratePerHour * mark * dt / (1 hour), so it is a
///      1e18 price-scaled accumulator. A position's owed amount over an interval is
///      size1e18 * indexDelta / (1e18 * usdgScale), which equals notional-at-accrual times the
///      rate over each accrual slice (spec 1.4 "notionalAtAccrual"). Funding sign convention:
///      a POSITIVE funding index delta means LONGS PAY (skew was long-heavy). The borrow index
///      is unsigned: both sides always pay. Every function is pure and fuzz-tested standalone.
library FundingLib {
    /// @notice 1e18, the fixed-point one used for skew, rates, prices and indices.
    uint256 internal constant ONE = 1e18;
    /// @notice Seconds per rate interval (rates are per hour).
    uint256 internal constant RATE_INTERVAL = 1 hours;

    /// @notice OI skew in [-1e18, +1e18]: (OI_long minus OI_short) / max(OI_long + OI_short, floor).
    /// @param oiLongUsdg Long open interest notional at the current mark, USDG units.
    /// @param oiShortUsdg Short open interest notional at the current mark, USDG units.
    /// @param skewFloorUsdg Denominator floor killing rate noise on empty markets (spec 5.2).
    function skew1e18(uint256 oiLongUsdg, uint256 oiShortUsdg, uint256 skewFloorUsdg) internal pure returns (int256) {
        uint256 total = oiLongUsdg + oiShortUsdg;
        uint256 denominator = total > skewFloorUsdg ? total : skewFloorUsdg;
        if (denominator == 0) return 0;
        int256 net = int256(oiLongUsdg) - int256(oiShortUsdg);
        return net * int256(ONE) / int256(denominator);
    }

    /// @notice Signed funding rate per hour, 1e18 scale: clamp(kF * skew, minus kF, plus kF).
    /// @dev The clamp is implicit: |skew| <= 1e18 by construction, so |rate| <= kF (spec 5.2,
    ///      capF equals kF at launch, linear to the cap).
    function fundingRatePerHour1e18(int256 skew, uint64 kFPerHour1e18) internal pure returns (int256) {
        return skew * int256(uint256(kFPerHour1e18)) / int256(ONE);
    }

    /// @notice Funding index increment for an interval: rate * mark * dt / 1 hour, 1e18 scale.
    function fundingIndexDelta1e18(int256 ratePerHour1e18, uint256 mark1e18, uint256 dtSeconds)
        internal
        pure
        returns (int256)
    {
        if (ratePerHour1e18 == 0 || mark1e18 == 0 || dtSeconds == 0) return 0;
        bool negative = ratePerHour1e18 < 0;
        uint256 magnitude = negative ? uint256(-ratePerHour1e18) : uint256(ratePerHour1e18);
        uint256 delta = Math.mulDiv(magnitude * dtSeconds, mark1e18, ONE * RATE_INTERVAL);
        return negative ? -int256(delta) : int256(delta);
    }

    /// @notice Borrow rate per hour, 1e18 scale: kB * reservedInMarket / vaultTotalAssets,
    ///         utilization capped at 100% defensively (spec 5.3).
    function borrowRatePerHour1e18(uint256 reservedUsdg, uint256 vaultAssetsUsdg, uint64 kBPerHour1e18)
        internal
        pure
        returns (uint256)
    {
        if (reservedUsdg == 0 || vaultAssetsUsdg == 0 || kBPerHour1e18 == 0) return 0;
        uint256 utilization1e18 = Math.mulDiv(reservedUsdg, ONE, vaultAssetsUsdg);
        if (utilization1e18 > ONE) utilization1e18 = ONE;
        return Math.mulDiv(uint256(kBPerHour1e18), utilization1e18, ONE);
    }

    /// @notice Absolute ceiling on the vol-scaled borrow rate: 2% per hour, the same hard cap
    ///         PerpRiskConfig enforces on the base funding/borrow coefficients. No governance
    ///         knob combination can push the effective borrow rate past it: the multiplier is
    ///         LP-revenue armor against the patient convexity harvest (RE-ECON-1), never a rug.
    uint256 internal constant MAX_VOL_BORROW_RATE_PER_HOUR_1E18 = 0.02e18;

    /// @notice Vol-scaled borrow rate (RE-ECON-1): base * (1 + volMultiplier), where
    ///         volMultiplier (x100 fixed point) = min(maxVolBorrowMultX100,
    ///         kBorrowVolX100 * excessBps) and excessBps = max(0, realizedVolBps - deadbandBps).
    ///         Borrow is unsigned (both sides always pay), so this holding cost is
    ///         delta-agnostic: BOTH legs of a delta-neutral straddle pay it while realized
    ///         volatility is elevated, pricing the gamma a position carries over its hold
    ///         rather than only at its open. The result is clamped to
    ///         MAX_VOL_BORROW_RATE_PER_HOUR_1E18 and is never below the base rate (the base
    ///         itself is bounded by the config's 2%/h coefficient cap, so the ceiling clamp
    ///         only ever trims the multiplier, never the base).
    /// @param baseRatePerHour1e18 The utilization borrow rate from borrowRatePerHour1e18.
    /// @param realizedVolBps The time-integrated realized-vol reading in bps (the settlement
    ///        mark's displacement from the engine's slow EWMA reference).
    /// @param deadbandBps Readings at or below this accrue no multiplier (ordinary noise).
    /// @param kBorrowVolX100 Multiplier slope per bps of excess reading, x100 (400 = 4.00x/bps).
    /// @param maxVolBorrowMultX100 Clamp on the multiplier, x100.
    function volScaledBorrowRatePerHour1e18(
        uint256 baseRatePerHour1e18,
        uint256 realizedVolBps,
        uint16 deadbandBps,
        uint16 kBorrowVolX100,
        uint32 maxVolBorrowMultX100
    ) internal pure returns (uint256) {
        if (baseRatePerHour1e18 == 0) return 0;
        uint256 rate = baseRatePerHour1e18;
        if (kBorrowVolX100 != 0 && realizedVolBps > deadbandBps) {
            uint256 multX100 = uint256(kBorrowVolX100) * (realizedVolBps - deadbandBps);
            if (multX100 > maxVolBorrowMultX100) multX100 = maxVolBorrowMultX100;
            rate += Math.mulDiv(baseRatePerHour1e18, multX100, 100);
        }
        return rate > MAX_VOL_BORROW_RATE_PER_HOUR_1E18 ? MAX_VOL_BORROW_RATE_PER_HOUR_1E18 : rate;
    }

    /// @notice Borrow index increment for an interval: rate * mark * dt / 1 hour, 1e18 scale.
    function borrowIndexDelta1e18(uint256 ratePerHour1e18, uint256 mark1e18, uint256 dtSeconds)
        internal
        pure
        returns (uint256)
    {
        if (ratePerHour1e18 == 0 || mark1e18 == 0 || dtSeconds == 0) return 0;
        return Math.mulDiv(ratePerHour1e18 * dtSeconds, mark1e18, ONE * RATE_INTERVAL);
    }

    /// @notice Pending funding owed by a position over an index delta, USDG units, signed:
    ///         POSITIVE means the trader owes (pays the pool), NEGATIVE means it receives.
    /// @dev Longs owe when the index rose (long-heavy skew paid); shorts owe when it fell.
    function fundingOwedUsdg(uint256 size1e18, int256 indexDelta1e18, bool isLong, uint256 usdgScale)
        internal
        pure
        returns (int256)
    {
        if (indexDelta1e18 == 0 || size1e18 == 0) return 0;
        bool deltaNegative = indexDelta1e18 < 0;
        uint256 magnitude = deltaNegative ? uint256(-indexDelta1e18) : uint256(indexDelta1e18);
        uint256 owed = Math.mulDiv(size1e18, magnitude, ONE * usdgScale);
        if (owed == 0) return 0;
        bool traderOwes = isLong ? !deltaNegative : deltaNegative;
        return traderOwes ? int256(owed) : -int256(owed);
    }

    /// @notice Pending borrow owed by a position over an index delta, USDG units, always owed.
    function borrowOwedUsdg(uint256 size1e18, uint256 indexDelta1e18, uint256 usdgScale)
        internal
        pure
        returns (uint256)
    {
        if (indexDelta1e18 == 0 || size1e18 == 0) return 0;
        return Math.mulDiv(size1e18, indexDelta1e18, ONE * usdgScale);
    }
}
