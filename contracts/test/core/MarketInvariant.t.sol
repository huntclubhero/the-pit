// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {PauseGuardian} from "../../src/core/PauseGuardian.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockOracleRouter} from "../mocks/MockOracleRouter.sol";
import {CoreBase} from "./CoreBase.t.sol";

/// @title MarketHandler: bounded random-walk driver for the invariant suite
/// @notice Performs randomized but plausibility-bounded protocol actions (post, cancel,
///         fill, settle, price and liquidity moves, time warps, pausing) with three
///         actors, and records ghost violations that the invariants assert against.
contract MarketHandler is Test {
    Market internal market;
    MockUSDG internal usdg;
    MockOracleRouter internal router;
    PauseGuardian internal pauseGuardian;
    address internal token;
    address internal guardianMultisig;
    address internal jackpot;
    address internal treasury;
    address internal referral;
    address internal buyback;

    address[3] internal actors;

    /// @notice Set when a settlement paid the parties more than the total position escrow
    ///         (longStake + shortStake), the capped-payout ceiling.
    bool public overpaidSettlement;
    /// @notice Set when settle succeeded on an already settled position.
    bool public resettleSucceeded;
    /// @notice Set when a successful fill left open interest above the OI cap.
    bool public oiCapViolatedOnFill;
    /// @notice Set when a successful fill left a participant above the per-address OI sub-cap.
    bool public perAddressCapViolatedOnFill;
    /// @notice Set when a successful fill's fee-recipient balance delta did not equal
    ///         the entry fee formula, 2 x (gross x multiple x 10 / 10_000).
    bool public entryFeeMismatch;
    /// @notice Lifetime protocol fees (entry plus settlement) observed leaving the
    ///         market into the four fee recipients.
    uint256 public ghostFeesPaid;

    constructor(
        Market market_,
        MockUSDG usdg_,
        MockOracleRouter router_,
        PauseGuardian pauseGuardian_,
        address token_,
        address guardianMultisig_,
        address jackpot_,
        address treasury_,
        address referral_,
        address buyback_
    ) {
        market = market_;
        usdg = usdg_;
        router = router_;
        pauseGuardian = pauseGuardian_;
        token = token_;
        guardianMultisig = guardianMultisig_;
        jackpot = jackpot_;
        treasury = treasury_;
        referral = referral_;
        buyback = buyback_;
        actors = [makeAddr("actor0"), makeAddr("actor1"), makeAddr("actor2")];
    }

    /// @dev Combined balance of the four fee recipients; they only ever receive
    ///      funds from market fees, so deltas measure fees exactly.
    function _feeRecipientBal() internal view returns (uint256) {
        return usdg.balanceOf(jackpot) + usdg.balanceOf(treasury) + usdg.balanceOf(referral) + usdg.balanceOf(buyback);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice The fixed actor at index `i` (0..2), for per-address ledger invariants.
    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function postOffer(
        uint256 actorSeed,
        uint128 collateralSeed,
        uint128 minFillSeed,
        uint16 multipleSeed,
        uint32 payoffRatioSeed,
        uint32 durationSeed,
        uint64 expirySeed,
        bool makerLong
    ) external {
        address actor = _actor(actorSeed);
        uint128 collateral = uint128(bound(collateralSeed, 1, 1_000_000e6));
        uint128 minFill = uint128(bound(minFillSeed, 1, collateral));
        uint16 multiple = uint16(bound(multipleSeed, 1, 10));
        // Fuzz the full odds band so the invariants run over ASYMMETRIC stakes, not just 1:1.
        uint32 payoffRatioBps = uint32(bound(payoffRatioSeed, 10_000, 200_000));
        uint32 duration = uint32(bound(durationSeed, 1 hours, 30 days));
        uint64 offerExpiry = uint64(block.timestamp + bound(expirySeed, 1, 30 days));

        usdg.mint(actor, collateral);
        vm.startPrank(actor);
        usdg.approve(address(market), type(uint256).max);
        market.postOffer(
            makerLong ? Types.Side.LONG : Types.Side.SHORT,
            collateral,
            minFill,
            multiple,
            payoffRatioBps,
            duration,
            offerExpiry,
            0
        );
        vm.stopPrank();
    }

    function cancelOffer(uint256 offerSeed) external {
        uint256 count = market.nextOfferId();
        if (count == 0) return;
        uint256 offerId = offerSeed % count;
        Types.Offer memory offer = market.offers(offerId);
        vm.prank(offer.maker);
        try market.cancelOffer(offerId) {} catch {}
    }

    function fillOffer(uint256 actorSeed, uint256 offerSeed, uint128 amountSeed) external {
        uint256 count = market.nextOfferId();
        if (count == 0) return;
        uint256 offerId = offerSeed % count;
        Types.Offer memory offer = market.offers(offerId);
        if (offer.cancelled || offer.collateralRemaining < offer.minFill) return;

        uint128 amount = uint128(bound(amountSeed, offer.minFill, offer.collateralRemaining));
        address actor = _actor(actorSeed);
        usdg.mint(actor, amount);
        uint256 feeBalBefore = _feeRecipientBal();
        vm.startPrank(actor);
        usdg.approve(address(market), type(uint256).max);
        try market.fillOffer(offerId, amount) returns (uint256) {
            // The cap keys off the IMMUTABLE creation snapshot, never live tracked liquidity.
            uint256 cap1e18 = Math.mulDiv(market.liquiditySnapshot1e18(), market.oiCapBps(), 10_000);
            if (market.openInterest() * market.collateralScale() > cap1e18) {
                oiCapViolatedOnFill = true;
            }
            // No participant may sit above the per-address sub-cap after a successful fill.
            uint256 subCap1e18 = Math.mulDiv(cap1e18, market.perAddressOiCapBps(), 10_000);
            for (uint256 j = 0; j < actors.length; j++) {
                if (market.openCollateralOf(actors[j]) * market.collateralScale() > subCap1e18) {
                    perAddressCapViolatedOnFill = true;
                }
            }
            // Entry fees provably left escrow at fill: the recipients' balance delta must equal
            // feeMaker + feeTaker, each side's 10 bps of its OWN gross notional under the offer's
            // odds (equal at 1:1). `amount` is the maker collateral consumed; the taker posts the
            // proportional takerGross.
            uint256 takerGross = Math.ceilDiv(uint256(amount) * 10_000, offer.payoffRatioBps);
            uint256 feeMaker = uint256(amount) * offer.multiple * 10 / 10_000;
            uint256 feeTaker = takerGross * offer.multiple * 10 / 10_000;
            uint256 expectedEntryFees = feeMaker + feeTaker;
            uint256 delta = _feeRecipientBal() - feeBalBefore;
            if (delta != expectedEntryFees) {
                entryFeeMismatch = true;
            }
            ghostFeesPaid += delta;
        } catch {}
        vm.stopPrank();
    }

    function settle(uint256 actorSeed, uint256 positionSeed) external {
        uint256 count = market.nextPositionId();
        if (count == 0) return;
        uint256 positionId = positionSeed % count;
        Types.Position memory position = market.positions(positionId);
        bool wasSettled = position.settled;
        // Payouts are CREDITED (pull-payment), so overpay is measured on the credit deltas.
        uint256 longCreditBefore = market.withdrawable(position.longParty);
        uint256 shortCreditBefore = market.withdrawable(position.shortParty);
        uint256 feeBalBefore = _feeRecipientBal();

        vm.prank(_actor(actorSeed));
        try market.settle(positionId) {
            ghostFeesPaid += _feeRecipientBal() - feeBalBefore;
            if (wasSettled) {
                resettleSucceeded = true;
            } else {
                uint256 paidToParties;
                if (position.longParty == position.shortParty) {
                    paidToParties = market.withdrawable(position.longParty) - longCreditBefore;
                } else {
                    paidToParties = (market.withdrawable(position.longParty) - longCreditBefore)
                        + (market.withdrawable(position.shortParty) - shortCreditBefore);
                }
                if (paidToParties > uint256(position.longStake) + uint256(position.shortStake)) {
                    overpaidSettlement = true;
                }
            }
        } catch {}
    }

    function withdraw(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        if (market.withdrawable(actor) == 0) return;
        vm.prank(actor);
        try market.withdraw() {} catch {}
    }

    function movePrice(uint256 priceSeed, uint256 statusSeed) external {
        uint256 price1e18 = bound(priceSeed, 1e12, 1e24);
        // Mostly healthy, sometimes broken, occasionally a zero price while OK.
        Types.PriceStatus status = statusSeed % 5 == 0 ? Types.PriceStatus.UNAVAILABLE : Types.PriceStatus.OK;
        if (statusSeed % 17 == 0) price1e18 = 0;
        router.setPrice(token, price1e18, status);
    }

    function moveLiquidity(uint256 liquiditySeed) external {
        // Range straddles the 40% floor of the 1_000_000e18 snapshot so the floor
        // gate is exercised in both directions.
        router.setTrackedLiquidity(token, bound(liquiditySeed, 200_000e18, 2_000_000e18));
    }

    function warpForward(uint256 deltaSeed) external {
        vm.warp(block.timestamp + bound(deltaSeed, 1 minutes, 3 days));
    }

    function togglePause(uint256 seed) external {
        address key = seed % 2 == 0 ? address(0) : address(market);
        vm.prank(guardianMultisig);
        if (seed % 3 == 0) {
            try pauseGuardian.unpause(key) {} catch {}
        } else {
            try pauseGuardian.pause(key) {} catch {}
        }
    }
}

/// @title Market invariant suite
/// @notice Invariants proven over randomized action sequences:
///         (a) the market's USDG balance always equals live offer collateral plus open
///             position escrow (longStake + shortStake per open position, net of entry
///             fees, which provably leave escrow in the fill transaction), exactly, across
///             ASYMMETRIC-odds positions as well as 1:1;
///         (b) no settlement ever pays the two parties more than the total position escrow
///             (longStake + shortStake);
///         (c) settled positions never settle again;
///         (d) successful fills never leave open interest above the OI cap;
///         (e) the openInterest accumulator always matches the sum over open positions;
///         (f) lifetime entry fees plus settlement fees paid out equal the fee
///             recipients' balance deltas exactly, and every fill's entry fee matched
///             the 10 bps gross-notional formula.
contract MarketInvariantTest is CoreBase {
    MarketHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new MarketHandler(
            market, usdg, router, pauseGuardian, token, guardianMultisig, jackpot, treasury, referral, buyback
        );
        targetContract(address(handler));
    }

    function invariant_escrowSolvencyExact() public view {
        uint256 expectedBalance;
        uint256 expectedOpenInterest;

        uint256 offerCount = market.nextOfferId();
        for (uint256 i = 0; i < offerCount; i++) {
            Types.Offer memory offer = market.offers(i);
            if (!offer.cancelled) {
                expectedBalance += offer.collateralRemaining;
            }
        }
        uint256 positionCount = market.nextPositionId();
        for (uint256 i = 0; i < positionCount; i++) {
            Types.Position memory position = market.positions(i);
            if (!position.settled) {
                // Total per-position escrow = longStake + shortStake (unequal under odds).
                uint256 totalStake = uint256(position.longStake) + uint256(position.shortStake);
                expectedBalance += totalStake;
                expectedOpenInterest += totalStake;
            }
        }

        // Settled-but-unwithdrawn payouts (pull-payment credits) are still held by the market.
        expectedBalance += market.totalUnwithdrawnCredit();

        assertEq(usdg.balanceOf(address(market)), expectedBalance, "escrow solvency");
        assertEq(market.openInterest(), expectedOpenInterest, "open interest accumulator");
    }

    /// @notice The per-address open-collateral ledger conserves exactly: summed over every actor
    ///         it equals the open-interest accumulator (each open position credits both parties).
    function invariant_addressOpenInterestConservation() public view {
        uint256 sum;
        for (uint256 i = 0; i < 3; i++) {
            sum += market.openCollateralOf(handler.actorAt(i));
        }
        assertEq(sum, market.openInterest(), "per-address open collateral conservation");
    }

    /// @notice No successful fill ever left a participant above the per-address OI sub-cap.
    function invariant_perAddressSubCapNeverExceeded() public view {
        assertFalse(handler.perAddressCapViolatedOnFill(), "fill breached per-address OI sub-cap");
    }

    function invariant_noSettlementOverpay() public view {
        assertFalse(handler.overpaidSettlement(), "settlement paid more than 2x collateral");
    }

    function invariant_settledPositionsNeverResettle() public view {
        assertFalse(handler.resettleSucceeded(), "settled position settled again");
    }

    function invariant_oiCapNeverExceededByFills() public view {
        assertFalse(handler.oiCapViolatedOnFill(), "fill breached OI cap");
    }

    /// @notice Fee accumulator: everything the FOUR fee recipients hold is exactly the
    ///         lifetime entry plus settlement fees the handler observed leaving the
    ///         market, and every fill's entry fee matched the formula.
    function invariant_feeAccumulatorMatchesRecipients() public view {
        assertEq(
            usdg.balanceOf(jackpot) + usdg.balanceOf(treasury) + usdg.balanceOf(referral) + usdg.balanceOf(buyback),
            handler.ghostFeesPaid(),
            "lifetime fees vs recipient balances"
        );
        assertFalse(handler.entryFeeMismatch(), "entry fee delta mismatched formula");
    }
}
