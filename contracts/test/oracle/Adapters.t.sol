// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {ChainlinkAdapter} from "../../src/oracle/adapters/ChainlinkAdapter.sol";
import {PythAdapter} from "../../src/oracle/adapters/PythAdapter.sol";
import {TwapAdapter} from "../../src/oracle/adapters/TwapAdapter.sol";
import {IPyth} from "../../src/oracle/adapters/IPyth.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {MockPythSource} from "../mocks/MockPythSource.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";

contract AdaptersTest is Test {
    address internal constant TOKEN = address(0xBEEF);
    bytes32 internal constant PRICE_ID = keccak256("PIT/USDG");

    ChainlinkAdapter internal chainlink;
    PythAdapter internal pythAdapter;
    TwapAdapter internal twap;
    MockChainlinkFeed internal feed;
    MockPythSource internal pyth;
    MockV3Pool internal pool;

    function setUp() public {
        chainlink = new ChainlinkAdapter(address(this));
        pyth = new MockPythSource();
        pythAdapter = new PythAdapter(address(this), IPyth(address(pyth)));
        twap = new TwapAdapter(address(this));
        feed = new MockChainlinkFeed(8);
        pool = new MockV3Pool();
    }

    // ===============================================================
    // ChainlinkAdapter
    // ===============================================================

    function test_chainlink_normalizes8Decimals() public {
        chainlink.setFeed(TOKEN, address(feed));
        feed.setAnswer(1234_5678_0000, 111);
        (uint256 p, uint256 at, bool ok) = chainlink.read(TOKEN);
        assertTrue(ok);
        assertEq(p, 1234.5678e18);
        assertEq(at, 111);
    }

    function test_chainlink_normalizes6And18Decimals() public {
        feed.setDecimals(6);
        chainlink.setFeed(TOKEN, address(feed));
        feed.setAnswer(2_500_000, 5);
        (uint256 p,, bool ok) = chainlink.read(TOKEN);
        assertTrue(ok);
        assertEq(p, 2.5e18);

        MockChainlinkFeed feed18 = new MockChainlinkFeed(18);
        chainlink.setFeed(TOKEN, address(feed18));
        feed18.setAnswer(7e18, 6);
        (p,, ok) = chainlink.read(TOKEN);
        assertTrue(ok);
        assertEq(p, 7e18);
    }

    function test_chainlink_normalizesAbove18Decimals() public {
        feed.setDecimals(24);
        chainlink.setFeed(TOKEN, address(feed));
        feed.setAnswer(3e24, 7);
        (uint256 p,, bool ok) = chainlink.read(TOKEN);
        assertTrue(ok);
        assertEq(p, 3e18);
    }

    function testFuzz_chainlink_decimalNormalization(uint8 dec, uint256 answerSeed) public {
        dec = uint8(bound(dec, 0, 30));
        uint256 answer = bound(answerSeed, 1, 1e15);
        feed.setDecimals(dec);
        chainlink.setFeed(TOKEN, address(feed));
        feed.setAnswer(int256(answer), block.timestamp);

        (uint256 p, uint256 at, bool ok) = chainlink.read(TOKEN);
        assertTrue(ok);
        assertEq(at, block.timestamp);
        uint256 expected = dec <= 18 ? answer * 10 ** (18 - uint256(dec)) : answer / 10 ** (uint256(dec) - 18);
        assertEq(p, expected);
    }

    function test_chainlink_notOkOnMissingFeed() public view {
        (uint256 p, uint256 at, bool ok) = chainlink.read(address(0x1234));
        assertFalse(ok);
        assertEq(p, 0);
        assertEq(at, 0);
    }

    function test_chainlink_notOkOnNonPositiveAnswer() public {
        chainlink.setFeed(TOKEN, address(feed));
        feed.setAnswer(0, block.timestamp);
        (,, bool ok) = chainlink.read(TOKEN);
        assertFalse(ok);
        feed.setAnswer(-1, block.timestamp);
        (,, ok) = chainlink.read(TOKEN);
        assertFalse(ok);
    }

    function test_chainlink_notOkOnFeedRevert() public {
        chainlink.setFeed(TOKEN, address(feed));
        feed.setAnswer(1e8, block.timestamp);
        feed.setRevertOnRead(true);
        (,, bool ok) = chainlink.read(TOKEN);
        assertFalse(ok);
    }

    function test_chainlink_removeFeed() public {
        chainlink.setFeed(TOKEN, address(feed));
        chainlink.setFeed(TOKEN, address(0));
        (,, bool ok) = chainlink.read(TOKEN);
        assertFalse(ok);
    }

    function test_chainlink_rejectsAbsurdDecimals() public {
        feed.setDecimals(31);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.UnsupportedFeedDecimals.selector, 31));
        chainlink.setFeed(TOKEN, address(feed));
    }

    function test_chainlink_onlyOwnerSetsFeeds() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD)));
        chainlink.setFeed(TOKEN, address(feed));
    }

    // ===============================================================
    // PythAdapter
    // ===============================================================

    function test_pyth_normalizesExpoMinus8() public {
        pythAdapter.setPriceId(TOKEN, PRICE_ID);
        pyth.setPrice(PRICE_ID, 123_456_789, 10, -8, 42);
        (uint256 p, uint256 at, bool ok) = pythAdapter.read(TOKEN);
        assertTrue(ok);
        assertEq(p, 1.23456789e18);
        assertEq(at, 42);
    }

    function testFuzz_pyth_expoNormalization(int32 expoSeed, uint64 mantissaSeed, uint64 publishTime) public {
        int32 expo = int32(bound(int256(expoSeed), -12, 0));
        int64 mantissa = int64(uint64(bound(mantissaSeed, 1, uint64(type(int64).max))));
        pythAdapter.setPriceId(TOKEN, PRICE_ID);
        pyth.setPrice(PRICE_ID, mantissa, 0, expo, publishTime);

        (uint256 p, uint256 at, bool ok) = pythAdapter.read(TOKEN);
        assertTrue(ok);
        assertEq(at, publishTime);
        uint256 expected = uint256(uint64(mantissa)) * 10 ** uint256(uint32(18 + expo));
        assertEq(p, expected);
    }

    function test_pyth_notOkOnMissingId() public view {
        (,, bool ok) = pythAdapter.read(TOKEN);
        assertFalse(ok);
    }

    function test_pyth_notOkOnNonPositivePrice() public {
        pythAdapter.setPriceId(TOKEN, PRICE_ID);
        pyth.setPrice(PRICE_ID, 0, 0, -8, 1);
        (,, bool ok) = pythAdapter.read(TOKEN);
        assertFalse(ok);
        pyth.setPrice(PRICE_ID, -5, 0, -8, 1);
        (,, ok) = pythAdapter.read(TOKEN);
        assertFalse(ok);
    }

    function test_pyth_notOkOnExpoOutOfBounds() public {
        pythAdapter.setPriceId(TOKEN, PRICE_ID);
        pyth.setPrice(PRICE_ID, 1e6, 0, 13, 1);
        (,, bool ok) = pythAdapter.read(TOKEN);
        assertFalse(ok);
        pyth.setPrice(PRICE_ID, 1e6, 0, -31, 1);
        (,, ok) = pythAdapter.read(TOKEN);
        assertFalse(ok);
    }

    function test_pyth_notOkOnRevert() public {
        pythAdapter.setPriceId(TOKEN, PRICE_ID);
        pyth.setPrice(PRICE_ID, 1e6, 0, -6, 1);
        pyth.setRevertOnRead(true);
        (,, bool ok) = pythAdapter.read(TOKEN);
        assertFalse(ok);
    }

    function test_pyth_onlyOwnerSetsIds() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD)));
        pythAdapter.setPriceId(TOKEN, PRICE_ID);
    }

    // ===============================================================
    // TwapAdapter
    // ===============================================================

    function test_twapAdapter_readsPool() public {
        pool.setTickCumulative(600, 0);
        pool.setTickCumulative(0, 0);
        twap.setConfig(TOKEN, IUniswapV3Pool(address(pool)), 600, false);
        (uint256 p, uint256 at, bool ok) = twap.read(TOKEN);
        assertTrue(ok);
        assertEq(p, 1e18);
        assertEq(at, block.timestamp);
    }

    function test_twapAdapter_notOkWhenUnconfigured() public view {
        (,, bool ok) = twap.read(TOKEN);
        assertFalse(ok);
    }

    function test_twapAdapter_notOkOnYoungPool() public {
        twap.setConfig(TOKEN, IUniswapV3Pool(address(pool)), 600, false);
        pool.setRevertOnObserve(true);
        (,, bool ok) = twap.read(TOKEN);
        assertFalse(ok);
    }

    function test_twapAdapter_configValidation() public {
        vm.expectRevert(TwapAdapter.WindowZero.selector);
        twap.setConfig(TOKEN, IUniswapV3Pool(address(pool)), 0, false);
        vm.expectRevert(TwapAdapter.TokenZero.selector);
        twap.setConfig(address(0), IUniswapV3Pool(address(pool)), 600, false);
    }

    function test_twapAdapter_removeConfig() public {
        twap.setConfig(TOKEN, IUniswapV3Pool(address(pool)), 600, false);
        twap.setConfig(TOKEN, IUniswapV3Pool(address(0)), 0, false);
        (,, bool ok) = twap.read(TOKEN);
        assertFalse(ok);
    }
}
