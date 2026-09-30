// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDG: 6-decimal test stablecoin with public mint
/// @notice Test-only stand-in for USDG. Anyone can mint.
contract MockUSDG is ERC20 {
    constructor() ERC20("Mock USDG", "USDG") {}

    /// @notice USDG uses 6 decimals.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint `amount` tokens to `to`. Test-only, unrestricted.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
