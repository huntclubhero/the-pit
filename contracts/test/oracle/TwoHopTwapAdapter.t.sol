// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {AggregatorV3Interface} from "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {TwoHopTwapAdapter} from "../../src/oracle/adapters/TwoHopTwapAdapter.sol";
import {UniV3TwapLib} from "../../src/oracle/UniV3TwapLib.sol";
import {FullMath} from "../../src/oracle/vendor/FullMath.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";

contract TwoHopTwapAdapterTest is Test {
    address internal constant TOKEN = address(0xBEEF);
    uint32 internal constant WINDOW = 1800;
    uint64 internal constant FEED_STALENESS = 1 days;

    TwoHopTwapAdapter internal adapter;
    MockV3Pool internal pool;
    MockChainlinkFeed internal feed;

    function setUp() public {
        adapter = new TwoHopTwapAdapter(address(this));
        pool = new MockV3Pool();
        feed = new MockChainlinkFeed(8);
        vm.warp(10_000_000);
    }

    function _configure(bool tokenIsToken0) internal {
        adapter.setConfig(
            TOKEN,
            IUniswapV3Pool(address(pool)),
            WINDOW,
            tokenIsToken0,
            AggregatorV3Interface(address(feed)),
            FEED_STALENESS
        );
    }

    /// @dev Pins the pool TWAP mean tick by setting cumulatives at the window edges.
    function _setMeanTick(int56 meanTick) internal {
        pool.setTickCumulative(WINDOW, 0);
        pool.setTickCumulative(0, meanTick * int56(uint56(WINDOW)));
    }

    // ===============================================================
    // Configuration
    // ===============================================================

    function test_setConfig_storesAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit TwoHopTwapAdapter.TwoHopConfigSet(TOKEN, address(pool), WINDOW, true, address(feed), FEED_STALENESS);
        _configure(true);
        (IUniswapV3Pool p, uint32 w, bool t0, AggregatorV3Interface f, uint64 st, uint8 dec) = adapter.configs(TOKEN);
        assertEq(address(p), address(pool));
        assertEq(w, WINDOW);
        assertTrue(t0);
        assertEq(address(f), address(feed));
        assertEq(st, FEED_STALENESS);
        assertEq(dec, 8);
    }

    function test_setConfig_zeroPoolRemoves() public {
        _configure(true);
        adapter.setConfig(TOKEN, IUniswapV3Pool(address(0)), 0, false, AggregatorV3Interface(address(0)), 0);
        (IUniswapV3Pool p,,,,,) = adapter.configs(TOKEN);
        assertEq(address(p), address(0));
        (,, bool ok) = adapter.read(TOKEN);
        assertFalse(ok);
    }

    function test_setConfig_revertsOnZeroToken() public {
        vm.expectRevert(TwoHopTwapAdapter.TokenZero.selector);
        adapter.setConfig(
            address(0),
            IUniswapV3Pool(address(pool)),
            WINDOW,
            true,
            AggregatorV3Interface(address(feed)),
            FEED_STALENESS
        );
    }

    function test_setConfig_revertsOnZeroWindow() public {
        vm.expectRevert(TwoHopTwapAdapter.WindowZero.selector);
        adapter.setConfig(
            TOKEN, IUniswapV3Pool(address(pool)), 0, true, AggregatorV3Interface(address(feed)), FEED_STALENESS
        );
    }

    function test_setConfig_revertsOnZeroFeed() public {
        vm.expectRevert(TwoHopTwapAdapter.FeedZero.selector);
        adapter.setConfig(
            TOKEN, IUniswapV3Pool(address(pool)), WINDOW, true, AggregatorV3Interface(address(0)), FEED_STALENESS
        );
    }

    function test_setConfig_revertsOnZeroStaleness() public {
        vm.expectRevert(TwoHopTwapAdapter.StalenessZero.selector);
        adapter.setConfig(TOKEN, IUniswapV3Pool(address(pool)), WINDOW, true, AggregatorV3Interface(address(feed)), 0);
    }

    function test_setConfig_revertsOnFeedDecimalsAbove30() public {
        feed.setDecimals(31);
        vm.expectRevert(abi.encodeWithSelector(TwoHopTwapAdapter.UnsupportedFeedDecimals.selector, 31));
        _configure(true);
    }

    function test_setConfig_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD)));
        _configure(true);
    }

    // ===============================================================
    // read: happy paths
    // ===============================================================

    function test_read_multipliesTwapByFeed_tokenIsToken0() public {
        _configure(true);
        _setMeanTick(0); // 1 WETH per token at tick 0.
        feed.setAnswer(2000e8, block.timestamp);
        (uint256 p, uint256 at, bool ok) = adapter.read(TOKEN);
        assertTrue(ok);
        assertEq(at, block.timestamp);
        // Token is token0, so the WETH quote sits on the token1 side.
        uint256 wethPerToken = UniV3TwapLib.quoteAtTick(0, false);
        assertEq(p, FullMath.mulDiv(wethPerToken, 2000e18, 1e18));
        assertEq(p, 2000e18);
    }

    function test_read_multipliesTwapByFeed_tokenIsToken1() public {
        _configure(false);
        _setMeanTick(6931); // Arbitrary nonzero tick; expectation recomputed exactly below.
        feed.setAnswer(1886_58000000, block.timestamp); // 1886.58 USD, 8 decimals.
        (uint256 p,, bool ok) = adapter.read(TOKEN);
        assertTrue(ok);
        uint256 wethPerToken = UniV3TwapLib.quoteAtTick(6931, true);
        assertEq(p, FullMath.mulDiv(wethPerToken, 1886.58e18, 1e18));
        assertGt(p, 0);
    }

    function test_read_normalizes18DecimalFeed() public {
        feed.setDecimals(18);
        _configure(true);
        _setMeanTick(0);
        feed.setAnswer(1500e18, block.timestamp);
        (uint256 p,, bool ok) = adapter.read(TOKEN);
        assertTrue(ok);
        assertEq(p, 1500e18);
    }

    function test_read_acceptsFeedExactlyAtStalenessBound() public {
        _configure(true);
        _setMeanTick(0);
        feed.setAnswer(2000e8, block.timestamp - FEED_STALENESS);
        (,, bool ok) = adapter.read(TOKEN);
        assertTrue(ok);
    }

    // ===============================================================
    // read: failure legs (always ok = false, never a revert)
    // ===============================================================

    function test_read_notOkWhenUnregistered() public view {
        (uint256 p, uint256 at, bool ok) = adapter.read(address(0x1234));
        assertFalse(ok);
        assertEq(p, 0);
        assertEq(at, 0);
    }

    function test_read_notOkWhenPoolObserveReverts() public {
        _configure(true);
        feed.setAnswer(2000e8, block.timestamp);
        pool.setRevertOnObserve(true); // Simulates Uniswap "OLD" (cardinality 1 or young pool).
        (uint256 p,, bool ok) = adapter.read(TOKEN);
        assertFalse(ok);
        assertEq(p, 0);
    }

    function test_read_notOkWhenFeedReverts() public {
        _configure(true);
        _setMeanTick(0);
        feed.setAnswer(2000e8, block.timestamp);
        feed.setRevertOnRead(true);
        (,, bool ok) = adapter.read(TOKEN);
        assertFalse(ok);
    }

    function test_read_notOkWhenFeedStale() public {
        _configure(true);
        _setMeanTick(0);
        feed.setAnswer(2000e8, block.timestamp - FEED_STALENESS - 1);
        (,, bool ok) = adapter.read(TOKEN);
        assertFalse(ok);
    }

    function test_read_notOkWhenFeedNonPositive() public {
        _configure(true);
        _setMeanTick(0);
        feed.setAnswer(0, block.timestamp);
        (,, bool ok) = adapter.read(TOKEN);
        assertFalse(ok);
        feed.setAnswer(-1, block.timestamp);
        (,, ok) = adapter.read(TOKEN);
        assertFalse(ok);
    }

    function test_read_notOkWhenBothLegsFail() public {
        _configure(true);
        pool.setRevertOnObserve(true);
        feed.setRevertOnRead(true);
        (,, bool ok) = adapter.read(TOKEN);
        assertFalse(ok);
    }
}
