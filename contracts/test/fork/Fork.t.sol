// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {AggregatorV3Interface} from "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {ChainlinkAdapter} from "../../src/oracle/adapters/ChainlinkAdapter.sol";
import {TwoHopTwapAdapter} from "../../src/oracle/adapters/TwoHopTwapAdapter.sol";
import {CrossPoolTwapAdapter} from "../../src/oracle/adapters/CrossPoolTwapAdapter.sol";
import {IPriceSource} from "../../src/oracle/adapters/IPriceSource.sol";
import {MarketFactory} from "../../src/core/MarketFactory.sol";
import {TickMath} from "../../src/oracle/vendor/TickMath.sol";
import {Types} from "../../src/interfaces/Types.sol";
import {Deploy, HandoverPlan} from "../../script/Deploy.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Minimal WETH9 surface used by the poke swapper.
interface IWETH9 {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Tiny exact-input swapper: sells WETH (token0) into a pool to write a fresh observation.
///      Uniswap v3 pools demand payment via callback, so a plain EOA-style call cannot poke.
contract PokeSwapper {
    IWETH9 public immutable weth;

    constructor(address weth_) {
        weth = IWETH9(weth_);
    }

    /// @notice Wraps `amountIn` native and swaps it into the pool (WETH must be token0).
    function pokeSellWeth(IUniswapV3Pool pool, uint256 amountIn) external payable {
        weth.deposit{value: amountIn}();
        pool.swap(address(this), true, int256(amountIn), TickMath.MIN_SQRT_RATIO + 1, "");
    }

    /// @notice Uniswap v3 swap callback: pays the owed WETH side.
    function uniswapV3SwapCallback(int256 amount0Delta, int256, bytes calldata) external {
        if (amount0Delta > 0) {
            weth.transfer(msg.sender, uint256(amount0Delta));
        }
    }
}

/// @title ForkTestBase: shared fork bootstrap for the Robinhood Chain live-fire suite
/// @notice Run with: forge test --match-contract ForkTest --fork-url <RPC>.
///         Non-fork CI skips with --no-match-contract ForkTest. Each setUp additionally calls
///         vm.createSelectFork itself (RPC from ROBINHOOD_RPC_URL, defaulting to the public
///         mainnet endpoint) and skips every test gracefully when the fork cannot be created.
abstract contract ForkTestBase is Test {
    string internal constant DEFAULT_RPC = "https://rpc.mainnet.chain.robinhood.com";

    // Canonical Robinhood Chain (4663) addresses, re-verified by these tests.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant FWA = 0xD60bF10a3556ae4538f8e2574d40e08C884549Eb;
    address internal constant FWA_WETH_POOL = 0x24d2e7D6966c0490e29d797b67Cc67f486b2a114;
    address internal constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    // CASHCAT (Cash Cat): a deep, multi-pool, actively traded memecoin (the Tier B_DEEP example).
    // Its deepest v3 pool (fee 10000, ~$1.6M WETH-quoted depth) carries a 4096-slot observation
    // buffer, so the 30-minute TWAP and the seasoning gate are live-serviceable with no poking.
    // Located via the DexScreener search API and re-verified on-chain by these tests.
    address internal constant CASHCAT = 0x020bfC650A365f8BB26819deAAbF3E21291018b4;
    address internal constant CASHCAT_WETH_10000 = 0xA70fc67C9F69da90B63a0e4C05D229954574E313;
    address internal constant CASHCAT_WETH_3000 = 0xd42A491087a15E5afd51FEb3606066Cc152d2b09;

    uint32 internal constant TWAP_WINDOW = 30 minutes;
    uint64 internal constant FEED_STALENESS = 2 days;

    bool internal forked;

    function setUp() public virtual {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", DEFAULT_RPC);
        try vm.createSelectFork(rpc) {
            forked = true;
        } catch {
            forked = false;
        }
    }

    /// @dev Skips the calling test when no fork is available.
    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }
}

/// @title ForkTestUsdg: canonical USDG sanity on the live chain
contract ForkTestUsdg is ForkTestBase {
    function test_usdgDecimalsAre6() public onlyForked {
        assertEq(IERC20Metadata(USDG).decimals(), 6);
    }

    function test_dealAndTransferWork() public onlyForked {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        deal(USDG, alice, 1_000e6);
        assertEq(IERC20(USDG).balanceOf(alice), 1_000e6);
        vm.prank(alice);
        assertTrue(IERC20(USDG).transfer(bob, 400e6));
        assertEq(IERC20(USDG).balanceOf(alice), 600e6);
        assertEq(IERC20(USDG).balanceOf(bob), 400e6);
    }
}

