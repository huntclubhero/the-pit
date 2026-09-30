// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {ChainlinkAdapter} from "../../src/oracle/adapters/ChainlinkAdapter.sol";
import {PythAdapter} from "../../src/oracle/adapters/PythAdapter.sol";
import {TwapAdapter} from "../../src/oracle/adapters/TwapAdapter.sol";
import {TwoHopTwapAdapter} from "../../src/oracle/adapters/TwoHopTwapAdapter.sol";
import {CrossPoolTwapAdapter} from "../../src/oracle/adapters/CrossPoolTwapAdapter.sol";
import {IPyth} from "../../src/oracle/adapters/IPyth.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";

/// @title F1: renounceOwnership is disabled on every ownable oracle-layer contract
/// @notice An erroneous or compromised one-step renounce would permanently freeze source
///         configuration. Each contract overrides renounceOwnership to revert; ownership can
///         still be transferred via the two-step Ownable2Step flow.
contract RenounceDisabledTest is Test {
    function test_router_renounceReverts() public {
        MockUSDG usdg = new MockUSDG();
        OracleRouter router = new OracleRouter(address(this), address(usdg));
        vm.expectRevert(OracleRouter.RenounceDisabled.selector);
        router.renounceOwnership();
        assertEq(router.owner(), address(this));
    }

    function test_chainlinkAdapter_renounceReverts() public {
        ChainlinkAdapter adapter = new ChainlinkAdapter(address(this));
        vm.expectRevert(ChainlinkAdapter.RenounceDisabled.selector);
        adapter.renounceOwnership();
        assertEq(adapter.owner(), address(this));
    }

    function test_pythAdapter_renounceReverts() public {
        PythAdapter adapter = new PythAdapter(address(this), IPyth(address(0xBEEF)));
        vm.expectRevert(PythAdapter.RenounceDisabled.selector);
        adapter.renounceOwnership();
        assertEq(adapter.owner(), address(this));
    }

    function test_twapAdapter_renounceReverts() public {
        TwapAdapter adapter = new TwapAdapter(address(this));
        vm.expectRevert(TwapAdapter.RenounceDisabled.selector);
        adapter.renounceOwnership();
        assertEq(adapter.owner(), address(this));
    }

    function test_twoHopAdapter_renounceReverts() public {
        TwoHopTwapAdapter adapter = new TwoHopTwapAdapter(address(this));
        vm.expectRevert(TwoHopTwapAdapter.RenounceDisabled.selector);
        adapter.renounceOwnership();
        assertEq(adapter.owner(), address(this));
    }

    function test_crossPoolAdapter_renounceReverts() public {
        CrossPoolTwapAdapter adapter = new CrossPoolTwapAdapter(address(this));
        vm.expectRevert(CrossPoolTwapAdapter.RenounceDisabled.selector);
        adapter.renounceOwnership();
        assertEq(adapter.owner(), address(this));
    }

    function test_transferOwnershipStillWorks() public {
        MockUSDG usdg = new MockUSDG();
        OracleRouter router = new OracleRouter(address(this), address(usdg));
        address newOwner = makeAddr("newOwner");
        router.transferOwnership(newOwner);
        vm.prank(newOwner);
        router.acceptOwnership();
        assertEq(router.owner(), newOwner);
    }
}
