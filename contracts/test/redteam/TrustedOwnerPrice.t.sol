// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {IPriceSource} from "../../src/oracle/adapters/IPriceSource.sol";
import {IIndependentSource} from "../../src/oracle/adapters/IIndependentSource.sol";

/// @dev A price source whose owner freely dictates the returned price and which is NOT independent
///      of a settlement pool (stands in for an owner-controlled TWAP/pool adapter). The router
///      treats every adapter as independent of EACH OTHER, never of the OWNER.
contract OwnerControlledSource is IPriceSource {
    uint256 public price;

    function set(uint256 p) external {
        price = p;
    }

    function read(address) external view returns (uint256, uint256, bool) {
        return (price, block.timestamp, true);
    }
}

/// @dev An owner-controlled source that DECLARES settlement-pool independence (stands in for a real
///      Chainlink/Pyth feed).
contract IndependentControlledSource is IPriceSource, IIndependentSource {
    uint256 public price;

    function set(uint256 p) external {
        price = p;
    }

    function read(address) external view returns (uint256, uint256, bool) {
        return (price, block.timestamp, true);
    }

    function isIndependent(address) external pure returns (bool) {
        return true;
    }
}

/// @dev Minimal USDG stand-in (decimals only) for the router constructor.
contract MiniUSDG {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @title TO-1: owner price control is now MITIGATED (independent-source gate + governance timelock)
/// @notice Regression PoC, FLIPPED. Wave 2 proved a compromised owner could point every source at
///         owner-controlled adapters and drive checkPrice to any value with deviation zero,
///         refuting the old "no admin function can ever set a price" NatSpec. The fix does NOT claim
///         impossibility; it bounds the exposure with two enforced defenses, and the NatSpec now
///         states the truth (sources are independent of each other, not of the owner):
///           1. isListable requires at least one genuinely settlement-pool-independent source for a
///              value-bearing (Tier A_MAJOR) token, so the owner cannot list a token whose every
///              source is an owned pool adapter.
///           2. The router owner is an OZ TimelockController (see Deploy.s.sol), so setSources takes
///              effect only after a public delay, giving a live position a window to settle at the
///              honest price before a source swap can land.
contract TrustedOwnerPriceTest is Test {
    MiniUSDG internal usdg;
    address internal token = makeAddr("liveToken");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdg = new MiniUSDG();
    }

    /// @notice Mitigation 1: a value-bearing A_MAJOR token whose sources are ALL owner-controlled
    ///         and non-independent is NOT listable, so a compromised owner cannot stand up a market
    ///         it fully prices from owned adapters. Listing requires a genuinely independent source.
    function test_TO1_independentSourceRequiredToListValueBearingToken() public {
        OracleRouter router = new OracleRouter(address(this), address(usdg));

        // Three owner-controlled, non-independent sources moving in lockstep (deviation zero).
        OwnerControlledSource s0 = new OwnerControlledSource();
        OwnerControlledSource s1 = new OwnerControlledSource();
        OwnerControlledSource s2 = new OwnerControlledSource();
        s0.set(1e18);
        s1.set(1e18);
        s2.set(1e18);
        OracleRouter.SourceConfig[] memory sources = new OracleRouter.SourceConfig[](3);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(s0)), maxStaleness: 1 hours});
        sources[1] = OracleRouter.SourceConfig({source: IPriceSource(address(s1)), maxStaleness: 1 hours});
        sources[2] = OracleRouter.SourceConfig({source: IPriceSource(address(s2)), maxStaleness: 1 hours});
        router.setSources(token, sources);

        // The median math still returns the owner's number (this is not an impossibility claim)...
        (uint256 p, Types.PriceStatus st) = router.checkPrice(token);
        assertEq(uint8(st), uint8(Types.PriceStatus.OK));
        assertEq(p, 1e18);

        // ...but the token is NOT LISTABLE: no configured source is independent of a settlement pool.
        assertFalse(router.isListable(token), "not listable: all sources owner-controlled, none independent");

        // Only once a genuinely independent feed backs the token does it become listable.
        IndependentControlledSource indy = new IndependentControlledSource();
        indy.set(1e18);
        sources[2] = OracleRouter.SourceConfig({source: IPriceSource(address(indy)), maxStaleness: 1 hours});
        router.setSources(token, sources);
        assertTrue(router.isListable(token), "listable once an independent source is present");
    }

    /// @notice Mitigation 2: with the router owned by a governance TimelockController, an owner
    ///         source swap can no longer take effect immediately. A direct call by the multisig
    ///         reverts (it is not the owner), and the scheduled operation cannot execute until the
    ///         timelock delay has elapsed, giving a live position a window to settle honestly first.
    address internal gov = makeAddr("govMultisig");
    uint256 internal constant MIN_DELAY = 2 days;

    function _newTimelock() internal returns (TimelockController) {
        address[] memory who = new address[](1);
        who[0] = gov;
        return new TimelockController(MIN_DELAY, who, who, address(0));
    }

    function _threeSources() internal returns (OracleRouter.SourceConfig[] memory sources) {
        OwnerControlledSource s0 = new OwnerControlledSource();
        OwnerControlledSource s1 = new OwnerControlledSource();
        OwnerControlledSource s2 = new OwnerControlledSource();
        s0.set(5e18);
        s1.set(5e18);
        s2.set(5e18);
        sources = new OracleRouter.SourceConfig[](3);
        sources[0] = OracleRouter.SourceConfig({source: IPriceSource(address(s0)), maxStaleness: 1 hours});
        sources[1] = OracleRouter.SourceConfig({source: IPriceSource(address(s1)), maxStaleness: 1 hours});
        sources[2] = OracleRouter.SourceConfig({source: IPriceSource(address(s2)), maxStaleness: 1 hours});
    }

    function test_TO1_timelockDelaysSetSources() public {
        TimelockController timelock = _newTimelock();
        // The router is owned by the TIMELOCK, not the multisig directly.
        OracleRouter router = new OracleRouter(address(timelock), address(usdg));
        OracleRouter.SourceConfig[] memory sources = _threeSources();
        bytes memory data = abi.encodeCall(OracleRouter.setSources, (token, sources));

        // A direct swap by the multisig is rejected: it is not the owner (the timelock is).
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, gov));
        router.setSources(token, sources);

        // The multisig must SCHEDULE the change on the timelock and wait out the delay.
        vm.prank(gov);
        timelock.schedule(address(router), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        // Executing before the delay elapses reverts: the swap cannot land instantly.
        vm.prank(gov);
        vm.expectRevert();
        timelock.execute(address(router), 0, data, bytes32(0), bytes32(0));
        assertEq(router.sourcesOf(token).length, 0, "no source swap took effect before the delay");

        // Only after the timelock delay does the swap take effect: a live position had the whole
        // window to settle at the honest price first.
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(gov);
        timelock.execute(address(router), 0, data, bytes32(0), bytes32(0));
        assertEq(router.sourcesOf(token).length, 3, "swap lands only after the delay");
    }
}
