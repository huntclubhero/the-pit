// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PauseGuardian} from "../../src/core/PauseGuardian.sol";

/// @title PauseGuardian unit tests
contract PauseGuardianTest is Test {
    PauseGuardian internal pg;
    address internal guardian = makeAddr("guardian");
    address internal marketA = makeAddr("marketA");
    address internal marketB = makeAddr("marketB");
    address internal rando = makeAddr("rando");

    event PauseTriggered(address indexed target, uint64 start, uint64 end);
    event Unpaused(address indexed target, uint64 at);

    function setUp() public {
        vm.warp(1_800_000_000);
        pg = new PauseGuardian(guardian);
    }

    // ====================================================================== constructor ======================================================================

    function test_constructor_setsGuardian() public view {
        assertEq(pg.guardian(), guardian);
    }

    function test_constructor_revertsOnZeroGuardian() public {
        vm.expectRevert(PauseGuardian.ZeroAddress.selector);
        new PauseGuardian(address(0));
    }

    // ====================================================================== pause ======================================================================

    function test_pause_setsWindowAndEmits() public {
        uint64 start = uint64(block.timestamp);
        vm.expectEmit(true, true, true, true);
        emit PauseTriggered(marketA, start, start + 24 hours);
        vm.prank(guardian);
        pg.pause(marketA);

        assertEq(pg.lastPauseStart(marketA), start);
        assertEq(pg.pauseEnd(marketA), start + 24 hours);
        assertTrue(pg.isPaused(marketA));
    }

    function test_pause_autoExpiresAfter24Hours() public {
        vm.prank(guardian);
        pg.pause(marketA);

        vm.warp(block.timestamp + 24 hours - 1);
        assertTrue(pg.isPaused(marketA));

        vm.warp(block.timestamp + 1);
        assertFalse(pg.isPaused(marketA));
    }

    function test_pause_globalKeyPausesEveryMarket() public {
        vm.prank(guardian);
        pg.pause(address(0));
        assertTrue(pg.isPaused(marketA));
        assertTrue(pg.isPaused(marketB));
    }

    function test_pause_keysAreIndependent() public {
        vm.prank(guardian);
        pg.pause(marketA);
        assertTrue(pg.isPaused(marketA));
        assertFalse(pg.isPaused(marketB));
    }

    function test_pause_revertsForNonGuardian() public {
        vm.expectRevert(PauseGuardian.NotGuardian.selector);
        vm.prank(rando);
        pg.pause(marketA);
    }

    function test_pause_revertsOnCooldownWhileActive() public {
        uint64 start = uint64(block.timestamp);
        vm.prank(guardian);
        pg.pause(marketA);

        vm.warp(start + 12 hours);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.PauseOnCooldown.selector, start + 72 hours));
        vm.prank(guardian);
        pg.pause(marketA);
    }

    function test_pause_revertsOnCooldownAfterExpiryBefore72Hours() public {
        uint64 start = uint64(block.timestamp);
        vm.prank(guardian);
        pg.pause(marketA);

        vm.warp(start + 72 hours - 1);
        assertFalse(pg.isPaused(marketA));
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.PauseOnCooldown.selector, start + 72 hours));
        vm.prank(guardian);
        pg.pause(marketA);
    }

    function test_pause_allowedExactlyAtCooldownEnd() public {
        uint64 start = uint64(block.timestamp);
        vm.prank(guardian);
        pg.pause(marketA);

        vm.warp(start + 72 hours);
        vm.prank(guardian);
        pg.pause(marketA);
        assertTrue(pg.isPaused(marketA));
        assertEq(pg.lastPauseStart(marketA), start + 72 hours);
    }

    function test_pause_cooldownIsPerKey() public {
        vm.prank(guardian);
        pg.pause(marketA);
        // A different key can still be paused immediately.
        vm.prank(guardian);
        pg.pause(marketB);
        assertTrue(pg.isPaused(marketB));
    }

    // ====================================================================== unpause ======================================================================

    function test_unpause_endsPauseEarlyAndEmits() public {
        vm.prank(guardian);
        pg.pause(marketA);

        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(true, true, true, true);
        emit Unpaused(marketA, uint64(block.timestamp));
        vm.prank(guardian);
        pg.unpause(marketA);
        assertFalse(pg.isPaused(marketA));
    }

    function test_unpause_revertsForNonGuardian() public {
        vm.prank(guardian);
        pg.pause(marketA);
        vm.expectRevert(PauseGuardian.NotGuardian.selector);
        vm.prank(rando);
        pg.unpause(marketA);
    }

    function test_unpause_revertsWhenNotPaused() public {
        vm.expectRevert(PauseGuardian.NotCurrentlyPaused.selector);
        vm.prank(guardian);
        pg.unpause(marketA);
    }

    function test_unpause_revertsAfterAutoExpiry() public {
        uint64 start = uint64(block.timestamp);
        vm.prank(guardian);
        pg.pause(marketA);
        vm.warp(start + 24 hours);
        vm.expectRevert(PauseGuardian.NotCurrentlyPaused.selector);
        vm.prank(guardian);
        pg.unpause(marketA);
    }

    function test_unpause_doesNotResetCooldown() public {
        uint64 start = uint64(block.timestamp);
        vm.prank(guardian);
        pg.pause(marketA);

        vm.warp(start + 1 hours);
        vm.prank(guardian);
        pg.unpause(marketA);

        // Even after an early unpause, a fresh pause must wait for the original
        // 72 hour cooldown measured from the first pause start.
        vm.warp(start + 71 hours);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.PauseOnCooldown.selector, start + 72 hours));
        vm.prank(guardian);
        pg.pause(marketA);
    }
}