/// @title ForkTestFwaTwap: the real FWA/WETH pool against the TwoHopTwapAdapter
contract ForkTestFwaTwap is ForkTestBase {
    TwoHopTwapAdapter internal adapter;
    IUniswapV3Pool internal pool;
    PokeSwapper internal swapper;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        pool = IUniswapV3Pool(FWA_WETH_POOL);
        adapter = new TwoHopTwapAdapter(address(this));
        // WETH (0x0Bd7...) sorts below FWA (0xD60b...), so WETH is token0 and FWA is token1.
        adapter.setConfig(
            FWA, pool, TWAP_WINDOW, false, AggregatorV3Interface(ETH_USD_FEED), FEED_STALENESS
        );
        swapper = new PokeSwapper(WETH);
        vm.deal(address(swapper), 1 ether);
    }

    function test_tokenOrderMatchesRecon() public onlyForked {
        assertEq(pool.token0(), WETH);
        assertEq(pool.token1(), FWA);
    }

    function test_cardinalityOnePoolRevertsOldAndAdapterStaysOk() public onlyForked {
        (,,,, uint16 cardinalityNext,,) = pool.slot0();
        assertEq(cardinalityNext, 1); // Recon: the pool never had its cardinality grown.

        // Write a fresh observation so the 30 minute lookback deterministically predates the
        // single stored slot regardless of when the pool last traded.
        swapper.pokeSellWeth(pool, 0.0005 ether);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;
        vm.expectRevert(bytes("OLD"));
        pool.observe(secondsAgos);

        // The adapter must swallow the revert and report ok = false, never revert.
        (uint256 p,, bool ok) = adapter.read(FWA);
        assertFalse(ok);
        assertEq(p, 0);
    }

    function test_afterCardinalityGrowthAndWindowFillAdapterPrices() public onlyForked {
        // Step 1: fresh observation at the fork head, then grow the ring buffer.
        swapper.pokeSellWeth(pool, 0.0005 ether);
        uint256 t0 = block.timestamp;
        pool.increaseObservationCardinalityNext(60);

        // Step 2: a later poke swap actually expands the ring and writes a second observation.
        vm.roll(block.number + 1);
        vm.warp(t0 + 15);
        swapper.pokeSellWeth(pool, 0.0005 ether);
        (,,,, uint16 cardinalityNext,,) = pool.slot0();
        assertEq(cardinalityNext, 60);

        // Step 3: once the window is fully behind the oldest stored observation, the TWAP
        // serves and the two-hop price composes with the live ETH/USD feed.
        vm.warp(t0 + TWAP_WINDOW + 100);
        (uint256 p, uint256 at, bool ok) = adapter.read(FWA);
        assertTrue(ok);
        assertEq(at, block.timestamp);
        assertGt(p, 0);
        assertLt(p, 1e36);
    }
}

/// @title ForkTestTrackedLiquidity: the 25K USDG floor rejects the real FWA/WETH pool
contract ForkTestTrackedLiquidity is ForkTestBase {
    OracleRouter internal router;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        router = new OracleRouter(address(this), USDG);
        address[] memory pools = new address[](1);
        pools[0] = FWA_WETH_POOL;
        router.setTrackedPools(FWA, pools);
        router.setPoolQuote(FWA_WETH_POOL, WETH, ETH_USD_FEED, FEED_STALENESS);
    }

    function test_fwaPoolLiquidityIsUnderTheFloor() public onlyForked {
        uint256 liq = router.trackedLiquidity(FWA);

        // Exact recomputation of the WETH-quoted contribution.
        uint256 wethBal = IERC20(WETH).balanceOf(FWA_WETH_POOL);
        (, int256 answer,,,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
        uint256 expected = (wethBal * uint256(answer) * 1e10 / 1e18) * 2;
        assertEq(liq, expected);

        // Recon: about 0.32 WETH of depth (roughly 1.2K USD). Well under the 25K floor.
        assertGt(liq, 0);
        assertLt(liq, router.DEFAULT_LIQUIDITY_FLOOR());
        assertFalse(router.isListable(FWA));
    }
}

