// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IPitVault} from "../../src/perp/interfaces/IPitVault.sol";
import {IPerpRiskConfig} from "../../src/perp/interfaces/IPerpRiskConfig.sol";
import {IOracleRouterVaultView} from "../../src/perp/interfaces/IPerpVaultDeps.sol";
import {PitVault} from "../../src/perp/PitVault.sol";
import {PerpRiskConfig} from "../../src/perp/PerpRiskConfig.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockOracleRouter} from "../mocks/MockOracleRouter.sol";
import {MockPerpEngine} from "../mocks/MockPerpEngine.sol";

/// @dev Randomized driver: LP deposits / queue requests / claims / epoch settles / time warps
///      interleaved with engine reserves, releases, trader wins and trader losses.
contract PitVaultHandler is CommonBase, StdCheats, StdUtils {
    PitVault public immutable vault;
    MockPerpEngine public immutable engine;
    MockUSDG public immutable usdg;

    address[3] public actors;
    address[2] public tokens;
    address public constant SINK = address(0x51CC);

    uint256 public ghostDeposited;
    uint256 public ghostClaimed;
    uint256 public ghostWins;
    uint256 public ghostLosses;

    constructor(PitVault vault_, MockPerpEngine engine_, MockUSDG usdg_) {
        vault = vault_;
        engine = engine_;
        usdg = usdg_;
        actors = [address(0xA001), address(0xA002), address(0xA003)];
        tokens = [address(0xAAA1), address(0xAAA2)];
        for (uint256 i = 0; i < actors.length; ++i) {
            vm.prank(actors[i]);
            usdg.approve(address(vault), type(uint256).max);
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 seed) private view returns (address) {
        return tokens[seed % tokens.length];
    }

    function deposit(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        assets = bound(assets, 1e6, 200_000e6);
        usdg.mint(actor, assets);
        vm.prank(actor);
        try vault.deposit(assets, actor) {
            ghostDeposited += assets;
        } catch {}
    }

    function requestWithdraw(uint256 actorSeed, uint256 pct) external {
        address actor = _actor(actorSeed);
        uint256 part = (vault.balanceOf(actor) * bound(pct, 1, 100)) / 100;
        if (part == 0) return;
        vm.prank(actor);
        try vault.requestWithdraw(part) {} catch {}
    }

    function claim(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try vault.claim() returns (uint256 got) {
            ghostClaimed += got;
        } catch {}
    }

    function settle() external {
        uint64 epoch = vault.currentEpoch();
        if (epoch == 0) return;
        try vault.settleEpoch(epoch - 1) {} catch {}
    }

    function warp(uint256 hoursForward) external {
        skip(bound(hoursForward, 1, 48) * 1 hours);
    }

    function reserve(uint256 tokenSeed, uint256 amount) external {
        amount = bound(amount, 1, 50_000e6);
        try engine.doReserve(_token(tokenSeed), amount) {} catch {}
    }

    function release(uint256 tokenSeed, uint256 amount) external {
        address token = _token(tokenSeed);
        uint256 reserved = vault.reservedBy(token);
        if (reserved == 0) return;
        amount = bound(amount, 1, reserved);
        try engine.doRelease(token, amount) {} catch {}
    }

    function traderWin(uint256 amount) external {
        uint256 reserved = vault.totalReserved();
        if (reserved == 0) return;
        amount = bound(amount, 1, reserved);
        try engine.doWin(SINK, amount) {
            ghostWins += amount;
        } catch {}
    }

    function traderLoss(uint256 amount) external {
        amount = bound(amount, 1, 50_000e6);
        usdg.mint(address(engine), amount);
        try engine.doLoss(amount) {
            ghostLosses += amount;
        } catch {}
    }

    // ================================ handler views for invariants ================================

    function sumRequestShares() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; ++i) {
            (uint128 shares,) = vault.requestOf(actors[i]);
            total += shares;
        }
    }

    function sumClaimable() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; ++i) {
            total += vault.claimableOf(actors[i]);
        }
    }

    function reservedSum() external view returns (uint256 total) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            total += vault.reservedBy(tokens[i]);
        }
    }
}

