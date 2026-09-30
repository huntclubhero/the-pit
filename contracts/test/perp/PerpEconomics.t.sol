// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpEngineBase} from "./PerpEngineBase.t.sol";
import {Types} from "../../src/interfaces/Types.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";
import {MockSpotSource} from "./mocks/MockSpotSource.sol";

/// @notice Economics v2 unit suite (findings A1 + A2): the immutable five-way fee split with
///         the vault leg, the liquidation-penalty vault share, the vol-scaled open-fee
///         surcharge (deviation + fresh-market decay + clamp), and the vol-scaled reserve-cap
///         discount (open path only). Every flow asserts wei-exact conservation.
contract PerpEconomicsTest is PerpEngineBase {
    MockSpotSource internal spot;

    /// @dev Launch-default vol params (the real PerpRiskConfig constructor values). The
    ///      RE-ECON-1 borrow-vol knobs are armed exactly as at launch; every fixture in this
    ///      suite holds the mark at its reference (or settles same-block), so the reading stays
    ///      zero and the surcharge/discount assertions remain byte-exact.
    function _launchVolParams() internal pure returns (PerpTypes.VolParams memory) {
        return PerpTypes.VolParams({
            kVolX100: 100,
            maxVolSurchargeBps: 50,
            freshSurchargeStartBps: 25,
            kCapVolX100: 2500,
            maxVolDiscountBps: 5000,
            kBorrowVolX100: 400,
            volBorrowDeadbandBps: 300,
            maxVolBorrowMultX100: 2_000_000,
            volRefTauSeconds: 12 hours
        });
    }

    function setUp() public override {
        super.setUp();
        spot = new MockSpotSource();
    }

    // ============================ Part 1a: five-way fee split ============================

    /// @notice Conservation of the split: for fuzzed fees the five recipient deltas sum to the
    ///         fee wei-exact, and the vault's 20% leg lands in vault cash (NAV), no USDG minted
    ///         or destroyed anywhere in the closed system.
    function testFuzz_feeSplitConservesWeiExact(uint128 rawMargin, uint32 rawLev) public {
        engine.setPerAddressReserveShareBps(10_000); // isolate the split under test
        uint128 margin = uint128(bound(rawMargin, 10e6, 10_000e6));
        uint32 lev = uint32(bound(rawLev, 110, 600));
        uint256 sysBefore = systemBalance();
        uint256 jackBefore = usdg.balanceOf(jackpot);
        uint256 refBefore = usdg.balanceOf(referral);
        uint256 buyBefore = usdg.balanceOf(buyback);
        uint256 treaBefore = usdg.balanceOf(treasury);
        uint256 vaultBefore = usdg.balanceOf(address(vault));

        open(alice, MEME, true, margin, lev);

        uint256 fee = margin - posOf(MEME, alice, true).margin;
        uint256 sum = (usdg.balanceOf(jackpot) - jackBefore) + (usdg.balanceOf(referral) - refBefore)
            + (usdg.balanceOf(buyback) - buyBefore) + (usdg.balanceOf(treasury) - treaBefore)
            + (usdg.balanceOf(address(vault)) - vaultBefore);
        assertEq(sum, fee, "five legs sum to the fee, wei-exact");
        assertEq(vault.cumulativeFeeRevenue(), fee * 2_000 / BPS, "vault leg = immutable 20%");
        assertEq(usdg.balanceOf(jackpot) - jackBefore, fee * 2_500 / BPS, "jackpot 25%");
        assertEq(usdg.balanceOf(referral) - refBefore, fee * 1_000 / BPS, "referral 10%");
        assertEq(usdg.balanceOf(buyback) - buyBefore, fee * 2_500 / BPS, "buyback 25%");
        assertEq(systemBalance(), sysBefore, "closed-system conservation");
    }

    /// @notice The engine constructor rejects a FeeSplit whose vault recipient is not the
    ///         counterparty vault: the immutable LP share can never be misrouted at deploy.
    function test_constructorRejectsForeignVaultRecipient() public {
        vm.expectRevert(PerpEngine.InvalidParam.selector);
        new PerpEngine(
            address(this),
            address(usdg),
            address(oracle),
            address(vault),
            address(ifund),
            address(risk),
            address(points),
            address(guardian),
            Types.FeeSplit({
                jackpot: jackpot,
                treasury: treasury,
                referralPool: referral,
                buyback: buyback,
                vault: address(0xDEAD)
            })
        );
    }

    // ============================ Part 1b: liquidation split ============================

    /// @notice keeperCut + vaultCut + fundCut + residual == pot, wei-exact, on a positive-equity
    ///         liquidation, with the vault's 40% leg counted as liquidation revenue.
    function test_liquidationSplitConservesPot() public {
        open(alice, MEME, true, 1_000e6, 600); // net 994, size 5964e18
        oracle.setLive(MEME, 85e16); // pnl = -894.6, pot = 99.4, penalty 1% of 5069.4 = 50.694
        uint256 sysBefore = systemBalance();
        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 ifBefore = usdg.balanceOf(address(ifund));
        uint256 vaultBefore = usdg.balanceOf(address(vault));

        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        uint256 pot = 99_400_000;
        uint256 penalty = 50_694_000;
        uint256 keeperCut = penalty * 2_000 / BPS; // 10.1388
        uint256 vaultCut = penalty * 4_000 / BPS; // 20.2776
        uint256 fundCut = penalty - keeperCut - vaultCut; // 20.2776 + dust
        uint256 residual = pot - penalty; // 48.706
        assertEq(usdg.balanceOf(keeper), keeperCut, "keeper 20%");
        assertEq(vault.cumulativeLiquidationRevenue(), vaultCut, "vault 40%");
        assertEq(usdg.balanceOf(address(ifund)) - ifBefore, fundCut, "IF 40% plus dust");
        assertEq(usdg.balanceOf(alice) - aliceBefore, residual, "residual returned unchanged");
        assertEq(keeperCut + vaultCut + fundCut + residual, pot, "penalty split conserves the pot");
        // Vault cash: absorbed loss (894.6) plus its penalty share.
        assertEq(usdg.balanceOf(address(vault)) - vaultBefore, 894_600_000 + vaultCut, "vault cash exact");
        assertEq(systemBalance(), sysBefore, "closed-system conservation");
    }

    /// @notice The keeper + vault penalty shares can never sum past 100% (conservation guard on
    ///         both setters), and only the owner can move them.
    function test_liquidationSplitSetterBounds() public {
        // Defaults: keeper 20%, vault 40%.
        assertEq(engine.keeperShareBps(), 2_000);
        assertEq(engine.liqVaultShareBps(), 4_000);
        vm.expectRevert(PerpEngine.InvalidParam.selector);
        engine.setLiqVaultShareBps(8_100); // 20% + 81% > 100%
        vm.expectRevert(PerpEngine.InvalidParam.selector);
        engine.setKeeperParams(6_100, 5e6); // 61% + 40% > 100%
        engine.setLiqVaultShareBps(5_000);
        assertEq(engine.liqVaultShareBps(), 5_000);
        vm.prank(alice);
        vm.expectRevert();
        engine.setLiqVaultShareBps(1_000);
    }

    // ============================ Part 2a: vol-scaled open fee ============================

    /// @notice Deviation-driven surcharge on a seasoned market: 30 bps of spot-vs-TWAP spread
    ///         at kVol 1.0 adds a 30 bps surcharge, credited 100% to the vault on top of its
    ///         20% share of the base fee; the base fee still splits five ways.
    function test_volSurcharge_deviationPricedAndVaultCredited() public {
        risk.setVolParams(_launchVolParams());
        oracle.setTierConfig(MEME, 2, address(spot));
        spot.setSpot(MEME, 1.003e18, true); // 30 bps above the $1 TWAP mark

        uint256 sysBefore = systemBalance();
        vm.expectEmit(true, true, false, true, address(engine));
        emit PerpEngine.VolSurchargeCharged(MEME, alice, 30, 18e6);
        open(alice, MEME, true, 1_000e6, 600);

        // Base fee 10 bps of 6,000 = 6; surcharge 30 bps of 6,000 = 18; net margin 976.
        assertEq(posOf(MEME, alice, true).margin, 976e6, "net margin after base + surcharge");
        assertEq(vault.cumulativeFeeRevenue(), 6e6 * 2_000 / BPS + 18e6, "vault: 20% of base + whole surcharge");
        assertEq(usdg.balanceOf(jackpot), 6e6 * 2_500 / BPS, "jackpot sees only the base fee");
        assertEq(systemBalance(), sysBefore, "conservation with the surcharge leg");
    }

    /// @notice Fresh-market surcharge decays linearly from 25 bps at listing to 0 over the
    ///         14-day ramp window (no deviation: the spot source is disarmed).
    function test_volSurcharge_freshMarketLinearDecay() public {
        engine.setPerAddressReserveShareBps(10_000); // day-one ramp cap is small; isolate the fee
        risk.setVolParams(_launchVolParams());
        address fresh = address(0xF4E5A);
        oracle.setLive(fresh, 1e18);
        oracle.setListable(fresh, true);
        risk.setParams(fresh, memeTierParams(), 2);
        engine.listMarket(fresh);

        // Day 0: full 25 bps. Fee = (10 + 25) bps of 6,000 = 21; net 979.
        open(alice, fresh, true, 1_000e6, 600);
        assertEq(posOf(fresh, alice, true).margin, 979e6, "day-0 fresh surcharge 25 bps");

        // Day 7: 25 * (14 - 7) / 14 = 12 bps (integer floor). Fee = 22 bps of 6,000 = 13.2.
        vm.warp(block.timestamp + 7 days);
        open(bob, fresh, true, 1_000e6, 600);
        assertEq(posOf(fresh, bob, true).margin, 1_000e6 - 13_200_000, "day-7 fresh surcharge 12 bps");

        // Past the window: base fee only.
        vm.warp(block.timestamp + 7 days);
        open(carol, fresh, true, 1_000e6, 600);
        assertEq(posOf(fresh, carol, true).margin, 994e6, "surcharge fully decayed");
    }

    /// @notice The total surcharge clamps at MAX_VOL_SURCHARGE_BPS (50): deviation + fresh
    ///         surcharge past the clamp never becomes punitive on a genuine directional trade.
    function test_volSurcharge_clampsAtMax() public {
        engine.setPerAddressReserveShareBps(10_000); // day-one ramp cap is small; isolate the fee
        risk.setVolParams(_launchVolParams());
        address fresh = address(0xF4E5B);
        oracle.setLive(fresh, 1e18);
        oracle.setListable(fresh, true);
        oracle.setTierConfig(fresh, 0, address(spot));
        risk.setParams(fresh, memeTierParams(), 2);
        engine.listMarket(fresh);
        spot.setSpot(fresh, 1.004e18, true); // 40 bps deviation + 25 fresh = 65 -> clamp 50

        vm.expectEmit(true, true, false, true, address(engine));
        emit PerpEngine.VolSurchargeCharged(fresh, alice, 50, 30e6);
        open(alice, fresh, true, 1_000e6, 600);
        assertEq(posOf(fresh, alice, true).margin, 1_000e6 - 6e6 - 30e6, "surcharge clamped at 50 bps");
    }

    /// @notice A reverting or not-ok spot source reads as zero deviation: the vol proxy can
    ///         never brick an open (fresh window already passed for MEME, so no surcharge).
    function test_volSurcharge_unreadableSpotNeverBlocks() public {
        risk.setVolParams(_launchVolParams());
        oracle.setTierConfig(MEME, 2, address(spot));
        spot.setRevertOnRead(true);
        open(alice, MEME, true, 1_000e6, 600);
        assertEq(posOf(MEME, alice, true).margin, 994e6, "reverting spot -> zero surcharge");
        spot.setRevertOnRead(false);
        spot.setSpot(MEME, 1.05e18, false); // not-ok reading
        open(bob, MEME, true, 1_000e6, 600);
        assertEq(posOf(MEME, bob, true).margin, 994e6, "not-ok spot -> zero surcharge");
    }

    // ============================ Part 2b: vol-scaled cap discount ============================

    /// @notice At 200 bps of deviation (about 2x a normal memecoin reading) the open-path cap
    ///         is halved (kCapVol 25 -> 5000 bps discount): a new open that fits the base cap
    ///         reverts, while closes, liquidations and addMargin are never blocked.
    function test_volCapDiscount_halvesOpenCapacityNeverBlocksExits() public {
        risk.setVolParams(_launchVolParams());
        engine.setPerAddressReserveShareBps(10_000);
        vault.setTotalAssetsOverride(1_000_000e6); // cap TVL leg deterministic: 100k
        oracle.setTierConfig(MEME, 2, address(spot));

        // Calm market: a large open reserving 62,622 fits under the 100k cap.
        spot.setSpot(MEME, 1e18, true);
        open(alice, MEME, true, 7_000e6, 600); // fee 42, net 6,958, payout 62,622
        assertEq(vault.reservedOf(MEME), 62_622e6);

        // Vol spike: 200 bps deviation -> surcharge clamps at 50 bps, cap discount 50%.
        spot.setSpot(MEME, 1.02e18, true);
        // bob's open would reserve 62,622 + 9 * net > 50k effective cap: denied.
        vm.prank(bob);
        vm.expectRevert(PerpEngine.MarketReserveCapExceeded.selector);
        engine.openPosition(MEME, false, 1_000e6, 600);
        // The UNDISCOUNTED view cap is unchanged (the discount is an open-path tightening).
        assertEq(engine.marketReserveCapUsdg(MEME), 100_000e6, "view cap undiscounted");

        // addMargin (strictly de-risking) is NOT discounted: it fits under the base 100k cap.
        vm.prank(alice);
        engine.addMargin(MEME, true, 3_000e6); // margin 9,958 < 10k cap; payout 89,622 < 100k
        assertEq(vault.reservedOf(MEME), 89_622e6, "addMargin unaffected by the vol discount");

        // Close under the same vol spike: never blocked.
        vm.prank(alice);
        engine.closePosition(MEME, true);
        assertEq(vault.reservedOf(MEME), 0, "exit clean during the vol spike");
    }

    /// @notice The discount clamps at maxVolDiscountBps: even absurd deviation never fully
    ///         closes a market to new opens (a suitably small open still fits).
    function test_volCapDiscount_neverClosesMarket() public {
        risk.setVolParams(_launchVolParams());
        vault.setTotalAssetsOverride(1_000_000e6);
        oracle.setTierConfig(MEME, 2, address(spot));
        spot.setSpot(MEME, 2e18, true); // 100% deviation -> discount clamps at 50%
        open(alice, MEME, true, 1_000e6, 600); // 9x payout well under the 50k effective cap
        assertGt(uint256(posOf(MEME, alice, true).size1e18), 0, "small open still admitted");
    }

    // ============================ ramp: only tightens ============================

    /// @notice The linear ramp can only TIGHTEN the cap: at every day inside the window the
    ///         effective cap never exceeds the un-ramped cap (the anti-drain cost-to-move leg
    ///         and the TVL leg are min() legs the ramp sits under).
    function test_linearRampNeverExceedsBaseCap() public {
        vault.setTotalAssetsOverride(1_000_000e6);
        address fresh = listFreshMeme(30_000e18); // frozen cost-to-move cap 30k (< TVL leg 100k)
        // listFreshMeme warps past the window: re-list a second fresh market for the in-window walk.
        address fresh2 = address(0xF4E5C);
        oracle.setLive(fresh2, 1e18);
        oracle.setListable(fresh2, true);
        oracle.setPayoutCap1e18(fresh2, 30_000e18);
        risk.setParams(fresh2, memeTierParams(), 2);
        engine.listMarket(fresh2);
        for (uint256 d = 0; d < 15; d++) {
            assertLe(engine.marketReserveCapUsdg(fresh2), 30_000e6, "ramped cap <= frozen cost-to-move cap");
            vm.warp(block.timestamp + 1 days);
        }
        assertEq(engine.marketReserveCapUsdg(fresh2), 30_000e6, "post-window: the frozen cap binds");
        assertEq(engine.marketReserveCapUsdg(fresh), 30_000e6, "seasoned market unchanged");
    }
}
