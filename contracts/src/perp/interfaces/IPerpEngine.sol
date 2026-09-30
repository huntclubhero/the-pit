// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpTypes} from "./PerpTypes.sol";

/// @title IPerpEngine: the singleton leveraged perps clearinghouse for THE PIT v2
/// @notice FROZEN: perp module teams must not modify signatures. Trades execute against the
///         PitVault at the OracleRouter mark (GMX-v2 style, no orderbook, no spread). Isolated
///         margin, mcap-tiered leverage, per-position payout cap, per-market reserve cap bounded
///         by the oracle cost-to-move estimate (the reincarnated v1 capped-payout invariant).
///         See spec sections 1, 2, 3, 8.
interface IPerpEngine {
    // -------------------------------- trading --------------------------------
    /// @notice Open a new isolated position. leverageX100 e.g. 450 = 4.5x, bounded by the tier.
    function openPosition(address token, bool isLong, uint128 margin, uint32 leverageX100)
        external
        returns (bytes32 key);
    /// @notice Increase an existing same-side position (size-weighted entry).
    function increasePosition(address token, bool isLong, uint128 addedMargin, uint32 leverageX100) external;
    /// @notice Fully close a position at mark (LIVE or FALLBACK print acceptable for exit).
    function closePosition(address token, bool isLong) external;
    /// @notice Reduce a position by fractionBps of size, realizing that fraction of PnL.
    function reducePosition(address token, bool isLong, uint32 fractionBps) external;
    /// @notice Add isolated margin (allowed even while opens are paused: strictly de-risking).
    function addMargin(address token, bool isLong, uint128 amount) external;
    /// @notice Remove isolated margin, enforcing the initial-margin floor (anti-JELLY: a position
    ///         can never be walked into liquidation by its owner via withdrawal).
    function removeMargin(address token, bool isLong, uint128 amount) external;

    // -------------------------- keepers (permissionless) --------------------------
    /// @notice Liquidate an underwater position at the fresh mark. Gated on a LIVE print +
    ///         openingAllowed (a manipulated print pauses liquidation). Full close at launch.
    function liquidate(address token, address trader, bool isLong) external;
    /// @notice Accrue the market's funding + borrow indices (any interaction also accrues).
    function pokeFunding(address token) external;

    // -------------------------------- views --------------------------------
    function getPosition(address token, address trader, bool isLong)
        external
        view
        returns (PerpTypes.Position memory);
    function equityOf(address token, address trader, bool isLong) external view returns (int256);
    function liquidationPrice(address token, address trader, bool isLong) external view returns (uint256);
    function marketState(address token) external view returns (PerpTypes.MarketAggregates memory);
    function liquidatable(address token, address trader, bool isLong) external view returns (bool);

    // ------------------------- governance (timelocked) -------------------------
    /// @notice List a market (requires router.isListable + a tier assigned in PerpRiskConfig).
    function listMarket(address token) external;
    /// @notice Set close-only (orderly delisting): no opens, closes + liquidations + funding continue.
    function setCloseOnly(address token, bool on) external;
}
