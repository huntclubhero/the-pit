// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Types} from "../interfaces/Types.sol";
import {IOracleRouter} from "../interfaces/IOracleRouter.sol";
import {IPitPoints} from "../interfaces/IPitPoints.sol";
import {Market} from "./Market.sol";

/// @notice Minimal registrar surface of the points engine. Not part of the frozen
///         hook interface: registration is deployment wiring, not a trading hook.
interface IPitPointsRegistrar {
    function registerMarket(address market) external;
}

/// @notice Minimal cost-to-move cap surface of the oracle router. Kept off the frozen
///         IOracleRouter interface (whose one additive function is the opening breaker); the
///         factory reads it by casting its router address, and the OracleRouter (and the core-test
///         MockOracleRouter) implement it. Returns type(uint256).max for an unbounded (Tier A)
///         market, so a router without the tier feature leaves the cap governed by oiCapBps alone.
interface IMarketPayoutCap {
    function maxMarketPayoutCap1e18(address token) external view returns (uint256);
}

/// @notice Minimal fallback-ring seeding surface of the oracle router. Kept off the frozen
///         IOracleRouter interface; the factory casts its router address and calls it best-effort so
///         a freshly listed market starts with a populated agreed-print fallback (wave-2 W2-10). A
///         router (or the core-test MockOracleRouter) that does not implement it makes the call
///         revert, which createMarket swallows. fallbackSeeded (wave-2b R-7) reports whether the
///         token's fallback path is guaranteed (ring full, or the token can never need it); a
///         router without the surface is treated as always seeded.
interface IRouterFallbackPrimer {
    function primeFallback(address token) external returns (uint8 ringCount);
    function fallbackSeeded(address token) external view returns (bool seeded);
}

