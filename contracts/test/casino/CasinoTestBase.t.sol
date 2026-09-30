// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PitPoints} from "../../src/casino/PitPoints.sol";
import {SpinVRF} from "../../src/casino/SpinVRF.sol";
import {Jackpot} from "../../src/casino/Jackpot.sol";
import {MockVRFCoordinator} from "../mocks/MockVRFCoordinator.sol";
import {CasinoMockUSDG} from "../mocks/CasinoMockUSDG.sol";

/// @title CasinoTestBase: shared fixture for the casino module tests
/// @notice Deploys the full casino stack wired together with mocks, registers a
///         test market address, and provides prank helpers for hook calls.
abstract contract CasinoTestBase is Test {
    PitPoints internal points;
    SpinVRF internal spin;
    Jackpot internal jackpot;
    MockVRFCoordinator internal coordinator;
    CasinoMockUSDG internal usdg;

    address internal owner;
    address internal market;
    address internal tokenA;
    address internal tokenB;

    uint256 internal constant START_TIME = 400 days;

    function setUp() public virtual {
        vm.warp(START_TIME);

        owner = address(this);
        market = makeAddr("market");
        tokenA = makeAddr("tokenA");
        tokenB = makeAddr("tokenB");

        coordinator = new MockVRFCoordinator();
        usdg = new CasinoMockUSDG();
        points = new PitPoints(owner);
        spin = new SpinVRF(owner, address(points));
        jackpot = new Jackpot(owner, address(usdg), address(points));

        points.setSpinVRF(address(spin));
        points.registerMarket(market);

        spin.setCoordinator(address(coordinator));
        spin.setRequestConfig(1, bytes32(uint256(0xabc123)), 500_000, 3, false);

        jackpot.setCoordinator(address(coordinator));
        jackpot.setRequestConfig(1, bytes32(uint256(0xbeef)), 500_000, 3, false);
    }

    // ===============================================================
    // Hook helpers (pranked as the registered market)
    // ===============================================================

    function fill(address longParty, address shortParty, address maker, address token, uint256 notional) internal {
        vm.prank(market);
        points.onFill(longParty, shortParty, maker, token, notional);
    }

    function settle(address winner, address loser, address token, uint256 notional, uint256 pnl) internal {
        vm.prank(market);
        points.onSettle(winner, loser, token, notional, pnl);
    }

    function createMarket(address creator, address token) internal {
        vm.prank(market);
        points.onMarketCreated(creator, token);
    }

    function win(address user) internal {
        settle(user, makeAddr("sacrificialLoser"), tokenA, 0, 1);
    }

    /// @dev Warps past the win-streak advance throttle (audit fix L3) so the next win advances the
    ///      streak. Used between consecutive wins that are meant to build a streak.
    function warpPastWinThrottle() internal {
        vm.warp(block.timestamp + points.WIN_STREAK_ADVANCE_WINDOW());
    }

    function lose(address user) internal {
        settle(makeAddr("sacrificialWinner"), user, tokenA, 0, 1);
    }

    function fulfillSpin(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        coordinator.fulfill(address(spin), requestId, words);
    }

    function fulfillJackpot(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        coordinator.fulfill(address(jackpot), requestId, words);
    }

    /// @dev Changes the jackpot's live coordinator through the delayed two-step flow (audit fix
    ///      W2-4): propose, wait out COORDINATOR_CHANGE_DELAY, then accept.
    function changeJackpotCoordinator(address newCoordinator) internal {
        jackpot.proposeCoordinator(newCoordinator);
        vm.warp(block.timestamp + jackpot.COORDINATOR_CHANGE_DELAY());
        jackpot.acceptCoordinator();
    }
}
