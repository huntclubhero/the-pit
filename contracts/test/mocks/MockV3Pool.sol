// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title MockV3Pool: settable Uniswap v3 pool stand-in for oracle tests
/// @notice Implements only the pool surface the oracle module touches: observe(), slot0(),
///         liquidity(), token0(), token1(). Tick cumulatives are settable per secondsAgo value
///         so tests can pin exact TWAP math. A revert flag simulates Uniswap's "OLD" revert for
///         pools whose oldest observation is younger than the requested window.
contract MockV3Pool {
    address public token0;
    address public token1;
    uint128 internal _liquidity;

    uint160 internal _sqrtPriceX96;
    int24 internal _tick;
    uint16 internal _observationIndex;
    uint16 internal _observationCardinality;

    bool public revertOnObserve;
    bool public revertOnLiquidity;

    mapping(uint32 => int56) public tickCumulativeAt;
    mapping(uint32 => uint160) public secondsPerLiquidityCumulativeAt;

    function setTokens(address t0, address t1) external {
        token0 = t0;
        token1 = t1;
    }

    function setLiquidity(uint128 liquidity_) external {
        _liquidity = liquidity_;
    }

    function setSlot0(uint160 sqrtPriceX96_, int24 tick_, uint16 observationIndex_, uint16 observationCardinality_)
        external
    {
        _sqrtPriceX96 = sqrtPriceX96_;
        _tick = tick_;
        _observationIndex = observationIndex_;
        _observationCardinality = observationCardinality_;
    }

    function setTickCumulative(uint32 secondsAgo, int56 cumulative) external {
        tickCumulativeAt[secondsAgo] = cumulative;
    }

    function setSecondsPerLiquidityCumulative(uint32 secondsAgo, uint160 cumulative) external {
        secondsPerLiquidityCumulativeAt[secondsAgo] = cumulative;
    }

    function setRevertOnObserve(bool value) external {
        revertOnObserve = value;
    }

    function setRevertOnLiquidity(bool value) external {
        revertOnLiquidity = value;
    }

    function liquidity() external view returns (uint128) {
        require(!revertOnLiquidity, "MOCK_LIQUIDITY_REVERT");
        return _liquidity;
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (_sqrtPriceX96, _tick, _observationIndex, _observationCardinality, _observationCardinality, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(!revertOnObserve, "OLD");
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            tickCumulatives[i] = tickCumulativeAt[secondsAgos[i]];
            secondsPerLiquidityCumulativeX128s[i] = secondsPerLiquidityCumulativeAt[secondsAgos[i]];
        }
    }
}
