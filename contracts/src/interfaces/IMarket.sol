// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Types} from "./Types.sol";

/// @title Per-token p2p capped-payout market
/// @notice INTEGRATOR-EVOLVED (economics increment E1): postOffer gained a payoffRatioBps
///         parameter and fillOffer's semantics were extended for ODDS-BASED ASYMMETRIC
///         COLLATERAL. A 1:1 offer (payoffRatioBps == 10_000) reproduces the old symmetric
///         behavior EXACTLY.
///         INTEGRATOR-EVOLVED (economics increment E2): the protocol fee split became four-way
///         (jackpot / referral / buyback / treasury) to fund the $PIT buyback-and-burn, and the
///         settlement fee dropped to a governance-tunable, MAX_FEE_BPS-capped per-market rate
///         (50 bps at launch). Neither change touches settlement conservation or the odds math. Any
///         further interface change goes through the integrator.
interface IMarket {
    // ------------------------------ book ------------------------------
    /// @notice Post a resting offer at chosen odds. The maker escrows `collateral` (its own gross
    ///         collateral) immediately and offers `payoffRatioBps` odds: the maker collateral
    ///         locked per unit of taker collateral, in basis points, with 10_000 = 1:1 symmetric
    ///         and the ceiling MAX_PAYOFF_RATIO_BPS. `multiple` (1..10) is the independent
    ///         price-move sensitivity knob, unchanged in meaning.
    function postOffer(
        Types.Side makerSide,
        uint128 collateral,
        uint128 minFill,
        uint16 multiple,
        uint32 payoffRatioBps,
        uint32 duration,
        uint64 offerExpiry,
        uint128 limitEntry1e18
    ) external returns (uint256 offerId);

    function cancelOffer(uint256 offerId) external;

    /// @notice Fill a slice of an offer. `fillCollateral` is the amount of MAKER collateral to
    ///         consume (checked against the offer's minFill and remaining, exactly as before). The
    ///         taker takes the opposite side and posts a proportional taker collateral of
    ///         ceil(fillCollateral * 10_000 / payoffRatioBps); at 1:1 that equals fillCollateral.
    ///         An entry fee of 10 bps of EACH side's own gross notional (grossCollateral * multiple)
    ///         is charged to that side at fill: the position opens with each side's stake net of its
    ///         own fee, and the combined maker + taker entry fee is paid out immediately with the
    ///         standard 25/10/39/26 jackpot/referral/buyback/treasury fee split. Fills whose per-side
    ///         entry fee rounds down to zero are dust and revert.
    function fillOffer(uint256 offerId, uint128 fillCollateral) external returns (uint256 positionId);

    // --------------------------- settlement ---------------------------
    /// @notice Either party after minHold, or anyone after expiry. Settles both legs at the
    ///         oracle composite. Reverts (no state change beyond breaker bookkeeping) when
    ///         the oracle status is not OK, EXCEPT the forced path after
    ///         expiry + maxSettleDelay: if the status is still not OK by then, the position
    ///         is neutrally unwound and both sides are refunded exactly their own stake with
    ///         zero fee, so funds can never be locked forever.
    /// @dev Settlement and forced unwind CREDIT each party's withdrawable balance rather than
    ///      pushing USDG, so a frozen or blocked recipient can never revert settlement or strand
    ///      the counterparty. Parties realize their payouts by calling withdraw().
    function settle(uint256 positionId) external;

    /// @notice Pull the caller's credited USDG balance (settlement and forced-unwind payouts).
    /// @dev Pull-payment counterpart to settle(): payouts are credited on settlement and each
    ///      party withdraws its own balance here. Reverts when the caller has nothing credited.
    ///      A failed pull by one party never blocks another party or settlement itself.
    /// @return amount The USDG amount transferred to the caller.
    function withdraw() external returns (uint256 amount);

    // ------------------------------ views -----------------------------
    function offers(uint256 offerId) external view returns (Types.Offer memory);
    function positions(uint256 positionId) external view returns (Types.Position memory);
    function openInterest() external view returns (uint256 totalEscrowedCollateral);
    function token() external view returns (address);

    // ------------------------------ params ----------------------------
    /// @dev Params: entry fee 10 bps of notional per side at fill (fixed, anti-wash; deducted from
    ///      each side's own gross fill collateral, so each stake is net of it); settlement fee
    ///      settlementFeeBps of the loser's notional (50 bps at launch, immutable per market and
    ///      bounded by the MAX_FEE_BPS 1% cap; the factory owner tunes the value used by future
    ///      markets), taken from realized winnings only; both fees split 25/10/39/26
    ///      jackpot/referral/buyback/treasury with round-down shares and dust to treasury; minHold
    ///      30 minutes; multiple 1..10; payoffRatioBps 10_000..MAX_PAYOFF_RATIO_BPS; OI cap =
    ///      oiCapBps of tracked liquidity (1_000 = 10%), measured on TOTAL net escrowed position
    ///      collateral (longStake + shortStake), which is also the maximum single-position payout.
}
