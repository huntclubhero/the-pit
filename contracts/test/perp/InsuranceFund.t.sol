// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IInsuranceFund} from "../../src/perp/interfaces/IInsuranceFund.sol";
import {InsuranceFund} from "../../src/perp/InsuranceFund.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockPerpEngine} from "../mocks/MockPerpEngine.sol";

contract InsuranceFundTest is Test {
    InsuranceFund internal fund;
    MockPerpEngine internal engine;
    MockUSDG internal usdg;

    address internal constant TIMELOCK = address(0x7157);
    address internal constant VAULT = address(0x7A01);
    address internal constant KEEPER = address(0x4E39);
    address internal constant RANDO = address(0xBEEF);

    function setUp() public {
        usdg = new MockUSDG();
        fund = new InsuranceFund(IERC20(address(usdg)), TIMELOCK);
        engine = new MockPerpEngine(IERC20(address(usdg)));
        engine.setFund(IInsuranceFund(address(fund)));
        vm.startPrank(TIMELOCK);
        fund.setEngine(address(engine));
        fund.setVault(VAULT);
        vm.stopPrank();
        usdg.mint(address(fund), 100_000e6); // treasury seed
    }

    // ================================ wiring ================================

    function test_wiringOnceOnlyAndOwnerOnly() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(InsuranceFund.EngineAlreadySet.selector);
        fund.setEngine(RANDO);
        vm.expectRevert(InsuranceFund.VaultAlreadySet.selector);
        fund.setVault(RANDO);
        vm.stopPrank();

        InsuranceFund fresh = new InsuranceFund(IERC20(address(usdg)), TIMELOCK);
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDO));
        fresh.setEngine(RANDO);
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDO));
        fresh.setVault(RANDO);
    }

    // ================================ cover ================================

    function test_coverEngineOnly() public {
        vm.prank(RANDO);
        vm.expectRevert(InsuranceFund.NotEngine.selector);
        fund.cover(1e6, VAULT);
    }

    function test_coverPaysConfiguredVaultOnly() public {
        vm.expectRevert(InsuranceFund.VaultMismatch.selector);
        engine.doCover(1e6, RANDO);
    }

    function test_coverPaysShortfall() public {
        uint256 covered = engine.doCover(30_000e6, VAULT);
        assertEq(covered, 30_000e6);
        assertEq(usdg.balanceOf(VAULT), 30_000e6);
        assertEq(fund.balance(), 70_000e6);
    }

    function test_coverDegradesGracefullyWhenShort() public {
        uint256 covered = engine.doCover(250_000e6, VAULT); // fund holds only 100k
        assertEq(covered, 100_000e6, "must cover min(shortfall, balance)");
        assertEq(fund.balance(), 0);
        // a follow-up cover on an empty fund pays zero without reverting (ADL takes over)
        covered = engine.doCover(1e6, VAULT);
        assertEq(covered, 0);
    }

    function testFuzz_coverNeverPaysMoreThanBalanceOrShortfall(uint256 shortfall) public {
        shortfall = bound(shortfall, 1, 10_000_000e6);
        uint256 balBefore = fund.balance();
        uint256 covered = engine.doCover(shortfall, VAULT);
        assertLe(covered, shortfall);
        assertLe(covered, balBefore);
        assertEq(usdg.balanceOf(VAULT), covered);
    }

    // ================================ keeper floor ================================

    function test_keeperFloorEngineOnly() public {
        vm.prank(RANDO);
        vm.expectRevert(InsuranceFund.NotEngine.selector);
        fund.payKeeperFloor(KEEPER, 5e6);
    }

    function test_keeperFloorBounded() public {
        vm.expectRevert(InsuranceFund.KeeperFloorAboveCap.selector);
        engine.doPayKeeperFloor(KEEPER, 5e6 + 1);
        engine.doPayKeeperFloor(KEEPER, 5e6);
        assertEq(usdg.balanceOf(KEEPER), 5e6);
    }

    function test_keeperFloorEmptyFundDoesNotBrickLiquidation() public {
        engine.doCover(100_000e6, VAULT); // drain
        engine.doPayKeeperFloor(KEEPER, 5e6); // must not revert
        assertEq(usdg.balanceOf(KEEPER), 0);
    }

    function test_setKeeperFloorCapBounds() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(InsuranceFund.ParamOutOfBounds.selector);
        fund.setKeeperFloorCap(101e6);
        vm.prank(TIMELOCK);
        fund.setKeeperFloorCap(10e6);
        assertEq(fund.keeperFloorCap(), 10e6);
        engine.doPayKeeperFloor(KEEPER, 10e6);
        assertEq(usdg.balanceOf(KEEPER), 10e6);
    }

    // ================================ no drain paths ================================

    function test_noExternalDrainPath() public {
        // Nothing a random address can call moves USDG out of the fund.
        vm.startPrank(RANDO);
        vm.expectRevert(InsuranceFund.NotEngine.selector);
        fund.cover(100_000e6, VAULT);
        vm.expectRevert(InsuranceFund.NotEngine.selector);
        fund.payKeeperFloor(RANDO, 5e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDO));
        fund.governanceWithdraw(RANDO, 100_000e6);
        vm.stopPrank();
        assertEq(fund.balance(), 100_000e6);
    }

    function test_governanceWithdrawIsOwnerOnly() public {
        vm.prank(TIMELOCK);
        fund.governanceWithdraw(TIMELOCK, 20_000e6);
        assertEq(usdg.balanceOf(TIMELOCK), 20_000e6);
        assertEq(fund.balance(), 80_000e6);
    }

    // ================================ governance withdraw rate limit ================================

    function test_govWithdrawDefaults() public view {
        assertEq(fund.govWithdrawCapBps(), 2500);
        assertEq(fund.GOV_WITHDRAW_WINDOW(), 7 days);
        assertEq(fund.GOV_WITHDRAW_FLOOR(), 10_000e6);
        // 25% of the 100k seed
        assertEq(fund.govWithdrawAvailable(), 25_000e6);
    }

    function test_govWithdrawExceedingCapReverts() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(InsuranceFund.GovWithdrawCapExceeded.selector, 25_000e6 + 1, 25_000e6));
        fund.governanceWithdraw(TIMELOCK, 25_000e6 + 1);
        assertEq(fund.balance(), 100_000e6);
    }

    function test_govWithdrawCapAccumulatesWithinWindow() public {
        vm.startPrank(TIMELOCK);
        fund.governanceWithdraw(TIMELOCK, 20_000e6);
        assertEq(fund.govWithdrawAvailable(), 5_000e6);
        fund.governanceWithdraw(TIMELOCK, 5_000e6); // exactly exhausts the window cap
        assertEq(fund.govWithdrawAvailable(), 0);
        vm.expectRevert(abi.encodeWithSelector(InsuranceFund.GovWithdrawCapExceeded.selector, 1, 0));
        fund.governanceWithdraw(TIMELOCK, 1);
        vm.stopPrank();
        assertEq(fund.balance(), 75_000e6);
    }

    function test_govWithdrawReplenishesAfterWindow() public {
        vm.prank(TIMELOCK);
        fund.governanceWithdraw(TIMELOCK, 25_000e6);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(InsuranceFund.GovWithdrawCapExceeded.selector, 1, 0));
        fund.governanceWithdraw(TIMELOCK, 1);
        skip(7 days);
        // fresh window snapshots 25% of the remaining 75k
        assertEq(fund.govWithdrawAvailable(), 18_750e6);
        vm.prank(TIMELOCK);
        fund.governanceWithdraw(TIMELOCK, 18_750e6);
        assertEq(fund.balance(), 56_250e6);
    }

    function test_govWithdrawFloorKeepsSmallFundWithdrawable() public {
        InsuranceFund small = new InsuranceFund(IERC20(address(usdg)), TIMELOCK);
        usdg.mint(address(small), 8_000e6);
        // The 10k floor dominates 25% of 8k, so the whole small fund moves in one call.
        assertEq(small.govWithdrawAvailable(), 10_000e6);
        vm.prank(TIMELOCK);
        small.governanceWithdraw(TIMELOCK, 8_000e6);
        assertEq(small.balance(), 0);
    }

    function test_govWithdrawFullDrainTerminates() public {
        // Migration liveness: the floor guarantees a full drain completes in bounded windows.
        uint256 rounds;
        while (fund.balance() > 0) {
            uint256 amt = fund.govWithdrawAvailable();
            if (amt > fund.balance()) amt = fund.balance();
            vm.prank(TIMELOCK);
            fund.governanceWithdraw(TIMELOCK, amt);
            skip(7 days);
            rounds++;
            assertLt(rounds, 20, "drain must terminate");
        }
        assertEq(usdg.balanceOf(TIMELOCK), 100_000e6);
    }

    function test_govWithdrawCoverUnaffectedByCap() public {
        // Engine bad-debt cover is NOT rate limited: it may exceed the governance window cap.
        uint256 covered = engine.doCover(90_000e6, VAULT);
        assertEq(covered, 90_000e6);
        assertEq(usdg.balanceOf(VAULT), 90_000e6);
    }

    function test_setGovWithdrawCapBpsBoundsAndAuth() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(InsuranceFund.ParamOutOfBounds.selector);
        fund.setGovWithdrawCapBps(5001);
        vm.prank(TIMELOCK);
        vm.expectRevert(InsuranceFund.ParamOutOfBounds.selector);
        fund.setGovWithdrawCapBps(0);
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDO));
        fund.setGovWithdrawCapBps(1000);
        vm.prank(TIMELOCK);
        fund.setGovWithdrawCapBps(4000);
        assertEq(fund.govWithdrawCapBps(), 4000);
        // No window open yet, so the new fraction is visible immediately: 40% of 100k.
        assertEq(fund.govWithdrawAvailable(), 40_000e6);
    }

    // ================================ seeding ================================

    function test_seed() public {
        usdg.mint(RANDO, 5_000e6);
        vm.startPrank(RANDO);
        usdg.approve(address(fund), 5_000e6);
        fund.seed(5_000e6);
        vm.stopPrank();
        assertEq(fund.balance(), 105_000e6);
    }
}
