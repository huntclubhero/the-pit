// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CasinoTestBase} from "./CasinoTestBase.t.sol";
import {Jackpot} from "../../src/casino/Jackpot.sol";
import {MockVRFCoordinator} from "../mocks/MockVRFCoordinator.sol";
import {CasinoMockUSDG} from "../mocks/CasinoMockUSDG.sol";

/// @title Jackpot accrual, points-weighted daily/weekly draws, rollover, pull-payment, and recovery
/// @notice Post audit fix C1 the daily mini-drop is points-weighted exactly like the weekly
///         mega-drop; the uniform Pit Drop entrant draw is gone. Payouts are pull-payment credits
///         (audit fix D2), duplicate request ids are rejected and a stuck draw kind is recoverable
///         via the owner escape hatch (audit fix C5).
contract JackpotTest is CasinoTestBase {
    address internal alice;
    address internal bob;

    function setUp() public override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function referenceSelect(uint256 epoch, uint256 target) internal view returns (address) {
        uint256 n = points.checkpointCount(epoch);
        for (uint256 i = 0; i < n; i++) {
            (address user, uint256 cumulative) = points.checkpointAt(epoch, i);
            if (cumulative > target) return user;
        }
        return address(0);
    }

    /// @dev Seeds current-epoch points via a fill (alice 10e18, bob 20e18), crosses a day
    ///      boundary within the same epoch, and starts a daily draw. Returns the epoch and
    ///      request id.
    function seedAndStartDaily() internal returns (uint256 requestId, uint256 epoch) {
        fill(alice, bob, bob, tokenB, 100e6);
        epoch = points.currentEpoch();
        vm.warp(block.timestamp + 1 days);
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
        requestId = coordinator.requestCount();
    }

    // ===============================================================
    // Accrual
    // ===============================================================

    function test_feeAccrualAndDonations() public {
        usdg.mint(address(jackpot), 700e6);
        assertEq(jackpot.potBalance(), 700e6);
        // Anyone can donate with a plain transfer.
        usdg.mint(alice, 50e6);
        vm.prank(alice);
        usdg.transfer(address(jackpot), 50e6);
        assertEq(jackpot.potBalance(), 750e6);
    }

    // ===============================================================
    // Access control and authority pinning
    // ===============================================================

    function test_fulfill_onlyRecordedCoordinator() public {
        (uint256 requestId,) = seedAndStartDaily();

        MockVRFCoordinator coordinator2 = new MockVRFCoordinator();
        changeJackpotCoordinator(address(coordinator2));

        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        vm.expectRevert(
            abi.encodeWithSelector(Jackpot.OnlyRequestCoordinator.selector, address(coordinator2), address(coordinator))
        );
        coordinator2.fulfill(address(jackpot), requestId, words);

        // Original coordinator still completes the pinned draw.
        fulfillJackpot(requestId, 0);
        assertTrue(jackpot.getDraw(0).fulfilled);
    }

    function test_fulfill_unknownAndDoubleRevert() public {
        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        vm.expectRevert(abi.encodeWithSelector(Jackpot.UnknownRequest.selector, 555));
        coordinator.fulfill(address(jackpot), 555, words);

        (uint256 requestId,) = seedAndStartDaily();
        fulfillJackpot(requestId, 3);
        vm.expectRevert(abi.encodeWithSelector(Jackpot.AlreadyFulfilled.selector, requestId));
        coordinator.fulfill(address(jackpot), requestId, words);
    }

    // ===============================================================
    // Draw timing
    // ===============================================================

    function test_daily_notDueOnDeployDay() public {
        vm.expectRevert(abi.encodeWithSelector(Jackpot.DrawNotDue.selector, Jackpot.DrawKind.DAILY));
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
    }

    function test_daily_oncePerDay() public {
        (uint256 requestId,) = seedAndStartDaily();
        fulfillJackpot(requestId, 0);
        vm.expectRevert(abi.encodeWithSelector(Jackpot.DrawNotDue.selector, Jackpot.DrawKind.DAILY));
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
    }

    function test_daily_pendingBlocksNextDay() public {
        seedAndStartDaily();
        // Not fulfilled; next day the previous draw is still in flight.
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(Jackpot.DrawPending.selector, Jackpot.DrawKind.DAILY));
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
    }

    function test_weekly_oncePerEpoch() public {
        // Earn points in the current epoch, then cross the boundary.
        fill(alice, bob, bob, tokenB, 100e6);
        uint256 epoch = points.currentEpoch();
        vm.warp((epoch + 1) * 7 days + 1);

        jackpot.startDraw(Jackpot.DrawKind.WEEKLY);
        fulfillJackpot(coordinator.requestCount(), 42);

        vm.expectRevert(abi.encodeWithSelector(Jackpot.DrawNotDue.selector, Jackpot.DrawKind.WEEKLY));
        jackpot.startDraw(Jackpot.DrawKind.WEEKLY);
    }

    // ===============================================================
    // Zero-points rollover
    // ===============================================================

    function test_daily_noPoints_skipsAndRollsPot() public {
        usdg.mint(address(jackpot), 1000e6);
        vm.warp(block.timestamp + 1 days);
        uint256 requestsBefore = coordinator.requestCount();

        vm.expectEmit(true, true, true, true, address(jackpot));
        emit Jackpot.DrawSkipped(Jackpot.DrawKind.DAILY, uint64(block.timestamp / 1 days));
        jackpot.startDraw(Jackpot.DrawKind.DAILY);

        assertEq(coordinator.requestCount(), requestsBefore, "no VRF consumed on skip");
        assertEq(jackpot.potBalance(), 1000e6, "pot rolls forward");
        assertEq(jackpot.drawCount(), 0, "no draw record");
        // The day is consumed.
        vm.expectRevert(abi.encodeWithSelector(Jackpot.DrawNotDue.selector, Jackpot.DrawKind.DAILY));
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
    }

    function test_weekly_emptyEpoch_skipsAndRollsPot() public {
        usdg.mint(address(jackpot), 1000e6);
        uint256 epoch = points.currentEpoch();
        vm.warp((epoch + 1) * 7 days + 1);

        vm.expectEmit(true, true, true, true, address(jackpot));
        emit Jackpot.DrawSkipped(Jackpot.DrawKind.WEEKLY, uint64(epoch));
        jackpot.startDraw(Jackpot.DrawKind.WEEKLY);

        assertEq(jackpot.potBalance(), 1000e6, "pot rolls forward");
        vm.expectRevert(abi.encodeWithSelector(Jackpot.DrawNotDue.selector, Jackpot.DrawKind.WEEKLY));
        jackpot.startDraw(Jackpot.DrawKind.WEEKLY);
    }

    // ===============================================================
    // Daily mini-drop: points-weighted (audit fix C1)
    // ===============================================================

    function test_dailyWeightedDraw_selectionAndPullPayment() public {
        usdg.mint(address(jackpot), 1000e6);
        (uint256 requestId, uint256 epoch) = seedAndStartDaily();
        assertTrue(jackpot.dailyPending());

        // Target 5e18 falls inside alice's first checkpoint [0, 10e18).
        uint256 word = 5e18;
        uint256 potBefore = jackpot.potBalance();
        fulfillJackpot(requestId, word);

        Jackpot.Draw memory draw = jackpot.getDraw(0);
        assertEq(draw.epoch, epoch);
        assertEq(draw.winner, alice);
        assertEq(draw.winner, referenceSelect(epoch, word % points.epochTotal(epoch)));
        assertEq(draw.amount, 100e6, "10% of pot");
        assertFalse(draw.cancelled);

        // Pull payment: credited, not pushed.
        assertEq(jackpot.claimable(alice), 100e6, "winner credited");
        assertEq(usdg.balanceOf(alice), 0, "not pushed");
        assertEq(potBefore - jackpot.potBalance(), 100e6, "pot reduced by the credit");
        assertFalse(jackpot.dailyPending());

        vm.prank(alice);
        jackpot.claim();
        assertEq(usdg.balanceOf(alice), 100e6, "winner withdrew");
        assertEq(jackpot.claimable(alice), 0);
        assertEq(jackpot.potBalance(), 900e6, "pot unchanged by the claim");
    }

    /// @dev C1: a flooder with many tiny fills does NOT gain disproportionate daily-draw win
    ///      probability. The daily draw weights by epoch points, and points track NOTIONAL
    ///      (money at risk), not fill count; under the removed uniform entrant draw the flooder's
    ///      200 slots would have dominated a handful of honest slots.
    function test_daily_floodingBuysNegligibleWinProbability() public {
        address whale = makeAddr("whale");
        address makerH = makeAddr("makerH");
        address attacker = makeAddr("attacker");
        address makerA = makeAddr("makerA");

        // Honest whale: one large fill (1,000,000 USDG notional).
        fill(whale, makerH, makerH, tokenB, 1_000_000e6);
        // Attacker: 200 minimum-size fills (1000 native units each), 200x the fill count.
        for (uint256 i = 0; i < 200; i++) {
            fill(attacker, makerA, makerA, tokenB, 1000);
        }

        uint256 epoch = points.currentEpoch();
        uint256 total = points.epochTotal(epoch);
        uint256 attackerPts = points.epochPointsOf(attacker, epoch);

        // Points are exactly notional * rate for a fresh 1x taker: proportional to money at risk.
        assertEq(attackerPts, uint256(200 * 1000) * points.POINTS_PER_NOTIONAL_UNIT(), "weight tracks notional");
        // Despite 200x the fill count, the attacker's draw weight rounds to under one basis point.
        assertEq(attackerPts * 10_000 / total, 0, "flooding buys < 1bp of win weight");

        // A representative daily draw does not select the attacker.
        usdg.mint(address(jackpot), 1000e6);
        vm.warp(block.timestamp + 1 days);
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
        uint256 requestId = coordinator.requestCount();
        fulfillJackpot(requestId, total / 2);
        assertTrue(jackpot.getDraw(0).winner != attacker, "flooder not selected mid-range");
    }

    // ===============================================================
    // Weekly mega-drop: weighted over the previous epoch
    // ===============================================================

    function testFuzz_weeklyWeightedDraw_matchesReferenceScan(uint256 word) public {
        usdg.mint(address(jackpot), 2000e6);
        address carol = makeAddr("carol");
        fill(alice, bob, bob, tokenB, 300e6);
        fill(carol, bob, carol, tokenB, 100e6);
        uint256 epoch = points.currentEpoch();
        uint256 total = points.epochTotal(epoch);
        assertGt(total, 0);

        // W2-2b: file the epoch's fee inflow while the epoch is still current; the bucket closes
        // at the boundary, so the weekly draw pays only inflow that arrived during its epoch.
        jackpot.syncInflow();
        vm.warp((epoch + 1) * 7 days + 1);
        jackpot.startDraw(Jackpot.DrawKind.WEEKLY);
        uint256 requestId = coordinator.requestCount();

        address expected = referenceSelect(epoch, word % total);
        uint256 potBefore = jackpot.potBalance();
        fulfillJackpot(requestId, word);

        Jackpot.Draw memory draw = jackpot.getDraw(0);
        assertEq(uint8(draw.kind), uint8(Jackpot.DrawKind.WEEKLY));
        assertEq(draw.epoch, epoch, "draws the previous epoch");
        assertEq(draw.winner, expected, "binary selection matches reference scan");
        assertEq(draw.amount, potBefore * 5000 / 10_000, "50% of pot");
        // Pull payment: credited then claimed.
        assertEq(jackpot.claimable(expected), draw.amount, "winner credited");
        assertEq(potBefore - jackpot.potBalance(), draw.amount, "pot reduced by the credit");

        uint256 balBefore = usdg.balanceOf(expected);
        vm.prank(expected);
        jackpot.claim();
        assertEq(usdg.balanceOf(expected) - balBefore, draw.amount, "winner withdrew");
        assertFalse(jackpot.weeklyPending());
    }

    function test_weekly_zeroPot_recordsWinnerZeroAmount() public {
        fill(alice, bob, bob, tokenB, 100e6);
        uint256 epoch = points.currentEpoch();
        vm.warp((epoch + 1) * 7 days + 1);
        jackpot.startDraw(Jackpot.DrawKind.WEEKLY);
        fulfillJackpot(coordinator.requestCount(), 0);
        Jackpot.Draw memory draw = jackpot.getDraw(0);
        assertEq(draw.winner, alice);
        assertEq(draw.amount, 0, "no pot, no payout, draw still recorded");
        assertEq(jackpot.claimable(alice), 0);
    }

    // ===============================================================
    // C4 coordination: creator-share points do not distort the draw
    // ===============================================================

    /// @dev A market creator's passive 5% share is excluded from epoch weighting, so it grants no
    ///      jackpot-draw win probability. Only the creator's own trading (their taker/maker points)
    ///      counts. Here the creator never trades tokenA, so despite earning creator-share points
    ///      they hold zero epoch weight and can never win the draw.
    function test_daily_creatorShareGrantsNoWinProbability() public {
        address creator = makeAddr("creator");
        createMarket(creator, tokenA);

        // Activity on the creator's token: alice and bob trade, the creator passively earns 5%.
        fill(alice, bob, bob, tokenA, 100e6);
        uint256 epoch = points.currentEpoch();

        assertGt(points.pointsOf(creator), 0, "creator earns lifetime credit");
        assertEq(points.epochPointsOf(creator, epoch), 0, "but zero epoch weight");

        // The draw's total equals the traders' weight only; the creator share is not in it.
        assertEq(points.epochTotal(epoch), 30e18, "10e18 taker + 20e18 maker, no creator share");

        usdg.mint(address(jackpot), 1000e6);
        vm.warp(block.timestamp + 1 days);
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
        uint256 requestId = coordinator.requestCount();
        // Sweep the whole weight range: the creator is never the selected winner.
        for (uint256 t = 0; t < 30e18; t += 3e18) {
            assertTrue(referenceSelect(epoch, t) != creator, "creator never covers any weight");
        }
        fulfillJackpot(requestId, 29e18);
        assertTrue(jackpot.getDraw(0).winner != creator, "creator share cannot win the draw");
    }

    // ===============================================================
    // C5: duplicate request id rejection and stuck-draw recovery
    // ===============================================================

    function test_duplicateRequestId_rejectedAndRollsBack() public {
        (uint256 requestId,) = seedAndStartDaily();
        fulfillJackpot(requestId, 0);

        vm.warp(block.timestamp + 1 days);
        fill(alice, bob, bob, tokenB, 100e6); // fresh points; its spin consumes a normal id first

        // Now force the coordinator to hand the already-recorded id back to the DRAW request.
        coordinator.setNextRequestId(requestId);
        vm.expectRevert(abi.encodeWithSelector(Jackpot.DuplicateRequestId.selector, requestId));
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
        // The whole call rolled back: the pending flag is not stuck.
        assertFalse(jackpot.dailyPending(), "pending flag rolled back with the revert");
    }

    function test_cancelStuckDraw_recoversBrickedKind() public {
        usdg.mint(address(jackpot), 1000e6);
        (uint256 requestId,) = seedAndStartDaily();
        assertTrue(jackpot.dailyPending());
        uint256 drawId = jackpot.drawIdForRequest(requestId);

        // The pinned coordinator is retired and never fulfills; the draw kind is bricked.
        MockVRFCoordinator retired = coordinator;
        MockVRFCoordinator coordinator2 = new MockVRFCoordinator();
        changeJackpotCoordinator(address(coordinator2));
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(Jackpot.DrawPending.selector, Jackpot.DrawKind.DAILY));
        jackpot.startDraw(Jackpot.DrawKind.DAILY);

        // Owner escape hatch clears the flag and neutralizes the stuck draw. No funds move.
        uint256 potBefore = jackpot.potBalance();
        vm.expectEmit(true, true, true, true, address(jackpot));
        emit Jackpot.DrawCancelled(drawId, Jackpot.DrawKind.DAILY, requestId);
        jackpot.cancelStuckDraw(Jackpot.DrawKind.DAILY);
        assertFalse(jackpot.dailyPending());
        assertTrue(jackpot.getDraw(drawId).cancelled);
        assertTrue(jackpot.getDraw(drawId).fulfilled);
        assertEq(jackpot.potBalance(), potBefore, "pot rolled forward, unchanged");

        // A late response from the retired coordinator cannot pay out.
        uint256[] memory words = new uint256[](1);
        words[0] = 5e18;
        vm.expectRevert(abi.encodeWithSelector(Jackpot.AlreadyFulfilled.selector, requestId));
        retired.fulfill(address(jackpot), requestId, words);

        // The draw kind runs again on the live coordinator.
        fill(alice, bob, bob, tokenB, 100e6);
        vm.warp(block.timestamp + 1 days);
        uint256 epoch = points.currentEpoch();
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
        uint256 newRequestId = coordinator2.requestCount();
        coordinator2.fulfill(address(jackpot), newRequestId, words);
        assertEq(
            jackpot.getDraw(jackpot.drawCount() - 1).winner, referenceSelect(epoch, 5e18 % points.epochTotal(epoch))
        );
    }

    function test_cancelStuckDraw_revertsWhenNothingPending() public {
        vm.expectRevert(abi.encodeWithSelector(Jackpot.NoPendingDraw.selector, Jackpot.DrawKind.WEEKLY));
        jackpot.cancelStuckDraw(Jackpot.DrawKind.WEEKLY);
    }

    function test_cancelStuckDraw_onlyOwner() public {
        seedAndStartDaily();
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        jackpot.cancelStuckDraw(Jackpot.DrawKind.DAILY);
    }

    // ===============================================================
    // D2: a frozen winner cannot brick the draw kind; the pot is recoverable
    // ===============================================================

    function test_frozenWinner_doesNotBrickDrawAndPotRecoverable() public {
        usdg.mint(address(jackpot), 1000e6);
        (uint256 requestId,) = seedAndStartDaily();

        // word 5e18 selects alice; freeze her (USDG is freeze-capable on-chain).
        usdg.setFrozen(alice, true);

        // Fulfillment does NOT revert despite the frozen winner: it credits, never pushes.
        fulfillJackpot(requestId, 5e18);
        Jackpot.Draw memory draw = jackpot.getDraw(0);
        assertEq(draw.winner, alice);
        assertEq(draw.amount, 100e6);
        assertEq(jackpot.claimable(alice), 100e6, "credited even while frozen");
        assertFalse(jackpot.dailyPending(), "draw kind not bricked");

        // Alice cannot claim while frozen, but nothing else is stuck.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CasinoMockUSDG.AccountFrozen.selector, alice));
        jackpot.claim();

        // The draw kind keeps working: a later draw pays a different, unfrozen winner.
        // A second fill appends checkpoints AFTER bob@30e18, so target 20e18 still selects bob.
        fill(bob, alice, alice, tokenB, 100e6);
        vm.warp(block.timestamp + 1 days);
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
        uint256 requestId2 = coordinator.requestCount();
        fulfillJackpot(requestId2, 20e18);
        assertEq(jackpot.getDraw(1).winner, bob, "unfrozen winner selected");
        assertEq(jackpot.claimable(bob), jackpot.getDraw(1).amount);
        vm.prank(bob);
        jackpot.claim();
        assertGt(usdg.balanceOf(bob), 0, "different winner paid normally");

        // Once unfrozen, alice recovers her credited award: the pot was never locked.
        usdg.setFrozen(alice, false);
        vm.prank(alice);
        jackpot.claim();
        assertEq(usdg.balanceOf(alice), 100e6, "frozen award fully recoverable");
    }

    // ===============================================================
    // F1: renounceOwnership is disabled
    // ===============================================================

    function test_renounceOwnership_reverts() public {
        vm.expectRevert(Jackpot.RenounceDisabled.selector);
        jackpot.renounceOwnership();
    }

    // ===============================================================
    // Claims
    // ===============================================================

    function test_claim_revertsWithNothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(Jackpot.NothingToClaim.selector);
        jackpot.claim();
    }

    // ===============================================================
    // Audit views
    // ===============================================================

    function test_drawIdForRequest() public {
        (uint256 requestId,) = seedAndStartDaily();
        assertEq(jackpot.drawIdForRequest(requestId), 0);
        vm.expectRevert(abi.encodeWithSelector(Jackpot.UnknownRequest.selector, 999));
        jackpot.drawIdForRequest(999);
    }

    // ===============================================================
    // W2-2: seeded/standing pot is no longer positive-EV wash-farmable
    // (payout is bounded by RECENT FEE INFLOW, not the standing balance)
    // ===============================================================

    /// @dev A large community-seeded pot deposited via seed() is excluded from the fee-inflow drip,
    ///      so a draw pays only a fraction of the RECENT honest inflow, never a fraction of the
    ///      seed. Pre-fix this daily draw would have paid 10% of the 50,020e6 standing pot (~5,002e6)
    ///      to whoever wash-farmed the epoch's points cheapest; now it pays 10e6.
    function test_W2_2_seededPotNotDrainable_payoutBoundedByInflow() public {
        uint256 seedAmount = 50_000e6;
        usdg.mint(address(this), seedAmount);
        usdg.approve(address(jackpot), seedAmount);
        jackpot.seed(seedAmount);
        uint256 epoch0 = points.currentEpoch();
        assertEq(jackpot.potBalance(), seedAmount, "seed accretes the standing pot");
        assertEq(jackpot.epochInflow(epoch0), 0, "seed is NOT counted as fee inflow");
        assertEq(jackpot.unattributedInflow(), 0, "seed leaves no unattributed inflow");

        // Only a tiny honest fee actually flows in (a plain transfer, counted as inflow).
        uint256 honestFee = 20e6;
        usdg.mint(address(jackpot), honestFee);
        assertEq(jackpot.unattributedInflow(), honestFee, "the fee transfer IS inflow");

        // Attacker wash-farms the epoch's points cheaply, then triggers the draw.
        fill(alice, bob, bob, tokenB, 100e6);
        vm.warp(block.timestamp + 1 days);
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
        uint256 requestId = coordinator.requestCount();
        uint256 potBefore = jackpot.potBalance();
        fulfillJackpot(requestId, 5e18); // selects alice

        Jackpot.Draw memory draw = jackpot.getDraw(0);
        assertTrue(draw.winner != address(0), "a winner was selected");
        uint256 expected = honestFee * jackpot.MAX_EPOCH_PAYOUT_BPS() / jackpot.BPS_DENOMINATOR();
        assertEq(draw.amount, expected, "payout bounded by MAX_EPOCH_PAYOUT_BPS of recent inflow");
        assertEq(draw.amount, 10e6, "concretely 50% of the 20e6 inflow");
        assertLt(draw.amount, potBefore / 10, "far below 10% of the standing pot (the old payout)");

        // The seed rolls forward intact.
        assertEq(jackpot.potBalance(), potBefore - 10e6, "only the tiny inflow drip left the pot");
        assertGt(jackpot.potBalance(), 49_000e6, "the 50k seed is protected");

        // A second daily draw next day (same epoch, no fresh inflow) pays ZERO: the epoch's drip
        // budget is spent, so the seed cannot be bled further by re-farming the same epoch.
        fill(alice, bob, bob, tokenB, 100e6);
        vm.warp(block.timestamp + 1 days);
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
        fulfillJackpot(coordinator.requestCount(), 5e18);
        assertEq(jackpot.getDraw(1).amount, 0, "no fresh inflow, no payout: seed stays protected");
    }

    /// @dev The drip budget is shared across every draw an epoch defends, so the daily draws plus
    ///      the weekly draw for one epoch cannot collectively exceed MAX_EPOCH_PAYOUT_BPS of that
    ///      epoch's fee inflow.
    function test_W2_2_dripBudgetSharedAcrossEpochDraws() public {
        // 1000e6 of honest fee inflow lands in the epoch.
        usdg.mint(address(jackpot), 1000e6);
        fill(alice, bob, bob, tokenB, 100e6);
        uint256 epoch = points.currentEpoch();

        // Five daily draws all inside the same epoch (days 401-405 of epoch 57), each weighted by
        // and drawing from that one epoch's shared drip budget.
        uint256 totalPaid;
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1 days);
            assertEq(points.currentEpoch(), epoch, "draws stay within one epoch");
            jackpot.startDraw(Jackpot.DrawKind.DAILY);
            fulfillJackpot(coordinator.requestCount(), 5e18);
            totalPaid += jackpot.getDraw(i).amount;
        }
        uint256 budget = 1000e6 * jackpot.MAX_EPOCH_PAYOUT_BPS() / jackpot.BPS_DENOMINATOR();
        assertLe(totalPaid, budget, "all draws share one epoch drip budget");
        assertEq(jackpot.epochPaidOut(epoch), totalPaid, "epochPaidOut tracks the shared budget");
        assertLe(jackpot.epochPaidOut(epoch), budget, "cumulative never exceeds the budget");
    }

    // ===============================================================
    // W2-4: pot-outflow guard and delayed coordinator change
    // ===============================================================

    /// @dev The pot-outflow guard is a coordinator-independent ceiling: at most
    ///      MAX_OUTFLOW_PER_WINDOW_BPS of the pot may leave per rolling window. A weekly mega-drop
    ///      fills the window budget, so a daily draw landing in the same 24h window is clamped to
    ///      zero even though its own drip budget and the pot fraction would allow a payout.
    function test_W2_4_outflowGuardClampsSecondDrawInWindow() public {
        // Epoch 57 inflow funds the weekly draw for epoch 57.
        fill(alice, bob, bob, tokenB, 100e6);
        usdg.mint(address(jackpot), 100_000e6);
        jackpot.syncInflow();
        uint256 epochWeekly = points.currentEpoch();

        // Cross into the next epoch and trade so the daily draw has a weighted epoch.
        vm.warp((epochWeekly + 1) * 7 days + 1);
        fill(alice, bob, bob, tokenB, 100e6);
        uint256 epochDaily = points.currentEpoch();

        // Weekly draw for epoch 57 pays the full 50% of the pot (= the window guard cap).
        jackpot.startDraw(Jackpot.DrawKind.WEEKLY);
        fulfillJackpot(coordinator.requestCount(), 5e18);
        uint256 weeklyDrawId = jackpot.drawCount() - 1;
        assertEq(jackpot.getDraw(weeklyDrawId).amount, 50_000e6, "weekly paid 50% of the pot");
        (,, uint256 creditedInWindow) = jackpot.outflowWindow();
        assertEq(creditedInWindow, 50_000e6, "the weekly filled the window budget");

        // Fresh inflow for the daily's epoch so its DRIP budget alone would allow a payout.
        usdg.mint(address(jackpot), 100_000e6);
        jackpot.syncInflow();
        assertEq(jackpot.epochInflow(epochDaily), 100_000e6, "daily epoch has ample inflow");

        // Daily draw in the SAME 24h window: drip + fraction would allow 15,000e6, but the guard
        // clamps it to zero because the window budget is exhausted.
        jackpot.startDraw(Jackpot.DrawKind.DAILY);
        fulfillJackpot(coordinator.requestCount(), 5e18);
        uint256 dailyDrawId = jackpot.drawCount() - 1;
        assertEq(jackpot.getDraw(dailyDrawId).amount, 0, "guard clamps the same-window draw to zero");
        assertEq(jackpot.epochPaidOut(epochDaily), 0, "nothing paid from the daily epoch budget");
        (,, uint256 creditedAfter) = jackpot.outflowWindow();
        assertEq(creditedAfter, 50_000e6, "window outflow held at the cap");
    }

    /// @dev W2-2b: the weekly draw can no longer harvest CURRENT-epoch honest inflow into a
    ///      cheaply-dominated PREVIOUS epoch via backward attribution. Pre-fix, startDraw(WEEKLY)
    ///      and its fulfillment both ran _syncInflow(previousEpoch), sweeping every unattributed
    ///      deposit (including honest fees that arrived AFTER the epoch rolled) into the drawn
    ///      epoch's drip budget; an attacker who cheaply dominated a quiet epoch's points and
    ///      withheld syncs during the next busy epoch could then capture 50% of the busy epoch's
    ///      inflow (the re-audit's ~$21.5k reconstituted wash-farm). Post-fix, attribution is by
    ///      arrival only: the completed epoch's budget is frozen at the inflow observed while it
    ///      was current, and both the startDraw sweep and fulfillment-window inflow file to the
    ///      CURRENT epoch.
    function test_W2_2b_weeklyCannotHarvestCurrentEpochInflow() public {
        // Epoch E is quiet: the attacker (alice) cheaply dominates its points; only 100e6 of
        // genuine fee inflow arrives during E and is synced while E is still current.
        fill(alice, bob, bob, tokenB, 100e6);
        uint256 epochE = points.currentEpoch();
        usdg.mint(address(jackpot), 100e6);
        jackpot.syncInflow();
        assertEq(jackpot.epochInflow(epochE), 100e6, "E's own inflow filed while E is current");

        // Epoch E+1 gains traction: 50_000e6 of honest fee inflow arrives. The attacker is the
        // de-facto draw caller and withholds every sync, so it all sits unattributed.
        vm.warp((epochE + 1) * 7 days + 1);
        fill(bob, alice, alice, tokenB, 100e6);
        usdg.mint(address(jackpot), 50_000e6);
        assertEq(jackpot.unattributedInflow(), 50_000e6, "busy-epoch inflow still unattributed");

        // At the end of E+1 the attacker triggers the weekly draw for E, timing the sweep.
        vm.warp((epochE + 2) * 7 days - 1);
        jackpot.startDraw(Jackpot.DrawKind.WEEKLY);
        assertEq(jackpot.epochInflow(epochE), 100e6, "completed epoch's budget is frozen: no backward sweep");
        assertEq(jackpot.epochInflow(epochE + 1), 50_000e6, "honest inflow filed to the epoch it arrived in");

        // Fulfillment-window inflow also files to the CURRENT epoch, not the drawn epoch.
        usdg.mint(address(jackpot), 7_000e6);
        fulfillJackpot(coordinator.requestCount(), 5e18); // selects the attacker in epoch E's weights
        Jackpot.Draw memory draw = jackpot.getDraw(0);
        assertEq(draw.epoch, epochE, "the weekly drew the previous epoch");
        assertEq(draw.winner, alice, "the attacker did win the cheap epoch");
        assertEq(draw.amount, 50e6, "but the payout is 50% of E's OWN 100e6 inflow, not of the 57k harvest");
        assertEq(jackpot.epochInflow(epochE), 100e6, "fulfillment-window inflow did not leak backward");
        assertEq(jackpot.epochInflow(epochE + 1), 57_000e6, "fulfillment-window inflow filed to current epoch");

        // The honest busy epoch keeps its full drip budget for its OWN weekly draw.
        vm.warp((epochE + 2) * 7 days + 1);
        jackpot.startDraw(Jackpot.DrawKind.WEEKLY);
        fulfillJackpot(coordinator.requestCount(), 15e18); // E+1 weights: bob taker, alice maker
        Jackpot.Draw memory honestDraw = jackpot.getDraw(1);
        assertEq(honestDraw.epoch, epochE + 1, "next weekly draws the busy epoch");
        assertEq(
            honestDraw.amount,
            uint256(57_000e6) * jackpot.MAX_EPOCH_PAYOUT_BPS() / jackpot.BPS_DENOMINATOR(),
            "the busy epoch's weekly pays from its own un-stolen budget"
        );
    }

    /// @dev A live coordinator can only be changed through the delayed two-step flow, and an
    ///      in-flight draw completes solely under its pinned old coordinator (audit fix W2-4).
    function test_W2_4_coordinatorChangeDelayed_inFlightUnderOldCoordinator() public {
        (uint256 requestId,) = seedAndStartDaily(); // pinned to base `coordinator`
        MockVRFCoordinator coord2 = new MockVRFCoordinator();

        jackpot.proposeCoordinator(address(coord2));
        assertEq(jackpot.pendingCoordinator(), address(coord2), "change is pending");

        // Cannot accept before the delay, and setCoordinator is bootstrap-only once live.
        vm.expectRevert(
            abi.encodeWithSelector(Jackpot.CoordinatorChangeNotReady.selector, jackpot.coordinatorChangeEffectiveTime())
        );
        jackpot.acceptCoordinator();
        vm.expectRevert(Jackpot.CoordinatorAlreadySet.selector);
        jackpot.setCoordinator(address(coord2));

        // After the delay, anyone finalizes the owner's published proposal.
        vm.warp(block.timestamp + jackpot.COORDINATOR_CHANGE_DELAY());
        address rando = makeAddr("rando2");
        vm.prank(rando);
        jackpot.acceptCoordinator();
        assertEq(address(jackpot.coordinator()), address(coord2), "coordinator switched");
        assertEq(jackpot.pendingCoordinator(), address(0), "proposal cleared");

        // The in-flight draw is fulfillable ONLY by the old pinned coordinator.
        uint256[] memory words = new uint256[](1);
        words[0] = 5e18;
        vm.expectRevert(
            abi.encodeWithSelector(Jackpot.OnlyRequestCoordinator.selector, address(coord2), address(coordinator))
        );
        coord2.fulfill(address(jackpot), requestId, words);
        fulfillJackpot(requestId, 5e18);
        assertTrue(jackpot.getDraw(0).fulfilled, "old coordinator completes the pinned draw");
    }

    function test_W2_4_cancelProposedCoordinator() public {
        MockVRFCoordinator coord2 = new MockVRFCoordinator();
        jackpot.proposeCoordinator(address(coord2));
        jackpot.cancelProposedCoordinator();
        assertEq(jackpot.pendingCoordinator(), address(0), "proposal cancelled");

        vm.warp(block.timestamp + jackpot.COORDINATOR_CHANGE_DELAY());
        vm.expectRevert(Jackpot.NoPendingCoordinatorChange.selector);
        jackpot.acceptCoordinator();
        assertEq(address(jackpot.coordinator()), address(coordinator), "coordinator unchanged");
    }

    function test_W2_4_proposeCoordinator_guards() public {
        address rando = makeAddr("rando3");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        jackpot.proposeCoordinator(makeAddr("x"));

        vm.expectRevert(Jackpot.ZeroAddress.selector);
        jackpot.proposeCoordinator(address(0));
    }

    function test_seed_zeroReverts() public {
        vm.expectRevert(Jackpot.ZeroAmount.selector);
        jackpot.seed(0);
    }
}
