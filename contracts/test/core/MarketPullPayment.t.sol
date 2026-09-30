// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {CoreBase} from "./CoreBase.t.sol";

/// @dev USDG stand-in that can freeze an address, reverting every transfer TO it (the confirmed
///      USDG freeze capability). 6 decimals, unrestricted mint.
contract BlockableUSDG is ERC20 {
    mapping(address => bool) public frozen;

    constructor() ERC20("Blockable USDG", "BUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFrozen(address who, bool value) external {
        frozen[who] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!frozen[to], "USDG_FROZEN_RECIPIENT");
        super._update(from, to, value);
    }
}

/// @dev USDG stand-in that re-enters Market.withdraw during its own transfer, to prove the pull
///      path's reentrancy guard holds.
contract ReentrantWithdrawUSDG is ERC20 {
    Market public target;
    bool public armed;
    bool public reentryBlocked;

    constructor() ERC20("Reentrant USDG", "RUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(Market target_) external {
        target = target_;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            try target.withdraw() {}
            catch {
                reentryBlocked = true;
            }
        }
        return super.transfer(to, amount);
    }
}

/// @title Pull-payment settlement and forced unwind (D1)
/// @notice Proves settlement and forced unwind CREDIT payouts and that a frozen recipient can
///         never revert settlement or strand the counterparty: each party pulls its own credit,
///         and one blocked pull never blocks another party or the settlement itself.
contract MarketPullPaymentTest is CoreBase {
    BlockableUSDG internal busdg;
    Market internal m;

    function setUp() public override {
        super.setUp();
        busdg = new BlockableUSDG();
        // A standalone market on the blockable collateral, reusing the mock router/points/guardian.
        Types.FeeSplit memory split =
            Types.FeeSplit({jackpot: jackpot, treasury: treasury, referralPool: referral, buyback: buyback, vault: address(0)});
        m = new Market(
            token, address(busdg), address(router), address(pitPoints), split, OI_CAP_BPS, PER_ADDRESS_OI_CAP_BPS, address(pauseGuardian), 1_000_000e18, type(uint256).max, SETTLEMENT_FEE_BPS
        , uint16(0));
        router.setPrice(token, 1e18, Types.PriceStatus.OK);
    }

    /// @dev Fund `who` on the blockable token and approve `m`.
    function _fundB(address who, uint256 amount) internal {
        busdg.mint(who, amount);
        vm.prank(who);
        busdg.approve(address(m), type(uint256).max);
    }

    /// @dev Open a 10_000e6 position (alice LONG maker, bob taker) at entry 1e18.
    function _open() internal returns (uint256 positionId) {
        _fundB(alice, 10_000e6);
        vm.prank(alice);
        uint256 offerId =
            m.postOffer(Types.Side.LONG, 10_000e6, 1_000e6, 5, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
        _fundB(bob, 10_000e6);
        vm.prank(bob);
        positionId = m.fillOffer(offerId, 10_000e6);
    }

    function test_pullPayment_creditsExactlyAndConserves() public {
        uint256 positionId = _open();
        // collateralEach = 10_000e6 - 50e6 = 9_950e6, notional 49_750e6.
        vm.warp(block.timestamp + 1 days);
        router.setPrice(token, 1.1e18, Types.PriceStatus.OK);
        vm.prank(carol);
        m.settle(positionId);

        // Winner alice credited collateralEach + pnl - fee; loser bob credited collateralEach - pnl.
        // Settlement fee = 50 bps of notional 49_750e6 = 248.75e6 (below the 4_975e6 pnl).
        uint256 pnl = 4_975e6;
        uint256 fee = 248_750_000;
        assertEq(m.withdrawable(alice), uint256(9_950e6) + pnl - fee);
        assertEq(m.withdrawable(bob), uint256(9_950e6) - pnl);
        // Conservation: credited payouts + pushed fee == 2 x collateralEach.
        assertEq(m.withdrawable(alice) + m.withdrawable(bob) + fee, 2 * uint256(9_950e6));
        assertEq(m.totalUnwithdrawnCredit(), m.withdrawable(alice) + m.withdrawable(bob));
    }

    function test_pullPayment_frozenWinnerDoesNotStrandLoserOrSettlement() public {
        uint256 positionId = _open();
        vm.warp(block.timestamp + 1 days);
        router.setPrice(token, 1.1e18, Types.PriceStatus.OK);

        // Freeze the WINNER (alice) before settlement: a push-payment model would revert here.
        busdg.setFrozen(alice, true);

        // Settlement still succeeds and credits both parties.
        vm.prank(carol);
        m.settle(positionId);
        assertTrue(m.positions(positionId).settled);

        // The loser (bob) pulls his credit with no trouble at all.
        uint256 bobCredit = m.withdrawable(bob);
        assertGt(bobCredit, 0);
        vm.prank(bob);
        m.withdraw();
        assertEq(busdg.balanceOf(bob), bobCredit);

        // The frozen winner's own pull reverts, but that failure is isolated to alice: her credit
        // is still recorded and recoverable once unfrozen. Nothing was stranded for bob.
        vm.prank(alice);
        vm.expectRevert(bytes("USDG_FROZEN_RECIPIENT"));
        m.withdraw();
        uint256 aliceCredit = m.withdrawable(alice);
        assertGt(aliceCredit, 0);

        busdg.setFrozen(alice, false);
        vm.prank(alice);
        m.withdraw();
        assertEq(busdg.balanceOf(alice), aliceCredit);
        assertEq(busdg.balanceOf(address(m)), 0);
    }

    function test_feeCredit_frozenFeeRecipientDoesNotBrickFillOrSettle() public {
        // Freeze the TREASURY fee recipient before any fill: a push-payment fee model would revert
        // every fillOffer and decisive settle market-wide. Credit-on-failure keeps both live (W2-12).
        busdg.setFrozen(treasury, true);

        // The fill still SUCCEEDS: the treasury entry-fee share is CREDITED, not pushed.
        uint256 positionId = _open();
        assertTrue(m.positions(positionId).longParty != address(0), "fill succeeded despite frozen treasury");

        // Entry fee total = feeMaker(50e6) + feeTaker(50e6) = 100e6. The three unfrozen recipients
        // are pushed their shares; the frozen treasury share (26e6) is credited.
        assertEq(busdg.balanceOf(jackpot), 25e6, "jackpot entry share pushed");
        assertEq(busdg.balanceOf(referral), 10e6, "referral entry share pushed");
        assertEq(busdg.balanceOf(buyback), 39e6, "buyback entry share pushed");
        assertEq(m.withdrawable(treasury), 26e6, "frozen treasury entry share credited");

        // A decisive settlement ALSO succeeds while the recipient stays frozen: its treasury fee
        // share is credited too, and both parties are credited normally.
        vm.warp(block.timestamp + 1 days);
        router.setPrice(token, 1.1e18, Types.PriceStatus.OK);
        vm.prank(carol);
        m.settle(positionId);
        assertTrue(m.positions(positionId).settled, "settlement succeeded despite frozen treasury");

        // Settlement fee = 50 bps of loser notional (loserStake 9_950e6 x multiple 5 = 49_750e6):
        // 248_750_000; treasury share = fee minus the 25/10/39 percent shares.
        uint256 settleFee = 248_750_000;
        uint256 settleTreasuryShare =
            settleFee - settleFee * 2_500 / 10_000 - settleFee * 1_000 / 10_000 - settleFee * 3_900 / 10_000;
        assertEq(m.withdrawable(treasury), 26e6 + settleTreasuryShare, "settle treasury share also credited");

        // Once unfrozen, treasury pulls its full accrued fee credit; the market holds no stray dust
        // beyond the still-unwithdrawn party payouts.
        busdg.setFrozen(treasury, false);
        uint256 owed = m.withdrawable(treasury);
        vm.prank(treasury);
        m.withdraw();
        assertEq(busdg.balanceOf(treasury), owed);
    }

    function test_pushFee_externalCallerRevertsOnlySelf() public {
        // Wave-2b R-8: the self-only guard on pushFee is security-critical. pushFee transfers an
        // arbitrary amount to an arbitrary address from the market balance; a broken guard would
        // let anyone drain ALL escrow. Assert an outside caller always reverts OnlySelf, while the
        // market holds live escrow the guard must protect.
        _open();
        uint256 escrow = busdg.balanceOf(address(m));
        assertGt(escrow, 0, "market holds live escrow");

        address attacker = makeAddr("pushFeeAttacker");
        vm.prank(attacker);
        vm.expectRevert(Market.OnlySelf.selector);
        m.pushFee(attacker, escrow);

        // A party to the position cannot call it either: only the market itself may.
        vm.prank(alice);
        vm.expectRevert(Market.OnlySelf.selector);
        m.pushFee(alice, 1);

        assertEq(busdg.balanceOf(address(m)), escrow, "escrow untouched by rejected pushes");
    }

    function test_pullPayment_forcedUnwindCreditsBothEvenWhenOneBlocked() public {
        uint256 positionId = _open();

        // Broken oracle past expiry + delay: only the forced-unwind path can pay out.
        vm.warp(block.timestamp + 1 days + 24 hours + 1);
        router.setPrice(token, 1e18, Types.PriceStatus.UNAVAILABLE);

        // Freeze one side (bob): the last-resort liveness path must still not revert.
        busdg.setFrozen(bob, true);

        vm.prank(carol);
        m.settle(positionId);
        assertTrue(m.positions(positionId).settled);

        // Both sides credited exactly collateralEach; the unblocked side withdraws immediately.
        assertEq(m.withdrawable(alice), 9_950e6);
        assertEq(m.withdrawable(bob), 9_950e6);
        vm.prank(alice);
        m.withdraw();
        assertEq(busdg.balanceOf(alice), 9_950e6);

        // The frozen side recovers once unfrozen; its escrow was never stranded.
        busdg.setFrozen(bob, false);
        vm.prank(bob);
        m.withdraw();
        assertEq(busdg.balanceOf(bob), 9_950e6);
    }

    function test_withdraw_revertsWhenNothingCredited() public {
        vm.prank(alice);
        vm.expectRevert(Market.NothingToWithdraw.selector);
        m.withdraw();
    }

    function test_withdraw_emitsAndClearsCredit() public {
        uint256 positionId = _open();
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        m.settle(positionId); // flat settle at entry: each credited collateralEach

        assertEq(m.withdrawable(alice), 9_950e6);
        vm.expectEmit(true, true, true, true);
        emit Market.Withdrawn(alice, 9_950e6);
        vm.prank(alice);
        uint256 amount = m.withdraw();
        assertEq(amount, 9_950e6);
        assertEq(m.withdrawable(alice), 0);
    }

    function test_withdraw_reentrancyBlocked() public {
        // Build a market on a token that re-enters withdraw during its transfer.
        ReentrantWithdrawUSDG evil = new ReentrantWithdrawUSDG();
        Types.FeeSplit memory split =
            Types.FeeSplit({jackpot: jackpot, treasury: treasury, referralPool: referral, buyback: buyback, vault: address(0)});
        Market em = new Market(
            token, address(evil), address(router), address(pitPoints), split, OI_CAP_BPS, PER_ADDRESS_OI_CAP_BPS, address(pauseGuardian), 1_000_000e18, type(uint256).max, SETTLEMENT_FEE_BPS
        , uint16(0));
        router.setPrice(token, 1e18, Types.PriceStatus.OK);

        evil.mint(alice, 10_000e6);
        evil.mint(bob, 10_000e6);
        vm.prank(alice);
        evil.approve(address(em), type(uint256).max);
        vm.prank(bob);
        evil.approve(address(em), type(uint256).max);

        vm.prank(alice);
        uint256 offerId =
            em.postOffer(Types.Side.LONG, 10_000e6, 1_000e6, 5, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
        vm.prank(bob);
        uint256 positionId = em.fillOffer(offerId, 10_000e6);

        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        em.settle(positionId); // flat: alice credited collateralEach

        evil.arm(em);
        vm.prank(alice);
        em.withdraw();

        // The reentrant withdraw during the payout transfer was blocked by nonReentrant.
        assertTrue(evil.reentryBlocked());
        assertEq(em.withdrawable(alice), 0);
    }
}