contract PitVaultInvariantTest is Test {
    PitVault internal vault;
    PerpRiskConfig internal config;
    MockOracleRouter internal router;
    MockPerpEngine internal engine;
    MockUSDG internal usdg;
    PitVaultHandler internal handler;

    address internal constant TIMELOCK = address(0x7157);

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
        handler = new PitVaultHandler(vault, engine, usdg);
        targetContract(address(handler));
    }

    /// @dev Regression: the CI profile found this 13-call sequence (2026-09-30), where carried
    ///      remainders rounded up made the users' claimable total exceed totalClaimLiability.
    function test_regression_claimableWithinLiabilityAfterRolls() public {
        handler.traderLoss(11256099);
        handler.deposit(15702700139153681029212707902086214, 71687985593922340381);
        handler.warp(31);
        handler.requestWithdraw(2866, 1030000000000000000);
        handler.deposit(919, 291520298044888626796916566000073);
        handler.deposit(
            72004410207903372592960743500646193048001415815967388756378955504736,
            328075473502868795308515216479077592786735303730896668129486961184853292
        );
        handler.requestWithdraw(
            34144405252123212886108227540205070664036687489838248,
            5679978018189686783872946215242972452013675907323459972937489388970417046
        );
        handler.warp(24975000000);
        handler.claim(8946);
        handler.warp(5276);
        handler.traderLoss(type(uint256).max - 1);
        handler.requestWithdraw(478, 1274690438533);
        handler.claim(32499);
        assertLe(handler.sumClaimable(), vault.totalClaimLiability());
    }

    /// @dev The global reservation ledger always equals the per-market ledger sum.
    function invariant_reservedLedgerConsistent() public view {
        assertEq(vault.totalReserved(), handler.reservedSum());
    }

    /// @dev Shares locked in the vault always cover the queue's live liability: the sum of
    ///      queued shares across UNSETTLED epochs (settled epochs either burned their fulfilled
    ///      shares or rolled the remainder forward into an unsettled epoch). Users' stored
    ///      requests resolve lazily against exactly this pool, and any surplus is vault-favoring
    ///      rounding dust that stays locked forever.
    function invariant_lockedSharesCoverUnsettledQueue() public view {
        uint64 current = vault.currentEpoch();
        uint256 unsettledShares = 0;
        for (uint64 e = 0; e <= current; ++e) {
            (uint128 sharesRequested,,,, bool settled,) = vault.epochs(e);
            if (!settled) unsettledShares += sharesRequested;
        }
        assertGe(vault.balanceOf(address(vault)), unsettledShares);
    }

    /// @dev Exact cash conservation: vault USDG = deposits + trader losses minus claims minus
    ///      trader wins (no other flow exists in this system).
    function invariant_cashConservation() public view {
        assertEq(
            usdg.balanceOf(address(vault)),
            handler.ghostDeposited() + handler.ghostLosses() - handler.ghostClaimed() - handler.ghostWins()
        );
    }

    /// @dev Crystallized per-user claims never exceed the recorded aggregate liability.
    function invariant_claimableWithinLiability() public view {
        assertLe(handler.sumClaimable(), vault.totalClaimLiability());
    }

    /// @dev The dead shares minted from the first deposit never move.
    function invariant_deadSharesIntact() public view {
        if (handler.ghostDeposited() == 0) return;
        assertEq(vault.balanceOf(vault.DEAD_ADDRESS()), vault.DEAD_SHARES());
    }

    /// @dev totalAssets never reverts and NAV stays consistent with cash when no marks are set:
    ///      balance minus liability, floored at zero.
    function invariant_navNeverReverts() public view {
        uint256 bal = usdg.balanceOf(address(vault));
        uint256 liability = vault.totalClaimLiability();
        uint256 expected = bal > liability ? bal - liability : 0;
        assertEq(vault.totalAssets(), expected);
    }
}
