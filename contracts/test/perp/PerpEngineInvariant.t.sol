// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PerpEngineBase} from "./PerpEngineBase.t.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockPerpOracle} from "./mocks/MockPerpOracle.sol";
import {MockPitVault} from "./mocks/MockPitVault.sol";

/// @notice Randomized-actor handler: opens, increases, closes, reduces, margin ops,
///         liquidations, funding pokes, price walks and time warps across two markets.
///         Failed preconditions revert inside try/catch: sequences never abort.
contract PerpHandler is CommonBase, StdCheats, StdUtils {
    PerpEngine internal immutable ENGINE;
    MockUSDG internal immutable USDG;
    MockPerpOracle internal immutable ORACLE;

    address[3] internal actors;
    address[2] internal markets;

    uint256 public opens;
    uint256 public closes;
    uint256 public liquidationsDone;

    constructor(PerpEngine engine_, MockUSDG usdg_, MockPerpOracle oracle_, address[3] memory actors_, address[2] memory markets_) {
        ENGINE = engine_;
        USDG = usdg_;
        ORACLE = oracle_;
        actors = actors_;
        markets = markets_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _market(uint256 seed) internal view returns (address) {
        return markets[seed % markets.length];
    }

    function open(uint256 actorSeed, uint256 marketSeed, bool isLong, uint128 margin, uint32 lev) external {
        margin = uint128(bound(margin, 10e6, 1_200e6));
        lev = uint32(bound(lev, 110, 600));
        vm.prank(_actor(actorSeed));
        try ENGINE.openPosition(_market(marketSeed), isLong, margin, lev) {
            opens++;
        } catch {}
    }

    function increase(uint256 actorSeed, uint256 marketSeed, bool isLong, uint128 margin, uint32 lev) external {
        margin = uint128(bound(margin, 1e6, 400e6));
        lev = uint32(bound(lev, 110, 600));
        vm.prank(_actor(actorSeed));
        try ENGINE.increasePosition(_market(marketSeed), isLong, margin, lev) {} catch {}
    }

    function close(uint256 actorSeed, uint256 marketSeed, bool isLong) external {
        vm.prank(_actor(actorSeed));
        try ENGINE.closePosition(_market(marketSeed), isLong) {
            closes++;
        } catch {}
    }

    function reduce(uint256 actorSeed, uint256 marketSeed, bool isLong, uint32 fractionBps) external {
        fractionBps = uint32(bound(fractionBps, 100, 9_900));
        vm.prank(_actor(actorSeed));
        try ENGINE.reducePosition(_market(marketSeed), isLong, fractionBps) {} catch {}
    }

    function addMargin(uint256 actorSeed, uint256 marketSeed, bool isLong, uint128 amount) external {
        amount = uint128(bound(amount, 1e6, 400e6));
        vm.prank(_actor(actorSeed));
        try ENGINE.addMargin(_market(marketSeed), isLong, amount) {} catch {}
    }

    function removeMargin(uint256 actorSeed, uint256 marketSeed, bool isLong, uint128 amount) external {
        amount = uint128(bound(amount, 1e6, 400e6));
        vm.prank(_actor(actorSeed));
        try ENGINE.removeMargin(_market(marketSeed), isLong, amount) {} catch {}
    }

    function liquidateSweep(uint256 marketSeed) external {
        address token = _market(marketSeed);
        for (uint256 i = 0; i < actors.length; i++) {
            for (uint256 sideIdx = 0; sideIdx < 2; sideIdx++) {
                try ENGINE.liquidate(token, actors[i], sideIdx == 0) {
                    liquidationsDone++;
                } catch {}
            }
        }
    }

    function poke(uint256 marketSeed) external {
        try ENGINE.pokeFunding(_market(marketSeed)) {} catch {}
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 10 minutes, 8 hours);
        vm.warp(block.timestamp + dt);
    }

    function movePrice(uint256 marketSeed, uint256 factorBps) external {
        address token = _market(marketSeed);
        factorBps = bound(factorBps, 7_000, 14_300); // x0.70 to x1.43 per step
        (uint256 current,) = ORACLE.peekPrice(token);
        uint256 next = current * factorBps / 10_000;
        if (next < 1e14) next = 1e14;
        if (next > 1e24) next = 1e24;
        ORACLE.setLive(token, next);
    }
}

