// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Shared types for THE PIT protocol
/// @notice INTEGRATOR-EVOLVED (economics increment E1): the Offer and Position structs were
///         deliberately extended for ODDS-BASED ASYMMETRIC COLLATERAL. The maker now offers a
///         payoff ratio (payoffRatioBps), the two sides escrow UNEQUAL collateral, and the
///         position records both stakes (longStake, shortStake) instead of a single
///         collateralEach. A 1:1 ratio (payoffRatioBps == 10_000) reproduces the old symmetric
///         behavior EXACTLY. Any further interface change still goes through the integrator.
library Types {
    enum Side {
        LONG,
        SHORT
    }

    enum PriceStatus {
        OK,
        COOLDOWN,
        STALE,
        UNAVAILABLE
    }

    /// @notice A resting offer on the p2p book. Collateral is USDG (native decimals).
    /// @dev payoffRatioBps expresses the ODDS the maker offers: it is the maker gross collateral
    ///      locked per unit of taker gross collateral, in basis points (10_000 = 1:1 symmetric).
    ///      A taker filling `fillCollateral` of the maker's remaining collateral posts a
    ///      proportional taker collateral of ceil(fillCollateral * 10_000 / payoffRatioBps), so a
    ///      short maker posting 900 at payoffRatioBps 90_000 (9:1) is fully matched by a long
    ///      taker posting 100: the winner takes the whole 1000 escrow. collateralRemaining stays
    ///      denominated in MAKER collateral, so minFill and partial-fill semantics are unchanged.
    struct Offer {
        address maker;
        address token; // underlying ERC-20 being speculated on
        Side makerSide; // side the MAKER takes; taker gets the opposite
        uint128 collateralRemaining; // unfilled MAKER collateral
        uint128 minFill; // smallest fillable slice of maker collateral
        uint16 multiple; // price-move sensitivity, integer 1..10 (independent of the payoff ratio)
        uint32 payoffRatioBps; // maker:taker collateral odds, bps; 10_000 (1:1) .. MAX_PAYOFF_RATIO_BPS
        uint32 duration; // position lifetime in seconds once matched
        uint64 offerExpiry; // timestamp after which the offer is dead
        uint128 limitEntry1e18; // 0 = none; LONG maker: max entry, SHORT maker: min entry
        bool cancelled;
    }

    /// @notice A matched long/short pair. The two sides escrow UNEQUAL stakes under asymmetric
    ///         odds: longStake and shortStake are each net of that side's own entry fee. The total
    ///         position escrow is longStake + shortStake, and that total is the maximum any single
    ///         position can ever pay out (the winner takes at most the loser's stake on top of its
    ///         own). At a 1:1 offer longStake == shortStake, reproducing the old collateralEach.
    struct Position {
        address longParty;
        address shortParty;
        address token;
        uint128 longStake; // net collateral escrowed by the long party
        uint128 shortStake; // net collateral escrowed by the short party
        uint16 multiple;
        uint64 openedAt;
        uint32 duration;
        uint128 entryPrice1e18;
        bool settled;
    }

    /// @notice Protocol fee split destinations, in basis points of EVERY fee (entry and settlement).
    ///         The shares sum to 10_000 per consumer. The v1 casino Market keeps the four-way
    ///         25/10/39/26 split (jackpot / referral / buyback / treasury plus dust) and IGNORES
    ///         the `vault` recipient. The v2 PerpEngine uses the five-way split (economics v2):
    ///         jackpot 2_500 / referral 1_000 / VAULT 2_000 / buyback 2_500 / treasury 2_000
    ///         plus round-down dust, with `vault` REQUIRED to equal the PitVault so 20% of every
    ///         perp trade fee accrues to LP NAV. The named shares live in Market and PerpEngine
    ///         as FEE_SHARE_* constants.
    /// @dev INTEGRATOR-EVOLVED (economics increment E2): the `buyback` recipient was added so protocol
    ///      revenue can fund the $PIT buyback-and-burn. The buyback address only RECEIVES USDG here;
    ///      the Buyback executor that swaps USDG for $PIT and burns it is a separate, later launch-time
    ///      contract and is intentionally NOT part of the trading engine.
    ///      INTEGRATOR-EVOLVED (economics increment E3, perp audit wave 1 finding A1): the `vault`
    ///      recipient was appended so the perp engine can route an immutable LP-vault share of every
    ///      trade fee to PitVault.receiveFeeRevenue (real-revenue LP yield). The split stays
    ///      IMMUTABLE in the engine (no setter): a settable split would reopen the trusted-owner
    ///      fee-redirection finding. Any further interface change still goes through the integrator.
    struct FeeSplit {
        address jackpot; // FEE_SHARE_JACKPOT_BPS (2_500)
        address treasury; // treasury share plus rounding dust (v1: 2_600; perp v2: 2_000)
        address referralPool; // FEE_SHARE_REFERRAL_BPS (1_000)
        address buyback; // buyback share (v1: 3_900; perp v2: 2_500)
        address vault; // perp v2 only: the PitVault, FEE_SHARE_VAULT_BPS (2_000); ignored by v1 Market
    }
}
