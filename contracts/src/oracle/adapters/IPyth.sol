// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title IPyth: minimal local declaration of the Pyth pull oracle surface THE PIT consumes
/// @notice The Pyth SDK is intentionally not a dependency. This interface declares exactly the
///         struct layout and the single function the PythAdapter reads, matching the deployed
///         Pyth contract ABI (IPyth.getPriceUnsafe and PythStructs.Price).
interface IPyth {
    /// @notice Pyth price struct, ABI-identical to PythStructs.Price.
    /// @param price Signed fixed point price mantissa.
    /// @param conf Confidence interval around the price (unused by the adapter, kept for ABI compatibility).
    /// @param expo Power-of-ten exponent: actual price = price * 10^expo.
    /// @param publishTime Unix timestamp the price was published at.
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    /// @notice Returns the latest stored price for a feed id without any staleness enforcement.
    /// @dev Staleness is enforced downstream by the OracleRouter via publishTime.
    /// @param id The Pyth price feed id.
    /// @return price The latest stored price struct.
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);
}