/// @notice THE aggregates-equal-sum-of-positions invariant (the GMX v1 desync class),
///         the per-market reserve-cap invariant (max vault outflow bounded by
///         cost-to-move / safetyFactor), engine escrow solvency, and vault reserve sync,
///         asserted after every fuzzed operation sequence.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 60
/// forge-config: ci.invariant.runs = 512
/// forge-config: ci.invariant.depth = 100
contract PerpEngineInvariantTest is StdInvariant, PerpEngineBase {
    PerpHandler internal handler;
    uint256 internal constant MEME_CAP_1E18 = 50_000e18; // cost-to-move leg for MEME

    /// @dev B1: the cost-to-move cap is frozen at listMarket, so it must be set before listing.
    function _configurePayoutCaps() internal override {
        oracle.setPayoutCap1e18(MEME, MEME_CAP_1E18); // MEME bounded by cost-to-move
    }

    function setUp() public override {
        super.setUp();
        vault.setTotalAssetsOverride(VAULT_SEED); // freeze TVL: caps deterministic
        // RE-ECON-1: arm the vol-scaled borrow at launch defaults for the whole fuzzed run.
        // The handler's price walks (x0.70 to x1.43 per step) and time warps continuously
        // exercise elevated realized-vol readings, so every invariant below (aggregates ==
        // position sums, reserve caps, escrow solvency, vault reserve sync) is asserted UNDER
        // vol-scaled borrow accrual, proving the layer only re-rates an existing inflow and
        // never bends the books or the anti-drain armor.
        risk.setVolParams(
            PerpTypes.VolParams({
                kVolX100: 100,
                maxVolSurchargeBps: 50,
                freshSurchargeStartBps: 25,
                kCapVolX100: 2500,
                maxVolDiscountBps: 5000,
                kBorrowVolX100: 400,
                volBorrowDeadbandBps: 300,
                maxVolBorrowMultX100: 2_000_000,
                volRefTauSeconds: 12 hours
            })
        );
        handler = new PerpHandler(engine, usdg, oracle, [alice, bob, carol], [MEME, MAJOR]);
        targetContract(address(handler));
    }

    /// @dev Every aggregate field equals the sum over live positions, exactly, always.
    function invariant_aggregatesEqualPositionSums() public view {
        assertAggMatchesPositions(MEME);
        assertAggMatchesPositions(MAJOR);
    }

    /// @dev The reincarnated capped-payout inequality: reserved payout (max vault outflow)
    ///      per market never exceeded its cap at any point in the run (high-water mark).
    function invariant_reserveCapNeverExceeded() public view {
        assertLe(vault.maxReservedEverOf(MEME), 50_000e6, "MEME cost-to-move cap");
        assertLe(vault.maxReservedEverOf(MAJOR), 100_000e6, "MAJOR TVL-percentage cap");
    }

    /// @dev Engine escrow solvency: the engine's USDG balance is exactly the sum of open
    ///      position margins plus unclaimed fee credit. Any desync between cash and the
    ///      position books (the GMX v1 failure) breaks this equality immediately.
    function invariant_engineEscrowSolvency() public view {
        uint256 margins;
        address[2] memory tokens = [MEME, MAJOR];
        address[3] memory traders = [alice, bob, carol];
        for (uint256 t = 0; t < tokens.length; t++) {
            for (uint256 i = 0; i < traders.length; i++) {
                margins += engine.getPosition(tokens[t], traders[i], true).margin;
                margins += engine.getPosition(tokens[t], traders[i], false).margin;
            }
        }
        assertEq(usdg.balanceOf(address(engine)), margins + engine.totalCredit(), "escrow == books");
    }

    /// @dev The vault's per-market reservation always mirrors the engine's totalMaxPayout.
    function invariant_vaultReserveSync() public view {
        assertEq(vault.reservedOf(MEME), aggOf(MEME).totalMaxPayout);
        assertEq(vault.reservedOf(MAJOR), aggOf(MAJOR).totalMaxPayout);
        assertEq(vault.totalReserved(), uint256(aggOf(MEME).totalMaxPayout) + aggOf(MAJOR).totalMaxPayout);
    }

    /// @dev Anti-vacuity: the handler's happy paths really mutate engine state (a handler
    ///      whose calls all reverted would make the invariants above hollow).
    function test_handlerSmoke_pathsActuallyExecute() public {
        handler.open(0, 0, true, 500e6, 300);
        assertEq(handler.opens(), 1, "open path live");
        assertGt(aggOf(MEME).totalLongSize1e18, 0);
        handler.warp(2 hours);
        handler.poke(0);
        handler.movePrice(0, 7_000); // crash the mark: the long becomes liquidatable
        handler.liquidateSweep(0);
        assertEq(handler.liquidationsDone(), 1, "liquidation path live");
        invariant_aggregatesEqualPositionSums();
        invariant_engineEscrowSolvency();
        invariant_vaultReserveSync();
    }

    /// @dev Position keys tracked per market always point at live positions and cover them.
    function invariant_positionKeySetConsistent() public view {
        address[2] memory tokens = [MEME, MAJOR];
        for (uint256 t = 0; t < tokens.length; t++) {
            bytes32[] memory keys = engine.positionKeysOf(tokens[t]);
            uint256 liveCount;
            address[3] memory traders = [alice, bob, carol];
            for (uint256 i = 0; i < traders.length; i++) {
                if (engine.getPosition(tokens[t], traders[i], true).size1e18 != 0) liveCount++;
                if (engine.getPosition(tokens[t], traders[i], false).size1e18 != 0) liveCount++;
            }
            assertEq(keys.length, liveCount, "key set covers exactly the live positions");
        }
    }
}
