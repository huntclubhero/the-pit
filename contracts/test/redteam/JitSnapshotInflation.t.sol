// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {MarketFactory} from "../../src/core/MarketFactory.sol";
import {PauseGuardian} from "../../src/core/PauseGuardian.sol";
import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {IPriceSource} from "../../src/oracle/adapters/IPriceSource.sol";
import {FullMath} from "../../src/oracle/vendor/FullMath.sol";
import {MockPitPoints} from "../mocks/MockPitPoints.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";

/// @dev Minimal functional 6-decimal USDG with mint AND burn so the PoC can (a) inflate a pool's
///      balanceOf and recover it inside a SINGLE transaction, exactly as a single-sided v3 LP
///      mint + burn does, and (b) support real offer/fill escrow transfers for the OI-capacity test.
contract PocUSDG {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Always-OK price stub. The depth measure never calls read(); this only needs to satisfy the
///      B_DEEP single-source minimum and serve an OK settlement/entry price.
contract PocSource is IPriceSource {
    function read(address) external view returns (uint256, uint256, bool) {
        return (1e18, block.timestamp, true);
    }
}

/// @dev The attacker. Performs the WHOLE just-in-time inflation atomically in one external call:
///      (1) single-sided quote deposit inflates the tracked pool's balanceOf,
///      (2) permissionless createMarket bakes the snapshot + payout cap as immutables,
///      (3) withdraw the deposit in the same tx. After the wave-2 W2-1 fix the snapshot no longer
///          keys off balanceOf, so step (1) does not move it: the baked caps track HONEST depth.
contract JitAttacker {
    PocUSDG public immutable usdg;
    MarketFactory public immutable factory;
    MockV3Pool public immutable pool;
    address public immutable token;

    constructor(PocUSDG usdg_, MarketFactory factory_, MockV3Pool pool_, address token_) {
        usdg = usdg_;
        factory = factory_;
        pool = pool_;
        token = token_;
    }

    function attack(uint256 inflateAmount) external returns (address market) {
        usdg.mint(address(pool), inflateAmount); // (1) flash single-sided LP: only quote lands in balanceOf
        market = factory.createMarket(token); // (2) snapshot + cap read from time-averaged in-range depth
        usdg.burn(address(pool), inflateAmount); // (3) withdraw next; fully recoverable, same tx
    }
}

/// @title JIT createMarket snapshot inflation, DEFEATED (wave-2 W2-1 fix; was red-oracle F1 /
///        red-jit / red-composition C-1)
/// @notice Regression PoC, FLIPPED. Wave 2 proved createMarket baked the immutable OI + payout caps
///         from a single-block-inflatable balanceOf. The fix re-bases the listing floor, creation
///         snapshot, and cost-to-move cap onto the TIME-AVERAGED IN-RANGE quote reserve (the router
///         reads UniV3TwapLib.consultMeanQuoteReserve over the settlement window). A single-sided
///         just-in-time LP deposit inflates only the pool's raw balance, never its time-averaged
///         in-range liquidity, so the same atomic attack now bakes the HONEST cap.
contract JitSnapshotInflationTest is Test {
    PocUSDG internal usdg;
    OracleRouter internal router;
    MockPitPoints internal points;
    PauseGuardian internal guardian;
    MarketFactory internal factory;
    MockV3Pool internal pool;
    PocSource internal source;
    JitAttacker internal attacker;

    address internal token = makeAddr("memecoin");
    address internal owner = makeAddr("owner");

    // Honest reality: a ~$30k single-pool memecoin (6-decimal USDG-quoted), whose HONEST
    // time-averaged in-range liquidity (at tick 0) is 30_000e6 native USDG.
    uint256 internal constant HONEST_DEPTH = 30_000e6;
    // JIT single-sided deposit: ~$5M of quote (flash-borrowed, recovered next block).
    uint256 internal constant INFLATE = 5_000_000e6;
    // Tier B params: coeff = ONE (costToMove == aggregate depth), safetyFactor 5, OI cap 10%.
    uint256 internal constant COEFF = 1e18;
    uint256 internal constant SAFETY = 5;
    uint16 internal constant OI_CAP_BPS = 1_000;
    uint32 internal constant WINDOW = 1_800;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new PocUSDG();
        router = new OracleRouter(owner, address(usdg));
        points = new MockPitPoints();
        guardian = new PauseGuardian(makeAddr("guardianMultisig"));
        factory = new MarketFactory(
            address(usdg),
            address(router),
            address(points),
            Types.FeeSplit({
                jackpot: makeAddr("jackpot"),
                treasury: makeAddr("treasury"),
                referralPool: makeAddr("referral"),
                buyback: makeAddr("buyback"),
                vault: address(0)
            }),
            OI_CAP_BPS,
            10_000, // per-address sub-cap 100% (not under test here)
            50,
            address(guardian),
            owner
        );

        pool = new MockV3Pool();
        source = new PocSource();

        // Owner configures the token as a listable Tier B_DEEP memecoin: 1 aggregating source, a
        // tracked USDG pool with declared geometry, low depth floor, seasoning disabled.
        vm.startPrank(owner);
        router.setTierConfig(token, OracleRouter.SettlementTier.B_DEEP, 25_000e18, 0, COEFF, SAFETY, 0, address(0));
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](1);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(source)), maxStaleness: 1 hours});
        router.setSources(token, sources);
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        router.setTrackedPools(token, pools);
        router.setPoolGeometry(address(pool), false, WINDOW); // USDG is token1: quoteIsToken0 = false
        vm.stopPrank();

        // Seed the pool's observation buffer so its HONEST time-averaged in-range quote reserve is
        // HONEST_DEPTH at tick 0. This is what backs the caps now, NOT balanceOf.
        _seedMeanLiquidity(pool, HONEST_DEPTH);

        attacker = new JitAttacker(usdg, factory, pool, token);
    }

    /// @dev Set the pool's observation buffer so consultMeanQuoteReserve(window) returns `targetL`
    ///      at tick 0 (mean tick 0 => sqrtP = 1 => reserve == mean in-range liquidity), AND fund the
    ///      pool with `targetL` of real quote so its concentration-aware depth (wave-3 R-1 / W2-1b:
    ///      MIN(virtual in-range reserve, real quote balanceOf)) equals targetL. An honest pool whose
    ///      in-range virtual quote reserve is targetL genuinely holds that quote, so the MIN does not
    ///      clamp it; only a CONCENTRATED pool (huge virtual reserve, small real balance) is clamped.
    function _seedMeanLiquidity(MockV3Pool p, uint256 targetL) internal {
        p.setTickCumulative(WINDOW, 0);
        p.setTickCumulative(0, 0);
        uint160 delta = uint160(FullMath.mulDiv(WINDOW, uint256(1) << 128, targetL));
        p.setSecondsPerLiquidityCumulative(WINDOW, 0);
        p.setSecondsPerLiquidityCumulative(0, delta);
        p.setRevertOnObserve(false);
        usdg.mint(address(p), targetL);
    }

    /// @notice The flagship claim, now DEFEATED and proven ATOMICALLY: a same-tx single-sided LP
    ///         deposit no longer raises the baked caps.
    function test_jit_bakedCapsTrackHonestDepthNotBalanceOf() public {
        // ---- Honest baseline (what an honest creation bakes) ----
        uint256 honestTracked = router.trackedLiquidity(token); // 2 * meanL * usdgScale
        assertGt(honestTracked, 25_000e18, "honest depth clears the floor");
        uint256 honestCostToMove = router.costToMoveEstimate1e18(token);
        assertEq(honestCostToMove, honestTracked, "coeff ONE: cost == depth");
        uint256 honestPayoutCap = router.maxMarketPayoutCap1e18(token);
        assertEq(honestPayoutCap, honestTracked / SAFETY, "honest payout cap = costToMove / 5");
        assertTrue(router.isListable(token), "token is honestly listable");

        // A raw balanceOf spike does NOT move the time-averaged measure at all: prove it directly.
        usdg.mint(address(pool), INFLATE);
        assertEq(router.trackedLiquidity(token), honestTracked, "balanceOf spike does not move depth");
        assertEq(router.costToMoveEstimate1e18(token), honestCostToMove, "balanceOf spike does not move cost");
        assertEq(router.maxMarketPayoutCap1e18(token), honestPayoutCap, "balanceOf spike does not move cap");
        usdg.burn(address(pool), INFLATE);

        // ---- The attack: one atomic transaction ----
        address mktAddr = attacker.attack(INFLATE);
        Market mkt = Market(mktAddr);

        // Pool is back to its honest quote balance after the same tx (the parked INFLATE is gone;
        // only the genuine HONEST_DEPTH quote remains).
        assertEq(usdg.balanceOf(address(pool)), HONEST_DEPTH, "pool holds only its honest quote after the attack");

        // ---- The market's IMMUTABLES are baked at the HONEST value, not the inflated one ----
        assertEq(mkt.liquiditySnapshot1e18(), honestTracked, "snapshot baked at HONEST depth");
        assertEq(mkt.maxPayoutCap1e18(), honestPayoutCap, "payout cap baked at HONEST depth / 5");

        // The effective baked OI cap is exactly the honest cap: no inflation survived.
        uint256 bakedOiCap = _min(honestTracked * OI_CAP_BPS / 10_000, honestPayoutCap);
        assertEq(_min(mkt.liquiditySnapshot1e18() * OI_CAP_BPS / 10_000, mkt.maxPayoutCap1e18()), bakedOiCap);

        emit log_named_uint("honest effective OI cap (1e18)", bakedOiCap);
        emit log_named_uint("baked  effective OI cap (1e18)", bakedOiCap);
    }

    /// @notice The JIT market accepts NO more open interest than an honestly created twin on the
    ///         same true-$30k pool: the frozen cap tracks honest liquidity, so oversized OI is
    ///         rejected on BOTH markets identically.
    function test_jit_marketDoesNotAcceptOversizedOI() public {
        // Honest twin: a second token on its own true-$30k pool, created with NO inflation.
        address htoken = makeAddr("honestMemecoin");
        MockV3Pool hpool = new MockV3Pool();
        vm.startPrank(owner);
        router.setTierConfig(htoken, OracleRouter.SettlementTier.B_DEEP, 25_000e18, 0, COEFF, SAFETY, 0, address(0));
        OracleRouter.SourceConfig[] memory s = new OracleRouter.SourceConfig[](1);
        s[0] = OracleRouter.SourceConfig({source: IPriceSource(address(source)), maxStaleness: 1 hours});
        router.setSources(htoken, s);
        address[] memory hp = new address[](1);
        hp[0] = address(hpool);
        router.setTrackedPools(htoken, hp);
        router.setPoolGeometry(address(hpool), false, WINDOW);
        vm.stopPrank();
        _seedMeanLiquidity(hpool, HONEST_DEPTH);
        Market honest = Market(factory.createMarket(htoken));

        // JIT market on the main token: its cap is the SAME honest cap as the twin.
        Market jit = Market(attacker.attack(INFLATE));
        assertEq(jit.maxPayoutCap1e18(), honest.maxPayoutCap1e18(), "JIT cap == honest cap");
        assertEq(jit.liquiditySnapshot1e18(), honest.liquiditySnapshot1e18(), "JIT snapshot == honest snapshot");

        // A fill escrowing ~200_000e6 of open interest: far above the ~6_000e6 honest cap.
        uint128 fill = 100_000e6;
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // Honest market REJECTS it (OiCapExceeded).
        _fund(alice, honest, fill);
        vm.prank(alice);
        uint256 hOffer =
            honest.postOffer(Types.Side.LONG, fill, 1_000e6, 1, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
        _fund(bob, honest, fill);
        vm.prank(bob);
        vm.expectRevert();
        honest.fillOffer(hOffer, fill);

        // The JIT market ALSO REJECTS the identical fill: its cap is the honest cap, not an inflated
        // one. The exploit is defeated.
        _fund(alice, jit, fill);
        vm.prank(alice);
        uint256 jOffer =
            jit.postOffer(Types.Side.LONG, fill, 1_000e6, 1, 10_000, 1 days, uint64(block.timestamp + 1 days), 0);
        _fund(bob, jit, fill);
        vm.prank(bob);
        vm.expectRevert();
        jit.fillOffer(jOffer, fill);

        // Both markets have zero open interest: neither accepted the oversized fill.
        assertEq(jit.openInterest(), 0, "JIT market opened no oversized OI");
        assertEq(honest.openInterest(), 0, "honest market opened no oversized OI");
    }

    function _fund(address who, Market m, uint128 amount) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(address(m), type(uint256).max);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
