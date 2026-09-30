// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AggregatorV3Interface} from "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPriceSource} from "./IPriceSource.sol";
import {IIndependentSource} from "./IIndependentSource.sol";

/// @title ChainlinkAdapter: wraps Chainlink AggregatorV3 feeds as an IPriceSource
/// @notice One registry entry per token: token => feed. Answers are normalized from the feed's
///         native decimals to 1e18. The adapter never reverts on read: any upstream failure,
///         missing feed, or non-positive answer yields ok = false.
/// @dev The owner (a timelocked multisig) can only map tokens to feeds; it can never inject a
///      price. Feed decimals are cached at registration to keep read() to a single external call.
///      Implements IIndependentSource: a Chainlink feed is a reference INDEPENDENT of any AMM
///      settlement pool, so the router accepts it as the owner-independent source a Tier A_MAJOR
///      listing requires.
contract ChainlinkAdapter is IPriceSource, IIndependentSource, Ownable2Step {
    /// @notice Registered feed plus its cached decimals.
    struct FeedConfig {
        AggregatorV3Interface feed;
        uint8 decimals;
    }

    /// @notice token => feed configuration. A zero feed address means unregistered.
    mapping(address => FeedConfig) public feeds;

    /// @notice Emitted when a feed is registered, replaced, or removed (feed = address(0)).
    event FeedSet(address indexed token, address indexed feed, uint8 decimals);

    /// @dev The token argument was the zero address.
    error TokenZero();
    /// @dev The feed reports more decimals than the adapter supports (max 30).
    error UnsupportedFeedDecimals(uint8 decimals);
    /// @dev Renouncing ownership is disabled: it would permanently freeze the feed registry.
    error RenounceDisabled();

    /// @param initialOwner Owner of the registry (timelocked multisig).
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Renouncing ownership is disabled: it would permanently freeze the feed registry
    ///         with no path to reconfigure sources. Ownership can still be transferred (two-step).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Registers, replaces, or removes (feed = address(0)) the feed for a token.
    /// @param token The token whose feed is being configured.
    /// @param feed The AggregatorV3 feed pricing the token in USD terms, or zero to remove.
    function setFeed(address token, address feed) external onlyOwner {
        if (token == address(0)) revert TokenZero();
        if (feed == address(0)) {
            delete feeds[token];
            emit FeedSet(token, address(0), 0);
            return;
        }
        uint8 dec = AggregatorV3Interface(feed).decimals();
        if (dec > 30) revert UnsupportedFeedDecimals(dec);
        feeds[token] = FeedConfig({feed: AggregatorV3Interface(feed), decimals: dec});
        emit FeedSet(token, feed, dec);
    }

    /// @inheritdoc IPriceSource
    function read(address token) external view returns (uint256 price1e18, uint256 updatedAt, bool ok) {
        FeedConfig memory cfg = feeds[token];
        if (address(cfg.feed) == address(0)) return (0, 0, false);
        try cfg.feed.latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 feedUpdatedAt, uint80
        ) {
            if (answer <= 0) return (0, 0, false);
            return (_to1e18(uint256(answer), cfg.decimals), feedUpdatedAt, true);
        } catch {
            return (0, 0, false);
        }
    }

    /// @inheritdoc IIndependentSource
    /// @dev A registered Chainlink feed is independent of any AMM settlement pool: its answer
    ///      cannot be moved by trading the token's pool. Returns true only when a feed is mapped
    ///      for `token`, so an unregistered token is not counted as independent.
    function isIndependent(address token) external view returns (bool independent) {
        return address(feeds[token].feed) != address(0);
    }

    /// @dev Rescales a raw feed answer from `dec` decimals to 18 decimals.
    function _to1e18(uint256 raw, uint8 dec) private pure returns (uint256) {
        if (dec == 18) return raw;
        if (dec < 18) return raw * 10 ** (18 - dec);
        return raw / 10 ** (dec - 18);
    }
}
