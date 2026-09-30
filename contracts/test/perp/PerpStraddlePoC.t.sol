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

/// @title The straddle-harvest PoC (perp audit wave 1 finding A2, economics v2 proof)
/// @notice The REAL PerpEngine + PitVault + InsuranceFund + PerpRiskConfig stack. A
///         delta-neutral harvester (long + short, two accounts, one fresh memecoin market)
///         rides a representative vol event just past the 1/leverage breakeven. WITHOUT the
///         vol pricing the straddle is +EV free convexity written by the LP vault; WITH the
///         launch-default vol surcharge (deviation + fresh-market premium, credited 100% to
///         the vault) the same trade is NEGATIVE EV, and the vault demonstrably CAPTURES the
///         premium. The companion test shows the vol-scaled cap discount halving fresh-market
///         capacity during a 2x-vol reading while exits stay open.
contract PerpStraddlePoCTest is Test {
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant LP_DEPOSIT = 1_000_000e6;
    uint256 internal constant IF_SEED = 100_000e6;

    // The harvester's straddle: 500 USDG per side at the 6x tier cap. The representative vol
    // event is +18%, just past the 1/L = 16.7% breakeven where the free convexity turns +EV.
    uint128 internal constant SIDE_MARGIN = 500e6;
    uint32 internal constant LEV = 600;
    uint256 internal constant MOVE_MARK = 1.18e18;

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
    address internal carol = makeAddr("carol");
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
        // vol-pricing levers under test.
        engine.setPerAddressReserveShareBps(10_000);
        vm.stopPrank();

        // The memecoin lists FRESH (no seasoning warp): highest info asymmetry, day-one ramp.
        // The spot source arms the deviation proxy exactly as the opening breaker's would.
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

        address[3] memory traders = [harvesterLong, harvesterShort, carol];
        for (uint256 i = 0; i < traders.length; i++) {
            usdg.mint(traders[i], 10_000e6);
            vm.prank(traders[i]);
            usdg.approve(address(engine), type(uint256).max);
        }
    }

    /// @dev Zero every vol knob (the pre-economics-v2 world, RE-ECON-1 layer included)
    ///      through the timelocked setter.
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

    /// @dev One full straddle-harvest cycle on the fresh market during a mild vol reading
    ///      (50 bps spot-vs-TWAP): open both legs day one, hold 12h, ride the +18% event,
    ///      the losing short is liquidated (residual-return model), the winning long exits.
    /// @return harvesterNet The harvester's signed USDG PnL across both accounts.
    /// @return vaultFeeRevenue The vault's cumulative fee revenue captured (carve + premium).
    function _runStraddle() internal returns (int256 harvesterNet, uint256 vaultFeeRevenue) {
        spot.setSpot(MEME, 1.005e18, true); // 50 bps: the vol reading the harvester targets

        uint256 balBefore = usdg.balanceOf(harvesterLong) + usdg.balanceOf(harvesterShort);
        vm.prank(harvesterLong);
        engine.openPosition(MEME, true, SIDE_MARGIN, LEV);
        vm.prank(harvesterShort);
        engine.openPosition(MEME, false, SIDE_MARGIN, LEV);

        vm.warp(block.timestamp + 12 hours);
        oracle.setLive(MEME, MOVE_MARK); // the vol event: +18% at 6x

        vm.prank(keeper);
        engine.liquidate(MEME, harvesterShort, false); // loser truncated, residual model intact
        vm.prank(harvesterLong);
        engine.closePosition(MEME, true); // winner exits at the pumped mark

        uint256 balAfter = usdg.balanceOf(harvesterLong) + usdg.balanceOf(harvesterShort);
        harvesterNet = int256(balAfter) - int256(balBefore);
        vaultFeeRevenue = vault.cumulativeFeeRevenue();
    }

    /// @notice THE PoC: identical straddle, identical vol event. Baseline (vol pricing
    ///         disarmed): the harvester milks the free convexity for a positive return.
    ///         Armed (launch defaults): the deviation + fresh-market premium (50 bps clamped,
    ///         100% to the vault) flips the same harvest to NEGATIVE EV, and the vault
    ///         captures more fee revenue than the whole EV swing it sold the option for.
    function test_straddleHarvest_volPremiumKillsTheFreeOption() public {
        uint256 snap = vm.snapshotState();

        // Baseline: the pre-economics-v2 world sells the straddle its convexity for free.
        _disarmVolPricing();
        (int256 baselineNet, uint256 baselineVaultRevenue) = _runStraddle();
        assertGt(baselineNet, 0, "BASELINE: the delta-neutral harvest is +EV (the A2 finding)");
        // Baseline vault revenue is only the Part 1a carve (20% of the tiny base fees), far
        // below the harvester's edge: the convexity itself is written for free.
        assertLt(baselineVaultRevenue, uint256(baselineNet), "BASELINE: carve alone does not cover the edge");

        vm.revertToState(snap);

        // Armed: launch-default vol pricing. Same market, same event, same size intent.
        (int256 armedNet, uint256 armedVaultRevenue) = _runStraddle();
        assertLe(armedNet, 0, "ARMED: the same harvest is no longer profitable");
        assertLt(armedNet, baselineNet, "ARMED: EV strictly reduced");

        // The premium the vault captured: 50 bps (clamped: 50 deviation + 25 fresh) on both
        // 3,000 USDG intended notionals = 30 USDG of surcharge, plus 20% of the 2 x 3 USDG
        // base open fees and 20% of the winner's close fee. The surcharge alone exceeds the
        // harvester's entire baseline edge.
        uint256 surcharge = 2 * (3_000e6 * 50 / BPS); // 30 USDG
        assertGe(armedVaultRevenue, surcharge, "vault captured at least the whole vol premium");
        assertGe(
            baselineNet - armedNet,
            int256(surcharge),
            "the EV swing is at least the premium the vault now charges"
        );
        emit log_named_int("baseline harvester net (USDG 1e6)", baselineNet);
        emit log_named_int("armed harvester net (USDG 1e6)", armedNet);
        emit log_named_uint("vault fee revenue captured (USDG 1e6)", armedVaultRevenue);
    }

    /// @notice Part 2b companion: during a 2x-normal vol reading (200 bps) the fresh market's
    ///         day-one capacity is HALVED for new opens (10k -> 5k of reserve) while the
    ///         discount never touches exits: the straddle that fit in calm conditions is
    ///         denied mid-spike, and an open position still closes.
    function test_capDiscount_halvesFreshCapacityDuringVolSpike() public {
        // Calm: carol's 600 USDG side (payout 9 * ~594 = ~5.3k) fits the 10k day-one ramp.
        spot.setSpot(MEME, 1e18, true);
        vm.prank(carol);
        engine.openPosition(MEME, true, 600e6, LEV);
        uint256 reservedCalm = vault.totalReserved();
        assertGt(reservedCalm, 5_000e6, "calm-market open exceeds half the day-one cap");

        // Spike: 200 bps deviation -> volDiscount = min(5000, 25 * 200) = 50%: the SAME open
        // on the other side is denied (5.3k + 5.3k would need > 5k effective cap headroom).
        spot.setSpot(MEME, 1.02e18, true);
        vm.prank(harvesterShort);
        vm.expectRevert(PerpEngine.MarketReserveCapExceeded.selector);
        engine.openPosition(MEME, false, 600e6, LEV);

        // Exits are never blocked by the discount: carol closes mid-spike.
        vm.prank(carol);
        engine.closePosition(MEME, true);
        assertEq(vault.totalReserved(), 0, "exit clean during the spike");
    }
}
