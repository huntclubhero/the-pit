// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {MarketFactory} from "../../src/core/MarketFactory.sol";
import {CoreBase} from "./CoreBase.t.sol";

/// @title MarketFactory unit tests
contract MarketFactoryTest is CoreBase {
    address internal token2;

    function setUp() public override {
        super.setUp();
        token2 = makeAddr("underlyingToken2");
        router.setListable(token2, true);
        router.setSnapshotValue(token2, 500_000e18);
        router.setTrackedLiquidity(token2, 500_000e18);
        router.setPrice(token2, 1e18, Types.PriceStatus.OK);
    }

    // ====================================================================== createMarket ======================================================================

    function test_createMarket_registersAndSnapshots() public {
        uint256 snapshotCallsBefore = router.snapshotCalls();

        vm.prank(carol);
        address created = factory.createMarket(token2);

        assertEq(factory.marketFor(token2), created);
        assertEq(factory.allMarketsLength(), 2);
        assertEq(factory.allMarkets(1), created);
        assertEq(router.snapshotCalls(), snapshotCallsBefore + 1);

        Market m = Market(created);
        assertEq(m.token(), token2);
        assertEq(m.liquiditySnapshot1e18(), 500_000e18);
        assertEq(address(m.usdg()), address(usdg));
        assertEq(address(m.router()), address(router));
        assertEq(address(m.points()), address(pitPoints));
        assertEq(address(m.guardian()), address(pauseGuardian));
        assertEq(m.oiCapBps(), OI_CAP_BPS);
        assertEq(m.perAddressOiCapBps(), PER_ADDRESS_OI_CAP_BPS);
        assertEq(m.feeJackpot(), jackpot);
        assertEq(m.feeTreasury(), treasury);
        assertEq(m.feeReferralPool(), referral);
        assertEq(m.feeBuyback(), buyback);
        assertEq(m.settlementFeeBps(), SETTLEMENT_FEE_BPS);
    }

    function test_createMarket_emitsMarketCreated() public {
        // The market address is not known in advance: skip topic2, match the rest.
        vm.expectEmit(true, false, true, true);
        emit MarketFactory.MarketCreated(token2, address(0), carol, 500_000e18);
        vm.prank(carol);
        factory.createMarket(token2);
    }

    function test_createMarket_callsPointsHookWithCreator() public {
        vm.prank(carol);
        factory.createMarket(token2);
        assertEq(pitPoints.lastCreator(), carol);
        assertEq(pitPoints.lastCreatedToken(), token2);
        // setUp created one market already, so this is call number two.
        assertEq(pitPoints.onMarketCreatedCalls(), 2);
    }

    function test_createMarket_survivesPointsRevert() public {
        pitPoints.setRevertOnCall(true);
        vm.expectEmit(true, true, true, true);
        emit MarketFactory.PointsHookFailed(abi.encodeWithSignature("PointsIntentionalRevert()"));
        vm.prank(carol);
        address created = factory.createMarket(token2);
        assertEq(factory.marketFor(token2), created);
    }

    function test_createMarket_revertsOnZeroToken() public {
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.createMarket(address(0));
    }

    function test_createMarket_revertsOnUsdg() public {
        vm.expectRevert(MarketFactory.TokenIsUsdg.selector);
        factory.createMarket(address(usdg));
    }

    function test_createMarket_revertsOnDuplicate() public {
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.MarketAlreadyExists.selector, address(market)));
        factory.createMarket(token);
    }

    function test_createMarket_revertsWhenNotListable() public {
        router.setListable(token2, false);
        vm.expectRevert(MarketFactory.TokenNotListable.selector);
        factory.createMarket(token2);
    }

    // ====================================================================== parameter updates ======================================================================

    function test_setters_updateStateAndEmit() public {
        address newRouter = makeAddr("newRouter");
        address newPoints = makeAddr("newPoints");
        address newGuardian = makeAddr("newGuardian");
        address newJackpot = makeAddr("newJackpot");
        address newTreasury = makeAddr("newTreasury");
        address newReferral = makeAddr("newReferral");
        address newBuyback = makeAddr("newBuyback");

        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit MarketFactory.RouterUpdated(newRouter);
        factory.setRouter(newRouter);
        assertEq(address(factory.router()), newRouter);

        vm.expectEmit(true, true, true, true);
        emit MarketFactory.PointsUpdated(newPoints);
        factory.setPoints(newPoints);
        assertEq(address(factory.points()), newPoints);

        vm.expectEmit(true, true, true, true);
        emit MarketFactory.FeeSplitUpdated(newJackpot, newTreasury, newReferral, newBuyback);
        factory.setFeeSplit(Types.FeeSplit(newJackpot, newTreasury, newReferral, newBuyback, address(0)));
        (address j, address t, address r, address b,) = factory.feeSplit();
        assertEq(j, newJackpot);
        assertEq(t, newTreasury);
        assertEq(r, newReferral);
        assertEq(b, newBuyback);

        vm.expectEmit(true, true, true, true);
        emit MarketFactory.SettlementFeeBpsUpdated(75);
        factory.setSettlementFeeBps(75);
        assertEq(factory.settlementFeeBps(), 75);

        vm.expectEmit(true, true, true, true);
        emit MarketFactory.OiCapUpdated(500);
        factory.setOiCapBps(500);
        assertEq(factory.oiCapBps(), 500);

        vm.expectEmit(true, true, true, true);
        emit MarketFactory.PerAddressOiCapUpdated(3_000);
        factory.setPerAddressOiCapBps(3_000);
        assertEq(factory.perAddressOiCapBps(), 3_000);

        vm.expectEmit(true, true, true, true);
        emit MarketFactory.GuardianUpdated(newGuardian);
        factory.setGuardian(newGuardian);
        assertEq(factory.guardian(), newGuardian);

        vm.stopPrank();
    }

    function test_setters_revertForNonOwner() public {
        vm.startPrank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        factory.setRouter(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        factory.setPoints(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        factory.setFeeSplit(Types.FeeSplit(carol, carol, carol, carol, address(0)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        factory.setSettlementFeeBps(60);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        factory.setOiCapBps(500);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        factory.setPerAddressOiCapBps(3_000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        factory.setGuardian(carol);
        vm.stopPrank();
    }

    function test_setters_validateInputs() public {
        vm.startPrank(owner);
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.setRouter(address(0));
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.setPoints(address(0));
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.setGuardian(address(0));
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.setFeeSplit(Types.FeeSplit(address(0), treasury, referral, buyback, address(0)));
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.setFeeSplit(Types.FeeSplit(jackpot, address(0), referral, buyback, address(0)));
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.setFeeSplit(Types.FeeSplit(jackpot, treasury, address(0), buyback, address(0)));
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        factory.setFeeSplit(Types.FeeSplit(jackpot, treasury, referral, address(0), address(0)));
        vm.expectRevert(MarketFactory.InvalidOiCap.selector);
        factory.setOiCapBps(0);
        vm.expectRevert(MarketFactory.InvalidOiCap.selector);
        factory.setOiCapBps(10_001);
        vm.expectRevert(MarketFactory.InvalidPerAddressOiCap.selector);
        factory.setPerAddressOiCapBps(0);
        vm.expectRevert(MarketFactory.InvalidPerAddressOiCap.selector);
        factory.setPerAddressOiCapBps(10_001);
        // The settlement fee cannot exceed MAX_SETTLEMENT_FEE_BPS (Market.MAX_FEE_BPS, 100 bps).
        // Cache the constant so its getter call does not consume the expectRevert cheat.
        uint16 maxFee = factory.MAX_SETTLEMENT_FEE_BPS();
        factory.setSettlementFeeBps(maxFee);
        vm.expectRevert(MarketFactory.InvalidSettlementFeeBps.selector);
        factory.setSettlementFeeBps(maxFee + 1);
        // The open bond cannot exceed MAX_OPEN_BOND_BPS (Market.MAX_OPEN_BOND_BPS, 500 bps).
        uint16 maxBond = factory.MAX_OPEN_BOND_BPS();
        factory.setOpenBondBps(maxBond);
        vm.expectRevert(MarketFactory.InvalidOpenBondBps.selector);
        factory.setOpenBondBps(maxBond + 1);
        vm.stopPrank();
    }

    function test_setOpenBondBps_armsFutureMarketsOnly() public {
        // Default is disabled: the pre-existing market carries a zero bond.
        assertEq(factory.openBondBps(), 0);
        assertEq(market.openBondBps(), 0);

        vm.prank(owner);
        factory.setOpenBondBps(200);
        assertEq(factory.openBondBps(), 200);

        // A NEW market bakes the armed bond; the pre-existing market is immutable at zero.
        vm.prank(carol);
        Market newMarket = Market(factory.createMarket(token2));
        assertEq(newMarket.openBondBps(), 200);
        assertEq(market.openBondBps(), 0);
    }

    function test_setOpenBondBps_onlyOwner() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        factory.setOpenBondBps(100);
    }

    function test_paramUpdates_affectFutureMarketsOnly() public {
        vm.prank(owner);
        factory.setOiCapBps(500);

        vm.prank(carol);
        Market newMarket = Market(factory.createMarket(token2));

        // The pre-existing market keeps its construction-time cap.
        assertEq(market.oiCapBps(), OI_CAP_BPS);
        assertEq(newMarket.oiCapBps(), 500);
    }

    function test_settlementFeeBps_affectsFutureMarketsOnly() public {
        // Owner retunes the settlement fee to 40 bps for future markets.
        vm.prank(owner);
        factory.setSettlementFeeBps(40);
        assertEq(factory.settlementFeeBps(), 40);

        vm.prank(carol);
        Market newMarket = Market(factory.createMarket(token2));

        // The pre-existing market keeps its immutable creation-time settlement fee; only the new
        // market picks up the retuned rate.
        assertEq(market.settlementFeeBps(), SETTLEMENT_FEE_BPS);
        assertEq(newMarket.settlementFeeBps(), 40);
    }

    function test_constructor_revertsOnZeroUsdg() public {
        vm.expectRevert(MarketFactory.ZeroAddress.selector);
        new MarketFactory(
            address(0),
            address(router),
            address(pitPoints),
            Types.FeeSplit(jackpot, treasury, referral, buyback, address(0)),
            1_000,
            PER_ADDRESS_OI_CAP_BPS,
            SETTLEMENT_FEE_BPS,
            address(pauseGuardian),
            owner
        );
    }

    function test_ownable2Step_transferFlow() public {
        vm.prank(owner);
        factory.transferOwnership(carol);
        // Two-step: still the old owner until acceptance.
        assertEq(factory.owner(), owner);

        vm.prank(carol);
        factory.acceptOwnership();
        assertEq(factory.owner(), carol);

        vm.prank(carol);
        factory.setOiCapBps(750);
        assertEq(factory.oiCapBps(), 750);
    }

    function test_perAddressOiCap_affectsFutureMarketsOnly() public {
        vm.prank(owner);
        factory.setPerAddressOiCapBps(2_500);

        vm.prank(carol);
        Market newMarket = Market(factory.createMarket(token2));

        // The pre-existing market keeps its construction-time sub-cap.
        assertEq(market.perAddressOiCapBps(), PER_ADDRESS_OI_CAP_BPS);
        assertEq(newMarket.perAddressOiCapBps(), 2_500);
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(MarketFactory.RenounceDisabled.selector);
        factory.renounceOwnership();
        // Ownership is intact and setters still work.
        assertEq(factory.owner(), owner);
    }
}