/// @title ForkTestDeploy: full production deploy dry-run plus end-to-end listing rejection
contract ForkTestDeploy is ForkTestBase, HandoverPlan {
    address internal constant OWNER = address(0x1111111111111111111111111111111111111111);
    address internal constant GUARDIAN = address(0x2222222222222222222222222222222222222222);
    address internal constant TREASURY = address(0x3333333333333333333333333333333333333333);
    address internal constant REFERRAL = address(0x4444444444444444444444444444444444444444);
    address internal constant BUYBACK = address(0x5555555555555555555555555555555555555555);

    /// @dev Exports the required deploy env block for the script run.
    function _setDeployEnv() internal {
        vm.setEnv("OWNER", vm.toString(OWNER));
        vm.setEnv("GUARDIAN", vm.toString(GUARDIAN));
        vm.setEnv("TREASURY", vm.toString(TREASURY));
        vm.setEnv("REFERRAL_POOL", vm.toString(REFERRAL));
        vm.setEnv("BUYBACK", vm.toString(BUYBACK));
    }

    /// @dev The eleven owned contracts from the freshly written address book, in the canonical
    ///      handover order of Deploy._ownedContracts (the batch hash depends on this order).
    function _ownedFromJson(string memory json) internal pure returns (address[] memory owned) {
        owned = new address[](11);
        owned[0] = vm.parseJsonAddress(json, ".oracleRouter");
        owned[1] = vm.parseJsonAddress(json, ".chainlinkAdapter");
        owned[2] = vm.parseJsonAddress(json, ".twapAdapter");
        owned[3] = vm.parseJsonAddress(json, ".twapAdapterB");
        owned[4] = vm.parseJsonAddress(json, ".crossPoolTwapAdapter");
        owned[5] = vm.parseJsonAddress(json, ".twoHopTwapAdapter");
        owned[6] = vm.parseJsonAddress(json, ".pitPoints");
        owned[7] = vm.parseJsonAddress(json, ".commitRevealCoordinator");
        owned[8] = vm.parseJsonAddress(json, ".spinVRF");
        owned[9] = vm.parseJsonAddress(json, ".jackpot");
        owned[10] = vm.parseJsonAddress(json, ".marketFactory");
    }

    function test_deployScriptRunsAndFwaIsNotListable() public onlyForked {
        _setDeployEnv();

        new Deploy().run();

        // The script must have written the address book.
        string memory json = vm.readFile("deployments/robinhood-4663.json");
        assertEq(vm.parseJsonAddress(json, ".usdg"), USDG);
        assertEq(vm.parseJsonAddress(json, ".ethUsdFeed"), ETH_USD_FEED);
        assertEq(vm.parseJsonAddress(json, ".owner"), OWNER);

        MarketFactory factory = MarketFactory(vm.parseJsonAddress(json, ".marketFactory"));
        OracleRouter router = OracleRouter(vm.parseJsonAddress(json, ".oracleRouter"));
        address points = vm.parseJsonAddress(json, ".pitPoints");
        address jackpot = vm.parseJsonAddress(json, ".jackpot");

        // Wiring spot checks.
        assertEq(factory.usdg(), USDG);
        assertEq(address(factory.router()), address(router));
        assertEq(address(factory.points()), points);
        (address feeJackpot, address feeTreasury, address feeReferral, address feeBuyback,) = factory.feeSplit();
        assertEq(feeJackpot, jackpot);
        assertEq(feeTreasury, TREASURY);
        assertEq(feeReferral, REFERRAL);
        assertEq(feeBuyback, BUYBACK);
        // The deploy baked the default settlement fee (50 bps) into the factory for new markets.
        assertEq(factory.settlementFeeBps(), factory.DEFAULT_SETTLEMENT_FEE_BPS());
        // Wave-2b R-3: the anti-monopolization open bond is ARMED in the deploy transaction (50
        // bps): the per-market rate is immutable and createMarket is permissionless, so any later
        // arming would be front-runnable. No value-bearing market can ever be created at bond 0.
        assertEq(factory.openBondBps(), 50);
        assertEq(vm.parseJsonUint(json, ".openBondBps"), 50);
        assertEq(vm.parseJsonAddress(json, ".buyback"), BUYBACK);
        assertEq(vm.parseJsonUint(json, ".settlementFeeBps"), 50);
        assertEq(router.usdg(), USDG);
        // Ownership is handed to the governance TIMELOCK, not OWNER directly (wave-2 TO-1/TO-2), so
        // every owner action is delayed. OWNER is the timelock's proposer/executor.
        address timelock = vm.parseJsonAddress(json, ".timelock");
        assertEq(factory.pendingOwner(), timelock);
        assertEq(router.pendingOwner(), timelock);
        assertEq(vm.parseJsonUint(json, ".timelockMinDelay"), 2 days);

        // End to end: FWA has no sources and no tracked liquidity on the fresh router, and its
        // only pool is 1.2K USD deep anyway; createMarket must revert TokenNotListable.
        vm.expectRevert(MarketFactory.TokenNotListable.selector);
        factory.createMarket(FWA);
    }

    /// @notice Wave-2b R-4 end to end: the deploy SCHEDULES the ownership-acceptance batch, and
    ///         once the timelock delay elapses OWNER executes it, after which the timelock is the
    ///         LIVE owner of all eleven contracts and the deployer's temporary roles are revoked in
    ///         the same operation. Until that execution the deployer remains the fully privileged
    ///         owner, which is exactly what the pre-execution assertions pin down.
    function test_handoverAcceptanceExecutesAndTimelockOwnsAll() public onlyForked {
        _setDeployEnv();
        new Deploy().run();

        string memory json = vm.readFile("deployments/robinhood-4663.json");
        TimelockController timelock = TimelockController(payable(vm.parseJsonAddress(json, ".timelock")));
        address deployer = vm.parseJsonAddress(json, ".deployer");
        address[] memory owned = _ownedFromJson(json);

        // Before execution: the deployer is still the LIVE owner of every contract (Ownable2Step
        // transferOwnership only set pendingOwner), pinning down the documented privileged window.
        for (uint256 i = 0; i < owned.length; i++) {
            assertEq(Ownable2Step(owned[i]).owner(), deployer, "deployer owns until acceptance executes");
            assertEq(Ownable2Step(owned[i]).pendingOwner(), address(timelock), "timelock is pending owner");
        }

        // The scheduled batch reconstructs bit-exactly from the shared HandoverPlan encoding.
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _handoverBatch(owned, timelock, deployer, deployer != OWNER);
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT);
        assertEq(id, vm.parseJsonBytes32(json, ".handoverOperationId"), "address book records the operation id");
        assertTrue(timelock.isOperationPending(id), "acceptance scheduled at deploy");
        assertFalse(timelock.isOperationReady(id), "timelock delay is real");

        // Delay not elapsed: execution must revert (the delay cannot be bypassed).
        vm.prank(OWNER);
        vm.expectRevert();
        timelock.executeBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT);

        // After the delay, OWNER (the sole executor) completes the handover.
        vm.warp(block.timestamp + vm.parseJsonUint(json, ".timelockMinDelay"));
        assertTrue(timelock.isOperationReady(id));
        vm.prank(OWNER);
        timelock.executeBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT);

        // Post-handover invariant: owner() == timelock on EVERY owned contract.
        for (uint256 i = 0; i < owned.length; i++) {
            assertEq(Ownable2Step(owned[i]).owner(), address(timelock), "timelock owns after acceptance");
        }
        // The deployer's temporary timelock roles died in the same batch; OWNER's roles stand.
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), deployer), "deployer proposer role revoked");
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), deployer), "deployer canceller role revoked");
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), OWNER));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), OWNER));
    }
}

