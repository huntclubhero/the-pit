// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PerpTypes} from "../../../src/perp/interfaces/PerpTypes.sol";
import {IPerpRiskConfig} from "../../../src/perp/interfaces/IPerpRiskConfig.sol";

/// @title MockPerpRiskConfig: settable tier table for PerpEngine tests
contract MockPerpRiskConfig is IPerpRiskConfig {
    mapping(address => PerpTypes.TierParams) internal _params;
    mapping(address => bool) internal _assigned;
    mapping(address => uint8) public tierOf;

    uint256 internal _payoutCapMultiple = 9;
    uint16 internal _maxUtilizationBps = 8_000;
    uint16 internal _marketReserveCapBps = 1_000;
    /// @dev Vol-pricing knobs default to ZERO in the mock so legacy fee/cap fixtures stay
    ///      byte-exact; the economics suites set them explicitly via setVolParams.
    PerpTypes.VolParams internal _volParams;

    error NoTierAssigned();

    function setParams(address token, PerpTypes.TierParams memory p, uint8 tier) external {
        _params[token] = p;
        _assigned[token] = true;
        tierOf[token] = tier;
    }

    function setPayoutCapMultiple(uint256 value) external {
        _payoutCapMultiple = value;
    }

    function setMaxUtilizationBps(uint16 value) external {
        _maxUtilizationBps = value;
    }

    function setMarketReserveCapBps(uint16 value) external {
        _marketReserveCapBps = value;
    }

    /// @inheritdoc IPerpRiskConfig
    function paramsFor(address token) external view returns (PerpTypes.TierParams memory) {
        if (!_assigned[token]) revert NoTierAssigned();
        return _params[token];
    }

    /// @inheritdoc IPerpRiskConfig
    function mcapTierOf(address token) external view returns (uint8) {
        return tierOf[token];
    }

    /// @inheritdoc IPerpRiskConfig
    function refreshTier(address token) external {}

    /// @inheritdoc IPerpRiskConfig
    function payoutCapMultiple() external view returns (uint256) {
        return _payoutCapMultiple;
    }

    /// @inheritdoc IPerpRiskConfig
    function maxUtilizationBps() external view returns (uint16) {
        return _maxUtilizationBps;
    }

    /// @inheritdoc IPerpRiskConfig
    function marketReserveCapBps() external view returns (uint16) {
        return _marketReserveCapBps;
    }

    function setVolParams(PerpTypes.VolParams memory p) external {
        _volParams = p;
    }

    /// @inheritdoc IPerpRiskConfig
    function volParams() external view returns (PerpTypes.VolParams memory) {
        return _volParams;
    }
}
