// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpEngineBase} from "./PerpEngineBase.t.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";

/// @notice Skew funding + borrow accrual through the market indices: zero-sum trader to
///         trader with the residual on the NET OI accruing to the vault (spec 5), borrow
///         paid by BOTH sides, funding drag on the liquidation price.
contract PerpEngineFundingTest is PerpEngineBase {
    function test_funding_zeroSumWithVaultResidual() public {
        // alice long 2000 at 6x (size 11928e18), bob short 1000 at 6x (size 5964e18).
        open(alice, MEME, true, 2_000e6, 600);
        open(bob, MEME, false, 1_000e6, 600);
        vm.warp(block.timestamp + 12 hours);
        engine.pokeFunding(MEME);

        PerpTypes.MarketAggregates memory agg = aggOf(MEME);
        uint256 fX = uint256(int256(agg.fundingX1e18));
        assertGt(fX, 0, "long-heavy skew: index rises, longs pay");

        (int256 aliceFund,) = engine.pendingOwedOf(MEME, alice, true);
        (int256 bobFund,) = engine.pendingOwedOf(MEME, bob, false);
        assertGt(aliceFund, 0, "long pays");
        assertLt(bobFund, 0, "short receives");
        // Exact index identity: paid = sizeLong * fX, received = sizeShort * fX.
        assertEq(uint256(aliceFund), 11_928e18 * fX / 1e30);
        assertEq(uint256(-bobFund), 5_964e18 * fX / 1e30);
        // Residual to the vault = net OI leg = (11928 minus 5964) * fX: never negative,
        // exact up to one unit of per-position floor rounding.
        assertGe(aliceFund + bobFund, 0, "vault never pays the residual");
        assertApproxEqAbs(aliceFund + bobFund, int256(5_964e18 * fX / 1e30), 1, "vault residual exact");
    }

    function test_funding_vaultCollectsResidualInCash() public {
        open(alice, MEME, true, 2_000e6, 600);
        open(bob, MEME, false, 1_000e6, 600);
        vm.warp(block.timestamp + 12 hours);
        engine.pokeFunding(MEME);
        (int256 aliceFund, uint256 aliceBor) = engine.pendingOwedOf(MEME, alice, true);
        (int256 bobFund, uint256 bobBor) = engine.pendingOwedOf(MEME, bob, false);

        uint256 vaultBefore = usdg.balanceOf(address(vault));
        vm.prank(alice);
        engine.closePosition(MEME, true);
        vm.prank(bob);
        engine.closePosition(MEME, false);

        // Vault cash delta: the funding + borrow legs (payer leg minus receiver leg plus
        // borrows) PLUS the vault's immutable 20% share of each close fee (economics v2:
        // alice 11.928, bob 5.964 of close fees at the flat $1 mark).
        int256 expectedVaultDelta = aliceFund + bobFund + int256(aliceBor) + int256(bobBor)
            + int256((11_928_000 + 5_964_000) * 2_000 / 10_000);
        assertEq(
            int256(usdg.balanceOf(address(vault))) - int256(vaultBefore),
            expectedVaultDelta,
            "funding is zero-sum trader-to-trader with the residual to the vault"
        );
    }

    function test_borrow_bothSidesPay() public {
        open(alice, MEME, true, 2_000e6, 600);
        open(bob, MEME, false, 2_000e6, 600); // perfectly balanced: zero skew
        vm.warp(block.timestamp + 24 hours);
        engine.pokeFunding(MEME);

        PerpTypes.MarketAggregates memory agg = aggOf(MEME);
        assertEq(agg.fundingX1e18, 0, "balanced book: no funding");
        assertGt(agg.borrowX1e18, 0, "borrow accrues regardless of skew");
        (int256 aliceFund, uint256 aliceBor) = engine.pendingOwedOf(MEME, alice, true);
        (int256 bobFund, uint256 bobBor) = engine.pendingOwedOf(MEME, bob, false);
        assertEq(aliceFund, 0);
        assertEq(bobFund, 0);
        assertGt(aliceBor, 0, "long pays borrow");
        assertGt(bobBor, 0, "short pays borrow");
        assertEq(aliceBor, bobBor, "equal size, equal borrow");
    }

    function test_borrow_rateScalesWithReservedUtilization() public {
        // reserved = totalMaxPayout = 9 * 1988 = 17,892 USDG on a 1M vault: utilization
        // 1.7892%; kB = 0.01%/h at 100%: borrowX per hour = 1e14 * 0.017892 * mark(1.0).
        vault.setTotalAssetsOverride(1_000_000e6);
        open(alice, MEME, true, 2_000e6, 600);
        vm.warp(block.timestamp + 1 hours);
        engine.pokeFunding(MEME);
        PerpTypes.MarketAggregates memory agg = aggOf(MEME);
        // utilization1e18 = 17892e6 * 1e18 / 1_000_000e6 = 17892e12.
        // rate = 1e14 * 17892e12 / 1e18 = 1.7892e12; delta = rate * 1.0 mark over one hour.
        assertEq(agg.borrowX1e18, 1_789_200_000_000);
    }

    function test_funding_dragsLiquidationPriceTowardEntry() public {
        open(alice, MEME, true, 2_000e6, 600); // lone long: pays funding forever
        uint256 pLiq0 = engine.liquidationPrice(MEME, alice, true);
        vm.warp(block.timestamp + 12 hours);
        uint256 pLiq1 = engine.liquidationPrice(MEME, alice, true);
        vm.warp(block.timestamp + 12 hours);
        uint256 pLiq2 = engine.liquidationPrice(MEME, alice, true);
        assertGt(pLiq1, pLiq0, "half a day of funding lifts the long liq price");
        assertGt(pLiq2, pLiq1, "and it keeps drifting toward entry");
        assertLt(pLiq2, 1e18, "still below entry after one day at full skew");
    }

    function test_pokeFunding_permissionlessAndCachesMark() public {
        open(alice, MEME, true, 2_000e6, 600);
        oracle.setLive(MEME, 11e17);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(makeAddr("randomKeeper"));
        engine.pokeFunding(MEME);
        PerpTypes.MarketAggregates memory agg = aggOf(MEME);
        assertEq(agg.cachedMark1e18, 11e17, "mark cached for vault NAV");
        assertEq(agg.cachedMarkAt, block.timestamp);
        assertEq(agg.lastAccrual, block.timestamp);
    }

    function test_equityOf_reflectsPendingFunding() public {
        open(alice, MEME, true, 2_000e6, 600);
        int256 eq0 = engine.equityOf(MEME, alice, true);
        assertEq(eq0, int256(1_988e6), "entry equity is net margin");
        vm.warp(block.timestamp + 24 hours);
        int256 eq1 = engine.equityOf(MEME, alice, true);
        assertLt(eq1, eq0, "pending funding erodes previewed equity");
        (int256 fund, uint256 bor) = engine.pendingOwedOf(MEME, alice, true);
        assertEq(eq1, eq0 - fund - int256(bor), "equity = margin minus pending owed");
    }

    function test_marketTraderPnl_navViewClampsAndSigns() public {
        open(alice, MEME, true, 2_000e6, 600);
        open(bob, MEME, false, 1_000e6, 600);
        oracle.setLive(MEME, 11e17);
        engine.pokeFunding(MEME); // refresh the cached mark to 1.10
        (int256 pnl,) = engine.marketTraderPnlUsdg(MEME);
        // longs +10% of 11928 = +1192.8; shorts minus 10% of 5964 = minus 596.4.
        assertEq(pnl, int256(1_192_800_000) - int256(596_400_000));
    }
}
