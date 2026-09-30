// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {PauseGuardian} from "../../src/core/PauseGuardian.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";
import {IPerpRiskConfig} from "../../src/perp/interfaces/IPerpRiskConfig.sol";
import {IOracleRouterVaultView} from "../../src/perp/interfaces/IPerpVaultDeps.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PitVault} from "../../src/perp/PitVault.sol";
import {InsuranceFund} from "../../src/perp/InsuranceFund.sol";
import {PerpRiskConfig} from "../../src/perp/PerpRiskConfig.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockPitPoints} from "../mocks/MockPitPoints.sol";
import {MockPerpOracle} from "./mocks/MockPerpOracle.sol";
import {MockSpotSource} from "./mocks/MockSpotSource.sol";

/// @title The PATIENT straddle-harvest PoC (RE-ECON-1 closure proof)
/// @notice The re-audit survivor: the original A2 levers (open surcharge + cap discount) price
///         the OPEN only, keyed to the instantaneous spot-vs-TWAP deviation, so a patient
///         harvester dodges them completely: open a delta-neutral straddle in CALM conditions
///         (deviation ~0, zero surcharge) on a SEASONED market (age > 14d, zero fresh premium,
///         full ramp), pay ~nothing, HOLD, and harvest a LATER vol event against the LP vault.
///         This PoC reproduces that exact trade on the REAL PerpEngine + PitVault +
///         InsuranceFund + PerpRiskConfig stack and proves the vol-scaled BORROW layer closes
///         it: WITH launch defaults the same patient harvest is NEGATIVE EV, because both legs
///         accrued borrow at the realized-vol-scaled rate over the hold that ended inside the
///         event, and the vault demonstrably keeps that borrow. With the layer disarmed the
///         harvest is still +EV, matching the re-audit's baseline.
contract PerpPatientStraddlePoCTest is Test {
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant LP_DEPOSIT = 1_000_000e6;
    uint256 internal constant IF_SEED = 100_000e6;

    // The patient straddle: 500 USDG per side at the 6x tier cap, opened CALM on a SEASONED
    // market, held 24h, harvesting a representative +30% vol event (comfortably past the
    // 1/L = 16.7% breakeven where the capped-payout asymmetry turns the straddle +EV).
    uint128 internal constant SIDE_MARGIN = 500e6;
    uint32 internal constant LEV = 600;
    uint256 internal constant MOVE_MARK = 1.3e18;
    uint256 internal constant HOLD = 24 hours;

    MockUSDG internal usdg;
    MockUSDG internal memeToken;
    MockPerpOracle internal oracle;
    MockSpotSource internal spot;
    PerpRiskConfig internal risk;
    InsuranceFund internal ifund;
    PitVault internal vault;
    PauseGuardian internal guardian;
    MockPitPoints internal points;
    PerpEngine internal engine;

    address internal MEME;

    address internal constant TIMELOCK = address(0x7157);
    address internal lp = makeAddr("lp");
    address internal harvesterLong = makeAddr("harvesterLong");
    address internal harvesterShort = makeAddr("harvesterShort");
    address internal keeper = makeAddr("keeper");
    address internal jackpot = makeAddr("jackpot");
    address internal treasury = makeAddr("treasury");
    address internal referral = makeAddr("referral");
    address internal buyback = makeAddr("buyback");

    function setUp() public {
        vm.warp(30 days);

        usdg = new MockUSDG();
        memeToken = new MockUSDG();
        MEME = address(memeToken);
        memeToken.mint(address(this), 3_000_000e6); // FDV $3M at $1: tier 2 (6x, 10 bps fees)

        oracle = new MockPerpOracle();
        spot = new MockSpotSource();
        risk = new PerpRiskConfig(IOracleRouter(address(oracle)), TIMELOCK);
        ifund = new InsuranceFund(IERC20(address(usdg)), TIMELOCK);
        vault = new PitVault(
            IERC20(address(usdg)), IOracleRouterVaultView(address(oracle)), IPerpRiskConfig(address(risk)), TIMELOCK
        );
        guardian = new PauseGuardian(makeAddr("guardianEoa"));
        points = new MockPitPoints();
        engine = new PerpEngine(
            TIMELOCK,
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
                vault: address(vault)
            })
        );

        vm.startPrank(TIMELOCK);
        vault.setEngine(address(engine));
        ifund.setEngine(address(engine));
        ifund.setVault(address(vault));
        vault.setDepositEpochCap(10_000, 2_000_000e6);
        // The per-address reserve share is an orthogonal sybil-splitting throttle (a real
        // harvester trivially spreads across addresses); widen it so the PoC isolates the
        // vol-borrow lever under test.
        engine.setPerAddressReserveShareBps(10_000);
        vm.stopPrank();

        oracle.setLive(MEME, 1e18);
        oracle.setListable(MEME, true);
        oracle.setTierConfig(MEME, 2, address(spot)); // C_MID pool-priced, breaker armed (B5)
        vm.prank(TIMELOCK);
        risk.assignTier(MEME, 2);
        vm.prank(TIMELOCK);
        engine.listMarket(MEME);

        usdg.mint(address(this), IF_SEED);
        usdg.approve(address(ifund), IF_SEED);
        ifund.seed(IF_SEED);

        usdg.mint(lp, LP_DEPOSIT);
        vm.prank(lp);
        usdg.approve(address(vault), type(uint256).max);
        vm.prank(lp);
        vault.deposit(LP_DEPOSIT, lp);

        address[2] memory traders = [harvesterLong, harvesterShort];
        for (uint256 i = 0; i < traders.length; i++) {
            usdg.mint(traders[i], 10_000e6);
            vm.prank(traders[i]);
            usdg.approve(address(engine), type(uint256).max);
        }

        // SEASONING: warp past the 14-day ramp + fresh-surcharge window BEFORE the harvester
        // touches the market. This is the re-audit's exact precondition: _freshSurchargeBps
        // is zero and the reserve ramp is fully open when the straddle lands.
        vm.warp(block.timestamp + 15 days);
    }

    /// @dev Zero every vol knob (the pre-RE-ECON-1 world) through the timelocked setter.
    function _disarmVolPricing() internal {
        vm.prank(TIMELOCK);
        risk.setVolParams(
            PerpTypes.VolParams({
                kVolX100: 0,
                maxVolSurchargeBps: 0,
                freshSurchargeStartBps: 0,
                kCapVolX100: 0,
                maxVolDiscountBps: 0,
                kBorrowVolX100: 0,
                volBorrowDeadbandBps: 0,
                maxVolBorrowMultX100: 0,
                volRefTauSeconds: 0
            })
        );
    }

    /// @dev The patient harvest cycle: CALM open on the seasoned market (spot flush with the
    ///      mark: zero deviation, zero surcharge, full capacity), an unpoked 24h hold, then
    ///      the +30% event; the losing short is liquidated and the winning long exits at the
    ///      pumped mark. Returns the harvester's net, the vault's cash delta over the cycle,
    ///      and the borrow the WINNING leg owed at exit (the vol-borrow kill lever).
    function _runPatientStraddle()
        internal
        returns (int256 harvesterNet, int256 vaultCashDelta, uint256 winnerBorrowOwed, uint256 winnerMaxPayout)
    {
        spot.setSpot(MEME, 1e18, true); // CALM: zero spot-vs-TWAP deviation at the open

        uint256 balBefore = usdg.balanceOf(harvesterLong) + usdg.balanceOf(harvesterShort);
        uint256 vaultBefore = usdg.balanceOf(address(vault));

        vm.prank(harvesterLong);
        engine.openPosition(MEME, true, SIDE_MARGIN, LEV);
        vm.prank(harvesterShort);
        engine.openPosition(MEME, false, SIDE_MARGIN, LEV);

        // The CALM SEASONED open really paid ~nothing beyond the 10 bps base fee: no vol
        // surcharge, no fresh premium (the exact dodge the re-audit proved).
        assertEq(engine.getPosition(MEME, harvesterLong, true).margin, 497e6, "calm open: base fee only");
        assertEq(engine.realizedVolBpsOf(MEME), 0, "calm open: zero realized-vol reading");

        vm.warp(block.timestamp + HOLD); // patient, unpoked hold
        oracle.setLive(MEME, MOVE_MARK); // the vol event arrives
        spot.setSpot(MEME, MOVE_MARK, true); // spot tracks: the open-time levers stay silent

        vm.prank(keeper);
        engine.liquidate(MEME, harvesterShort, false); // loser truncated at its margin
        (, winnerBorrowOwed) = engine.pendingOwedOf(MEME, harvesterLong, true);
        winnerMaxPayout = engine.getPosition(MEME, harvesterLong, true).maxPayout; // frozen cap, pre-close
        vm.prank(harvesterLong);
        engine.closePosition(MEME, true); // winner exits at the pumped mark

        uint256 balAfter = usdg.balanceOf(harvesterLong) + usdg.balanceOf(harvesterShort);
        harvesterNet = int256(balAfter) - int256(balBefore);
        vaultCashDelta = int256(usdg.balanceOf(address(vault))) - int256(vaultBefore);
    }

    /// @notice THE RE-ECON-1 PoC. Baseline (vol pricing disarmed = the state the re-audit
    ///         flagged): the patient seasoned-market straddle dodges every open-time lever and
    ///         milks the vol event for a positive return. Armed (launch defaults): the SAME
    ///         trade with the SAME event is NEGATIVE EV, killed by the vol-scaled borrow both
    ///         legs accrued over the hold that ended inside the event, and the vault CAPTURES
    ///         that borrow (its cash improves by more than the winner's whole charge).
    function test_patientStraddle_volBorrowKillsTheSeasonedCalmHarvest() public {
        uint256 snap = vm.snapshotState();

        // Baseline: the exact re-audit survivor. Every open-time lever silent, borrow at the
        // plain utilization rate: the patient harvest is +EV free convexity.
        _disarmVolPricing();
        (int256 baselineNet, int256 baselineVaultDelta, uint256 baselineWinnerBorrow,) = _runPatientStraddle();
        assertGt(baselineNet, 0, "BASELINE: the patient seasoned-calm harvest is +EV (RE-ECON-1)");
        assertLt(baselineWinnerBorrow, 1e6, "BASELINE: base borrow is dust, no deterrent");

        vm.revertToState(snap);

        // Armed: launch defaults. Identical market age, identical calm open, identical event.
        (int256 armedNet, int256 armedVaultDelta, uint256 armedWinnerBorrow,) = _runPatientStraddle();
        assertLt(armedNet, 0, "ARMED: the same patient harvest is NEGATIVE EV");
        assertLt(armedNet, baselineNet, "ARMED: EV strictly reduced");

        // The kill came from the vol-scaled borrow, not from any open-time lever: the winner
        // alone owed more at exit than the harvester's entire baseline edge.
        assertGt(armedWinnerBorrow, uint256(baselineNet), "winner's vol-borrow exceeds the whole baseline edge");

        // And the vault CAPTURES it: its cash over the armed cycle improves on the baseline
        // cycle by at least the winner's charge (the loser's charge arrives via the
        // insurance-fund cover of its post-liquidation borrow shortfall on top).
        assertGe(
            armedVaultDelta - baselineVaultDelta,
            int256(armedWinnerBorrow),
            "vault cash captures at least the winner's vol-borrow"
        );

        emit log_named_int("baseline harvester net (USDG 1e6)", baselineNet);
        emit log_named_int("armed harvester net (USDG 1e6)", armedNet);
        emit log_named_uint("winner vol-borrow paid (USDG 1e6)", armedWinnerBorrow);
        emit log_named_int("vault cash delta baseline (USDG 1e6)", baselineVaultDelta);
        emit log_named_int("vault cash delta armed (USDG 1e6)", armedVaultDelta);
    }

    /// @notice Conservation with the layer armed on the REAL stack: the whole patient cycle
    ///         neither mints nor destroys USDG anywhere in the closed system.
    function test_patientStraddle_conservationWeiExact() public {
        uint256 sysBefore = _systemBalance();
        _runPatientStraddle();
        assertEq(_systemBalance(), sysBefore, "closed-system conservation across the armed cycle");
    }

    /// @notice Anti-drain armor untouched: the vol-borrow layer adds an INFLOW only. The
    ///         winner's payout stays clamped by its frozen maxPayout, reservations release to
    ///         zero, and the reserve caps still gate a follow-up open exactly as before.
    function test_patientStraddle_armorUnchanged() public {
        (,, uint256 winnerBorrow, uint256 winnerMaxPayout) = _runPatientStraddle();
        assertGt(winnerBorrow, 0, "vol-borrow actually accrued");
        assertEq(vault.totalReserved(), 0, "all reservations released after the cycle");
        // The payout-cap invariant held: the winner could never have received more than its
        // frozen 9x cap regardless of the event size; with the vol event at +30% the clamped
        // win (894.6) stayed far under the 4,473 cap. Bound the winner's balance by its starting
        // balance plus that FROZEN cap (captured pre-close: a closed position reports maxPayout 0).
        assertLe(
            usdg.balanceOf(harvesterLong),
            10_000e6 - SIDE_MARGIN + winnerMaxPayout,
            "winner bounded by starting balance + capped payout"
        );
    }

    /// @notice The one-block suppression contrast on the REAL stack: in the event block an
    ///         attacker pins the spot flush with the mark, which zeroes the instantaneous
    ///         deviation (the dodgeable open-time reading), yet the realized-vol reading and
    ///         the vol-scaled borrow it drives are unmoved.
    function test_eventBlock_spotManipulationCannotZeroTheReading() public {
        spot.setSpot(MEME, 1e18, true);
        vm.prank(harvesterLong);
        engine.openPosition(MEME, true, SIDE_MARGIN, LEV);
        vm.warp(block.timestamp + HOLD);
        oracle.setLive(MEME, MOVE_MARK);

        // One-block action: spot pinned to the mark. Deviation reads zero...
        spot.setSpot(MEME, MOVE_MARK, true);
        (bool allowed,) = oracle.openingAllowed(MEME);
        assertTrue(allowed, "opening breaker sees zero deviation");
        // ...but the realized-vol reading is the mark against the slow EWMA reference:
        assertEq(engine.realizedVolBpsOf(MEME), 3_000, "reading pinned to the realized move, not the spot");
        // and the held position's pending borrow already carries the event-rate bill.
        (, uint256 borrowOwed) = engine.pendingOwedOf(MEME, harvesterLong, true);
        assertGt(borrowOwed, 100e6, "the hold owes the vol-scaled borrow regardless of the spot game");
    }

    /// @dev Sum of USDG across every actor in the closed test system.
    function _systemBalance() internal view returns (uint256 total) {
        address[10] memory holders = [
            lp,
            harvesterLong,
            harvesterShort,
            keeper,
            address(engine),
            address(vault),
            address(ifund),
            jackpot,
            treasury,
            address(this)
        ];
        for (uint256 i = 0; i < holders.length; i++) {
            total += usdg.balanceOf(holders[i]);
        }
        total += usdg.balanceOf(referral) + usdg.balanceOf(buyback);
    }
}
