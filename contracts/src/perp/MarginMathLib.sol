// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MarginMathLib: pure position math for THE PIT v2 perps engine
/// @notice Exact closed forms for notional, unrealized PnL, the payout clamp, equity,
///         maintenance and initial margin, and the liquidation price (spec 1.4, 1.7).
///         All USDG amounts are native 6-decimal units unless a name says otherwise;
///         prices and sizes are 1e18 scale, identical to IOracleRouter.checkPrice.
/// @dev Every function is pure and fuzz-tested standalone against a reference model.
///      Domain assumptions (enforced by the engine, asserted in fuzz bounds):
///      size1e18 and prices fit uint128-ish magnitudes so size * price fits uint256.
library MarginMathLib {
    /// @notice Price and size scale (1e18), the router's price scale.
    uint256 internal constant PRICE_SCALE = 1e18;
    /// @notice Basis point denominator.
    uint256 internal constant BPS_DENOM = 10_000;
    /// @notice Leverage fixed-point denominator: leverageX100 of 450 means 4.5x.
    uint256 internal constant LEVERAGE_DENOM = 100;

    /// @notice A price of zero was supplied where a positive price is required.
    error ZeroPrice();
    /// @notice The maintenance margin ratio must be strictly below 100%.
    error MmrTooHigh();
    /// @notice Leverage denominator of zero.
    error ZeroLeverage();

    /// @notice Notional value of `size1e18` base units at `price1e18`, in USDG units.
    /// @param size1e18 Position size, base units at 1e18 scale.
    /// @param price1e18 Mark price, USDG per token at 1e18 scale.
    /// @param usdgScale 10 ** (18 minus USDG decimals), the router's usdgScale.
    function notionalUsdg(uint256 size1e18, uint256 price1e18, uint256 usdgScale) internal pure returns (uint256) {
        return Math.mulDiv(size1e18, price1e18, PRICE_SCALE * usdgScale);
    }

    /// @notice Size in 1e18 base units whose notional at `price1e18` equals `notional` USDG.
    /// @dev Floor division: the opened size is never larger than the paid-for notional.
    function sizeForNotional(uint256 notional, uint256 price1e18, uint256 usdgScale) internal pure returns (uint256) {
        if (price1e18 == 0) revert ZeroPrice();
        return Math.mulDiv(notional * usdgScale, PRICE_SCALE, price1e18);
    }

    /// @notice Unrealized PnL in USDG units, signed. Long profits when mark > entry.
    function uPnlUsdg(uint256 size1e18, uint256 entry1e18, uint256 mark1e18, bool isLong, uint256 usdgScale)
        internal
        pure
        returns (int256)
    {
        uint256 diff = mark1e18 >= entry1e18 ? mark1e18 - entry1e18 : entry1e18 - mark1e18;
        uint256 magnitude = Math.mulDiv(size1e18, diff, PRICE_SCALE * usdgScale);
        if (magnitude == 0) return 0;
        bool markAbove = mark1e18 > entry1e18;
        // Long profits above entry, short profits below entry.
        return (isLong == markAbove) ? int256(magnitude) : -int256(magnitude);
    }

    /// @notice The payout clamp (spec 1.4): profit capped at maxPayout, loss capped at margin.
    function clampPnl(int256 pnl, uint256 margin, uint256 maxPayout) internal pure returns (int256) {
        if (pnl > 0 && uint256(pnl) > maxPayout) return int256(maxPayout);
        if (pnl < 0 && uint256(-pnl) > margin) return -int256(margin);
        return pnl;
    }

    /// @notice Equity (spec 1.4): margin + clamped uPnL minus pending funding minus pending borrow.
    /// @param fundingOwed Signed pending funding in USDG units; positive means the trader owes.
    /// @param borrowOwed Pending borrow fee in USDG units, always owed by the trader.
    function equityUsdg(uint256 margin, int256 clampedPnl, int256 fundingOwed, uint256 borrowOwed)
        internal
        pure
        returns (int256)
    {
        return int256(margin) + clampedPnl - fundingOwed - int256(borrowOwed);
    }

    /// @notice Maintenance margin requirement in USDG units: mmrBps of current notional.
    function maintenanceMarginUsdg(uint256 size1e18, uint256 mark1e18, uint16 mmrBps, uint256 usdgScale)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(notionalUsdg(size1e18, mark1e18, usdgScale), mmrBps, BPS_DENOM);
    }

    /// @notice Initial margin requirement in USDG units: notional / maxLeverage, rounded up
    ///         (the conservative direction for the anti-JELLY removeMargin floor, spec 1.5).
    function initialMarginUsdg(uint256 size1e18, uint256 mark1e18, uint32 maxLeverageX100, uint256 usdgScale)
        internal
        pure
        returns (uint256)
    {
        if (maxLeverageX100 == 0) revert ZeroLeverage();
        return
            Math.mulDiv(
                notionalUsdg(size1e18, mark1e18, usdgScale), LEVERAGE_DENOM, maxLeverageX100, Math.Rounding.Ceil
            );
    }

    /// @notice Exact liquidation price (spec 1.7).
    /// @dev LONG:  P_liq = (S*P0 + (F minus m) * 1e18) / (S * (1e18 minus r) / 1e18)
    ///      SHORT: P_liq = (S*P0 + (m minus F) * 1e18) / (S * (1e18 + r) / 1e18)
    ///      where m and F are converted to 1e18-scaled USD via usdgScale and r = mmrBps as a
    ///      1e18 fraction. Returns 0 when the position cannot be liquidated by a price move in
    ///      its adverse direction (numerator non-positive). Floor division: the returned price
    ///      is never past the true boundary in the trader-adverse direction.
    /// @param netOwedUsdg Signed pending funding plus borrow in USDG units (positive = owed).
    function liquidationPrice1e18(
        uint256 size1e18,
        uint256 entry1e18,
        uint256 margin,
        int256 netOwedUsdg,
        uint16 mmrBps,
        bool isLong,
        uint256 usdgScale
    ) internal pure returns (uint256) {
        if (size1e18 == 0) return 0;
        if (mmrBps >= BPS_DENOM) revert MmrTooHigh();
        uint256 r1e18 = uint256(mmrBps) * (PRICE_SCALE / BPS_DENOM);
        int256 sizeEntry = int256(size1e18 * entry1e18); // 1e36 scale
        int256 owed1e18 = netOwedUsdg * int256(usdgScale);
        int256 margin1e18 = int256(margin * usdgScale);
        if (isLong) {
            int256 numerator = sizeEntry + (owed1e18 - margin1e18) * int256(PRICE_SCALE);
            if (numerator <= 0) return 0;
            uint256 denominator = Math.mulDiv(size1e18, PRICE_SCALE - r1e18, PRICE_SCALE);
            return uint256(numerator) / denominator;
        } else {
            int256 numerator = sizeEntry + (margin1e18 - owed1e18) * int256(PRICE_SCALE);
            if (numerator <= 0) return 0;
            uint256 denominator = Math.mulDiv(size1e18, PRICE_SCALE + r1e18, PRICE_SCALE);
            return uint256(numerator) / denominator;
        }
    }

    /// @notice Volume-weighted entry price after adding `addSize` at `addPrice` to an existing
    ///         position of `size` at `entry` (spec 1.2: size-weighted entry on increases).
    function weightedEntry1e18(uint256 size1e18, uint256 entry1e18, uint256 addSize1e18, uint256 addPrice1e18)
        internal
        pure
        returns (uint256)
    {
        uint256 total = size1e18 + addSize1e18;
        if (total == 0) return 0;
        // (S1*P1 + S2*P2) / (S1+S2), each product 1e36 scale, computed in uint256.
        return (size1e18 * entry1e18 + addSize1e18 * addPrice1e18) / total;
    }
}
