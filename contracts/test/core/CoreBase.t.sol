// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Types} from "../../src/interfaces/Types.sol";
import {Market} from "../../src/core/Market.sol";
import {MarketFactory} from "../../src/core/MarketFactory.sol";
import {PauseGuardian} from "../../src/core/PauseGuardian.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";
import {MockOracleRouter} from "../mocks/MockOracleRouter.sol";
import {MockPitPoints} from "../mocks/MockPitPoints.sol";

/// @title CoreBase: shared fixture for CORE module tests
/// @notice Deploys the full core stack against mocks and creates one market for a
///         synthetic underlying token. Subclasses can override _initialLiquidity to
///         widen the OI headroom (the fuzz suite does).
abstract contract CoreBase is Test {
    MockUSDG internal usdg;
    MockOracleRouter internal router;
    MockPitPoints internal pitPoints;
    PauseGuardian internal pauseGuardian;
    MarketFactory internal factory;
    Market internal market;

    address internal token;
    address internal guardianMultisig;
    address internal owner;
    address internal jackpot;
    address internal treasury;
    address internal referral;
    address internal buyback;
    address internal alice;
    address internal bob;
    address internal carol;

    uint16 internal constant OI_CAP_BPS = 1_000;
    /// @dev Per-address sub-cap for the shared fixture. Set to 100 percent so it never binds
    ///      before the GLOBAL OI cap: the shared suites exercise other behavior, and the
    ///      sub-cap has focused coverage in MarketPerAddressOiCap.t.sol.
    uint16 internal constant PER_ADDRESS_OI_CAP_BPS = 10_000;
    /// @dev Settlement fee baked into the fixture's markets, in basis points of the loser's notional
    ///      (the launch default, at or below Market.MAX_FEE_BPS).
    uint16 internal constant SETTLEMENT_FEE_BPS = 50;

    function _initialLiquidity() internal pure virtual returns (uint256) {
        return 1_000_000e18;
    }

    /// @dev Per-address sub-cap a subclass fixture bakes into its market; overridable.
    function _perAddressOiCapBps() internal pure virtual returns (uint16) {
        return PER_ADDRESS_OI_CAP_BPS;
    }

    function setUp() public virtual {
        // A deterministic non-genesis timestamp so expiry math never underflows.
        vm.warp(1_800_000_000);

        token = makeAddr("underlyingToken");
        guardianMultisig = makeAddr("guardianMultisig");
        owner = makeAddr("owner");
        jackpot = makeAddr("jackpot");
        treasury = makeAddr("treasury");
        referral = makeAddr("referral");
        buyback = makeAddr("buyback");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        usdg = new MockUSDG();
        router = new MockOracleRouter();
        pitPoints = new MockPitPoints();
        pauseGuardian = new PauseGuardian(guardianMultisig);
        factory = new MarketFactory(
            address(usdg),
            address(router),
            address(pitPoints),
            Types.FeeSplit({
                jackpot: jackpot, treasury: treasury, referralPool: referral, buyback: buyback, vault: address(0)
            }),
            OI_CAP_BPS,
            _perAddressOiCapBps(),
            SETTLEMENT_FEE_BPS,
            address(pauseGuardian),
            owner
        );

        router.setListable(token, true);
        router.setSnapshotValue(token, _initialLiquidity());
        router.setTrackedLiquidity(token, _initialLiquidity());
        router.setPrice(token, 1e18, Types.PriceStatus.OK);

        market = Market(factory.createMarket(token));
    }

    /// @dev Mint USDG to `who` and approve the market to pull it.
    function _fund(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.prank(who);
        usdg.approve(address(market), type(uint256).max);
    }

    /// @dev Post an offer with sane defaults from `maker`, funding them first.
    function _postOffer(address maker, Types.Side side, uint128 collateral, uint128 minFill)
        internal
        returns (uint256 offerId)
    {
        return _postOfferFull(maker, side, collateral, minFill, 5, 1 days, uint64(block.timestamp + 1 days), 0);
    }

    /// @dev The 1:1 (symmetric) payoff ratio in basis points; reproduces the pre-odds behavior.
    uint32 internal constant SYMMETRIC_RATIO_BPS = 10_000;

    /// @dev Post an offer with explicit parameters from `maker`, funding them first. Uses the 1:1
    ///      (symmetric) payoff ratio, so it reproduces the pre-odds equal-collateral behavior.
    function _postOfferFull(
        address maker,
        Types.Side side,
        uint128 collateral,
        uint128 minFill,
        uint16 multiple,
        uint32 duration,
        uint64 offerExpiry,
        uint128 limitEntry1e18
    ) internal returns (uint256 offerId) {
        return _postOfferOdds(
            maker, side, collateral, minFill, multiple, SYMMETRIC_RATIO_BPS, duration, offerExpiry, limitEntry1e18
        );
    }

    /// @dev Post an offer at an explicit payoff ratio (odds), funding the maker first.
    function _postOfferOdds(
        address maker,
        Types.Side side,
        uint128 collateral,
        uint128 minFill,
        uint16 multiple,
        uint32 payoffRatioBps,
        uint32 duration,
        uint64 offerExpiry,
        uint128 limitEntry1e18
    ) internal returns (uint256 offerId) {
        _fund(maker, collateral);
        vm.prank(maker);
        offerId = market.postOffer(
            side, collateral, minFill, multiple, payoffRatioBps, duration, offerExpiry, limitEntry1e18
        );
    }

    /// @dev Fill `fillCollateral` of MAKER collateral from `taker`, funding them first. `fillCollateral`
    ///      is an upper bound on the taker's own posted collateral (equal at 1:1, less under odds), so
    ///      funding `fillCollateral` always suffices.
    function _fill(address taker, uint256 offerId, uint128 fillCollateral) internal returns (uint256 positionId) {
        _fund(taker, fillCollateral);
        vm.prank(taker);
        positionId = market.fillOffer(offerId, fillCollateral);
    }

    /// @dev Pull `who`'s credited settlement/unwind payout (pull-payment) if any, so the existing
    ///      balance-based assertions can observe the funds. A no-op when nothing is credited.
    function _drain(address who) internal {
        if (market.withdrawable(who) > 0) {
            vm.prank(who);
            market.withdraw();
        }
    }
}
