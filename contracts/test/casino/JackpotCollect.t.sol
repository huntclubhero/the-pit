// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {CasinoTestBase} from "./CasinoTestBase.t.sol";
import {Jackpot} from "../../src/casino/Jackpot.sol";
import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {PauseGuardian} from "../../src/core/PauseGuardian.sol";
import {CasinoMockUSDG} from "../mocks/CasinoMockUSDG.sol";
import {MockOracleRouter} from "../mocks/MockOracleRouter.sol";
import {MockPitPoints} from "../mocks/MockPitPoints.sol";

/// @title R-6: frozen-recipient fee credit is recoverable into the pot via Jackpot.collectFees
/// @notice When USDG freezes the Jackpot CONTRACT address, every Market fee push to it fails and
///         the 25% jackpot share is credited to the Jackpot's pull-payment balance inside the
///         Market (wave-2 W2-12 credit-on-failure). Pre-fix the Jackpot had no code path calling
///         Market.withdraw(), so those credits were a permanent black hole. collectFees (audit fix
///         R-6) is the permissionless passthrough that pulls the Jackpot's OWN credited balance
///         back into the pot and files it as current-epoch fee inflow (the W2-2b arrival-time
///         attribution model), so it feeds the drip exactly like a normal fee push.
contract JackpotCollectTest is CasinoTestBase {
    /// @dev Entry-fee jackpot share for the 10_000e6 + 10_000e6 fill below: the total entry fee is
    ///      100e6 (50 bps of each side's collateral) and the jackpot receives 25%.
    uint256 internal constant ENTRY_JACKPOT_SHARE = 25e6;

    /// @dev Settlement-fee jackpot share for the decisive settle below: the settlement fee is
    ///      50 bps of the loser notional 49_750e6 (= 248_750_000) and the jackpot receives 25%.
    uint256 internal constant SETTLE_JACKPOT_SHARE = 62_187_500;

    Market internal m;
    MockOracleRouter internal router;
    MockPitPoints internal coreMockPoints;
    PauseGuardian internal pauseGuardian;

    address internal underlying;
    address internal rando;

    function setUp() public override {
        super.setUp();
        underlying = makeAddr("underlyingToken");
        rando = makeAddr("rando");

        router = new MockOracleRouter();
        coreMockPoints = new MockPitPoints();
        pauseGuardian = new PauseGuardian(makeAddr("guardianMultisig"));

        // A real Market on the freeze-capable USDG, with the REAL Jackpot as its fee recipient.
        Types.FeeSplit memory split = Types.FeeSplit({
            jackpot: address(jackpot),
            treasury: makeAddr("treasury"),
            referralPool: makeAddr("referral"),
            buyback: makeAddr("buyback"),
            vault: address(0)
        });
        m = new Market(
            underlying,
            address(usdg),
            address(router),
            address(coreMockPoints),
            split,
            1_000,
            10_000,
            address(pauseGuardian),
            1_000_000e18,
            type(uint256).max,
            50,
            uint16(0)
        );
        router.setPrice(underlying, 1e18, Types.PriceStatus.OK);
    }

    /// @dev Funds `who` with market USDG and approves the market.
    function _fund(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(address(m), type(uint256).max);
    }

    /// @dev Opens a 10_000e6 per-side position (alice LONG maker, bob taker) at entry 1e18.
    function _open() internal returns (uint256 positionId) {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _fund(alice, 10_000e6);
        vm.prank(alice);
        uint256 offerId =
            m.postOffer(Types.Side.LONG, 10_000e6, 1_000e6, 5, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
        _fund(bob, 10_000e6);
        vm.prank(bob);
        positionId = m.fillOffer(offerId, 10_000e6);
    }

    /// @dev The full R-6 scenario: freeze the Jackpot recipient, accrue fee credit through a fill
    ///      AND a decisive settle, unfreeze, collect, and assert the pot rises by exactly the
    ///      credited amount with the recovered funds filed as current-epoch drip inflow.
    function test_R6_frozenJackpotFeeShare_recoveredIntoPotByCollectFees() public {
        // USDG freezes the Jackpot CONTRACT: every push of its fee share now fails.
        usdg.setFrozen(address(jackpot), true);

        // Fill succeeds regardless (W2-12) and the entry share is CREDITED inside the Market.
        uint256 positionId = _open();
        assertEq(m.withdrawable(address(jackpot)), ENTRY_JACKPOT_SHARE, "entry share credited, not pushed");
        assertEq(usdg.balanceOf(address(jackpot)), 0, "nothing reached the pot while frozen");

        // A decisive settlement accrues the settlement-fee share the same way.
        vm.warp(block.timestamp + 1 days);
        router.setPrice(underlying, 1.1e18, Types.PriceStatus.OK);
        vm.prank(rando);
        m.settle(positionId);
        uint256 credited = ENTRY_JACKPOT_SHARE + SETTLE_JACKPOT_SHARE;
        assertEq(m.withdrawable(address(jackpot)), credited, "settle share also credited");

        // While still frozen, the pull itself fails inside Market.withdraw and bubbles up: the
        // credit stays intact in the Market ledger for a later attempt.
        vm.expectRevert(abi.encodeWithSelector(CasinoMockUSDG.AccountFrozen.selector, address(jackpot)));
        jackpot.collectFees(address(m));
        assertEq(m.withdrawable(address(jackpot)), credited, "failed pull leaves the credit intact");

        // Unfrozen: ANYONE recovers the credit into the pot; no owner action is needed.
        usdg.setFrozen(address(jackpot), false);
        uint256 potBefore = jackpot.potBalance();
        uint256 epoch = points.currentEpoch();
        uint256 inflowBefore = jackpot.epochInflow(epoch);
        vm.expectEmit(true, true, true, true, address(jackpot));
        emit Jackpot.FeesCollected(address(m), credited);
        vm.prank(rando);
        uint256 collected = jackpot.collectFees(address(m));

        assertEq(collected, credited, "collect returns the exact pulled amount");
        assertEq(jackpot.potBalance(), potBefore + credited, "pot rises by exactly the credited amount");
        assertEq(m.withdrawable(address(jackpot)), 0, "the Market credit is fully drained");
        // Drip integration (W2-2b): the recovered share is current-epoch fee inflow, payable
        // through the normal drip like any other fee, and nothing is left unattributed.
        assertEq(jackpot.epochInflow(epoch), inflowBefore + credited, "filed as current-epoch drip inflow");
        assertEq(jackpot.unattributedInflow(), 0, "nothing left unattributed");
    }

    function test_R6_collectFees_zeroMarketReverts() public {
        vm.expectRevert(Jackpot.ZeroAddress.selector);
        jackpot.collectFees(address(0));
    }

    /// @dev With nothing credited, Market.withdraw reverts NothingToWithdraw and collectFees
    ///      bubbles it up: the collector can never mint phantom inflow.
    function test_R6_collectFees_nothingCreditedReverts() public {
        vm.expectRevert(Market.NothingToWithdraw.selector);
        jackpot.collectFees(address(m));
    }
}
