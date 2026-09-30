// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CasinoMockUSDG: 6-decimal USDG test token for the casino module tests
/// @notice Public mint; no access control; test use only. Models USDG's confirmed
///         freeze capability: transfers to or from a frozen address revert, so tests
///         can exercise the jackpot pull-payment path (audit fix D2). No address is
///         frozen unless a test explicitly calls setFrozen.
contract CasinoMockUSDG is ERC20 {
    /// @notice Addresses whose transfers (in or out) revert, simulating USDG freezing.
    mapping(address account => bool isFrozen) public frozen;

    /// @notice Reverts a transfer that touches a frozen account.
    error AccountFrozen(address account);

    constructor() ERC20("Mock USDG", "USDG") {}

    /// @notice USDG uses 6 decimals.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints tokens to any address; unrestricted, tests only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Freezes or unfreezes an account; a frozen account cannot send or receive.
    function setFrozen(address account, bool value) external {
        frozen[account] = value;
    }

    /// @dev Reverts when a frozen account is the sender or recipient of a transfer. Pure mints
    ///      (from == address(0)) to a non-frozen address and burns (to == address(0)) are
    ///      unaffected, so tests can still fund the pot.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && frozen[from]) revert AccountFrozen(from);
        if (to != address(0) && frozen[to]) revert AccountFrozen(to);
        super._update(from, to, value);
    }
}
