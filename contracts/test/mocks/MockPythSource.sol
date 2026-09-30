// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPyth} from "../../src/oracle/adapters/IPyth.sol";

/// @title MockPythSource: settable IPyth implementation for oracle tests
/// @notice Mirrors real Pyth behavior: getPriceUnsafe reverts for unknown feed ids and returns
///         the stored struct verbatim otherwise (no staleness enforcement).
contract MockPythSource is IPyth {
    mapping(bytes32 => Price) internal _prices;
    mapping(bytes32 => bool) internal _exists;
    bool public revertOnRead;

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        _prices[id] = Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
        _exists[id] = true;
    }

    function removePrice(bytes32 id) external {
        delete _prices[id];
        _exists[id] = false;
    }

    function setRevertOnRead(bool value) external {
        revertOnRead = value;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory price) {
        require(!revertOnRead, "MOCK_PYTH_REVERT");
        require(_exists[id], "PriceFeedNotFound");
        return _prices[id];
    }
}
