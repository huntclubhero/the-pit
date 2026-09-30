// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Shared types for THE PIT v2 leveraged perps engine
/// @notice FROZEN: the perp module teams must not modify this file. Interface changes go
///         through the integrator. Basis: the-pit-perp-v2-spec-detailed-2026-07-24.md.
library PerpTypes {
    /// @notice One isolated-margin position, keyed by keccak(token, trader, isLong).
    /// @dev All USDG amounts are native 6-decimal units; prices are 1e18 (USDG per token),
    ///      identical to IOracleRouter.checkPrice. size is base-token units at 1e18 scale.
    struct Position {
        address trader;
        address token; // market key (underlying ERC-20; synthetic, never held)
        bool isLong;
        uint128 size1e18; // base units, 1e18 scale
        uint128 margin; // USDG units, isolated, net of open fee
        uint128 entryPrice1e18; // volume-weighted mark at open/increase
        int128 entryFundingX1e18; // per-market funding index snapshot at open/increase
        uint128 entryBorrowX1e18; // per-market borrow index snapshot at open/increase
        uint128 maxPayout; // USDG units: payoutCapMultiple * margin, frozen at open/add
        uint64 openedAt;
        uint64 lastIncreasedAt;
        uint32 entryMmrBps; // maintenance-margin ratio snapshot at open/increase (grandfathered, spec 8.4)
    }

    /// @notice Per-market running aggregates maintained by the engine for O(1) vault NAV and caps.
    struct MarketAggregates {
        uint128 totalLongSize1e18;
        uint128 totalLongCost; // sum of size*entry (USDG units), longs
        uint128 totalShortSize1e18;
        uint128 totalShortCost; // sum of size*entry (USDG units), shorts
        uint128 totalLongMargin;
        uint128 totalShortMargin;
        uint128 totalMaxPayout; // sum of maxPayout over all open positions in this market
        int128 fundingX1e18; // cumulative funding index (signed)
        uint128 borrowX1e18; // cumulative borrow index
        uint64 lastAccrual;
        uint128 cachedMark1e18; // last LIVE/FALLBACK mark, for NAV between pokes
        uint64 cachedMarkAt;
        bool closeOnly; // governance delist: no opens, closes+liquidations continue
    }

    /// @notice Volatility-pricing parameters (economics v2, perp audit wave 1 finding A2 plus
    ///         the RE-ECON-1 holding-cost layer): the vol-scaled open-fee surcharge credited
    ///         100% to the LP vault (the premium for the gamma the vault sells on that open),
    ///         the vol-scaled reserve-cap discount that shrinks NEW-position capacity during
    ///         vol spikes (open path only; closes and liquidations are never blocked), and the
    ///         vol-scaled BORROW multiplier that makes borrow accrue faster while REALIZED
    ///         volatility is high, so a position held through a vol event pays for the gamma it
    ///         carried no matter when it opened (both legs of a delta-neutral straddle pay it).
    ///         Deviation (surcharge/discount) is the oracle's instantaneous spot-vs-TWAP spread
    ///         in bps; the borrow multiplier instead reads the TIME-INTEGRATED displacement of
    ///         the settlement mark from a slow per-market EWMA reference maintained by the
    ///         engine, which a one-block print cannot suppress. All knobs are timelock-settable
    ///         within HARD caps enforced by PerpRiskConfig.setVolParams.
    struct VolParams {
        uint16 kVolX100; // surcharge slope: bps of surcharge per bps of deviation, x100 (100 = 1.0)
        uint16 maxVolSurchargeBps; // hard clamp on the total vol surcharge per open (launch 50)
        uint16 freshSurchargeStartBps; // fresh-market surcharge at listing, linear decay to 0 over the ramp window (launch 25)
        uint16 kCapVolX100; // cap-discount slope: bps of discount per bps of deviation, x100 (launch 2500 = 25 bps per bps)
        uint16 maxVolDiscountBps; // clamp on the reserve-cap discount (launch 5000; hard cap < 100%: never closes the market)
        uint16 kBorrowVolX100; // borrow-multiplier slope: x100 of extra borrow multiple per bps of realized vol past the deadband (launch 400 = 4.00x per bps)
        uint16 volBorrowDeadbandBps; // realized-vol readings at or below this are ordinary noise: no multiplier (launch 300)
        uint32 maxVolBorrowMultX100; // clamp on the borrow multiplier, x100 (launch 2_000_000 = 20,000x; effective rate further hard-capped at 2%/h in FundingLib)
        uint32 volRefTauSeconds; // EWMA time constant of the engine's long reference mark (launch 12h; 0 only with kBorrowVolX100 = 0)
    }

    /// @notice Per-tier risk parameters (governance, timelocked). Fee bps are of notional.
    struct TierParams {
        uint32 maxLeverageX100; // e.g. 450 = 4.5x
        uint16 mmrBps; // maintenance margin ratio, bps of notional
        uint16 openFeeBps;
        uint16 closeFeeBps;
        uint64 kFPerHour1e18; // funding coefficient at 100% skew, per hour, 1e18
        uint64 kBPerHour1e18; // borrow coefficient at 100% utilization, per hour, 1e18
        uint16 liqPenaltyBps; // liquidation penalty, bps of notional
        uint128 maxPositionMargin; // USDG units, per-position margin cap
    }
}
