// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Types} from "../../src/interfaces/Types.sol";
import {PauseGuardian} from "../../src/core/PauseGuardian.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockPitPoints} from "../mocks/MockPitPoints.sol";
import {MockPerpOracle} from "./mocks/MockPerpOracle.sol";
import {MockPitVault} from "./mocks/MockPitVault.sol";
import {MockInsuranceFund} from "./mocks/MockInsuranceFund.sol";
import {MockPerpRiskConfig} from "./mocks/MockPerpRiskConfig.sol";

/// @notice Shared harness for PerpEngine suites. USDG 6 decimals; two listed markets:
///         MEME (6x cap, 10% MMR, 10 bps fees, hot funding) and MAJOR (15x, 3.33% MMR,
///         5 bps fees, cool funding). Vault seeded with 1M USDG, insurance fund with 100k.
contract PerpEngineBase is Test {
    uint256 internal constant SCALE = 1e12;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant VAULT_SEED = 1_000_000e6;
    uint256 internal constant IF_SEED = 100_000e6;

    MockUSDG internal usdg;
    MockPerpOracle internal oracle;
    MockPitVault internal vault;
    MockInsuranceFund internal ifund;
    MockPerpRiskConfig internal risk;
    MockPitPoints internal points;
    PauseGuardian internal guardian;
    PerpEngine internal engine;

    address internal constant MEME = address(0xAE11E001);
    address internal constant MAJOR = address(0xAE11E002);

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");
    address internal guardianEoa = makeAddr("guardian");
    address internal jackpot = makeAddr("jackpot");
    address internal treasury = makeAddr("treasury");
    address internal referral = makeAddr("referral");
    address internal buyback = makeAddr("buyback");

    function setUp() public virtual {
        // Anchor away from timestamp 0 so ramp/window arithmetic behaves.
        vm.warp(30 days);

        usdg = new MockUSDG();
        oracle = new MockPerpOracle();
        vault = new MockPitVault(usdg);
        ifund = new MockInsuranceFund(usdg);
        risk = new MockPerpRiskConfig();
        points = new MockPitPoints();
        guardian = new PauseGuardian(guardianEoa);
        engine = new PerpEngine(
            address(this),
            address(usdg),
            address(oracle),
            address(vault),
            address(ifund),
            address(risk),
            address(points),
            address(guardian),
            Types.FeeSplit({jackpot: jackpot, treasury: treasury, referralPool: referral, buyback: buyback, vault: address(vault)})
        );
        vault.setEngine(address(engine));
        ifund.setEngine(address(engine));

        usdg.mint(address(this), VAULT_SEED + IF_SEED);
        usdg.approve(address(vault), VAULT_SEED);
        vault.fund(VAULT_SEED);
        usdg.approve(address(ifund), IF_SEED);
        ifund.fund(IF_SEED);

        // MEME: $2M-to-$5M style tier. 6x, MMR 10%, 10 bps fees, kF 0.25%/h, kB 0.01%/h,
        // penalty 1%, per-position margin cap 10k USDG.
        risk.setParams(
            MEME,
            PerpTypes.TierParams({
                maxLeverageX100: 600,
                mmrBps: 1_000,
                openFeeBps: 10,
                closeFeeBps: 10,
                kFPerHour1e18: 25e14,
                kBPerHour1e18: 1e14,
                liqPenaltyBps: 100,
                maxPositionMargin: 10_000e6
            }),
            2
        );
        // MAJOR: >$50M tier. 15x, MMR 3.33%, 5 bps fees, kF 0.05%/h.
        risk.setParams(
            MAJOR,
            PerpTypes.TierParams({
                maxLeverageX100: 1_500,
                mmrBps: 333,
                openFeeBps: 5,
                closeFeeBps: 5,
                kFPerHour1e18: 5e14,
                kBPerHour1e18: 1e14,
                liqPenaltyBps: 100,
                maxPositionMargin: 250_000e6
            }),
            5
        );

        oracle.setLive(MEME, 1e18);
        oracle.setLive(MAJOR, 50_000e18);
        oracle.setListable(MEME, true);
        oracle.setListable(MAJOR, true);

        // Hook for suites that must freeze a specific cost-to-move cap: B1 snapshots the router
        // cap at listMarket, so it MUST be set before the listMarket calls below.
        _configurePayoutCaps();

        engine.listMarket(MEME);
        engine.listMarket(MAJOR);
        // Fast-forward past the 14-day new-market ramp AND the fresh-market vol-surcharge
        // window so base suites see the full cap and undisturbed fee math; the ramp and the
        // surcharge are tested explicitly in the caps and economics suites.
        vm.warp(block.timestamp + 15 days);

        address[3] memory traders = [alice, bob, carol];
        for (uint256 i = 0; i < traders.length; i++) {
            usdg.mint(traders[i], 100_000e6);
            vm.prank(traders[i]);
            usdg.approve(address(engine), type(uint256).max);
        }
    }

    // ================================ helpers ================================

    /// @dev Override to set oracle payout caps BEFORE listMarket freezes them (B1).
    function _configurePayoutCaps() internal virtual {}

    /// @dev Default MEME-tier params (6x, MMR 10%, 10 bps fees, hot funding).
    function memeTierParams() internal pure returns (PerpTypes.TierParams memory) {
        return PerpTypes.TierParams({
            maxLeverageX100: 600,
            mmrBps: 1_000,
            openFeeBps: 10,
            closeFeeBps: 10,
            kFPerHour1e18: 25e14,
            kBPerHour1e18: 1e14,
            liqPenaltyBps: 100,
            maxPositionMargin: 10_000e6
        });
    }

    /// @dev List a fresh MEME-like market with a cost-to-move cap FROZEN at listing (B1). The cap
    ///      is set on the oracle BEFORE listMarket so the engine snapshots it; the ramp is skipped
    ///      so the full cap binds. Returns the market token.
    function listFreshMeme(uint256 payoutCap1e18) internal returns (address token) {
        token = address(uint160(0xCA9E00 + (++_freshNonce)));
        oracle.setLive(token, 1e18);
        oracle.setListable(token, true);
        if (payoutCap1e18 != type(uint256).max) oracle.setPayoutCap1e18(token, payoutCap1e18);
        risk.setParams(token, memeTierParams(), 2);
        engine.listMarket(token);
        // Skip both the engine (listedAt) and vault (firstReserveAt) new-market ramps plus the
        // fresh-market surcharge window (all 14 days under economics v2).
        vm.warp(block.timestamp + 15 days);
    }

    uint256 private _freshNonce;

    function open(address who, address token, bool isLong, uint128 margin, uint32 lev) internal returns (bytes32) {
        vm.prank(who);
        return engine.openPosition(token, isLong, margin, lev);
    }

    function posOf(address token, address who, bool isLong) internal view returns (PerpTypes.Position memory) {
        return engine.getPosition(token, who, isLong);
    }

    function aggOf(address token) internal view returns (PerpTypes.MarketAggregates memory) {
        return engine.marketState(token);
    }

    /// @dev Sum of USDG across every actor in the closed test system.
    function systemBalance() internal view returns (uint256 total) {
        address[12] memory holders = [
            alice,
            bob,
            carol,
            keeper,
            address(engine),
            address(vault),
            address(ifund),
            jackpot,
            treasury,
            referral,
            buyback,
            address(this)
        ];
        for (uint256 i = 0; i < holders.length; i++) {
            total += usdg.balanceOf(holders[i]);
        }
    }

    /// @dev Aggregates must equal position sums for the (token x traders x sides) grid.
    function assertAggMatchesPositions(address token) internal view {
        PerpTypes.MarketAggregates memory agg = aggOf(token);
        uint256 longSize;
        uint256 shortSize;
        uint256 longCost;
        uint256 shortCost;
        uint256 longMargin;
        uint256 shortMargin;
        uint256 payoutSum;
        address[4] memory traders = [alice, bob, carol, keeper];
        for (uint256 i = 0; i < traders.length; i++) {
            for (uint256 sideIdx = 0; sideIdx < 2; sideIdx++) {
                PerpTypes.Position memory p = posOf(token, traders[i], sideIdx == 0);
                if (p.size1e18 == 0) continue;
                uint256 cost = uint256(p.size1e18) * p.entryPrice1e18 / (1e18 * SCALE);
                if (p.isLong) {
                    longSize += p.size1e18;
                    longCost += cost;
                    longMargin += p.margin;
                } else {
                    shortSize += p.size1e18;
                    shortCost += cost;
                    shortMargin += p.margin;
                }
                payoutSum += p.maxPayout;
            }
        }
        assertEq(agg.totalLongSize1e18, longSize, "agg long size");
        assertEq(agg.totalShortSize1e18, shortSize, "agg short size");
        assertEq(agg.totalLongCost, longCost, "agg long cost");
        assertEq(agg.totalShortCost, shortCost, "agg short cost");
        assertEq(agg.totalLongMargin, longMargin, "agg long margin");
        assertEq(agg.totalShortMargin, shortMargin, "agg short margin");
        assertEq(agg.totalMaxPayout, payoutSum, "agg max payout");
        assertEq(vault.reservedOf(token), payoutSum, "vault reserve sync");
    }
}