/// @title MarketFactory: deploys and registers one Market per underlying token
/// @notice Anyone can create a market for a token that passes the oracle router's
///         listing rules. The factory snapshots tracked liquidity at creation and bakes
///         all protocol parameters into the new Market as immutables. The owner (a
///         timelocked multisig in production, via Ownable2Step) can update the
///         parameters used by FUTURE markets only; existing markets are immutable.
contract MarketFactory is Ownable2Step {
    // ======================================================================
    // Storage
    // ======================================================================

    /// @notice Default settlement fee (basis points of the loser's notional) for a fresh protocol
    ///         deployment. Deploy scripts use it as the SETTLEMENT_FEE_BPS env default. At or below
    ///         MAX_SETTLEMENT_FEE_BPS.
    uint16 public constant DEFAULT_SETTLEMENT_FEE_BPS = 50;

    /// @notice Hard ceiling on the settlement fee the factory will accept, in basis points of the
    ///         loser's notional (1%). MUST mirror Market.MAX_FEE_BPS: Solidity cannot reference a
    ///         contract constant by type name, so it is restated here for the factory's early revert.
    ///         The Market constructor independently enforces Market.MAX_FEE_BPS as the authoritative
    ///         boundary, so this local mirror can never widen the real cap: if the two ever drifted,
    ///         a too-high value would simply revert in createMarket rather than reach a live market.
    uint16 public constant MAX_SETTLEMENT_FEE_BPS = 100;

    /// @notice Hard ceiling on the anti-monopolization open bond the factory will bake, in basis
    ///         points of a fill's open interest (5%). MUST mirror Market.MAX_OPEN_BOND_BPS: the
    ///         Market constructor independently enforces it as the authoritative boundary, so this
    ///         local mirror can never widen the real cap.
    uint16 public constant MAX_OPEN_BOND_BPS = 500;

    /// @notice USDG collateral token used by every market; fixed for the protocol.
    address public immutable usdg;

    /// @notice Oracle router wired into future markets.
    IOracleRouter public router;
    /// @notice Points engine wired into future markets.
    IPitPoints public points;
    /// @notice Fee split wired into future markets.
    Types.FeeSplit public feeSplit;
    /// @notice Settlement fee (basis points of the loser's notional) baked into future markets.
    ///         Owner-tunable at or below Market.MAX_FEE_BPS; existing markets keep their immutable
    ///         creation-time rate.
    uint16 public settlementFeeBps;
    /// @notice Open interest cap (basis points of tracked liquidity) for future markets.
    uint16 public oiCapBps;
    /// @notice Per-address open-interest sub-cap for future markets, in basis points of the
    ///         market OI cap. Bounds the escrow a single participant (as maker or as taker) can
    ///         hold open, so a pair of colluding addresses cannot monopolize the whole OI cap.
    uint16 public perAddressOiCapBps;
    /// @notice Anti-monopolization open bond (basis points of a fill's open interest) baked into
    ///         future markets (wave-2 W2-9). Zero at deployment (disabled); governance arms it via
    ///         setOpenBondBps for thin/new markets where OI-cap monopolization is cheapest. Existing
    ///         markets keep their immutable creation-time rate.
    uint16 public openBondBps;
    /// @notice PauseGuardian wired into future markets.
    address public guardian;

    /// @notice Registry: underlying token to its market (address(0) = none).
    mapping(address token => address market) public marketFor;
    /// @notice All markets ever created, in creation order.
    address[] public allMarkets;

    // ======================================================================
    // Errors and events
    // ======================================================================

    /// @notice A zero address was supplied for a required parameter.
    error ZeroAddress();
    /// @notice Markets cannot be created on USDG itself.
    error TokenIsUsdg();
    /// @notice A market already exists for this token.
    error MarketAlreadyExists(address market);
    /// @notice The oracle router rejects this token under its listing rules.
    error TokenNotListable();
    /// @notice The OI cap must be in (0, 10_000] basis points.
    error InvalidOiCap();
    /// @notice The per-address OI sub-cap must be in (0, 10_000] basis points of the OI cap.
    error InvalidPerAddressOiCap();
    /// @notice The settlement fee must be at or below MAX_SETTLEMENT_FEE_BPS (Market.MAX_FEE_BPS).
    error InvalidSettlementFeeBps();
    /// @notice The open bond must be at or below MAX_OPEN_BOND_BPS (Market.MAX_OPEN_BOND_BPS).
    error InvalidOpenBondBps();
    /// @notice The oracle router's agreed-print fallback ring for this token is not fully seeded,
    ///         so a market created now would carry the permanent-COOLDOWN forced-unwind free option
    ///         (wave-2 W2-10 / wave-2b R-7). Seed via checkPrice or primeFallback across distinct
    ///         blocks while sources agree, then retry.
    error FallbackRingNotSeeded();
    /// @notice Renouncing ownership is disabled: it would freeze future-market parameters.
    error RenounceDisabled();

    /// @notice A new market was deployed and registered.
    event MarketCreated(
        address indexed token, address indexed market, address indexed creator, uint256 liquiditySnapshot1e18
    );
    /// @notice The router for future markets was updated.
    event RouterUpdated(address indexed router);
    /// @notice The points engine for future markets was updated.
    event PointsUpdated(address indexed points);
    /// @notice The fee split for future markets was updated.
    event FeeSplitUpdated(address jackpot, address treasury, address referralPool, address buyback);
    /// @notice The settlement fee for future markets was updated.
    event SettlementFeeBpsUpdated(uint16 settlementFeeBps);
    /// @notice The OI cap for future markets was updated.
    event OiCapUpdated(uint16 oiCapBps);
    /// @notice The per-address OI sub-cap for future markets was updated.
    event PerAddressOiCapUpdated(uint16 perAddressOiCapBps);
    /// @notice The anti-monopolization open bond for future markets was updated.
    event OpenBondBpsUpdated(uint16 openBondBps);
    /// @notice The guardian for future markets was updated.
    event GuardianUpdated(address indexed guardian);
    /// @notice The points onMarketCreated hook reverted; creation proceeded regardless.
    event PointsHookFailed(bytes reason);
    /// @notice The oracle fallback-ring pre-seed reverted; creation proceeded regardless.
    event FallbackPrimeFailed(bytes reason);

    // ======================================================================
    // Constructor
    // ======================================================================

    /// @param usdg_ USDG collateral token (fixed forever).
    /// @param router_ Initial oracle router.
    /// @param points_ Initial points engine.
    /// @param feeSplit_ Initial fee split (jackpot 25%, referral 10%, buyback 39%, treasury 26%).
    /// @param oiCapBps_ Initial OI cap in basis points (1_000 = 10%).
    /// @param perAddressOiCapBps_ Initial per-address OI sub-cap in basis points of the OI cap
    ///        (2_500 = 25%, so any two colluding addresses cap at 50% of the market OI cap).
    /// @param settlementFeeBps_ Initial settlement fee in basis points of the loser's notional
    ///        (DEFAULT_SETTLEMENT_FEE_BPS at launch), validated at or below Market.MAX_FEE_BPS.
    /// @param guardian_ Initial PauseGuardian.
    /// @param owner_ Factory owner (timelocked multisig in production).
    constructor(
        address usdg_,
        address router_,
        address points_,
        Types.FeeSplit memory feeSplit_,
        uint16 oiCapBps_,
        uint16 perAddressOiCapBps_,
        uint16 settlementFeeBps_,
        address guardian_,
        address owner_
    ) Ownable(owner_) {
        if (usdg_ == address(0)) revert ZeroAddress();
        usdg = usdg_;
        _setRouter(router_);
        _setPoints(points_);
        _setFeeSplit(feeSplit_);
        _setOiCapBps(oiCapBps_);
        _setPerAddressOiCapBps(perAddressOiCapBps_);
        _setSettlementFeeBps(settlementFeeBps_);
        _setGuardian(guardian_);
    }

    /// @notice Renouncing ownership is disabled: it would permanently freeze the parameters used
    ///         by every future market with no recovery path. Ownership can still be transferred to
    ///         a new multisig (two-step Ownable2Step).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ======================================================================
    // Market creation
    // ======================================================================

    /// @notice Deploy the Market for `token`, snapshotting tracked liquidity first.
    /// @dev Permissionless: the oracle router's isListable gate (tier, source count, aggregate-depth
    ///      floor, seasoning, cardinality) is the listing policy. The points onMarketCreated hook is
    ///      best-effort and can never block creation.
    ///
    ///      COST-TO-MOVE CAP DERIVATION (safe memecoin settlement, increment 1). Right after taking
    ///      the immutable liquidity snapshot, the factory reads the router's absolute payout cap
    ///      (maxMarketPayoutCap = costToMove / safetyFactor) and bakes it into the Market as an
    ///      immutable. The Market's effective OI cap is min(oiCapBps-of-snapshot cap, this absolute
    ///      cap), so a single position's maximum payout can never exceed costToMove / safetyFactor.
    ///      The read happens in the SAME transaction as the snapshot with no intervening external
    ///      interaction, so it reflects the identical creation-time liquidity and is then frozen:
    ///      the fill path never re-reads live liquidity (the audit-wave-1 B1 snapshot basis is
    ///      preserved). For Tier A majors the router returns type(uint256).max (unbounded), leaving
    ///      the cap governed solely by oiCapBps.
    /// @param token Underlying ERC-20 to create a market for.
    /// @return market Address of the newly deployed Market.
    function createMarket(address token) external returns (address market) {
        if (token == address(0)) revert ZeroAddress();
        if (token == usdg) revert TokenIsUsdg();
        address existing = marketFor[token];
        if (existing != address(0)) revert MarketAlreadyExists(existing);
        if (!router.isListable(token)) revert TokenNotListable();

        uint256 snapshot1e18 = router.snapshotLiquidity(token);
        uint256 maxPayoutCap1e18 = IMarketPayoutCap(address(router)).maxMarketPayoutCap1e18(token);

        market = address(
            new Market(
                token,
                usdg,
                address(router),
                address(points),
                feeSplit,
                oiCapBps,
                perAddressOiCapBps,
                guardian,
                snapshot1e18,
                maxPayoutCap1e18,
                settlementFeeBps,
                openBondBps
            )
        );

        marketFor[token] = market;
        allMarkets.push(market);

        emit MarketCreated(token, market, msg.sender, snapshot1e18);

        // Best-effort points wiring: register the new market so its hooks are accepted
        // (requires this factory to be set as the points registrar), then report the
        // creator. Neither call can ever block market creation.
        try IPitPointsRegistrar(address(points)).registerMarket(market) {}
        catch (bytes memory reason) {
            emit PointsHookFailed(reason);
        }
        try points.onMarketCreated(msg.sender, token) {}
        catch (bytes memory reason) {
            emit PointsHookFailed(reason);
        }

        // Best-effort: advance the oracle's agreed-print fallback ring (at most one print per
        // block since wave-2b R-7) so this transaction can complete a nearly seeded ring. A router
        // without the primer, or one whose sources do not currently agree, leaves the ring as-is.
        try IRouterFallbackPrimer(address(router)).primeFallback(token) {}
        catch (bytes memory reason) {
            emit FallbackPrimeFailed(reason);
        }

        // Hard gate (wave-2 W2-10, wave-2b R-7): a multi-source token whose ring is not FULL must
        // not get a market. An empty or partial ring means a sustained from-birth source deviation
        // has no fallback and sticks the market in permanent COOLDOWN until the expiry + 24h
        // NEUTRAL forced unwind: a free option for whichever party is losing (and re-listing F1:
        // exactly what a market listed during a deviation would ship with). primeFallback now
        // advances one print per block, so creators seed across AGREED_PRINTS distinct blocks
        // (permissionless, gas-only) before createMarket; single-source (aggregating-tier) tokens
        // can never enter COOLDOWN and pass vacuously. A router without the surface (core-test
        // mocks) is treated as seeded.
        try IRouterFallbackPrimer(address(router)).fallbackSeeded(token) returns (bool seeded) {
            if (!seeded) revert FallbackRingNotSeeded();
        } catch (bytes memory) {}
    }

    /// @notice Number of markets ever created.
    function allMarketsLength() external view returns (uint256) {
        return allMarkets.length;
    }

    // ======================================================================
    // Owner parameter updates (future markets only)
    // ======================================================================

    /// @notice Set the oracle router used by future markets.
    function setRouter(address router_) external onlyOwner {
        _setRouter(router_);
    }

    /// @notice Set the points engine used by future markets.
    function setPoints(address points_) external onlyOwner {
        _setPoints(points_);
    }

    /// @notice Set the fee split used by future markets.
    function setFeeSplit(Types.FeeSplit calldata feeSplit_) external onlyOwner {
        _setFeeSplit(feeSplit_);
    }

    /// @notice Set the settlement fee (basis points of the loser's notional) for future markets.
    /// @dev Bounded by MAX_SETTLEMENT_FEE_BPS (Market.MAX_FEE_BPS) so the owner can never bake an
    ///      exorbitant fee into a market. Existing markets keep their immutable creation-time rate.
    function setSettlementFeeBps(uint16 settlementFeeBps_) external onlyOwner {
        _setSettlementFeeBps(settlementFeeBps_);
    }

    /// @notice Set the OI cap used by future markets.
    function setOiCapBps(uint16 oiCapBps_) external onlyOwner {
        _setOiCapBps(oiCapBps_);
    }

    /// @notice Set the per-address OI sub-cap (basis points of the OI cap) for future markets.
    function setPerAddressOiCapBps(uint16 perAddressOiCapBps_) external onlyOwner {
        _setPerAddressOiCapBps(perAddressOiCapBps_);
    }

    /// @notice Set the anti-monopolization open bond (basis points of a fill's OI) for future
    ///         markets (wave-2 W2-9). Bounded by MAX_OPEN_BOND_BPS (Market.MAX_OPEN_BOND_BPS) so the
    ///         owner can never bake a punitive open cost; existing markets keep their immutable rate.
    function setOpenBondBps(uint16 openBondBps_) external onlyOwner {
        if (openBondBps_ > MAX_OPEN_BOND_BPS) revert InvalidOpenBondBps();
        openBondBps = openBondBps_;
        emit OpenBondBpsUpdated(openBondBps_);
    }

    /// @notice Set the PauseGuardian used by future markets.
    function setGuardian(address guardian_) external onlyOwner {
        _setGuardian(guardian_);
    }

    function _setRouter(address router_) private {
        if (router_ == address(0)) revert ZeroAddress();
        router = IOracleRouter(router_);
        emit RouterUpdated(router_);
    }

    function _setPoints(address points_) private {
        if (points_ == address(0)) revert ZeroAddress();
        points = IPitPoints(points_);
        emit PointsUpdated(points_);
    }

    function _setFeeSplit(Types.FeeSplit memory feeSplit_) private {
        if (
            feeSplit_.jackpot == address(0) || feeSplit_.treasury == address(0)
                || feeSplit_.referralPool == address(0) || feeSplit_.buyback == address(0)
        ) {
            revert ZeroAddress();
        }
        feeSplit = feeSplit_;
        emit FeeSplitUpdated(feeSplit_.jackpot, feeSplit_.treasury, feeSplit_.referralPool, feeSplit_.buyback);
    }

    function _setSettlementFeeBps(uint16 settlementFeeBps_) private {
        if (settlementFeeBps_ > MAX_SETTLEMENT_FEE_BPS) revert InvalidSettlementFeeBps();
        settlementFeeBps = settlementFeeBps_;
        emit SettlementFeeBpsUpdated(settlementFeeBps_);
    }

    function _setOiCapBps(uint16 oiCapBps_) private {
        if (oiCapBps_ == 0 || oiCapBps_ > 10_000) revert InvalidOiCap();
        oiCapBps = oiCapBps_;
        emit OiCapUpdated(oiCapBps_);
    }

    function _setPerAddressOiCapBps(uint16 perAddressOiCapBps_) private {
        if (perAddressOiCapBps_ == 0 || perAddressOiCapBps_ > 10_000) revert InvalidPerAddressOiCap();
        perAddressOiCapBps = perAddressOiCapBps_;
        emit PerAddressOiCapUpdated(perAddressOiCapBps_);
    }

    function _setGuardian(address guardian_) private {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        emit GuardianUpdated(guardian_);
    }
}