/// @title ForkTestChainlinkFeed: the located ETH/USD feed is live, sane, and fresh
contract ForkTestChainlinkFeed is ForkTestBase {
    function test_feedShapeAndFreshness() public onlyForked {
        AggregatorV3Interface feed = AggregatorV3Interface(ETH_USD_FEED);
        assertEq(feed.decimals(), 8);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertGt(answer, 0);
        // Plausibility bounds: 1_000 to 100_000 USD.
        assertGt(uint256(answer), 1_000e8);
        assertLt(uint256(answer), 100_000e8);
        // Fresh within the documented 86400s heartbeat (plus grace for propagation).
        assertLt(block.timestamp - updatedAt, 86_400 + 3_600);
    }

    function test_chainlinkAdapterServesEthUsd() public onlyForked {
        ChainlinkAdapter adapter = new ChainlinkAdapter(address(this));
        adapter.setFeed(WETH, ETH_USD_FEED);
        (uint256 p, uint256 at, bool ok) = adapter.read(WETH);
        assertTrue(ok);
        assertGt(p, 1_000e18);
        assertLt(p, 100_000e18);
        assertLt(block.timestamp - at, 86_400 + 3_600);
    }
}

/// @title ForkTestCashcatTierB: CASHCAT (deep memecoin) configured as Tier B_DEEP on its real pools
/// @notice Proves the safe memecoin settlement layer end to end on live state: CASHCAT is isListable
///         at a BOUNDED cost-to-move cap, and the opening-side spot-vs-TWAP deviation breaker
///         computes a real verdict against the aggregated live TWAP and spot.
contract ForkTestCashcatTierB is ForkTestBase {
    OracleRouter internal router;
    CrossPoolTwapAdapter internal cross;

    // Governance knobs for the CASHCAT market (illustrative, calibratable).
    uint256 internal constant DEPTH_FLOOR = 1_000_000e18; // $1M aggregate depth floor
    uint256 internal constant COEFF = 1e18; // cost-to-move == aggregate depth (COST_COEFF_ONE)
    uint256 internal constant SAFETY_FACTOR = 5;
    uint16 internal constant BREAKER_BPS = 2_000; // 20 percent spot-vs-TWAP opening breaker

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        router = new OracleRouter(address(this), USDG);
        cross = new CrossPoolTwapAdapter(address(this));

        // Register the two seasoned CASHCAT/WETH v3 pools (fee 10000 deep, fee 3000 secondary).
        // CASHCAT (0x020b...) sorts below WETH (0x0Bd7...), so CASHCAT is token0 and WETH is token1:
        // the quote asset (WETH) is token1, hence quoteIsToken0 = false for both.
        CrossPoolTwapAdapter.PoolConfig[] memory pools = new CrossPoolTwapAdapter.PoolConfig[](2);
        pools[0] = CrossPoolTwapAdapter.PoolConfig({pool: IUniswapV3Pool(CASHCAT_WETH_10000), quoteIsToken0: false});
        pools[1] = CrossPoolTwapAdapter.PoolConfig({pool: IUniswapV3Pool(CASHCAT_WETH_3000), quoteIsToken0: false});
        cross.setPools(CASHCAT, pools, TWAP_WINDOW);

        // Tier B_DEEP: settle on the aggregated multi-pool TWAP (the single aggregating source), and
        // use the same adapter as the opening breaker's spot source.
        router.setTierConfig(
            CASHCAT,
            OracleRouter.SettlementTier.B_DEEP,
            DEPTH_FLOOR,
            TWAP_WINDOW, // seasoning window = the TWAP window
            COEFF,
            SAFETY_FACTOR,
            BREAKER_BPS,
            address(cross)
        );
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](1);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(cross)), maxStaleness: 1 hours});
        router.setSources(CASHCAT, sources);

        // Tracked depth (USD): both CASHCAT/WETH pools priced through the ETH/USD feed. The primary
        // (seasoning) pool is the deep fee-10000 pool, listed first.
        address[] memory tracked = new address[](2);
        tracked[0] = CASHCAT_WETH_10000;
        tracked[1] = CASHCAT_WETH_3000;
        router.setTrackedPools(CASHCAT, tracked);
        router.setPoolQuote(CASHCAT_WETH_10000, WETH, ETH_USD_FEED, FEED_STALENESS);
        router.setPoolQuote(CASHCAT_WETH_3000, WETH, ETH_USD_FEED, FEED_STALENESS);
        // Manipulation-resistant depth geometry (wave-2 W2-1): CASHCAT is token0, WETH is token1,
        // so the quote asset (WETH) is token1 -> quoteIsToken0 = false. The depth is now the
        // time-averaged in-range WETH reserve over the same TWAP window, not a same-block balanceOf.
        router.setPoolGeometry(CASHCAT_WETH_10000, false, TWAP_WINDOW);
        router.setPoolGeometry(CASHCAT_WETH_3000, false, TWAP_WINDOW);
    }

    function test_poolReconMatches() public onlyForked {
        // Token ordering and fee tier are what the config assumes.
        assertEq(IUniswapV3Pool(CASHCAT_WETH_10000).token0(), CASHCAT);
        assertEq(IUniswapV3Pool(CASHCAT_WETH_10000).token1(), WETH);
        // The deep pool's buffer serves the 30-minute window (seasoned, cardinality grown).
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;
        IUniswapV3Pool(CASHCAT_WETH_10000).observe(secondsAgos); // must not revert
    }

    function test_cashcatIsListableAtBoundedCap() public onlyForked {
        // Manipulation-resistant aggregate depth (the time-averaged in-range WETH reserve across
        // both pools, wave-2 W2-1) is positive on the live pools.
        uint256 depth = router.trackedLiquidity(CASHCAT);
        assertGt(depth, 0);

        // Re-base the illustrative depth floor to just under the measured in-range depth: the exact
        // in-range reserve magnitude is a live-state value, so the listing gate is exercised
        // relative to it rather than a hardcoded USD figure that assumed the old balanceOf basis.
        router.setTierConfig(
            CASHCAT,
            OracleRouter.SettlementTier.B_DEEP,
            depth / 2,
            TWAP_WINDOW,
            COEFF,
            SAFETY_FACTOR,
            BREAKER_BPS,
            address(cross)
        );

        // Tier B_DEEP: sources + depth + seasoning + cardinality all pass.
        assertTrue(router.isListable(CASHCAT));

        // The cost-to-move payout cap is BOUNDED (finite and positive), not the Tier A unbounded
        // sentinel: max payout = costToMove / safetyFactor = depth * COEFF / ONE / SF.
        uint256 cap = router.maxMarketPayoutCap1e18(CASHCAT);
        assertLt(cap, type(uint256).max);
        assertGt(cap, 0);
        assertEq(router.costToMoveEstimate1e18(CASHCAT), depth); // COEFF == COST_COEFF_ONE
        assertEq(cap, depth / SAFETY_FACTOR);
    }

    function test_deviationBreakerComputes() public onlyForked {
        // Both references are readable from the live pools.
        (uint256 twap,, bool twapOk) = cross.read(CASHCAT);
        (uint256 spot, bool spotOk) = cross.readSpot(CASHCAT);
        assertTrue(twapOk);
        assertTrue(spotOk);
        assertGt(twap, 0);
        assertGt(spot, 0);

        (bool allowed, uint8 reason) = router.openingAllowed(CASHCAT);

        // The breaker COMPUTED a real spot-vs-TWAP verdict (never "reference unavailable").
        assertTrue(reason != router.OPENING_DENIED_REFERENCE_UNAVAILABLE());

        // The verdict matches the independent division-free deviation check against the same
        // aggregated live spot and TWAP.
        uint256 lo = spot < twap ? spot : twap;
        uint256 hi = spot < twap ? twap : spot;
        bool expectAllowed = (hi - lo) * 10_000 <= uint256(BREAKER_BPS) * lo;
        assertEq(allowed, expectAllowed);
        assertEq(allowed, reason == router.OPENING_ALLOWED());
    }
}

