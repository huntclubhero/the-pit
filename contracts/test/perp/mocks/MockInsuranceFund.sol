// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IInsuranceFund} from "../../../src/perp/interfaces/IInsuranceFund.sol";

/// @title MockInsuranceFund: recording bad-debt backstop for PerpEngine tests
/// @notice Pays min(shortfall, balance) on cover, records every call, and can be toggled
///         to revert so tests prove the engine's best-effort try/catch paths.
contract MockInsuranceFund is IInsuranceFund {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdg;
    address public engine;
    bool public revertOnCall;

    uint256 public coverCalls;
    uint256 public lastShortfall;
    uint256 public totalCovered;
    uint256 public keeperFloorPaid;

    error OnlyEngine();
    error IntentionalRevert();

    constructor(IERC20 usdg_) {
        usdg = usdg_;
    }

    function setEngine(address engine_) external {
        engine = engine_;
    }

    function setRevertOnCall(bool value) external {
        revertOnCall = value;
    }

    /// @dev Test funding: seed the fund.
    function fund(uint256 amount) external {
        usdg.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @dev Test drain: empty the fund (ADL scenarios).
    function sweep(address to) external {
        usdg.safeTransfer(to, usdg.balanceOf(address(this)));
    }

    /// @inheritdoc IInsuranceFund
    function cover(uint256 shortfall, address vault) external returns (uint256 covered) {
        if (msg.sender != engine) revert OnlyEngine();
        if (revertOnCall) revert IntentionalRevert();
        coverCalls++;
        lastShortfall = shortfall;
        uint256 bal = usdg.balanceOf(address(this));
        covered = shortfall > bal ? bal : shortfall;
        totalCovered += covered;
        if (covered > 0) usdg.safeTransfer(vault, covered);
    }

    /// @inheritdoc IInsuranceFund
    function payKeeperFloor(address keeper, uint256 amount) external {
        if (msg.sender != engine) revert OnlyEngine();
        if (revertOnCall) revert IntentionalRevert();
        uint256 bal = usdg.balanceOf(address(this));
        uint256 pay = amount > bal ? bal : amount;
        keeperFloorPaid += pay;
        if (pay > 0) usdg.safeTransfer(keeper, pay);
    }

    /// @inheritdoc IInsuranceFund
    function balance() external view returns (uint256) {
        return usdg.balanceOf(address(this));
    }
}
