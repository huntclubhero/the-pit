// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Types} from "../../../src/interfaces/Types.sol";
import {IOracleRouter} from "../../../src/interfaces/IOracleRouter.sol";
import {PauseGuardian} from "../../../src/core/PauseGuardian.sol";
import {PerpTypes} from "../../../src/perp/interfaces/PerpTypes.sol";
import {IPerpRiskConfig} from "../../../src/perp/interfaces/IPerpRiskConfig.sol";
import {IOracleRouterVaultView} from "../../../src/perp/interfaces/IPerpVaultDeps.sol";
import {PerpEngine} from "../../../src/perp/PerpEngine.sol";
import {PitVault} from "../../../src/perp/PitVault.sol";
import {InsuranceFund} from "../../../src/perp/InsuranceFund.sol";
import {PerpRiskConfig} from "../../../src/perp/PerpRiskConfig.sol";
import {MarginMathLib} from "../../../src/perp/MarginMathLib.sol";
import {FundingLib} from "../../../src/perp/FundingLib.sol";
import {MockUSDG} from "../../mocks/MockUSDG.sol";
import {MockPitPoints} from "../../mocks/MockPitPoints.sol";
import {MockPerpOracle} from "../mocks/MockPerpOracle.sol";

/// @title PerpIntegration: the REAL PerpEngine + PitVault + InsuranceFund + PerpRiskConfig
///        wired together exactly as production will be, with only the leaves mocked
///        (MockPerpOracle for the router surface, MockUSDG for the 6-decimal collateral).
/// @notice Every scenario asserts WEI-EXACT conservation of USDG across the closed system
///         (engine escrow + vault + insurance fund + traders + keeper + fee recipients +
///         LP + timelock) after every step, plus exact per-actor balance deltas recomputed
///         independently through the standalone-fuzzed math libraries (MarginMathLib,
///         FundingLib) and the ERC-4626 share formulas. This is the additive proof that the
///         two modules, each unit-tested against mocks of the other, actually seam.
///
///         Production wiring mirrored here (the Deploy.s.sol seam, spec 8.6):
///           1. deploy PerpRiskConfig(router, timelock)
///           2. deploy InsuranceFund(usdg, timelock)
///           3. deploy PitVault(usdg, router, riskConfig, timelock)
///           4. deploy PerpEngine(timelock, usdg, router, vault, ifund, riskConfig, points,
///              guardian, feeSplit); the engine max-approves the vault in its constructor
///              (settleTraderLoss PULLS via transferFrom)
///           5. vault.setEngine(engine); ifund.setEngine(engine); ifund.setVault(vault)
///           6. riskConfig.assignTier(token, tier) with the live FDV inside the band, then
///              engine.listMarket(token)
///           7. LP seeds the vault through deposit(); the insurance fund is seeded via seed()
contract PerpIntegrationTest is Test {
    uint256 internal constant SCALE = 1e12; // 10 ** (18 - 6): USDG scale, mirrors the engine
    uint256 internal constant BPS = 10_000;
    uint256 internal constant LP_DEPOSIT = 1_000_000e6;
    uint256 internal constant IF_SEED = 100_000e6;
    uint256 internal constant TRADER_STAKE = 100_000e6;

    MockUSDG internal usdg;
    MockUSDG internal memeToken; // real ERC20 so PerpRiskConfig.fdvOf(totalSupply) works
    MockPerpOracle internal oracle;
    PerpRiskConfig internal risk;
    InsuranceFund internal ifund;
    PitVault internal vault;
    PauseGuardian internal guardian;
    MockPitPoints internal points;
    PerpEngine internal engine;

    address internal MEME;

    address internal constant TIMELOCK = address(0x7157);
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");
    address internal guardianEoa = makeAddr("guardianEoa");
    address internal jackpot = makeAddr("jackpot");
    address internal treasury = makeAddr("treasury");
    address internal referral = makeAddr("referral");
    address internal buyback = makeAddr("buyback");

    function setUp() public {
        vm.warp(30 days); // anchor away from zero so window arithmetic behaves

        usdg = new MockUSDG();
        memeToken = new MockUSDG();
        MEME = address(memeToken);
        // 3,000,000 tokens at $1: FDV $3M, inside the tier-2 band [$2M, $5M).
        memeToken.mint(address(this), 3_000_000e6);

        oracle = new MockPerpOracle();
        risk = new PerpRiskConfig(IOracleRouter(address(oracle)), TIMELOCK);
        ifund = new InsuranceFund(IERC20(address(usdg)), TIMELOCK);
        vault = new PitVault(
            IERC20(address(usdg)), IOracleRouterVaultView(address(oracle)), IPerpRiskConfig(address(risk)), TIMELOCK
        );
        guardian = new PauseGuardian(guardianEoa);
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
            Types.FeeSplit({jackpot: jackpot, treasury: treasury, referralPool: referral, buyback: buyback, vault: address(vault)})
        );

        // Wiring (owner = the timelock in production; pranked here).
        vm.startPrank(TIMELOCK);
        vault.setEngine(address(engine));
        ifund.setEngine(address(engine));
        ifund.setVault(address(vault));
        // Governance lifts the bootstrap deposit-cap floor so the LP seed lands in one epoch.
        vault.setDepositEpochCap(10_000, 2_000_000e6);
        // Disarm ONLY the RE-ECON-1 vol-scaled borrow layer for these scenarios: every
        // exact-value fixture below was calibrated against the plain utilization borrow rate,
        // and the mark moves that drive the scenarios would otherwise re-rate it. The armed
        // layer's end-to-end behavior on the identical real stack is proven in
        // PerpPatientStraddlePoC.t.sol; the remaining vol knobs stay at launch values.
        risk.setVolParams(
            PerpTypes.VolParams({
                kVolX100: risk.DEFAULT_K_VOL_X100(),
                maxVolSurchargeBps: risk.DEFAULT_MAX_VOL_SURCHARGE_BPS(),
                freshSurchargeStartBps: risk.DEFAULT_FRESH_SURCHARGE_START_BPS(),
                kCapVolX100: risk.DEFAULT_K_CAP_VOL_X100(),
                maxVolDiscountBps: risk.DEFAULT_MAX_VOL_DISCOUNT_BPS(),
                kBorrowVolX100: 0,
                volBorrowDeadbandBps: risk.DEFAULT_VOL_BORROW_DEADBAND_BPS(),
                maxVolBorrowMultX100: risk.DEFAULT_MAX_VOL_BORROW_MULT_X100(),
                volRefTauSeconds: risk.DEFAULT_VOL_REF_TAU()
            })
        );
        vm.stopPrank();

        // Listing: oracle knows the token, governance assigns the tier, engine lists.
        oracle.setLive(MEME, 1e18);
        oracle.setListable(MEME, true);
        vm.prank(TIMELOCK);
        risk.assignTier(MEME, 2); // 6x cap, MMR 10%, 10 bps fees, kF 0.25%/h, kB 0.01%/h
        vm.prank(TIMELOCK);
        engine.listMarket(MEME);

        // Skip the ENGINE's 14-day new-market reserve ramp (anchored at listing) AND the
        // 14-day fresh-market vol-surcharge window, so scenario fee math is undisturbed. The
        // VAULT's own linear ramp anchors at the first reservation, so each scenario still
        // trades inside 1%/day of TVL (10k USDG on day one) for realism; scenarios that need
        // more capacity widen it explicitly.
        vm.warp(block.timestamp + 15 days);

        // Insurance fund seed (spec 6.1 treasury seed).
        usdg.mint(address(this), IF_SEED);
        usdg.approve(address(ifund), IF_SEED);
        ifund.seed(IF_SEED);

        // Actors.
        usdg.mint(lp, LP_DEPOSIT);
        vm.prank(lp);
        usdg.approve(address(vault), type(uint256).max);
        address[2] memory traders = [alice, bob];
        for (uint256 i = 0; i < traders.length; i++) {
            usdg.mint(traders[i], TRADER_STAKE);
            vm.prank(traders[i]);
            usdg.approve(address(engine), type(uint256).max);
        }
    }

    // ================================ shared helpers ================================

    /// @dev Wei-exact conservation: every USDG ever minted sits with a known member of the
    ///      closed system. Any leak to an unexpected address breaks the holder sum.
    function _assertConservation(string memory tag) internal view {
        uint256 sum = usdg.balanceOf(lp) + usdg.balanceOf(alice) + usdg.balanceOf(bob) + usdg.balanceOf(keeper)
            + usdg.balanceOf(TIMELOCK) + usdg.balanceOf(address(engine)) + usdg.balanceOf(address(vault))
            + usdg.balanceOf(address(ifund)) + usdg.balanceOf(jackpot) + usdg.balanceOf(treasury)
            + usdg.balanceOf(referral) + usdg.balanceOf(buyback) + usdg.balanceOf(address(this));
        assertEq(sum, usdg.totalSupply(), string.concat("conservation: ", tag));
    }

    /// @dev Engine escrow solvency: the engine's balance must cover every open margin plus
    ///      any credited-but-unpulled fee shares.
    function _assertEngineEscrow(uint256 expectedMargins, string memory tag) internal view {
        assertEq(
            usdg.balanceOf(address(engine)), expectedMargins + engine.totalCredit(), string.concat("escrow: ", tag)
        );
    }

    function _seedVault() internal returns (uint256 shares) {
        vm.prank(lp);
        shares = vault.deposit(LP_DEPOSIT, lp);
    }

    function _openLong(address who, uint128 margin, uint32 lev) internal returns (bytes32 key) {
        vm.prank(who);
        key = engine.openPosition(MEME, true, margin, lev);
    }

    /// @dev ERC-4626 share mirror (OZ virtual shares, offset 6): independent recomputation.
    function _toShares(uint256 assets) internal view returns (uint256) {
        return Math.mulDiv(assets, vault.totalSupply() + 1e6, vault.totalAssets() + 1);
    }

    function _toAssets(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, vault.totalAssets() + 1, vault.totalSupply() + 1e6);
    }

    /// @dev Funding/borrow accrual mirror. MUST be called with pre-accrual aggregates, the
    ///      mark the engine will accrue at, and the TVL the engine will read in its preamble.
    function _accrualDeltas(uint256 dtSecs, uint256 mark, uint256 tvl)
        internal
        view
        returns (int256 fDelta, uint256 bDelta)
    {
        PerpTypes.MarketAggregates memory agg = engine.marketState(MEME);
        PerpTypes.TierParams memory p = risk.paramsFor(MEME);
        uint256 oiLong = MarginMathLib.notionalUsdg(agg.totalLongSize1e18, mark, SCALE);
        uint256 oiShort = MarginMathLib.notionalUsdg(agg.totalShortSize1e18, mark, SCALE);
        int256 rate = FundingLib.fundingRatePerHour1e18(
            FundingLib.skew1e18(oiLong, oiShort, engine.skewFloorUsdg()), p.kFPerHour1e18
        );
        fDelta = FundingLib.fundingIndexDelta1e18(rate, mark, dtSecs);
        uint256 bRate = FundingLib.borrowRatePerHour1e18(agg.totalMaxPayout, tvl, p.kBPerHour1e18);
        bDelta = FundingLib.borrowIndexDelta1e18(bRate, mark, dtSecs);
    }

    /// @dev Economics v2 25/10/VAULT 20/25/20 fee-split mirror (dust to treasury).
    function _feeShares(uint256 fee)
        internal
        pure
        returns (uint256 jack, uint256 refe, uint256 buy, uint256 trea)
    {
        jack = fee * 2_500 / BPS;
        refe = fee * 1_000 / BPS;
        buy = fee * 2_500 / BPS;
        trea = fee - jack - refe - _vaultFeeCut(fee) - buy;
    }

    /// @dev The vault's immutable 20% share of a trade fee (economics v2, finding A1).
    function _vaultFeeCut(uint256 fee) internal pure returns (uint256) {
        return fee * 2_000 / BPS;
    }

    // ================================ 1. LP deposit ================================

    /// @notice LP deposits USDG into the REAL vault: PLP minted at the virtual-share rate net
    ///         of the 10 bps fee, dead shares carved, and NAV equal to the full deposit (the
    ///         fee accrues to NAV). Engine aggregates are live in totalAssets from block one.
    function test_1_lpDepositSharesAndNav() public {
        assertEq(vault.totalAssets(), 0, "NAV starts empty");
        uint256 fee = LP_DEPOSIT * 10 / BPS; // 10 bps deposit fee
        // Empty-vault share rate: (assets - fee) * (0 + 1e6 virtual) / (0 + 1).
        uint256 grossShares = (LP_DEPOSIT - fee) * 1e6;

        uint256 shares = _seedVault();

        assertEq(shares, grossShares - vault.DEAD_SHARES(), "LP shares net of dead carve");
        assertEq(vault.balanceOf(lp), shares, "LP holds its shares");
        assertEq(vault.balanceOf(vault.DEAD_ADDRESS()), vault.DEAD_SHARES(), "dead shares carved");
        assertEq(vault.totalAssets(), LP_DEPOSIT, "NAV = full deposit (fee accrues to NAV)");
        assertEq(usdg.balanceOf(address(vault)), LP_DEPOSIT, "vault holds the cash");
        assertEq(vault.totalReserved(), 0, "nothing reserved yet");
        _assertConservation("after LP deposit");
    }

    // ================================ 2. open reserves + reconciliation ================================

    /// @notice A leveraged open against the REAL vault: fee routed 25/10/vault 20/25/20, net margin
    ///         escrowed in the engine, maxPayout reserved in the vault, and engine aggregates,
    ///         vault reservations and NAV all reconcile to the wei.
    function test_2_openReservesAndReconciles() public {
        _seedVault();
        uint256 margin = 1_000e6;
        uint32 lev = 600; // 6x, the tier cap

        uint256 openFee = Math.mulDiv(margin * lev / 100, 10, BPS); // 10 bps of intended notional
        uint256 marginNet = margin - openFee;
        uint256 size = MarginMathLib.sizeForNotional(marginNet * lev / 100, 1e18, SCALE);
        uint256 maxPayout = risk.payoutCapMultiple() * marginNet;
        assertEq(openFee, 6e6, "fee sanity");
        assertEq(marginNet, 994e6, "net margin sanity");
        assertEq(size, 5_964e18, "size sanity");
        assertEq(maxPayout, 8_946e6, "cap sanity");

        _openLong(alice, uint128(margin), lev);

        // Vault side.
        assertEq(vault.totalReserved(), maxPayout, "vault totalReserved");
        assertEq(vault.reservedBy(MEME), maxPayout, "vault per-market reserve");
        // Engine side.
        PerpTypes.MarketAggregates memory agg = engine.marketState(MEME);
        assertEq(agg.totalMaxPayout, maxPayout, "agg maxPayout");
        assertEq(agg.totalLongSize1e18, size, "agg long size");
        assertEq(agg.totalLongCost, MarginMathLib.notionalUsdg(size, 1e18, SCALE), "agg long cost");
        assertEq(agg.totalLongMargin, marginNet, "agg long margin");
        assertEq(engine.addressReserved(MEME, alice), maxPayout, "per-address reserve attribution");
        // Cash placement.
        _assertEngineEscrow(marginNet, "open escrow");
        assertEq(usdg.balanceOf(alice), TRADER_STAKE - margin, "trader debit");
        (uint256 j, uint256 r, uint256 b, uint256 t) = _feeShares(openFee);
        assertEq(usdg.balanceOf(jackpot), j, "jackpot fee leg");
        assertEq(usdg.balanceOf(referral), r, "referral fee leg");
        assertEq(usdg.balanceOf(buyback), b, "buyback fee leg");
        assertEq(usdg.balanceOf(treasury), t, "treasury fee leg");
        assertEq(vault.cumulativeFeeRevenue(), _vaultFeeCut(openFee), "vault fee leg counted");
        // NAV: trader uPnL is zero at the entry mark, so NAV moves by exactly the vault's
        // 20% fee share (real LP revenue, no shares minted).
        assertEq(vault.totalAssets(), LP_DEPOSIT + _vaultFeeCut(openFee), "NAV up by the vault fee share");
        _assertConservation("after open");
    }

    // ================================ 3. funding accrual + profit close ================================

    /// @notice Price moves up, funding accrues via pokeFunding (real skew math), the trader
    ///         closes in profit: the REAL vault pays the win from OUTSTANDING reserves (the
    ///         settle-before-release seam), the reserve is fully released, and LP NAV drops by
    ///         exactly the trader win net of the funding and borrow the position owed.
    /// @dev Locals for the profit-close mirror, bundled for stack relief.
    struct ProfitCalc {
        int256 fDelta;
        uint256 bDelta;
        uint256 win;
        uint256 closeFee;
        uint256 traderNet;
        uint256 vaultBefore;
        uint256 aliceBefore;
        uint256 jackBefore;
    }

    function test_3_fundingAccrualAndProfitClose() public {
        _seedVault();
        _openLong(alice, 1_000e6, 600);
        uint256 size = 5_964e18;
        ProfitCalc memory c;

        // One hour passes; the mark moves to $1.20.
        vm.warp(block.timestamp + 1 hours);
        oracle.setLive(MEME, 1.2e18);

        // Mirror the accrual the poke will perform (pre-accrual aggregates, poke-time TVL).
        (c.fDelta, c.bDelta) = _accrualDeltas(1 hours, 1.2e18, vault.totalAssets());
        engine.pokeFunding(MEME);
        {
            PerpTypes.MarketAggregates memory agg = engine.marketState(MEME);
            assertEq(int256(agg.fundingX1e18), c.fDelta, "funding index accrued exactly");
            assertEq(uint256(agg.borrowX1e18), c.bDelta, "borrow index accrued exactly");
            assertEq(agg.cachedMark1e18, 1.2e18, "NAV mark cached");
        }

        // Long-heavy skew: the long pays funding; borrow is always owed.
        int256 fundOwed = FundingLib.fundingOwedUsdg(size, c.fDelta, true, SCALE);
        uint256 borOwed = FundingLib.borrowOwedUsdg(size, c.bDelta, SCALE);
        assertGt(fundOwed, 0, "lone long must pay funding");

        // Vault NAV marked down by the trader's unrealized claim before the close.
        int256 rawPnl = MarginMathLib.uPnlUsdg(size, 1e18, 1.2e18, true, SCALE);
        assertEq(rawPnl, int256(1_192.8e6), "uPnL sanity");
        assertEq(
            vault.totalAssets(),
            LP_DEPOSIT + _vaultFeeCut(6e6) - uint256(rawPnl),
            "NAV nets unrealized trader profit (plus the open-fee vault leg)"
        );

        // Close in the same block as the poke: no further accrual interval.
        c.win = uint256(rawPnl - fundOwed - int256(borOwed)); // single netted vault outflow
        c.closeFee = Math.mulDiv(MarginMathLib.notionalUsdg(size, 1.2e18, SCALE), 10, BPS);
        c.traderNet = 994e6 + c.win - c.closeFee;

        c.vaultBefore = usdg.balanceOf(address(vault));
        c.aliceBefore = usdg.balanceOf(alice);
        c.jackBefore = usdg.balanceOf(jackpot);
        vm.prank(alice);
        engine.closePosition(MEME, true);

        assertEq(usdg.balanceOf(alice) - c.aliceBefore, c.traderNet, "trader payout exact");
        assertEq(
            c.vaultBefore - usdg.balanceOf(address(vault)),
            c.win - _vaultFeeCut(c.closeFee),
            "vault paid the netted win minus its close-fee share"
        );
        assertEq(vault.totalReserved(), 0, "reserve released");
        assertEq(vault.reservedBy(MEME), 0, "market reserve released");
        assertEq(engine.addressReserved(MEME, alice), 0, "address reserve released");
        _assertEngineEscrow(0, "engine empty after close");
        (uint256 j2,,,) = _feeShares(c.closeFee);
        assertEq(usdg.balanceOf(jackpot) - c.jackBefore, j2, "close fee routed");
        // LP NAV dropped by exactly the win: trader profit minus the funding + borrow flows
        // the vault kept (the 8,946 maxPayout was never hit, so no clamping anywhere).
        assertLt(c.win, 8_946e6, "win under the payout cap");
        assertEq(
            vault.totalAssets(),
            LP_DEPOSIT + _vaultFeeCut(6e6) + _vaultFeeCut(c.closeFee) - c.win,
            "NAV = seed plus fee legs minus netted trader win"
        );
        PerpTypes.MarketAggregates memory aggAfter = engine.marketState(MEME);
        assertEq(aggAfter.totalLongSize1e18, 0, "aggregates cleared");
        assertEq(aggAfter.totalMaxPayout, 0, "agg payout cleared");
        _assertConservation("after profit close");
    }

    // ================================ 4. loss close: the real transferFrom pull ================================

    /// @notice A second trader loses: the REAL vault PULLS the realized loss out of the
    ///         engine's escrow via settleTraderLoss (transferFrom against the constructor
    ///         approval), NAV rises by exactly the pulled amount, conservation holds.
    function test_4_lossCloseVaultPullsFromEngine() public {
        _seedVault();
        _openLong(bob, 1_000e6, 600);
        uint256 marginNet = 994e6;
        uint256 size = 5_964e18;

        vm.warp(block.timestamp + 1 hours);
        oracle.setLive(MEME, 0.95e18);

        // The close itself accrues one hour of funding + borrow at the new mark.
        uint256 tvlAtClose = vault.totalAssets();
        (int256 fDelta, uint256 bDelta) = _accrualDeltas(1 hours, 0.95e18, tvlAtClose);
        int256 fundOwed = FundingLib.fundingOwedUsdg(size, fDelta, true, SCALE);
        uint256 borOwed = FundingLib.borrowOwedUsdg(size, bDelta, SCALE);
        int256 rawPnl = MarginMathLib.uPnlUsdg(size, 1e18, 0.95e18, true, SCALE);
        assertEq(rawPnl, -int256(298.2e6), "loss sanity");

        uint256 payToVault = uint256(-rawPnl + fundOwed + int256(borOwed));
        assertLt(payToVault, marginNet, "loss inside margin: no bad debt");
        uint256 closedNotional = MarginMathLib.notionalUsdg(size, 0.95e18, SCALE);
        uint256 closeFee = Math.mulDiv(closedNotional, 10, BPS);
        uint256 traderNet = marginNet - payToVault - closeFee;

        uint256 vaultBefore = usdg.balanceOf(address(vault));
        uint256 bobBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        engine.closePosition(MEME, true);

        assertEq(
            usdg.balanceOf(address(vault)) - vaultBefore,
            payToVault + _vaultFeeCut(closeFee),
            "vault pulled the exact loss plus its close-fee share"
        );
        assertEq(usdg.balanceOf(bob) - bobBefore, traderNet, "loser residual exact");
        assertEq(vault.totalReserved(), 0, "reserve released");
        _assertEngineEscrow(0, "engine drained");
        // NAV rose by the realized loss + funding + borrow plus both fee legs.
        assertEq(
            vault.totalAssets(),
            LP_DEPOSIT + payToVault + _vaultFeeCut(6e6) + _vaultFeeCut(closeFee),
            "NAV up by the pull plus fee legs"
        );
        _assertConservation("after loss close");
    }

    // ================================ 5a. liquidation: residual waterfall ================================

    /// @notice Liquidation with positive equity: penalty split 20/40/40 between the keeper,
    ///         the REAL vault (economics v2 LP revenue) and the REAL InsuranceFund, residual
    ///         returned to the trader, loss pulled by the vault, reserve released. All actors'
    ///         balances land to the wei.
    function test_5a_liquidationResidualWaterfall() public {
        _seedVault();
        _openLong(alice, 1_000e6, 600);
        uint256 marginNet = 994e6;
        uint256 size = 5_964e18;

        // Same block: no funding, pure price math. $0.90 breaches the 10% MMR.
        oracle.setLive(MEME, 0.9e18);
        assertTrue(engine.liquidatable(MEME, alice, true), "view agrees position is under");

        int256 pnl = MarginMathLib.uPnlUsdg(size, 1e18, 0.9e18, true, SCALE); // -596.4e6
        uint256 payToVault = uint256(-pnl);
        uint256 pot = marginNet - payToVault; // == equity, 397.6e6
        uint256 notionalAtMark = MarginMathLib.notionalUsdg(size, 0.9e18, SCALE);
        uint256 mm = Math.mulDiv(notionalAtMark, 1_000, BPS);
        assertLt(pot, mm, "equity below maintenance");
        uint256 penalty = Math.mulDiv(notionalAtMark, 100, BPS); // 1% of notional
        uint256 keeperCut = penalty * 2_000 / BPS;
        uint256 vaultCut = penalty * 4_000 / BPS;
        uint256 fundCut = penalty - keeperCut - vaultCut;
        uint256 residual = pot - penalty;
        assertEq(keeperCut + vaultCut + fundCut + residual, pot, "penalty split conserves the pot");
        assertGe(keeperCut, 5e6, "keeper clears the floor: no fund top-up leg");

        uint256 vaultBefore = usdg.balanceOf(address(vault));
        uint256 ifBefore = usdg.balanceOf(address(ifund));
        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        assertEq(
            usdg.balanceOf(address(vault)) - vaultBefore,
            payToVault + vaultCut,
            "vault absorbed the loss plus its 40% penalty share"
        );
        assertEq(vault.cumulativeLiquidationRevenue(), vaultCut, "liquidation revenue counted");
        assertEq(usdg.balanceOf(keeper), keeperCut, "keeper reward exact");
        assertEq(usdg.balanceOf(address(ifund)) - ifBefore, fundCut, "insurance fund penalty leg exact");
        assertEq(usdg.balanceOf(alice) - aliceBefore, residual, "trader residual returned (dYdX model)");
        assertEq(vault.totalReserved(), 0, "reserve released");
        _assertEngineEscrow(0, "engine drained");
        assertEq(
            vault.totalAssets(),
            LP_DEPOSIT + payToVault + vaultCut + _vaultFeeCut(6e6),
            "NAV up by the absorbed loss, the penalty share and the open-fee leg"
        );
        assertEq(engine.getPosition(MEME, alice, true).size1e18, 0, "position gone");
        _assertConservation("after residual liquidation");
    }

    // ================================ 5b. liquidation: bad debt, IF covers ================================

    /// @notice A gap through the margin: price loss clamps at the isolated margin, so the
    ///         shortfall is exactly the accrued funding + borrow. The REAL InsuranceFund
    ///         covers it (paying the vault directly) and tops the keeper up to the 5 USDG
    ///         floor. IF balance, vault absorb and conservation are all exact.
    function test_5b_badDebtCoveredByInsuranceFund() public {
        _seedVault();
        _openLong(alice, 1_000e6, 600);
        uint256 marginNet = 994e6;
        uint256 size = 5_964e18;

        // Two days of lone-long funding accrual, then a crash through the margin.
        vm.warp(block.timestamp + 48 hours);
        oracle.setLive(MEME, 0.8e18);

        uint256 tvlAtLiq = vault.totalAssets();
        (int256 fDelta, uint256 bDelta) = _accrualDeltas(48 hours, 0.8e18, tvlAtLiq);
        int256 fundOwed = FundingLib.fundingOwedUsdg(size, fDelta, true, SCALE);
        uint256 borOwed = FundingLib.borrowOwedUsdg(size, bDelta, SCALE);
        assertGt(fundOwed, 0, "long paid 48h of funding");

        // Raw loss 1,192.8 exceeds the 994 margin: clamped, trader pays the whole margin and
        // the uncovered remainder is exactly funding + borrow.
        int256 clamped = MarginMathLib.clampPnl(
            MarginMathLib.uPnlUsdg(size, 1e18, 0.8e18, true, SCALE), marginNet, 8_946e6
        );
        assertEq(clamped, -int256(marginNet), "loss clamped at isolated margin");
        uint256 shortfall = uint256(fundOwed) + borOwed;
        assertGt(shortfall, 0, "bad debt present");
        assertLt(shortfall, IF_SEED, "fund can cover");

        uint256 vaultBefore = usdg.balanceOf(address(vault));
        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(engine));
        emit PerpEngine.BadDebt(MEME, alice, shortfall, shortfall, 0);
        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        // Vault got the whole margin from the engine plus the covered shortfall from the IF.
        assertEq(usdg.balanceOf(address(vault)) - vaultBefore, marginNet + shortfall, "vault made whole");
        // IF paid the cover plus the 5 USDG keeper floor (penalty pot was zero).
        assertEq(usdg.balanceOf(address(ifund)), IF_SEED - shortfall - 5e6, "IF outflow exact");
        assertEq(ifund.balance(), IF_SEED - shortfall - 5e6, "IF view agrees");
        assertEq(usdg.balanceOf(keeper), 5e6, "keeper floor top-up");
        assertEq(usdg.balanceOf(alice), aliceBefore, "trader residual zero");
        assertEq(vault.totalReserved(), 0, "reserve released");
        _assertEngineEscrow(0, "engine drained");
        assertEq(
            vault.totalAssets(),
            LP_DEPOSIT + marginNet + shortfall + _vaultFeeCut(6e6),
            "NAV exact after cover (plus the open-fee leg)"
        );
        _assertConservation("after bad-debt liquidation");
    }

    // ================================ 5c. liquidation: IF empty, ADL absorbs ================================

    /// @notice The full last-resort waterfall: the insurance fund is drained, a bad-debt
    ///         liquidation escalates to ADL, and the opposite-side winner is force-closed at
    ///         a profit haircut exactly equal to the uncovered shortfall. Zero net vault
    ///         outflow for the haircut leg; conservation exact.
    function test_5c_badDebtEscalatesToAdl() public {
        // Drain the IF through the rate-limited governance path (timelocked in production;
        // owner-pranked here): walk withdrawal windows until the fund is empty.
        while (ifund.balance() > 0) {
            uint256 amt = ifund.govWithdrawAvailable();
            if (amt > ifund.balance()) amt = ifund.balance();
            vm.prank(TIMELOCK);
            ifund.governanceWithdraw(TIMELOCK, amt);
            if (ifund.balance() > 0) vm.warp(block.timestamp + ifund.GOV_WITHDRAW_WINDOW());
        }
        assertEq(ifund.balance(), 0, "IF empty");
        _seedVault();
        // The two-sided book reserves 13,419 USDG; the vault's day-one linear ramp allows 10k,
        // so governance widens it for this scenario (the ramp itself is tested in PitVault.t).
        vm.prank(TIMELOCK);
        vault.setNewMarketRamp(10_000, 0);

        _openLong(alice, 1_000e6, 600); // 994e6 net, 5964e18 size, long
        vm.prank(bob);
        engine.openPosition(MEME, false, 500e6, 600); // 497e6 net, 2982e18 size, short
        uint256 sizeA = 5_964e18;
        uint256 sizeB = 2_982e18;

        vm.warp(block.timestamp + 24 hours);
        oracle.setLive(MEME, 0.8e18);

        uint256 tvlAtLiq = vault.totalAssets();
        (int256 fDelta, uint256 bDelta) = _accrualDeltas(24 hours, 0.8e18, tvlAtLiq);
        // Alice (long, majority side) owes funding; Bob (short, minority) receives it.
        int256 fundA = FundingLib.fundingOwedUsdg(sizeA, fDelta, true, SCALE);
        uint256 borA = FundingLib.borrowOwedUsdg(sizeA, bDelta, SCALE);
        int256 fundB = FundingLib.fundingOwedUsdg(sizeB, fDelta, false, SCALE);
        uint256 borB = FundingLib.borrowOwedUsdg(sizeB, bDelta, SCALE);
        assertGt(fundA, 0, "long pays");
        assertLt(fundB, 0, "short receives");

        uint256 shortfall = uint256(fundA) + borA; // loss clamped at margin, as in 5b
        int256 pnlB = MarginMathLib.clampPnl(
            MarginMathLib.uPnlUsdg(sizeB, 1e18, 0.8e18, false, SCALE), 497e6, 4_473e6
        );
        assertEq(pnlB, int256(596.4e6), "victim profit sanity");
        assertLt(shortfall, uint256(pnlB), "one victim absorbs the whole shortfall");

        // Bob's forced close at the haircut: win = (pnl - haircut) + funding credit - borrow.
        uint256 winB = uint256(pnlB - int256(shortfall) - fundB - int256(borB));
        uint256 potB = 497e6 + winB; // no close fee on ADL

        uint256 vaultBefore = usdg.balanceOf(address(vault));
        uint256 bobBefore = usdg.balanceOf(bob);
        vm.expectEmit(true, true, false, true, address(engine));
        emit PerpEngine.AdlExecuted(MEME, bob, false, shortfall, 0.8e18);
        vm.expectEmit(true, true, false, true, address(engine));
        emit PerpEngine.BadDebt(MEME, alice, shortfall, 0, shortfall);
        vm.prank(keeper);
        engine.liquidate(MEME, alice, true);

        // Vault: received Alice's whole margin, paid Bob's haircut-reduced win. The haircut
        // saved it exactly the uncovered shortfall relative to an honest close of Bob.
        assertEq(
            int256(usdg.balanceOf(address(vault))) - int256(vaultBefore),
            int256(994e6) - int256(winB),
            "vault net flow exact"
        );
        assertEq(usdg.balanceOf(bob) - bobBefore, potB, "ADL victim payout exact");
        assertEq(usdg.balanceOf(keeper), 0, "empty IF cannot pay the keeper floor (best effort)");
        assertEq(vault.totalReserved(), 0, "both reserves released");
        assertEq(engine.getPosition(MEME, alice, true).size1e18, 0, "bad-debt position gone");
        assertEq(engine.getPosition(MEME, bob, false).size1e18, 0, "victim position gone");
        assertEq(engine.positionKeysOf(MEME).length, 0, "key set empty");
        _assertEngineEscrow(0, "engine drained");
        // Open fees: alice 6e6 + bob 3e6 paid 20% each to the vault.
        assertEq(
            vault.totalAssets(),
            LP_DEPOSIT + 994e6 - winB + _vaultFeeCut(6e6) + _vaultFeeCut(3e6),
            "NAV exact after ADL (plus the open-fee legs)"
        );
        _assertConservation("after ADL");
    }

    // ================================ 6. withdraw queue: epoch + claim ================================

    /// @notice LP exit through the REAL two-step queue while open interest reserves capacity:
    ///         settlement prices at settlement-time NAV, fulfilment is bounded by the solvency
    ///         floor (1.2x totalReserved), PLP burns exactly, the remainder rolls, and the
    ///         claim pays the crystallized USDG to the wei.
    /// @dev Locals for the queue-settlement mirror, bundled for stack relief.
    struct QueueCalc {
        uint256 floorAssets;
        uint256 fulfilled;
        uint256 netOwed;
        uint256 owed;
        uint256 supplyBefore;
        uint256 lpBefore;
        uint256 navBeforeClaim;
    }

    function test_6_withdrawQueueSolvencyFloorAndClaim() public {
        uint256 lpShares = _seedVault();
        _openLong(alice, 1_000e6, 600); // reserves 8,946 USDG against the vault
        QueueCalc memory q;

        // Lift the 25% epoch cap so the SOLVENCY FLOOR is the binding constraint.
        vm.prank(TIMELOCK);
        vault.setWithdrawEpochCapBps(10_000);

        vm.prank(lp);
        vault.requestWithdraw(lpShares);
        uint64 reqEpoch = vault.currentEpoch();
        assertEq(vault.balanceOf(address(vault)), lpShares, "shares locked in the vault");

        vm.warp(block.timestamp + 25 hours); // epoch matures; mark unchanged so NAV is stable

        // Mirror the settlement math against live state (price still $1, so NAV == seed plus
        // the vault's 20% share of the 6 USDG open fee).
        uint256 nav = LP_DEPOSIT + _vaultFeeCut(6e6);
        assertEq(vault.totalAssets(), nav, "NAV stable through the epoch");
        {
            uint256 gross = _toAssets(lpShares);
            q.floorAssets = Math.mulDiv(8_946e6, 12_000, BPS); // 1.2x totalReserved
            uint256 headroom = nav - q.floorAssets;
            assertLt(headroom, gross, "solvency floor binds this settlement");
            q.fulfilled = Math.mulDiv(lpShares, headroom, gross);
            uint256 grossAssets = _toAssets(q.fulfilled);
            q.netOwed = grossAssets - Math.mulDiv(grossAssets, 10, BPS);
            q.owed = Math.mulDiv(q.fulfilled, Math.mulDiv(q.netOwed, 1e18, q.fulfilled), 1e18);
        }

        q.supplyBefore = vault.totalSupply();
        vault.settleEpoch(reqEpoch);

        assertEq(q.supplyBefore - vault.totalSupply(), q.fulfilled, "PLP burned exactly");
        assertEq(vault.totalClaimLiability(), q.netOwed, "liability crystallized");
        assertGe(vault.totalAssets(), q.floorAssets, "solvency floor respected post-settlement");

        // Claim: pays the user's floor-rounded slice; the request remainder rolled forward.
        q.lpBefore = usdg.balanceOf(lp);
        q.navBeforeClaim = vault.totalAssets();
        vm.prank(lp);
        uint256 claimed = vault.claim();

        assertEq(claimed, q.owed, "claim mirrors the per-share settlement price");
        assertEq(usdg.balanceOf(lp) - q.lpBefore, q.owed, "USDG out at settlement NAV");
        assertEq(vault.totalAssets(), q.navBeforeClaim, "claim is NAV-neutral");
        (uint128 remShares, uint64 remEpoch) = vault.requestOf(lp);
        assertEq(uint256(remShares), lpShares - q.fulfilled, "remainder rolled");
        assertEq(remEpoch, vault.currentEpoch(), "rolled into the settlement-time epoch");
        assertEq(vault.balanceOf(address(vault)), lpShares - q.fulfilled, "vault holds only the rolled shares");
        _assertConservation("after queue claim");

        // The trader can still exit in full afterwards: reserves stayed solvent.
        vm.prank(alice);
        engine.closePosition(MEME, true);
        assertEq(vault.totalReserved(), 0, "reserve released after the LP exit wave");
        _assertConservation("after post-queue close");
    }

    // ================================ 7. manipulation gate, end to end ================================

    /// @notice The spec 2.3 gating matrix against the REAL engine + REAL vault: on a FALLBACK
    ///         print (OK price, dirty breaker) opens and liquidations revert while closes and
    ///         addMargin succeed, and on a BLOCKED print closes revert too but addMargin still
    ///         works. Funding accrual stays frozen throughout (non-LIVE prints).
    function test_7_manipulationGateEndToEnd() public {
        _seedVault();
        // The addMargin steps push total reserve to 10,296 USDG, past the vault's 10k day-one
        // linear ramp: governance widens it (the ramp itself is tested in PitVault.t).
        vm.prank(TIMELOCK);
        vault.setNewMarketRamp(10_000, 0);
        _openLong(alice, 1_000e6, 600);
        uint256 reservedAfterOpen = 8_946e6;

        // Breaker trips: ring-median FALLBACK print at the same price.
        oracle.setFallback(MEME, 1e18);

        // Opens: denied.
        vm.prank(bob);
        vm.expectRevert(PerpEngine.PrintNotLive.selector);
        engine.openPosition(MEME, true, 1_000e6, 600);
        // Liquidations: paused, even if the fallback price were adverse.
        vm.prank(keeper);
        vm.expectRevert(PerpEngine.PrintNotLive.selector);
        engine.liquidate(MEME, alice, true);
        assertFalse(engine.liquidatable(MEME, alice, true), "view mirrors the pause");
        // removeMargin (risk-increasing): denied.
        vm.prank(alice);
        vm.expectRevert(PerpEngine.PrintNotLive.selector);
        engine.removeMargin(MEME, true, 10e6);

        // addMargin (strictly de-risking): allowed, and the REAL vault takes the reservation.
        vm.prank(alice);
        engine.addMargin(MEME, true, 100e6);
        assertEq(vault.totalReserved(), reservedAfterOpen + 900e6, "reserve grew through the breaker");
        assertEq(engine.getPosition(MEME, alice, true).margin, 994e6 + 100e6, "margin credited");
        _assertConservation("addMargin during fallback");

        // Full outage: BLOCKED print. Closes now revert too; addMargin still works.
        oracle.setBlocked(MEME);
        vm.prank(alice);
        vm.expectRevert(PerpEngine.PrintBlocked.selector);
        engine.closePosition(MEME, true);
        vm.prank(alice);
        engine.addMargin(MEME, true, 50e6);
        assertEq(vault.totalReserved(), reservedAfterOpen + 900e6 + 450e6, "reserve grew while blocked");
        _assertConservation("addMargin while blocked");

        // Back to FALLBACK: the user-initiated exit works at the ring-median price.
        oracle.setFallback(MEME, 1e18);
        uint256 margin = 994e6 + 100e6 + 50e6;
        uint256 closeFee = Math.mulDiv(MarginMathLib.notionalUsdg(5_964e18, 1e18, SCALE), 10, BPS);
        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        engine.closePosition(MEME, true);
        assertEq(usdg.balanceOf(alice) - aliceBefore, margin - closeFee, "flat exit on fallback print");
        assertEq(vault.totalReserved(), 0, "reserve released");
        PerpTypes.MarketAggregates memory agg = engine.marketState(MEME);
        assertEq(int256(agg.fundingX1e18), 0, "funding stayed frozen through non-LIVE prints");
        _assertEngineEscrow(0, "engine drained");
        _assertConservation("after fallback close");

        // Breaker heals: opens work again against the real stack.
        oracle.setLive(MEME, 1e18);
        vm.prank(bob);
        engine.openPosition(MEME, true, 1_000e6, 600);
        assertEq(vault.totalReserved(), reservedAfterOpen, "fresh open reserves again");
        _assertConservation("after recovery open");
    }

    // ================================ 8. payout cap bounds TOTAL vault outflow ================================

    /// @notice The at-cap winner holding a funding credit: a minority-side long rides a 2.6x
    ///         pump to the 9x payout clamp WHILE having received funding from the majority shorts.
    ///         The PRICE payout is bounded at the reserved maxPayout (the manipulation-proof cap),
    ///         but the funding credit is money the shorts actually paid, so B9 pays it on the
    ///         separate unbounded funding channel rather than confiscating it: the trader receives
    ///         margin + capped price payout + funding credit, and conservation holds to the wei.
    function test_8_payoutCapBoundsTotalVaultOutflow() public {
        _seedVault();
        // Governance widens the vault's new-market ramp so the majority short fits (the
        // engine-side ramp already expired 8 days after listing).
        vm.prank(TIMELOCK);
        vault.setNewMarketRamp(10_000, 0);

        _openLong(alice, 100e6, 600); // net 99.4e6, size 596.4e18, maxPayout 894.6e6
        vm.prank(bob);
        engine.openPosition(MEME, false, 2_500e6, 600); // net 2,485e6, size 14,910e18: majority short

        vm.warp(block.timestamp + 24 hours);
        oracle.setLive(MEME, 2.6e18); // the pump: alice's raw uPnL 954.24e6 > her 894.6e6 cap

        // Bob's close accrues 24h of short-heavy funding at the pump mark: shorts paid, alice
        // (minority long) accrued a funding CREDIT.
        (int256 fDelta, uint256 bDelta) = _accrualDeltas(24 hours, 2.6e18, vault.totalAssets());
        assertLt(fDelta, 0, "short-heavy skew: funding index fell");
        vm.prank(bob);
        engine.closePosition(MEME, false); // the bust short exits; IF covers its funding gap
        assertEq(vault.totalReserved(), 894_600_000, "only alice's reservation remains");

        int256 fundA = FundingLib.fundingOwedUsdg(596.4e18, fDelta, true, SCALE);
        uint256 borA = FundingLib.borrowOwedUsdg(596.4e18, bDelta, SCALE);
        assertLt(fundA, 0, "alice holds a funding credit");
        // The price payout is capped at the reservation; the funding credit rides on top (B9).
        uint256 credit = uint256(-fundA) - borA; // = preClampWin - 894.6e6
        assertGt(credit, 0, "credit pushes the raw ask past the reserved cap");

        uint256 closeFee = Math.mulDiv(MarginMathLib.notionalUsdg(596.4e18, 2.6e18, SCALE), 10, BPS);
        uint256 vaultBefore = usdg.balanceOf(address(vault));
        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        engine.closePosition(MEME, true); // same block as bob's close: no further accrual

        // Vault outflow = the reserved maxPayout (PRICE, manipulation-bounded) PLUS the funding
        // credit paid on the separate channel: the price cap still bounds price extraction, but a
        // legitimate funding credit is no longer confiscated (B9).
        assertEq(
            vaultBefore - usdg.balanceOf(address(vault)),
            894.6e6 + credit - _vaultFeeCut(closeFee),
            "capped price + funding credit, net of the vault's close-fee share"
        );
        assertEq(
            usdg.balanceOf(alice) - aliceBefore,
            99.4e6 + 894.6e6 + credit - closeFee,
            "trader gets margin + capped price + funding credit"
        );
        assertEq(vault.totalReserved(), 0, "reserve released");
        _assertEngineEscrow(0, "engine drained");
        _assertConservation("after capped exit");
    }

    // ================================ 9. reduce: real-vault conservation + funding credit ================================

    /// @dev Locals for the reduce mirror, bundled for stack relief.
    struct ReduceMirror {
        int256 fDelta;
        uint256 bDelta;
        uint256 credit;
        uint256 settledMargin;
        uint256 win;
        uint256 releasedMargin;
        uint256 newMargin;
        uint256 newMaxPayout;
        uint256 releaseAmt;
        uint256 closeFee;
        uint256 traderNet;
        uint256 vaultBefore;
        uint256 aliceBefore;
        uint256 jackBefore;
    }

    /// @notice B13: partial close against the REAL vault while the reducer holds a funding
    ///         CREDIT (minority long vs a majority short book). The closed slice's price win
    ///         is paid on the RESERVED channel (settleTraderWin, bounded by the outstanding
    ///         reservation) while the whole-position funding credit rides the SEPARATE
    ///         unbounded channel (settleFundingCredit, B9); both settle BEFORE the release
    ///         (event-order enforced against the real vault), and afterwards reservedBy equals
    ///         the sum of open maxPayouts with every balance wei-exact.
    function test_9_reduceRealVaultConservationWithFundingCredit() public {
        _seedVault();
        vm.prank(TIMELOCK);
        vault.setNewMarketRamp(10_000, 0); // fit the majority short, as in test_8

        _openLong(alice, 100e6, 600); // net 99.4e6, size 596.4e18, maxPayout 894.6e6
        vm.prank(bob);
        engine.openPosition(MEME, false, 2_500e6, 600); // net 2,485e6, size 14,910e18: majority short
        uint256 sizeA = 596.4e18;

        vm.warp(block.timestamp + 24 hours);
        oracle.setLive(MEME, 1.2e18); // modest pump: the slice win stays under the slice cap

        ReduceMirror memory m;
        (m.fDelta, m.bDelta) = _accrualDeltas(24 hours, 1.2e18, vault.totalAssets());
        {
            int256 fund = FundingLib.fundingOwedUsdg(sizeA, m.fDelta, true, SCALE);
            uint256 bor = FundingLib.borrowOwedUsdg(sizeA, m.bDelta, SCALE);
            assertLt(fund + int256(bor), 0, "minority long nets a funding credit");
            m.credit = uint256(-(fund + int256(bor)));
        }
        m.settledMargin = 99.4e6 + m.credit;

        // Mirror the 40% slice exactly as _computeReduce does.
        uint256 closedSize = sizeA * 4_000 / BPS; // 238.56e18
        uint256 remainSize = sizeA - closedSize;
        {
            int256 realized = MarginMathLib.clampPnl(
                MarginMathLib.uPnlUsdg(closedSize, 1e18, 1.2e18, true, SCALE),
                m.settledMargin * 4_000 / BPS,
                894.6e6 * 4_000 / BPS
            );
            assertGt(realized, 0, "slice closes in profit");
            assertLt(realized, int256(894.6e6 * 4_000 / BPS), "price win under the slice cap");
            m.win = uint256(realized);
        }
        {
            uint256 marginSlice = m.settledMargin * 4_000 / BPS;
            uint256 imReq = MarginMathLib.initialMarginUsdg(remainSize, 1.2e18, 600, SCALE);
            uint256 maxW = m.settledMargin > imReq ? m.settledMargin - imReq : 0;
            m.releasedMargin = marginSlice < maxW ? marginSlice : maxW;
        }
        m.newMargin = m.settledMargin - m.releasedMargin;
        m.newMaxPayout = 9 * m.newMargin;
        if (m.newMaxPayout > 894.6e6) m.newMaxPayout = 894.6e6;
        m.releaseAmt = 894.6e6 - m.newMaxPayout;
        assertGt(m.releaseAmt, 0, "the reservation shrinks with the slice");
        m.closeFee = Math.mulDiv(MarginMathLib.notionalUsdg(closedSize, 1.2e18, SCALE), 10, BPS);
        if (m.closeFee > m.releasedMargin + m.win) m.closeFee = m.releasedMargin + m.win;
        m.traderNet = m.releasedMargin + m.win - m.closeFee;

        m.vaultBefore = usdg.balanceOf(address(vault));
        m.aliceBefore = usdg.balanceOf(alice);
        m.jackBefore = usdg.balanceOf(jackpot);
        // Channel split AND ordering: the reserved price win, then the funding credit, and only
        // THEN the release (settle-before-release against the real vault).
        vm.expectEmit(true, false, false, true, address(vault));
        emit PitVault.TraderWinSettled(address(engine), m.win);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PitVault.FundingCreditSettled(address(engine), m.credit);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PitVault.PayoutReleased(MEME, m.releaseAmt, m.newMaxPayout + 22_365e6, m.newMaxPayout + 22_365e6);
        vm.prank(alice);
        engine.reducePosition(MEME, true, 4_000);

        // Cash placement, wei exact: engine USDG in == out across trader, vault and fees.
        assertEq(usdg.balanceOf(alice) - m.aliceBefore, m.traderNet, "trader payout exact");
        assertEq(
            m.vaultBefore - usdg.balanceOf(address(vault)),
            m.win + m.credit - _vaultFeeCut(m.closeFee),
            "vault outflow = price win + credit, net of its close-fee share"
        );
        (uint256 j,,,) = _feeShares(m.closeFee);
        assertEq(usdg.balanceOf(jackpot) - m.jackBefore, j, "close fee routed");
        // Position and reservation bookkeeping.
        PerpTypes.Position memory pos = engine.getPosition(MEME, alice, true);
        assertEq(uint256(pos.size1e18), remainSize, "size sliced");
        assertEq(uint256(pos.margin), m.newMargin, "margin: settled once, sliced once");
        assertEq(uint256(pos.maxPayout), m.newMaxPayout, "maxPayout recomputed on the remaining margin");
        PerpTypes.MarketAggregates memory agg = engine.marketState(MEME);
        assertEq(int256(pos.entryFundingX1e18), int256(agg.fundingX1e18), "funding re-anchored: no double credit");
        assertEq(uint256(pos.entryBorrowX1e18), uint256(agg.borrowX1e18), "borrow re-anchored");
        uint256 sumMaxPayouts = m.newMaxPayout + uint256(engine.getPosition(MEME, bob, false).maxPayout);
        assertEq(vault.reservedBy(MEME), sumMaxPayouts, "reservedBy == sum of open maxPayouts");
        assertEq(vault.totalReserved(), sumMaxPayouts, "totalReserved consistent");
        assertEq(uint256(agg.totalMaxPayout), sumMaxPayouts, "engine aggregate mirrors the vault");
        assertEq(engine.addressReserved(MEME, alice), m.newMaxPayout, "address reserve tracks");
        _assertEngineEscrow(m.newMargin + 2_485e6, "escrow = sum of open margins");
        _assertConservation("after credit-bearing reduce");
    }

    // ================================ 10. reduce: at the maxPayout cap boundary ================================

    /// @notice B13 boundary: the closed slice's raw price PnL OVERSHOOTS the slice's maxPayout
    ///         bound, so the REAL vault pays exactly the clamped slice cap on the reserved
    ///         channel and not a wei more (no funding leg: same-block, zero accrual interval).
    ///         The IM floor at the pumped mark binds, so no margin releases, the reservation
    ///         stays put (releaseAmt zero), and the remainder still closes clean afterwards.
    function test_10_reduceAtPayoutCapBoundary() public {
        _seedVault();
        _openLong(alice, 1_000e6, 600); // net 994e6, size 5,964e18, maxPayout 8,946e6

        oracle.setLive(MEME, 2.6e18); // same block: no funding, pure price math

        uint256 capSlice = 8_946e6 * 5_000 / BPS; // 4,473e6: the slice's payout bound
        int256 raw = MarginMathLib.uPnlUsdg(2_982e18, 1e18, 2.6e18, true, SCALE);
        assertGt(raw, int256(capSlice), "raw slice pnl overshoots the slice cap");
        // IM at $2.60 exceeds the whole margin pool, so zero margin releases and the remaining
        // maxPayout re-clamps to the original value: the reservation must NOT move.
        assertGt(MarginMathLib.initialMarginUsdg(2_982e18, 2.6e18, 600, SCALE), 994e6, "IM floor binds");
        uint256 closeFee = Math.mulDiv(MarginMathLib.notionalUsdg(2_982e18, 2.6e18, SCALE), 10, BPS);

        uint256 vaultBefore = usdg.balanceOf(address(vault));
        uint256 aliceBefore = usdg.balanceOf(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PitVault.TraderWinSettled(address(engine), capSlice);
        vm.prank(alice);
        engine.reducePosition(MEME, true, 5_000);

        assertEq(
            vaultBefore - usdg.balanceOf(address(vault)),
            capSlice - _vaultFeeCut(closeFee),
            "vault outflow exactly the clamped cap, net of its close-fee share"
        );
        assertEq(usdg.balanceOf(alice) - aliceBefore, capSlice - closeFee, "trader nets the capped win less fee");
        PerpTypes.Position memory pos = engine.getPosition(MEME, alice, true);
        assertEq(uint256(pos.size1e18), 2_982e18, "half the size remains");
        assertEq(uint256(pos.margin), 994e6, "no margin released at the IM floor");
        assertEq(uint256(pos.maxPayout), 8_946e6, "maxPayout re-clamps to the original");
        assertEq(vault.reservedBy(MEME), 8_946e6, "reservation untouched (releaseAmt zero)");
        assertEq(vault.totalReserved(), 8_946e6, "totalReserved consistent");
        assertEq(engine.addressReserved(MEME, alice), 8_946e6, "address reserve untouched");
        _assertEngineEscrow(994e6, "escrow = remaining margin");
        _assertConservation("after at-cap reduce");

        // The remainder closes clean in the same block: full release, nothing minted or lost.
        uint256 win2 = uint256(MarginMathLib.uPnlUsdg(2_982e18, 1e18, 2.6e18, true, SCALE)); // 4,771.2e6 < 8,946e6
        aliceBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        engine.closePosition(MEME, true);
        assertEq(usdg.balanceOf(alice) - aliceBefore, 994e6 + win2 - closeFee, "close-out payout exact");
        assertEq(vault.totalReserved(), 0, "reserve fully released");
        assertEq(vault.reservedBy(MEME), 0, "market reserve fully released");
        _assertEngineEscrow(0, "engine drained");
        _assertConservation("after boundary close-out");
    }

    // ================================ 11. removeMargin: real-vault conservation + funding credit ================================

    /// @dev Locals for the removeMargin mirror, bundled for stack relief.
    struct RemoveMirror {
        int256 fDelta;
        uint256 bDelta;
        uint256 credit;
        uint256 settledMargin;
        uint256 newMargin;
        uint256 newMaxPayout;
        uint256 releaseAmt;
        uint256 vaultBefore;
        uint256 aliceBefore;
    }

    /// @notice B13: a successful de-risking removeMargin against the REAL vault while the
    ///         position holds a funding credit: the credit settles through the unbounded
    ///         funding channel BEFORE the reservation release, the trader receives exactly the
    ///         removed amount, the maxPayout re-derives from the post-settle margin (the
    ///         reservation shrinks), and no value is minted or lost in the closed system.
    function test_11_removeMarginRealVaultConservationWithFundingCredit() public {
        _seedVault();
        vm.prank(TIMELOCK);
        vault.setNewMarketRamp(10_000, 0);

        // 3x long: IM headroom so the withdrawal clears the anti-JELLY floor at the flat mark.
        vm.prank(alice);
        engine.openPosition(MEME, true, 200e6, 300); // fee 0.6e6, net 199.4e6, size 598.2e18, maxPayout 1,794.6e6
        vm.prank(bob);
        engine.openPosition(MEME, false, 2_500e6, 600); // majority short: the long side RECEIVES funding

        vm.warp(block.timestamp + 24 hours); // flat mark: zero price pnl, the credit leg isolated

        RemoveMirror memory m;
        (m.fDelta, m.bDelta) = _accrualDeltas(24 hours, 1e18, vault.totalAssets());
        {
            int256 fund = FundingLib.fundingOwedUsdg(598.2e18, m.fDelta, true, SCALE);
            uint256 bor = FundingLib.borrowOwedUsdg(598.2e18, m.bDelta, SCALE);
            assertLt(fund + int256(bor), 0, "minority long nets a funding credit");
            m.credit = uint256(-(fund + int256(bor)));
        }
        assertLt(m.credit, 60e6, "credit below the removed amount: the reservation must shrink");
        m.settledMargin = 199.4e6 + m.credit;
        m.newMargin = m.settledMargin - 60e6;
        m.newMaxPayout = 9 * m.newMargin; // < 1,794.6e6 exactly because credit < 60e6
        m.releaseAmt = 1_794.6e6 - m.newMaxPayout;
        assertGe(m.newMargin, MarginMathLib.initialMarginUsdg(598.2e18, 1e18, 600, SCALE), "above the IM floor");

        m.vaultBefore = usdg.balanceOf(address(vault));
        m.aliceBefore = usdg.balanceOf(alice);
        // The credit settles BEFORE the release, both against the real vault.
        vm.expectEmit(true, false, false, true, address(vault));
        emit PitVault.FundingCreditSettled(address(engine), m.credit);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PitVault.PayoutReleased(MEME, m.releaseAmt, m.newMaxPayout + 22_365e6, m.newMaxPayout + 22_365e6);
        vm.prank(alice);
        engine.removeMargin(MEME, true, 60e6);

        assertEq(usdg.balanceOf(alice) - m.aliceBefore, 60e6, "trader receives exactly the removed amount");
        assertEq(m.vaultBefore - usdg.balanceOf(address(vault)), m.credit, "vault paid only the funding credit");
        PerpTypes.Position memory pos = engine.getPosition(MEME, alice, true);
        assertEq(uint256(pos.margin), m.newMargin, "margin = settled credit minus withdrawal, applied once");
        assertEq(uint256(pos.maxPayout), m.newMaxPayout, "maxPayout re-derived from the settled margin");
        PerpTypes.MarketAggregates memory agg = engine.marketState(MEME);
        assertEq(int256(pos.entryFundingX1e18), int256(agg.fundingX1e18), "funding re-anchored: no double credit");
        assertEq(uint256(pos.entryBorrowX1e18), uint256(agg.borrowX1e18), "borrow re-anchored");
        uint256 sumMaxPayouts = m.newMaxPayout + uint256(engine.getPosition(MEME, bob, false).maxPayout);
        assertEq(vault.reservedBy(MEME), sumMaxPayouts, "reservedBy == sum of open maxPayouts");
        assertEq(vault.totalReserved(), sumMaxPayouts, "totalReserved consistent");
        assertEq(uint256(agg.totalMaxPayout), sumMaxPayouts, "engine aggregate mirrors the vault");
        assertEq(engine.addressReserved(MEME, alice), m.newMaxPayout, "address reserve tracks");
        _assertEngineEscrow(m.newMargin + 2_485e6, "escrow = sum of open margins");
        _assertConservation("after credit-bearing removeMargin");
    }

    // ================================ 12. increase: real-vault reserve-then-settle ================================

    /// @dev Locals for the increase mirror, bundled for stack relief.
    struct IncreaseMirror {
        int256 fDelta;
        uint256 bDelta;
        uint256 credit;
        uint256 addedNet;
        uint256 addedSize;
        uint256 payoutAdd;
        uint256 entryAfter;
        uint256 vaultBefore;
        uint256 aliceBefore;
        uint256 jackBefore;
    }

    /// @notice B13: increasePosition against the REAL vault with a funding credit pending: the
    ///         reservation GROWS FIRST (PayoutReserved) and only then does the credit settle on
    ///         the unbounded funding channel (the reserve-then-settle ordering pa-accounting
    ///         verified in code, here proven against the live vault), the entry price is
    ///         size-weighted, the mmr snapshot adopts the STRICTER of the grandfathered and the
    ///         live tier ratio after a permissionless downgrade, funding settles exactly once,
    ///         and every balance and reservation reconciles to the wei.
    function test_12_increaseRealVaultConservationReserveThenSettle() public {
        _seedVault();
        vm.prank(TIMELOCK);
        vault.setNewMarketRamp(10_000, 0);

        vm.prank(alice);
        engine.openPosition(MEME, false, 500e6, 600); // net 497e6, size 2,982e18 short, maxPayout 4,473e6
        vm.prank(bob);
        engine.openPosition(MEME, true, 2_500e6, 600); // net 2,485e6, size 14,910e18: majority long PAYS funding
        assertEq(uint256(engine.getPosition(MEME, alice, false).entryMmrBps), 1_000, "tier-2 mmr snapshot at open");

        vm.warp(block.timestamp + 24 hours);
        oracle.setLive(MEME, 0.15e18); // dump: FDV $450K, alice's short deep in (uncapped) profit
        // Permissionless downgrade to tier 0 (mmr 15%, locked leverage 4x): the merged position
        // must adopt the STRICTER maintenance ratio.
        risk.refreshTier(MEME);
        assertEq(uint256(risk.mcapTierOf(MEME)), 0, "downgraded to tier 0");

        IncreaseMirror memory m;
        (m.fDelta, m.bDelta) = _accrualDeltas(24 hours, 0.15e18, vault.totalAssets());
        {
            int256 fund = FundingLib.fundingOwedUsdg(2_982e18, m.fDelta, false, SCALE);
            uint256 bor = FundingLib.borrowOwedUsdg(2_982e18, m.bDelta, SCALE);
            assertLt(fund + int256(bor), 0, "minority short nets a funding credit");
            m.credit = uint256(-(fund + int256(bor)));
        }
        // Added slice at 3x (tier 0 locks leverage at 4x): fee 10 bps of the added notional.
        m.addedNet = 300e6 - 900_000; // openFee = 300e6 * 3 * 10 / 10_000 = 0.9e6
        m.addedSize = MarginMathLib.sizeForNotional(m.addedNet * 3, 0.15e18, SCALE); // 897.3 USDG notional
        m.payoutAdd = 9 * m.addedNet; // 2,691.9e6
        m.entryAfter = MarginMathLib.weightedEntry1e18(2_982e18, 1e18, m.addedSize, 0.15e18);

        m.vaultBefore = usdg.balanceOf(address(vault));
        m.aliceBefore = usdg.balanceOf(alice);
        m.jackBefore = usdg.balanceOf(jackpot);
        // Reserve-then-settle: the reservation grows FIRST, then the credit settles against the
        // GROWN book, both against the real vault.
        vm.expectEmit(true, false, false, true, address(vault));
        emit PitVault.PayoutReserved(MEME, m.payoutAdd, 29_529.9e6, 29_529.9e6); // 4,473 + 22,365 + 2,691.9
        vm.expectEmit(true, false, false, true, address(vault));
        emit PitVault.FundingCreditSettled(address(engine), m.credit);
        vm.prank(alice);
        engine.increasePosition(MEME, false, 300e6, 300);

        // Cash placement, wei exact.
        assertEq(m.aliceBefore - usdg.balanceOf(alice), 300e6, "trader debited the gross added margin");
        assertEq(
            m.vaultBefore - usdg.balanceOf(address(vault)),
            m.credit - _vaultFeeCut(900_000),
            "vault paid the funding credit, net of its open-fee share"
        );
        (uint256 j,,,) = _feeShares(900_000);
        assertEq(usdg.balanceOf(jackpot) - m.jackBefore, j, "open fee routed");
        // Position state: one settle, weighted entry, stricter mmr, re-anchored indices.
        PerpTypes.Position memory pos = engine.getPosition(MEME, alice, false);
        assertEq(uint256(pos.margin), 497e6 + m.credit + m.addedNet, "funding settled ONCE into the merged margin");
        assertEq(uint256(pos.size1e18), 2_982e18 + m.addedSize, "size merged");
        assertEq(uint256(pos.entryPrice1e18), m.entryAfter, "size-weighted entry price");
        assertEq(uint256(pos.maxPayout), 4_473e6 + m.payoutAdd, "maxPayout grew by the added reserve");
        assertEq(uint256(pos.entryMmrBps), 1_500, "stricter-of mmr adopted on increase");
        PerpTypes.MarketAggregates memory agg = engine.marketState(MEME);
        assertEq(int256(pos.entryFundingX1e18), int256(agg.fundingX1e18), "funding re-anchored: no double credit");
        assertEq(uint256(pos.entryBorrowX1e18), uint256(agg.borrowX1e18), "borrow re-anchored");
        // Reservations: the grown book reconciles everywhere.
        uint256 sumMaxPayouts = uint256(pos.maxPayout) + uint256(engine.getPosition(MEME, bob, true).maxPayout);
        assertEq(sumMaxPayouts, 29_529.9e6, "sum of open maxPayouts");
        assertEq(vault.reservedBy(MEME), sumMaxPayouts, "reservedBy == sum of open maxPayouts");
        assertEq(vault.totalReserved(), sumMaxPayouts, "totalReserved consistent");
        assertEq(uint256(agg.totalMaxPayout), sumMaxPayouts, "engine aggregate mirrors the vault");
        assertEq(engine.addressReserved(MEME, alice), uint256(pos.maxPayout), "address reserve tracks");
        _assertEngineEscrow(uint256(pos.margin) + 2_485e6, "escrow = sum of open margins");
        _assertConservation("after credit-bearing increase");
    }
}
