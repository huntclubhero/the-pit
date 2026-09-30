// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {PerpTypes} from "../../src/perp/interfaces/PerpTypes.sol";
import {PerpRiskConfig} from "../../src/perp/PerpRiskConfig.sol";
import {MockOracleRouter} from "../mocks/MockOracleRouter.sol";

/// @dev 18-decimal token with a fixed 1,000,000-token supply so FDV(USD 1e18) = 1e6 * price1e18.
contract RiskMockToken is ERC20 {
    constructor() ERC20("Perp Underlying", "PUP") {
        _mint(msg.sender, 1_000_000e18);
    }
}

contract PerpRiskConfigTest is Test {
    PerpRiskConfig internal config;
    MockOracleRouter internal router;
    RiskMockToken internal token;

    address internal constant TIMELOCK = address(0x7157);
    address internal constant RANDO = address(0xBEEF);

    uint256 internal constant SUPPLY_TOKENS = 1_000_000;

    function setUp() public {
        router = new MockOracleRouter();
        config = new PerpRiskConfig(IOracleRouter(address(router)), TIMELOCK);
        token = new RiskMockToken();
    }

    /// @dev Sets the router price so fdvOf(token) returns exactly `fdvUsd1e18`.
    function _setFdv(uint256 fdvUsd1e18) internal {
        router.setPrice(address(token), fdvUsd1e18 / SUPPLY_TOKENS, Types.PriceStatus.OK);
    }

    function _assign(uint8 tier, uint256 fdvUsd1e18) internal {
        _setFdv(fdvUsd1e18);
        vm.prank(TIMELOCK);
        config.assignTier(address(token), tier);
    }

    // ================================ defaults ================================

    function test_volParamsLaunchDefaults() public view {
        PerpTypes.VolParams memory p = config.volParams();
        assertEq(p.kVolX100, 100, "kVol 1.0");
        assertEq(p.maxVolSurchargeBps, 50, "surcharge clamp 50 bps");
        assertEq(p.freshSurchargeStartBps, 25, "fresh surcharge 25 bps");
        assertEq(p.kCapVolX100, 2500, "kCapVol 25 bps per bps");
        assertEq(p.maxVolDiscountBps, 5000, "cap-discount clamp 50%");
        assertEq(p.kBorrowVolX100, 400, "borrow-vol slope 4.00x per bps");
        assertEq(p.volBorrowDeadbandBps, 300, "borrow-vol deadband 300 bps");
        assertEq(p.maxVolBorrowMultX100, 2_000_000, "borrow multiplier clamp 20,000x");
        assertEq(p.volRefTauSeconds, 12 hours, "vol reference tau 12h");
    }

    function test_setVolParams_hardCapsAndAuth() public {
        PerpTypes.VolParams memory launch = config.volParams();
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDO));
        config.setVolParams(launch);

        vm.startPrank(TIMELOCK);
        PerpTypes.VolParams memory bad = config.volParams(); // fresh copy per mutation (memory aliasing)
        bad.kVolX100 = 1_001; // > 10.0 hard cap
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setVolParams(bad);
        bad = config.volParams();
        bad.maxVolSurchargeBps = 201; // > 2% hard cap
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setVolParams(bad);
        bad = config.volParams();
        bad.freshSurchargeStartBps = 101; // > 1% hard cap
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setVolParams(bad);
        bad = config.volParams();
        bad.kCapVolX100 = 10_001; // > 100 bps per bps hard cap
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setVolParams(bad);
        bad = config.volParams();
        bad.maxVolDiscountBps = 9_001; // > 90% hard cap: a market can never fully close
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setVolParams(bad);
        // RE-ECON-1 borrow-vol hard caps.
        bad = config.volParams();
        bad.kBorrowVolX100 = 2_001; // > 20x per bps hard cap
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setVolParams(bad);
        bad = config.volParams();
        bad.volBorrowDeadbandBps = 1_001; // > 10% hard cap (would disarm the layer)
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setVolParams(bad);
        bad = config.volParams();
        bad.maxVolBorrowMultX100 = 5_000_001; // > 50,000x hard cap
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setVolParams(bad);
        bad = config.volParams();
        bad.volRefTauSeconds = 30 minutes; // below the 1h tau floor
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setVolParams(bad);
        bad = config.volParams();
        bad.volRefTauSeconds = 8 days; // above the 7d tau ceiling
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setVolParams(bad);
        // Arming the multiplier without a tau is forbidden: a zero tau snaps the engine's
        // reference to every accrual mark and reintroduces the per-slice suppression dodge.
        bad = config.volParams();
        bad.volRefTauSeconds = 0; // kBorrowVolX100 still 400
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setVolParams(bad);

        // Zeros are legal (each zero disables that lever) and in-cap values persist.
        config.setVolParams(
            PerpTypes.VolParams({
                kVolX100: 0,
                maxVolSurchargeBps: 0,
                freshSurchargeStartBps: 0,
                kCapVolX100: 0,
                maxVolDiscountBps: 0,
                kBorrowVolX100: 0,
                volBorrowDeadbandBps: 0,
                maxVolBorrowMultX100: 0,
                volRefTauSeconds: 0
            })
        );
        assertEq(config.volParams().kVolX100, 0, "zeroed");
        config.setVolParams(
            PerpTypes.VolParams({
                kVolX100: 100,
                maxVolSurchargeBps: 50,
                freshSurchargeStartBps: 25,
                kCapVolX100: 2500,
                maxVolDiscountBps: 5000,
                kBorrowVolX100: 400,
                volBorrowDeadbandBps: 300,
                maxVolBorrowMultX100: 2_000_000,
                volRefTauSeconds: 12 hours
            })
        );
        assertEq(config.volParams().kCapVolX100, 2500, "restored");
        assertEq(config.volParams().kBorrowVolX100, 400, "borrow-vol restored");
        vm.stopPrank();
    }

    function test_lockedLeverageSchedule() public view {
        assertEq(config.lockedMaxLeverageX100(0), 400);
        assertEq(config.lockedMaxLeverageX100(1), 600);
        assertEq(config.lockedMaxLeverageX100(2), 600);
        assertEq(config.lockedMaxLeverageX100(3), 800);
        assertEq(config.lockedMaxLeverageX100(4), 1000);
        assertEq(config.lockedMaxLeverageX100(5), 1500);
    }

    function test_tierDefaultsMatchSpecTable() public view {
        uint16[6] memory mmr = [uint16(1500), 1000, 1000, 800, 600, 400];
        uint128[6] memory caps =
            [uint128(5_000e6), 10_000e6, 10_000e6, 25_000e6, 50_000e6, 50_000e6];
        for (uint8 t = 0; t < 6; t++) {
            PerpTypes.TierParams memory p = config.tierDefaults(t);
            assertEq(p.maxLeverageX100, config.lockedMaxLeverageX100(t), "lev");
            assertEq(p.mmrBps, mmr[t], "mmr");
            assertEq(p.openFeeBps, 10, "openFee");
            assertEq(p.closeFeeBps, 10, "closeFee");
            assertEq(p.kFPerHour1e18, 0.0025e18, "kF");
            assertEq(p.kBPerHour1e18, 0.0001e18, "kB");
            assertEq(p.liqPenaltyBps, 100, "penalty");
            assertEq(p.maxPositionMargin, caps[t], "posCap");
            // maintenance strictly below initial margin at max leverage
            assertLt(uint256(p.mmrBps) * p.maxLeverageX100, 1_000_000, "mmr < 1/L");
        }
    }

    function test_governanceScalarDefaults() public view {
        assertEq(config.payoutCapMultiple(), 9);
        assertEq(config.maxUtilizationBps(), 8000);
        assertEq(config.marketReserveCapBps(), 1000);
        assertEq(config.refreshCooldown(), 24 hours);
        assertEq(config.hysteresisBps(), 2000);
    }

    function test_tierBandEdges() public view {
        assertEq(config.tierLowerBoundUsd1e18(0), 0);
        assertEq(config.tierLowerBoundUsd1e18(1), 500_000e18);
        assertEq(config.tierUpperBoundUsd1e18(4), 50_000_000e18);
        assertEq(config.tierUpperBoundUsd1e18(5), type(uint256).max);
        assertEq(config.tierForFdv(499_999e18), 0);
        assertEq(config.tierForFdv(500_000e18), 1);
        assertEq(config.tierForFdv(60_000_000e18), 5);
    }

    // ================================ assignment ================================

    function test_assignTier_happyPath() public {
        _assign(1, 1_000_000e18);
        assertEq(config.mcapTierOf(address(token)), 1);
        PerpTypes.TierParams memory p = config.paramsFor(address(token));
        assertEq(p.maxLeverageX100, 600);
        assertEq(p.mmrBps, 1000);
    }

    function test_assignTier_onlyOwner() public {
        _setFdv(1_000_000e18);
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDO));
        config.assignTier(address(token), 1);
    }

    function test_assignTier_fdvOutsideBandReverts() public {
        _setFdv(1_000_000e18); // tier 1 band
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpRiskConfig.FdvOutsideTierBand.selector, address(token), 3, 1_000_000e18
            )
        );
        config.assignTier(address(token), 3);
    }

    function test_assignTier_staleOracleReverts() public {
        router.setPrice(address(token), 1e18, Types.PriceStatus.STALE);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.PriceUnavailable.selector, address(token)));
        config.assignTier(address(token), 1);
    }

    function test_unassignedTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.TierNotAssigned.selector, address(token)));
        config.paramsFor(address(token));
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.TierNotAssigned.selector, address(token)));
        config.mcapTierOf(address(token));
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.TierNotAssigned.selector, address(token)));
        config.refreshTier(address(token));
    }

    // ================================ refresh: downgrade ================================

    function test_refresh_noChangeRevertsAndDoesNotConsumeEpoch() public {
        _assign(1, 1_000_000e18);
        skip(25 hours);
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.NoTierChange.selector, address(token)));
        config.refreshTier(address(token));
        // A real downgrade right after still works: the no-op did not consume the epoch.
        _setFdv(300_000e18);
        config.refreshTier(address(token));
        assertEq(config.mcapTierOf(address(token)), 0);
    }

    function test_refresh_downgradeExemptFromCooldown() public {
        // Emergency path: FDV craters right after assignment; the downgrade must land
        // immediately, inside the 24h cooldown window.
        _assign(1, 1_000_000e18);
        _setFdv(300_000e18);
        vm.prank(RANDO);
        config.refreshTier(address(token));
        assertEq(config.mcapTierOf(address(token)), 0, "downgrade must not wait out the cooldown");
        assertEq(config.paramsFor(address(token)).maxLeverageX100, 400);
    }

    function test_refresh_consecutiveDowngradesNeedNoCooldown() public {
        _assign(4, 20_000_000e18);
        // First downgrade inside the cooldown window.
        _setFdv(6_000_000e18); // below 10M * 0.8 = 8M: tier 4 -> 3
        config.refreshTier(address(token));
        assertEq(config.mcapTierOf(address(token)), 3);
        // Keeps cratering: the next downgrade is also immediate.
        _setFdv(300_000e18); // below 5M * 0.8 = 4M: tier 3 -> 0
        config.refreshTier(address(token));
        assertEq(config.mcapTierOf(address(token)), 0);
    }

    function test_refresh_upgradeCooldownFromAssignment() public {
        _assign(1, 1_000_000e18);
        _setFdv(3_000_000e18); // clears tier 1 upper edge + hysteresis (2.4M)
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.RefreshCooldownActive.selector, address(token)));
        config.refreshTier(address(token));
    }

    function test_refresh_queuedUpgradeCannotDelayDowngrade() public {
        // The griefing vector from the audit: front-running a needed downgrade with a
        // queued upgrade consumes lastChangeAt but must NOT delay the downgrade.
        _assign(1, 1_000_000e18);
        skip(24 hours);
        _setFdv(3_000_000e18);
        config.refreshTier(address(token)); // queues an upgrade, consumes the epoch
        assertTrue(config.tierStateOf(address(token)).upgradePending);
        _setFdv(300_000e18); // rug in the same window
        vm.prank(RANDO);
        config.refreshTier(address(token));
        assertEq(config.mcapTierOf(address(token)), 0, "downgrade must land despite the queued upgrade");
        assertFalse(config.tierStateOf(address(token)).upgradePending, "stale upgrade must cancel");
    }

    function test_refresh_downgradeAppliesImmediately() public {
        _assign(2, 3_000_000e18);
        skip(24 hours);
        // tier 2 lower edge is 2M; hysteresis needs FDV < 1.6M
        _setFdv(1_500_000e18);
        vm.prank(RANDO); // permissionless
        config.refreshTier(address(token));
        assertEq(config.mcapTierOf(address(token)), 1);
        assertEq(config.paramsFor(address(token)).maxLeverageX100, 600);
    }

    function test_refresh_downgradeHysteresisBlocksInsideBand() public {
        _assign(1, 1_000_000e18);
        skip(24 hours);
        // tier 1 lower edge 500k; hysteresis threshold 400k. 450k must NOT downgrade.
        _setFdv(450_000e18);
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.HysteresisNotCleared.selector, address(token)));
        config.refreshTier(address(token));
        // 399,999 clears it.
        _setFdv(399_999e18);
        config.refreshTier(address(token));
        assertEq(config.mcapTierOf(address(token)), 0);
    }

    function test_refresh_multiTierDowngradeInOneCall() public {
        _assign(4, 20_000_000e18);
        skip(24 hours);
        _setFdv(300_000e18); // way below tier 4 edge (10M * 0.8 = 8M)
        config.refreshTier(address(token));
        assertEq(config.mcapTierOf(address(token)), 0);
    }

    function test_refresh_upgradeRateLimitAfterDowngrade() public {
        _assign(2, 3_000_000e18);
        skip(24 hours);
        _setFdv(1_500_000e18);
        config.refreshTier(address(token)); // tier 2 -> 1, consumes the epoch
        // An upgrade attempt inside the fresh cooldown must still be rate limited.
        _setFdv(3_000_000e18); // clears tier 1 upper edge + hysteresis (2.4M)
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.RefreshCooldownActive.selector, address(token)));
        config.refreshTier(address(token));
        skip(24 hours);
        config.refreshTier(address(token)); // now allowed: queues
        assertEq(config.mcapTierOf(address(token)), 1, "upgrade only queues");
        assertTrue(config.tierStateOf(address(token)).upgradePending);
    }

    // ================================ refresh: upgrade queue ================================

    function test_refresh_upgradeQueuesAndDoesNotRaiseTier() public {
        _assign(1, 1_000_000e18);
        skip(24 hours);
        // tier 1 upper edge 2M; hysteresis needs FDV > 2.4M
        _setFdv(3_000_000e18);
        config.refreshTier(address(token));
        assertEq(config.mcapTierOf(address(token)), 1, "tier must not rise permissionlessly");
        PerpRiskConfig.TierState memory st = config.tierStateOf(address(token));
        assertTrue(st.upgradePending);
        assertEq(st.pendingUpgradeTier, 2);
    }

    function test_refresh_upgradeHysteresisBlocks() public {
        _assign(1, 1_000_000e18);
        skip(24 hours);
        _setFdv(2_300_000e18); // above edge but below 2.4M threshold
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.HysteresisNotCleared.selector, address(token)));
        config.refreshTier(address(token));
    }

    function test_applyTierUpgrade_ownerOnlyAndRechecksFdv() public {
        _assign(1, 1_000_000e18);
        skip(24 hours);
        _setFdv(3_000_000e18);
        config.refreshTier(address(token));

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDO));
        config.applyTierUpgrade(address(token));

        // pump faded during the timelock delay: apply must refuse
        _setFdv(1_000_000e18);
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.UpgradeNoLongerSupported.selector, address(token)));
        config.applyTierUpgrade(address(token));

        // FDV held: apply lands
        _setFdv(3_000_000e18);
        vm.prank(TIMELOCK);
        config.applyTierUpgrade(address(token));
        assertEq(config.mcapTierOf(address(token)), 2);
        assertFalse(config.tierStateOf(address(token)).upgradePending);
    }

    function test_downgradeCancelsPendingUpgrade() public {
        _assign(1, 1_000_000e18);
        skip(24 hours);
        _setFdv(3_000_000e18);
        config.refreshTier(address(token));
        skip(24 hours);
        _setFdv(200_000e18);
        config.refreshTier(address(token));
        assertEq(config.mcapTierOf(address(token)), 0);
        assertFalse(config.tierStateOf(address(token)).upgradePending);
    }

    function test_cancelTierUpgrade() public {
        _assign(1, 1_000_000e18);
        skip(24 hours);
        _setFdv(3_000_000e18);
        config.refreshTier(address(token));
        vm.prank(TIMELOCK);
        config.cancelTierUpgrade(address(token));
        assertFalse(config.tierStateOf(address(token)).upgradePending);
    }

    /// @dev THE anti-manipulation property: no permissionless call sequence raises the tier.
    function testFuzz_refreshNeverRaisesTier(uint256 fdv, uint32 warpBy) public {
        fdv = bound(fdv, 1e18, 1_000_000_000e18);
        warpBy = uint32(bound(warpBy, 0, 30 days));
        _assign(2, 3_000_000e18);
        uint8 before = config.mcapTierOf(address(token));
        skip(warpBy);
        _setFdv(fdv);
        try config.refreshTier(address(token)) {} catch {}
        assertLe(config.mcapTierOf(address(token)), before, "permissionless refresh raised leverage tier");
    }

    // ================================ overrides ================================

    function _majorOverride() internal pure returns (PerpTypes.TierParams memory) {
        return PerpTypes.TierParams({
            maxLeverageX100: 1500,
            mmrBps: 333,
            openFeeBps: 5,
            closeFeeBps: 5,
            kFPerHour1e18: 0.0005e18,
            kBPerHour1e18: 0.0001e18,
            liqPenaltyBps: 100,
            maxPositionMargin: 250_000e6
        });
    }

    function test_tokenOverride_majorsProfile() public {
        _assign(5, 100_000_000e18);
        vm.prank(TIMELOCK);
        config.setTokenOverride(address(token), _majorOverride());
        PerpTypes.TierParams memory p = config.paramsFor(address(token));
        assertEq(p.mmrBps, 333);
        assertEq(p.openFeeBps, 5);
        assertEq(p.maxPositionMargin, 250_000e6);
        assertEq(p.maxLeverageX100, 1500);
    }

    function test_overrideLeverageClampedAfterDowngrade() public {
        _assign(5, 100_000_000e18);
        vm.prank(TIMELOCK);
        config.setTokenOverride(address(token), _majorOverride());
        skip(24 hours);
        _setFdv(30_000_000e18); // below 50M * 0.8 = 40M: downgrade to tier 4
        config.refreshTier(address(token));
        assertEq(config.mcapTierOf(address(token)), 4);
        // Override still active, but leverage clamps to tier 4's locked 10x.
        PerpTypes.TierParams memory p = config.paramsFor(address(token));
        assertEq(p.maxLeverageX100, 1000, "override leverage must clamp to current tier lock");
        assertEq(p.mmrBps, 333, "other override fields survive");
    }

    function test_overrideCannotExceedLockedLeverage() public {
        _assign(1, 1_000_000e18);
        PerpTypes.TierParams memory p = _majorOverride(); // 15x, locked for tier 1 is 6x
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.LeverageAboveLockedSchedule.selector, 1, 1500));
        config.setTokenOverride(address(token), p);
    }

    function test_clearTokenOverride() public {
        _assign(5, 100_000_000e18);
        vm.startPrank(TIMELOCK);
        config.setTokenOverride(address(token), _majorOverride());
        config.clearTokenOverride(address(token));
        vm.stopPrank();
        assertEq(config.paramsFor(address(token)).mmrBps, 400); // back to tier 5 default
    }

    // ================================ setter validation ================================

    function test_setTierParams_cannotRaiseAboveLockedSchedule() public {
        PerpTypes.TierParams memory p = config.tierDefaults(0);
        p.maxLeverageX100 = 500; // locked is 400
        vm.prank(TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(PerpRiskConfig.LeverageAboveLockedSchedule.selector, 0, 500));
        config.setTierParams(0, p);
    }

    function test_setTierParams_rejectsMmrAtOrAboveInitialMargin() public {
        PerpTypes.TierParams memory p = config.tierDefaults(0);
        p.mmrBps = 2500; // 25% >= 1/4x initial margin
        vm.prank(TIMELOCK);
        vm.expectRevert(PerpRiskConfig.InvalidTierParams.selector);
        config.setTierParams(0, p);
    }

    function test_setTierParams_validLoweringWorks() public {
        PerpTypes.TierParams memory p = config.tierDefaults(0);
        p.maxLeverageX100 = 200; // emergency de-risk below locked schedule
        p.openFeeBps = 15;
        vm.prank(TIMELOCK);
        config.setTierParams(0, p);
        assertEq(config.tierDefaults(0).maxLeverageX100, 200);
        assertEq(config.tierDefaults(0).openFeeBps, 15);
    }

    function test_scalarSetterBoundsAndAuth() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setPayoutCapMultiple(1);
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setPayoutCapMultiple(21);
        config.setPayoutCapMultiple(12);
        assertEq(config.payoutCapMultiple(), 12);

        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setMaxUtilizationBps(0);
        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setMaxUtilizationBps(10_001);
        config.setMaxUtilizationBps(6000);
        assertEq(config.maxUtilizationBps(), 6000);

        config.setMarketReserveCapBps(500);
        assertEq(config.marketReserveCapBps(), 500);

        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setRefreshCooldown(30 minutes);
        config.setRefreshCooldown(48 hours);
        assertEq(config.refreshCooldown(), 48 hours);

        vm.expectRevert(PerpRiskConfig.ParamOutOfBounds.selector);
        config.setHysteresisBps(5001);
        config.setHysteresisBps(1000);
        assertEq(config.hysteresisBps(), 1000);
        vm.stopPrank();

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, RANDO));
        config.setPayoutCapMultiple(9);
    }
}