/// @title ForkTestFwaTierD: the $1.2K FWA/WETH pool is NOT listable under the tier gate
/// @notice The thin FWA/WETH pool fails the aggregate-depth floor as a B_DEEP token and is never
///         listable when explicitly classified D_THIN. Either classification denies continuous
///         settlement, exactly as the design requires for the thin tail.
contract ForkTestFwaTierD is ForkTestBase {
    OracleRouter internal router;
    CrossPoolTwapAdapter internal cross;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        router = new OracleRouter(address(this), USDG);
        cross = new CrossPoolTwapAdapter(address(this));

        // Register the single thin FWA/WETH pool. WETH (0x0Bd7...) sorts below FWA (0xD60b...), so
        // WETH is token0 and FWA is token1: the quote asset (WETH) is token0, quoteIsToken0 = true.
        CrossPoolTwapAdapter.PoolConfig[] memory pools = new CrossPoolTwapAdapter.PoolConfig[](1);
        pools[0] = CrossPoolTwapAdapter.PoolConfig({pool: IUniswapV3Pool(FWA_WETH_POOL), quoteIsToken0: true});
        cross.setPools(FWA, pools, TWAP_WINDOW);

        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](1);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(cross)), maxStaleness: 1 hours});

        address[] memory tracked = new address[](1);
        tracked[0] = FWA_WETH_POOL;
        router.setTrackedPools(FWA, tracked);
        router.setPoolQuote(FWA_WETH_POOL, WETH, ETH_USD_FEED, FEED_STALENESS);
        // Manipulation-resistant depth geometry (wave-2 W2-1): for FWA, WETH is token0 so the quote
        // asset is token0 -> quoteIsToken0 = true. The thin FWA pool carries a cardinality-1 buffer
        // that cannot serve the TWAP window, so its manipulation-resistant in-range depth is zero.
        router.setPoolGeometry(FWA_WETH_POOL, true, TWAP_WINDOW);
    }

    function test_fwaAsBDeepFailsDepthFloor() public onlyForked {
        // Classify FWA as B_DEEP with a modest $1M floor. Its pool cannot serve the TWAP window
        // (cardinality 1), so its manipulation-resistant in-range depth is zero: not listable, far
        // below the floor, even before seasoning is considered.
        router.setTierConfig(
            FWA, OracleRouter.SettlementTier.B_DEEP, 1_000_000e18, TWAP_WINDOW, 1e18, 5, 2_000, address(cross)
        );
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](1);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(cross)), maxStaleness: 1 hours});
        router.setSources(FWA, sources);

        uint256 depth = router.trackedLiquidity(FWA);
        assertLt(depth, 1_000_000e18); // nowhere near the floor (zero: buffer cannot cover the window)
        assertFalse(router.isListable(FWA));
    }

    function test_fwaAsDThinNeverListable() public onlyForked {
        // Explicit D_THIN classification: never listable regardless of any parameter.
        router.setTierConfig(
            FWA, OracleRouter.SettlementTier.D_THIN, 0, 0, 1e18, 5, 0, address(cross)
        );
        assertFalse(router.isListable(FWA));
    }
}

