// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPriceSource} from "./IPriceSource.sol";
import {IIndependentSource} from "./IIndependentSource.sol";
import {IPyth} from "./IPyth.sol";

/// @title PythAdapter: wraps the pull-based Pyth oracle as an IPriceSource
/// @notice Registry maps token => Pyth price feed id. Prices are read via getPriceUnsafe (no
///         staleness enforcement at the Pyth layer) and normalized from Pyth's power-of-ten
///         exponent representation to 1e18. Staleness is enforced by the OracleRouter using
///         the returned publishTime, so a keeper that stops pushing Pyth updates degrades the
///         source to "stale" rather than serving old prices.
/// @dev The owner (a timelocked multisig) can only map tokens to feed ids; it can never inject
///      a price. The adapter never reverts on read: failures yield ok = false.
contract PythAdapter is IPriceSource, IIndependentSource, Ownable2Step {
    /// @notice Most negative exponent accepted; below this the mantissa cannot carry 1e18 precision meaningfully.
    int32 public constant MIN_EXPO = -30;
    /// @notice Most positive exponent accepted; bounds the normalization multiplier so it cannot overflow.
    int32 public constant MAX_EXPO = 12;

    /// @notice The Pyth core contract on this chain.
    IPyth public immutable pyth;

    /// @notice token => Pyth price feed id. bytes32(0) means unregistered.
    mapping(address => bytes32) public priceIds;

    /// @notice Emitted when a price id is registered, replaced, or removed (id = bytes32(0)).
    event PriceIdSet(address indexed token, bytes32 indexed priceId);

    /// @dev The token argument was the zero address.
    error TokenZero();
    /// @dev The Pyth contract address was zero.
    error PythZero();
    /// @dev Renouncing ownership is disabled: it would permanently freeze the feed-id registry.
    error RenounceDisabled();

    /// @param initialOwner Owner of the registry (timelocked multisig).
    /// @param pyth_ The deployed Pyth core contract.
    constructor(address initialOwner, IPyth pyth_) Ownable(initialOwner) {
        if (address(pyth_) == address(0)) revert PythZero();
        pyth = pyth_;
    }

    /// @notice Renouncing ownership is disabled: it would permanently freeze the feed-id registry
    ///         with no path to reconfigure sources. Ownership can still be transferred (two-step).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Registers, replaces, or removes (id = bytes32(0)) the Pyth feed id for a token.
    /// @param token The token whose feed id is being configured.
    /// @param priceId The Pyth price feed id quoting the token in USD terms, or zero to remove.
    function setPriceId(address token, bytes32 priceId) external onlyOwner {
        if (token == address(0)) revert TokenZero();
        priceIds[token] = priceId;
        emit PriceIdSet(token, priceId);
    }

    /// @inheritdoc IIndependentSource
    /// @dev A registered Pyth feed id is independent of any AMM settlement pool: its price cannot
    ///      be moved by trading the token's pool. Returns true only when an id is mapped for
    ///      `token`, so an unregistered token is not counted as independent.
    function isIndependent(address token) external view returns (bool independent) {
        return priceIds[token] != bytes32(0);
    }

    /// @inheritdoc IPriceSource
    function read(address token) external view returns (uint256 price1e18, uint256 updatedAt, bool ok) {
        bytes32 id = priceIds[token];
        if (id == bytes32(0)) return (0, 0, false);
        try pyth.getPriceUnsafe(id) returns (IPyth.Price memory p) {
            if (p.price <= 0 || p.expo < MIN_EXPO || p.expo > MAX_EXPO) return (0, 0, false);
            uint256 mantissa = uint256(uint64(p.price));
            // Actual price = mantissa * 10^expo, so the 1e18-scaled price is mantissa * 10^(18 + expo).
            int32 shift = 18 + p.expo;
            uint256 scaled = shift >= 0
                ? mantissa * 10 ** uint256(uint32(shift))
                : mantissa / 10 ** uint256(uint32(-shift));
            return (scaled, p.publishTime, true);
        } catch {
            return (0, 0, false);
        }
    }
}
