// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";
import {IPitVault} from "../../src/perp/interfaces/IPitVault.sol";
import {IPerpRiskConfig} from "../../src/perp/interfaces/IPerpRiskConfig.sol";
import {IOracleRouterVaultView} from "../../src/perp/interfaces/IPerpVaultDeps.sol";
import {PitVault} from "../../src/perp/PitVault.sol";
import {PerpRiskConfig} from "../../src/perp/PerpRiskConfig.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockOracleRouter} from "../mocks/MockOracleRouter.sol";
import {MockPerpEngine} from "../mocks/MockPerpEngine.sol";

contract PitVaultTest is Test {
    PitVault internal vault;
    PerpRiskConfig internal config;
    MockOracleRouter internal router;
    MockPerpEngine internal engine;
    MockUSDG internal usdg;

    address internal constant TIMELOCK = address(0x7157);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant RANDO = address(0xBEEF);
    address internal constant TRADER = address(0x7124);
    address internal constant MKT = address(0xAAA1);

    function setUp() public {
        usdg = new MockUSDG();
        router = new MockOracleRouter();
        config = new PerpRiskConfig(IOracleRouter(address(router)), TIMELOCK);
        vault = new PitVault(
            IERC20(address(usdg)), IOracleRouterVaultView(address(router)), IPerpRiskConfig(address(config)), TIMELOCK
        );
        engine = new MockPerpEngine(IERC20(address(usdg)));
        engine.setVault(IPitVault(address(vault)));
        vm.prank(TIMELOCK);
        vault.setEngine(address(engine));

        usdg.mint(ALICE, 10_000_000e6);
        usdg.mint(BOB, 10_000_000e6);
        vm.prank(ALICE);
        usdg.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        usdg.approve(address(vault), type(uint256).max);
    }

    /// @dev Lift the deposit epoch cap for tests that need TVL above the bootstrap floor fast.
    function _openDepositCap() internal {
        vm.prank(TIMELOCK);
        vault.setDepositEpochCap(10_000, 1_000_000_000_000e6);
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(assets, who);
    }

    // ================================ deposit + inflation guard ================================

    function test_depositBelowMinimumReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(PitVault.DepositBelowMinimum.selector);
        vault.deposit(0.5e6, ALICE);
    }

    function test_firstDepositCarvesDeadShares() public {
        uint256 shares = _deposit(ALICE, 100_000e6);
        assertEq(vault.balanceOf(vault.DEAD_ADDRESS()), vault.DEAD_SHARES());
        // net of 10 bps fee: 99,900 USDG at the empty-vault rate of 1e6 raw shares per unit
        assertEq(shares, 99_900e6 * 1e6 - vault.DEAD_SHARES());
        assertEq(vault.balanceOf(ALICE), shares);
        assertEq(vault.totalAssets(), 100_000e6);
    }

    function test_depositFeeAccruesToNav() public {
        uint256 shares = _deposit(ALICE, 100_000e6);
        // Alice minted shares on 99,900 net but the full 100,000 backs the supply, so her
        // redeemable value exceeds her net contribution (the fee leaks back pro-rata).
        uint256 value = vault.convertToAssets(shares);
        assertGt(value, 99_900e6);
        assertLt(value, 100_000e6);
    }

    function test_depositEpochCap() public {
        _deposit(ALICE, 100_000e6); // exactly the bootstrap floor
        vm.prank(BOB);
        vm.expectRevert(PitVault.DepositEpochCapExceeded.selector);
        vault.deposit(1e6, BOB);
        assertEq(vault.maxDeposit(BOB), 0);
        skip(24 hours);
        // fresh epoch: cap = max(20% of 100k, 100k floor) = 100k
        assertEq(vault.maxDeposit(BOB), 100_000e6);
        _deposit(BOB, 50_000e6);
    }

    function test_disabledErc4626Doors() public {
        _deposit(ALICE, 1_000e6);
        vm.startPrank(ALICE);
        vm.expectRevert(PitVault.MintDisabledUseDeposit.selector);
        vault.mint(1e12, ALICE);
        vm.expectRevert(PitVault.ExitDisabledUseQueue.selector);
        vault.withdraw(1e6, ALICE, ALICE);
        vm.expectRevert(PitVault.ExitDisabledUseQueue.selector);
        vault.redeem(1e12, ALICE, ALICE);
        vm.stopPrank();
        assertEq(vault.maxMint(ALICE), 0);
        assertEq(vault.maxWithdraw(ALICE), 0);
        assertEq(vault.maxRedeem(ALICE), 0);
    }

    function test_inflationAttackIsEconomicallyDead() public {
        address attacker = RANDO;
        usdg.mint(attacker, 2_000_000e6);
        vm.startPrank(attacker);
        usdg.approve(address(vault), type(uint256).max);
        uint256 attackerShares = vault.deposit(1e6, attacker); // minimum first deposit
        usdg.transfer(address(vault), 1_000_000e6); // donation inflation attempt
        vm.stopPrank();

        uint256 victimShares = _deposit(ALICE, 100e6);
        assertGt(victimShares, 0, "victim must receive shares");

        uint256 attackerValue = vault.convertToAssets(attackerShares);
        uint256 attackerSpent = 1e6 + 1_000_000e6;
        assertLt(attackerValue, attackerSpent, "attacker must not profit");
        // Dead + virtual shares capture a material slice of the donation (~0.1% here, ~1,000
        // USDG), so the attack is strictly negative EV before even counting the exit queue + fee.
        assertLe(attackerValue, attackerSpent - 500e6, "guard must impose a real cost");
        // Victim keeps at least 99% of the deposit despite the attempted inflation.
        assertGe(vault.convertToAssets(victimShares), 99e6, "victim value gutted");
    }

    function testFuzz_inflationAttackNeverProfits(uint256 donation, uint256 victimDeposit) public {
        donation = bound(donation, 1, 1_000_000e6);
        victimDeposit = bound(victimDeposit, 1e6, 90_000e6);
        address attacker = RANDO;
        usdg.mint(attacker, 1e6 + donation);
        vm.startPrank(attacker);
        usdg.approve(address(vault), type(uint256).max);
        uint256 attackerShares = vault.deposit(1e6, attacker);
        usdg.transfer(address(vault), donation);
        vm.stopPrank();
        _deposit(ALICE, victimDeposit);
        assertLe(vault.convertToAssets(attackerShares), 1e6 + donation, "inflation attack turned a profit");
    }

    // ================================ withdraw queue ================================

    function test_requestLocksShares() public {
        uint256 shares = _deposit(ALICE, 100_000e6);
        uint256 part = shares / 10;
        vm.prank(ALICE);
        vault.requestWithdraw(part);
        assertEq(vault.balanceOf(ALICE), shares - part);
        assertEq(vault.balanceOf(address(vault)), part);
        (uint128 qShares, uint64 qEpoch) = vault.requestOf(ALICE);
        assertEq(qShares, part);
        assertEq(qEpoch, 0);
    }

    function test_settleEpochRequiresMaturity() public {
        _deposit(ALICE, 100_000e6);
        vm.expectRevert(PitVault.EpochNotMature.selector);
        vault.settleEpoch(0);
    }

    function test_claimBeforeSettlementWindowReverts() public {
        uint256 shares = _deposit(ALICE, 100_000e6);
        vm.startPrank(ALICE);
        vault.requestWithdraw(shares / 10);
        vm.expectRevert(PitVault.NothingToClaim.selector);
        vault.claim();
        vm.stopPrank();
    }

    function test_queueHappyPath() public {
        uint256 shares = _deposit(ALICE, 100_000e6);
        uint256 part = shares / 10;
        vm.prank(ALICE);
        vault.requestWithdraw(part);
        skip(25 hours);
        uint256 expectedGross = vault.convertToAssets(part);
        uint256 expectedNet = expectedGross - (expectedGross * 10) / 10_000;
        vault.settleEpoch(0); // permissionless
        uint256 balBefore = usdg.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 got = vault.claim();
        assertApproxEqAbs(got, expectedNet, 2);
        assertEq(usdg.balanceOf(ALICE) - balBefore, got);
        (uint128 qShares,) = vault.requestOf(ALICE);
        assertEq(qShares, 0, "request fully resolved");
    }

    function test_lazySettlementViaClaim() public {
        uint256 shares = _deposit(ALICE, 100_000e6);
        vm.prank(ALICE);
        vault.requestWithdraw(shares / 10);
        skip(25 hours);
        vm.prank(ALICE);
        uint256 got = vault.claim(); // nobody called settleEpoch
        assertGt(got, 0);
    }

    function test_pricesAtSettlementNotRequestTime() public {
        uint256 shares = _deposit(ALICE, 100_000e6);
        uint256 part = shares / 5; // 20%, inside the 25% epoch cap
        vm.prank(ALICE);
        vault.requestWithdraw(part);
        // A trader loss lands AFTER the request: the queued shares must capture it.
        usdg.mint(address(engine), 50_000e6);
        engine.doLoss(50_000e6);
        skip(25 hours);
        vm.prank(ALICE);
        uint256 got = vault.claim();
        // 20% of a vault now worth ~150k: ~30k, far above 20% of the request-time 100k.
        assertGt(got, 25_000e6, "queued exit did not capture post-request NAV move");
    }

    function test_epochCapProRataAndRoll() public {
        _openDepositCap();
        uint256 sharesA = _deposit(ALICE, 50_000e6);
        uint256 sharesB = _deposit(BOB, 50_000e6);
        // each requests 30% of own shares: combined ~30% of supply > 25% cap
        vm.prank(ALICE);
        vault.requestWithdraw((sharesA * 30) / 100);
        vm.prank(BOB);
        vault.requestWithdraw((sharesB * 30) / 100);
        skip(25 hours);
        vault.settleEpoch(0);

        vm.prank(ALICE);
        uint256 gotA1 = vault.claim();
        vm.prank(BOB);
        uint256 gotB1 = vault.claim();
        // pro-rata: equal stakes get equal fills, bounded by the 25% cap
        assertApproxEqRel(gotA1, gotB1, 0.005e18);
        uint256 capAssets = (100_000e6 * 2500) / 10_000;
        assertLe(gotA1 + gotB1, capAssets + 2, "epoch cap breached");
        // remainder rolled: still queued
        (uint128 remA,) = vault.requestOf(ALICE);
        assertGt(remA, 0, "remainder must roll");

        skip(24 hours);
        vm.prank(ALICE);
        uint256 gotA2 = vault.claim(); // lazily settles the rolled epoch
        vm.prank(BOB);
        uint256 gotB2 = vault.claim();
        // both users eventually receive ~30% of 100k minus the 10 bps exit fee
        assertApproxEqRel(gotA1 + gotA2 + gotB1 + gotB2, 29_970e6, 0.01e18);
        (remA,) = vault.requestOf(ALICE);
        assertEq(remA, 0);
    }

    function test_solvencyFloorLimitsFulfilment() public {
        vm.startPrank(TIMELOCK);
        config.setMarketReserveCapBps(10_000);
        vault.setNewMarketRamp(10_000, 0);
        vm.stopPrank();
        uint256 shares = _deposit(ALICE, 100_000e6);
        engine.doReserve(MKT, 70_000e6);
        // floor = 1.2 * 70k = 84k; headroom = 16k
        vm.prank(ALICE);
        vault.requestWithdraw(shares / 5); // ~20k gross
        skip(25 hours);
        vm.prank(ALICE);
        uint256 got = vault.claim();
        assertLe(got, 16_000e6, "solvency floor breached");
        assertGt(got, 15_000e6, "fulfilment should reach the floor headroom");
        (uint128 rem,) = vault.requestOf(ALICE);
        assertGt(rem, 0, "excess must roll, not vanish");

        // reserves released: the rolled remainder pays out next epoch
        engine.doRelease(MKT, 70_000e6);
        skip(24 hours);
        vm.prank(ALICE);
        uint256 got2 = vault.claim();
        assertGt(got2, 0);
    }

    function test_solvencyFloorZeroHeadroomBlocksAll() public {
        vm.startPrank(TIMELOCK);
        config.setMarketReserveCapBps(10_000);
        vault.setNewMarketRamp(10_000, 0);
        vm.stopPrank();
        uint256 shares = _deposit(ALICE, 100_000e6);
        engine.doReserve(MKT, 80_000e6); // floor 96k > TVL 100k? headroom = 4k
        vm.prank(ALICE);
        vault.requestWithdraw(shares / 5);
        skip(25 hours);
        vm.prank(ALICE);
        uint256 got = vault.claim();
        assertLe(got, 4_000e6, "fulfilment exceeded solvency headroom");
    }

    // ================================ NAV ================================

    function _agg(
        uint128 longSize,
        uint128 longCost,
        uint128 shortSize,
        uint128 shortCost,
        uint128 longMargin,
        uint128 shortMargin,
        uint128 maxPayout,
        uint128 cachedMark,
        uint64 cachedAt
    ) internal pure returns (PerpTypes.MarketAggregates memory a) {
        a.totalLongSize1e18 = longSize;
        a.totalLongCost = longCost;
        a.totalShortSize1e18 = shortSize;
        a.totalShortCost = shortCost;
        a.totalLongMargin = longMargin;
        a.totalShortMargin = shortMargin;
        a.totalMaxPayout = maxPayout;
        a.cachedMark1e18 = cachedMark;
        a.cachedMarkAt = cachedAt;
    }

    function test_navSubtractsTraderProfit() public {
        _deposit(ALICE, 100_000e6);
        // longs: 1000 tokens at entry $1 (cost 1000 USDG), margin 200, cap 1800
        engine.setMarketState(
            MKT, _agg(1000e18, 1000e6, 0, 0, 200e6, 0, 1800e6, 1e18, uint64(block.timestamp))
        );
        router.setPrice(MKT, 1.5e18, Types.PriceStatus.OK);
        assertEq(vault.aggTraderUnrealizedPnl(), 500e6);
        assertEq(vault.totalAssets(), 100_000e6 - 500e6);
    }

    function test_navProfitClampedAtMaxPayout() public {
        _deposit(ALICE, 100_000e6);
        engine.setMarketState(
            MKT, _agg(1000e18, 1000e6, 0, 0, 200e6, 0, 1800e6, 1e18, uint64(block.timestamp))
        );
        router.setPrice(MKT, 10e18, Types.PriceStatus.OK); // raw uPnL +9000, cap 1800
        assertEq(vault.aggTraderUnrealizedPnl(), 1800e6);
        assertEq(vault.totalAssets(), 100_000e6 - 1800e6);
    }

    function test_navLossClampedAtMargin() public {
        _deposit(ALICE, 100_000e6);
        engine.setMarketState(
            MKT, _agg(1000e18, 1000e6, 0, 0, 200e6, 0, 1800e6, 1e18, uint64(block.timestamp))
        );
        router.setPrice(MKT, 0.1e18, Types.PriceStatus.OK); // raw uPnL -900, margin clamp -200
        assertEq(vault.aggTraderUnrealizedPnl(), -200e6);
        assertEq(vault.totalAssets(), 100_000e6 + 200e6);
    }

    function test_navShortSide() public {
        _deposit(ALICE, 100_000e6);
        // shorts: 1000 tokens sold at $1, margin 300
        engine.setMarketState(
            MKT, _agg(0, 0, 1000e18, 1000e6, 0, 300e6, 2700e6, 1e18, uint64(block.timestamp))
        );
        router.setPrice(MKT, 0.6e18, Types.PriceStatus.OK); // shorts up 400
        assertEq(vault.aggTraderUnrealizedPnl(), 400e6);
        router.setPrice(MKT, 1.5e18, Types.PriceStatus.OK); // shorts down 500, clamp -300
        assertEq(vault.aggTraderUnrealizedPnl(), -300e6);
    }

    function test_navUsesCachedMarkWhenPeekBlocked() public {
        _deposit(ALICE, 100_000e6);
        engine.setMarketState(
            MKT, _agg(1000e18, 1000e6, 0, 0, 500e6, 0, 9000e6, 2e18, uint64(block.timestamp))
        );
        router.setPrice(MKT, 1.5e18, Types.PriceStatus.STALE);
        // peek blocked: cached mark $2 drives uPnL = +1000
        assertEq(vault.aggTraderUnrealizedPnl(), 1000e6);
        // an outage never zeroes the contribution (that would inflate NAV)
        router.setPrice(MKT, 0, Types.PriceStatus.UNAVAILABLE);
        assertEq(vault.aggTraderUnrealizedPnl(), 1000e6);
    }

    function test_navMarkStaleFlag() public {
        _deposit(ALICE, 100_000e6);
        engine.setMarketState(
            MKT, _agg(1000e18, 1000e6, 0, 0, 500e6, 0, 9000e6, 2e18, uint64(block.timestamp))
        );
        router.setPrice(MKT, 1.5e18, Types.PriceStatus.OK);
        assertFalse(vault.navMarkStale());
        router.setPrice(MKT, 1.5e18, Types.PriceStatus.STALE);
        assertFalse(vault.navMarkStale(), "cache still fresh");
        skip(16 minutes);
        assertTrue(vault.navMarkStale(), "blocked peek + expired cache must flag");
    }

    // ================================ B8: settlement staleness gate ================================

    /// @dev Reproduce the pa-vaultshares S1 scenario against the real vault: a standing-queued LP
    ///      request plus an open-interest market that goes stale (oracle gap: peek blocked past
    ///      maxMarkAge). The aggregate loss clamp overstates NAV during that window, so settleEpoch
    ///      MUST revert rather than let the queued LP crystallize the rich price and socialize the
    ///      uncollectable bad debt. Once the mark is fresh again settlement proceeds normally.
    function test_settleEpochRevertsWhileMarkStale() public {
        uint256 shares = _deposit(ALICE, 100_000e6);
        // A net-long market with a position underwater past its own margin (the S1 overstatement).
        engine.setMarketState(
            MKT, _agg(1000e18, 1000e6, 0, 0, 200e6, 0, 1800e6, 1e18, uint64(block.timestamp))
        );
        router.setPrice(MKT, 1e18, Types.PriceStatus.OK);

        // The exiter pre-queues a request, then the oracle gaps (peek blocked). While the cached
        // mark is still fresh (< maxMarkAge) settlement is allowed; once it ages past maxMarkAge
        // the settlement gate slams shut.
        vm.prank(ALICE);
        vault.requestWithdraw(shares / 5); // 20%, inside the epoch cap
        skip(25 hours); // epoch matures; the cached mark is now old anyway
        router.setPrice(MKT, 1e18, Types.PriceStatus.STALE); // oracle gap: peek blocked
        assertTrue(vault.settlementPaused(), "gate open: stale cached mark past maxMarkAge");
        vm.expectRevert(PitVault.SettlementPaused.selector);
        vault.settleEpoch(0);

        // Mark fresh again: the gate clears and settlement crystallizes at the honest NAV.
        router.setPrice(MKT, 1e18, Types.PriceStatus.OK);
        assertFalse(vault.settlementPaused(), "gate closed once the mark is fresh");
        vault.settleEpoch(0);
        (,,,, bool settled) = vault.epochs(0);
        assertTrue(settled, "settlement proceeds when the mark is fresh");
    }

    /// @dev The other S1 trigger: the mark stays FRESH but the spot-vs-TWAP deviation breaker is
    ///      tripped, so opens AND liquidations are blocked and an underwater-past-margin position
    ///      sits uncollected (the aggregate loss clamp still overstates NAV). Settlement must be
    ///      gated on the deviation breaker too, not only on cached-mark staleness.
    function test_settleEpochRevertsWhileDeviationBreakerTripped() public {
        uint256 shares = _deposit(ALICE, 100_000e6);
        engine.setMarketState(
            MKT, _agg(1000e18, 1000e6, 0, 0, 200e6, 0, 1800e6, 1e18, uint64(block.timestamp))
        );
        router.setPrice(MKT, 1e18, Types.PriceStatus.OK); // mark stays fresh throughout
        vm.prank(ALICE);
        vault.requestWithdraw(shares / 5);
        skip(25 hours);

        router.setOpeningDenied(MKT, true, 1); // deviation breaker: liquidations blocked
        assertFalse(vault.navMarkStale(), "mark itself is fresh: navMarkStale does NOT flag");
        assertTrue(vault.settlementPaused(), "gate open: deviation breaker tripped");
        vm.expectRevert(PitVault.SettlementPaused.selector);
        vault.settleEpoch(0);

        router.setOpeningDenied(MKT, false, 0);
        assertFalse(vault.settlementPaused(), "gate closed once the breaker resets");
        vault.settleEpoch(0);
        (,,,, bool settled) = vault.epochs(0);
        assertTrue(settled, "settlement proceeds once the breaker resets");
    }

    /// @dev The lazy settlement path (claim -> _resolve -> _settleEpoch) is gated too: a claim
    ///      during a stale window defers the NEW settlement (leaves the request pending) but must
    ///      still pay out any ALREADY-crystallized claim (money set aside as liability before the
    ///      gap). Once fresh, the deferred settlement completes.
    function test_lazySettlementDefersButPriorClaimStillPays() public {
        uint256 shares = _deposit(ALICE, 100_000e6);
        engine.setMarketState(
            MKT, _agg(1000e18, 1000e6, 0, 0, 200e6, 0, 1800e6, 1e18, uint64(block.timestamp))
        );
        router.setPrice(MKT, 1e18, Types.PriceStatus.OK);
        vm.prank(ALICE);
        vault.requestWithdraw(shares / 5);
        skip(25 hours);

        // Gap: the lazy claim path must not settle the matured epoch, and there is nothing
        // crystallized yet, so it reverts NothingToClaim (the request stays pending, unsettled).
        router.setPrice(MKT, 1e18, Types.PriceStatus.STALE);
        skip(1); // cached mark now older than maxMarkAge
        vm.prank(ALICE);
        vm.expectRevert(PitVault.NothingToClaim.selector);
        vault.claim();
        (uint128 pending,) = vault.requestOf(ALICE);
        assertEq(pending, uint128(shares / 5), "request left pending, not settled, during the gap");

        // Fresh again: lazy settlement resolves and pays.
        router.setPrice(MKT, 1e18, Types.PriceStatus.OK);
        vm.prank(ALICE);
        uint256 got = vault.claim();
        assertGt(got, 0, "deferred settlement completes once the mark is fresh");
    }

    // ================================ engine-only surface ================================

    function test_engineSurfaceAccessControl() public {
        vm.startPrank(RANDO);
        vm.expectRevert(PitVault.NotEngine.selector);
        vault.reservePayout(MKT, 1);
        vm.expectRevert(PitVault.NotEngine.selector);
        vault.releasePayout(MKT, 1);
        vm.expectRevert(PitVault.NotEngine.selector);
        vault.settleTraderWin(RANDO, 1);
        vm.expectRevert(PitVault.NotEngine.selector);
        vault.settleFundingCredit(RANDO, 1); // B9 channel is engine-only too
        vm.expectRevert(PitVault.NotEngine.selector);
        vault.settleTraderLoss(1);
        vm.stopPrank();
    }

    /// @notice B2a: drawdownReferenceAssets = totalAssets + crystallized withdraw liability, so a
    ///         settled LP exit (which lowers totalAssets and raises the liability together) leaves
    ///         the reference unchanged for the engine's drawdown circuit.
    function test_drawdownReferenceAddsBackClaimLiability() public {
        uint256 shares = _deposit(ALICE, 100_000e6);
        assertEq(vault.drawdownReferenceAssets(), vault.totalAssets(), "no liability yet");
        vm.prank(ALICE);
        vault.requestWithdraw(shares / 5); // 20%, inside the epoch cap
        skip(25 hours);
        vault.settleEpoch(0); // crystallizes ~20% into totalClaimLiability
        assertGt(vault.totalClaimLiability(), 0, "liability crystallized");
        // The reference adds the liability back: the exit did not shrink the drawdown anchor.
        assertEq(
            vault.drawdownReferenceAssets(),
            vault.totalAssets() + vault.totalClaimLiability(),
            "reference = totalAssets + claim liability"
        );
    }

    /// @notice B9: a funding credit is paid on the unbounded channel (not clamped by totalReserved).
    ///         RH1: the recipient must be the engine itself (the engine settles onward).
    function test_settleFundingCreditNotBoundedByReserve() public {
        vm.prank(TIMELOCK);
        vault.setNewMarketRamp(10_000, 0);
        _deposit(ALICE, 100_000e6);
        engine.doReserve(MKT, 1_000e6); // small reservation
        uint256 before = usdg.balanceOf(address(engine));
        // A funding credit far larger than totalReserved still pays (settleTraderWin would revert).
        engine.doFundingCredit(address(engine), 10_000e6);
        assertEq(usdg.balanceOf(address(engine)) - before, 10_000e6, "funding credit paid unbounded by reserve");
    }

    /// @notice RH1: settleFundingCredit asserts to == engine inside the vault, so even a future
    ///         (buggy or compromised) engine change can never route the unbounded funding-credit
    ///         channel straight to a user address.
    function test_settleFundingCreditRecipientMustBeEngine() public {
        _deposit(ALICE, 100_000e6);
        vm.expectRevert(PitVault.CreditRecipientNotEngine.selector);
        engine.doFundingCredit(TRADER, 1e6);
        vm.expectRevert(PitVault.CreditRecipientNotEngine.selector);
        engine.doFundingCredit(address(0), 1e6);
    }

    function test_setEngineOnceOnly() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(PitVault.EngineAlreadySet.selector);
        vault.setEngine(RANDO);
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDO));
        vault.setEngine(RANDO);
    }

    function test_utilizationCap() public {
        vm.startPrank(TIMELOCK);
        config.setMarketReserveCapBps(10_000);
        vault.setNewMarketRamp(10_000, 0);
        vm.stopPrank();
        _deposit(ALICE, 100_000e6);
        engine.doReserve(MKT, 80_000e6); // exactly 80% of TVL: allowed
        vm.expectRevert(PitVault.UtilizationCapExceeded.selector);
        engine.doReserve(MKT, 1);
        assertEq(vault.totalReserved(), 80_000e6);
    }

    function test_marketReserveCapTvlLeg() public {
        vm.prank(TIMELOCK);
        vault.setNewMarketRamp(10_000, 0); // isolate the 10% TVL leg from the ramp
        _deposit(ALICE, 100_000e6);
        engine.doReserve(MKT, 10_000e6); // exactly 10% of TVL
        vm.expectRevert(PitVault.MarketReserveCapExceeded.selector);
        engine.doReserve(MKT, 1);
        // a second market has its own cap
        engine.doReserve(address(0xAAA2), 5_000e6);
    }

    function test_marketReserveCapRouterLeg() public {
        vm.prank(TIMELOCK);
        vault.setNewMarketRamp(10_000, 0);
        _deposit(ALICE, 100_000e6);
        // B1: the vault reads the engine's FROZEN cost-to-move snapshot, not the router's live
        // value, so the cap is set on the engine (mirroring PerpEngine.listMarket).
        engine.setMarketMaxPayoutCap1e18(MKT, 5_000e18); // cost-to-move cap $5k < 10% TVL ($10k)
        engine.doReserve(MKT, 5_000e6);
        vm.expectRevert(PitVault.MarketReserveCapExceeded.selector);
        engine.doReserve(MKT, 1);
        assertEq(vault.marketReserveCapOf(MKT), 5_000e6);
    }

    function test_newMarketRamp_linearOnePercentPerDay() public {
        _deposit(ALICE, 100_000e6);
        // Economics v2 launch defaults: LINEAR 1%/day of TVL over 14 days, anchored at the
        // first reservation. Day one: 1% = 1k.
        engine.doReserve(MKT, 1_000e6);
        vm.expectRevert(PitVault.MarketReserveCapExceeded.selector);
        engine.doReserve(MKT, 1);
        // Day three (2 full days elapsed): 3% = 3k total.
        skip(2 days);
        engine.doReserve(MKT, 2_000e6);
        vm.expectRevert(PitVault.MarketReserveCapExceeded.selector);
        engine.doReserve(MKT, 1);
        // Past the window: up to the 10% TVL leg (10k total).
        skip(12 days + 1);
        engine.doReserve(MKT, 7_000e6);
        vm.expectRevert(PitVault.MarketReserveCapExceeded.selector);
        engine.doReserve(MKT, 1);
    }

    function test_releaseBounds() public {
        vm.prank(TIMELOCK);
        vault.setNewMarketRamp(10_000, 0);
        _deposit(ALICE, 100_000e6);
        engine.doReserve(MKT, 5_000e6);
        vm.expectRevert(PitVault.ReleaseExceedsReserved.selector);
        engine.doRelease(MKT, 5_001e6);
        engine.doRelease(MKT, 5_000e6);
        assertEq(vault.totalReserved(), 0);
        assertEq(vault.reservedBy(MKT), 0);
    }

    function test_settleTraderWinPaysFromReserves() public {
        vm.prank(TIMELOCK);
        vault.setNewMarketRamp(10_000, 0);
        _deposit(ALICE, 100_000e6);
        engine.doReserve(MKT, 5_000e6);
        engine.doWin(TRADER, 3_000e6);
        assertEq(usdg.balanceOf(TRADER), 3_000e6);
        vm.expectRevert(PitVault.WinExceedsReserved.selector);
        engine.doWin(TRADER, 5_001e6);
    }

    function test_settleTraderLossPullsFromEngine() public {
        _deposit(ALICE, 100_000e6);
        usdg.mint(address(engine), 10_000e6);
        engine.doLoss(10_000e6);
        assertEq(vault.totalAssets(), 110_000e6);
    }

    // ================================ economics v2: revenue receivers ================================

    /// @notice Fee and liquidation revenue land in vault cash and raise NAV PRO-RATA: share
    ///         price rises, total supply is untouched (no shares minted), and the two
    ///         transparency counters track exactly.
    function test_receiveRevenue_raisesNavProRataNoMint() public {
        _deposit(ALICE, 100_000e6);
        uint256 supplyBefore = vault.totalSupply();
        uint256 pricePerShareBefore = vault.convertToAssets(1e12);
        usdg.mint(address(engine), 1_000e6);

        engine.doFeeRevenue(600e6);
        engine.doLiqRevenue(400e6);

        assertEq(vault.cumulativeFeeRevenue(), 600e6, "fee counter");
        assertEq(vault.cumulativeLiquidationRevenue(), 400e6, "liquidation counter");
        assertEq(vault.totalAssets(), 101_000e6, "NAV up by exactly the revenue");
        assertEq(vault.totalSupply(), supplyBefore, "no shares minted");
        assertGt(vault.convertToAssets(1e12), pricePerShareBefore, "share price rose pro-rata");
    }

    /// @notice The receivers are engine-only and zero-amount reverting; the pull leaves no
    ///         residue on the engine (conservation: the engine's USDG moved into vault cash).
    function test_receiveRevenue_onlyEngineNonZeroAndPulls() public {
        vm.prank(RANDO);
        vm.expectRevert(PitVault.NotEngine.selector);
        vault.receiveFeeRevenue(1e6);
        vm.prank(RANDO);
        vm.expectRevert(PitVault.NotEngine.selector);
        vault.receiveLiquidationRevenue(1e6);
        vm.expectRevert(PitVault.ZeroAmount.selector);
        engine.doFeeRevenue(0);
        vm.expectRevert(PitVault.ZeroAmount.selector);
        engine.doLiqRevenue(0);

        usdg.mint(address(engine), 5e6);
        engine.doFeeRevenue(5e6);
        assertEq(usdg.balanceOf(address(engine)), 0, "revenue pulled from the engine");
        assertEq(usdg.balanceOf(address(vault)), 5e6, "revenue sits in vault cash");
    }

    // ================================ params ================================

    function test_paramSetterBoundsAndAuth() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(PitVault.ParamOutOfBounds.selector);
        vault.setVaultFees(101, 10);
        vault.setVaultFees(20, 20);
        assertEq(vault.depositFeeBps(), 20);

        vm.expectRevert(PitVault.ParamOutOfBounds.selector);
        vault.setWithdrawEpochCapBps(0);
        vault.setWithdrawEpochCapBps(5000);

        vm.expectRevert(PitVault.ParamOutOfBounds.selector);
        vault.setSolvencyFloorBps(9_999);
        // B10: the settable MAX is lowered from 3.0x to 1.5x so a mis-set owner cannot brick LP
        // withdrawals across the normal utilization band.
        vm.expectRevert(PitVault.ParamOutOfBounds.selector);
        vault.setSolvencyFloorBps(15_001);
        vault.setSolvencyFloorBps(15_000); // the new maximum is valid

        vm.expectRevert(PitVault.ParamOutOfBounds.selector);
        vault.setMaxMarkAge(0);
        vault.setMaxMarkAge(30 minutes);
        vm.stopPrank();

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDO));
        vault.setVaultFees(10, 10);
    }

    function test_shareDecimalsIncludeOffset() public view {
        assertEq(vault.decimals(), 12); // 6 asset decimals + offset 6
    }

    // ================================ fuzz: queue conservation ================================

    /// @dev No sequence of request/settle/claim can extract more than was deposited when the
    ///      vault saw no trading PnL: fees make the round trip strictly lossy.
    function testFuzz_queueRoundTripNeverProfits(uint256 amount, uint256 fraction) public {
        _openDepositCap();
        amount = bound(amount, 1e6, 1_000_000e6);
        fraction = bound(fraction, 1, 100);
        uint256 shares = _deposit(ALICE, amount);
        uint256 part = (shares * fraction) / 100;
        if (part == 0) return;
        vm.prank(ALICE);
        vault.requestWithdraw(part);
        uint256 claimed = 0;
        for (uint256 i = 0; i < 12; ++i) {
            skip(24 hours);
            vm.prank(ALICE);
            try vault.claim() returns (uint256 got) {
                claimed += got;
            } catch {}
            (uint128 rem,) = vault.requestOf(ALICE);
            if (rem == 0) break;
        }
        assertLe(claimed, amount, "queue round trip extracted free money");
    }
}