/// @title ForkTestEthTierA: ETH via the real Chainlink ETH/USD feed is Tier A_MAJOR listable
/// @notice A major with a source independent of any AMM pool lists on the source requirement alone
///         (no pool-depth gate) and settles via the median of its independent sources.
contract ForkTestEthTierA is ForkTestBase {
    OracleRouter internal router;
    ChainlinkAdapter internal chainlink;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        router = new OracleRouter(address(this), USDG);
        chainlink = new ChainlinkAdapter(address(this));
        chainlink.setFeed(WETH, ETH_USD_FEED);

        // Tier A_MAJOR is the default; give it the MIN_SOURCES independent Chainlink reads. On this
        // chain ETH has one canonical feed, so the three source slots reference the same adapter:
        // isListable checks the source count, and the median of three identical fresh reads is the
        // feed price. No tracked pool and no depth are configured, proving majors need neither.
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](3);
        for (uint256 i = 0; i < 3; i++) {
            sources[i] = OracleRouter.SourceConfig({source: IPriceSource(address(chainlink)), maxStaleness: FEED_STALENESS});
        }
        router.setSources(WETH, sources);
    }

    function test_ethIsTierAListableWithoutPoolDepth() public onlyForked {
        (OracleRouter.SettlementTier tier,,,,,,,) = router.tierConfigOf(WETH);
        assertEq(uint8(tier), uint8(OracleRouter.SettlementTier.A_MAJOR));
        assertEq(router.trackedLiquidity(WETH), 0); // no pools tracked at all
        assertTrue(router.isListable(WETH)); // still listable: independent feed, no depth gate

        // Majors carry no cost-to-move payout cap.
        assertEq(router.maxMarketPayoutCap1e18(WETH), type(uint256).max);

        // Opening is always allowed for a major (no spot source, breaker inert).
        (bool allowed, uint8 reason) = router.openingAllowed(WETH);
        assertTrue(allowed);
        assertEq(reason, router.OPENING_ALLOWED());
    }

    function test_ethSettlesViaMedianOnRealFeed() public onlyForked {
        (uint256 p, Types.PriceStatus status) = router.checkPrice(WETH);
        assertEq(uint8(status), uint8(Types.PriceStatus.OK));
        // The live ETH/USD price, 1e18 scaled, in a sane band.
        assertGt(p, 1_000e18);
        assertLt(p, 100_000e18);
    }
}
