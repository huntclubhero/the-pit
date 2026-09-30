/**
 * Perp math for THE PIT v2: leveraged perps against the PitVault.
 *
 * Every function mirrors the on-chain math in MarginMathLib.sol, FundingLib.sol
 * and PerpEngine.sol EXACTLY, including floor division and the ceil on the
 * initial-margin requirement, so what the ticket previews is what the engine
 * does to the wei.
 *
 * Scales:
 *   USDG collateral: native 6 decimals (bigint)
 *   Prices:          1e18, USDG per token (identical to IOracleRouter.checkPrice)
 *   Sizes:           base-token units at 1e18 (synthetic; no base token is held)
 *   Rates/indices:   1e18 fixed point
 */

// ---------------------------------------------------------------------------
// Protocol constants (mirrors PerpEngine / PerpRiskConfig / PitVault)
// ---------------------------------------------------------------------------

export const PRICE_SCALE = 10n ** 18n;
/** 10 ** (18 minus USDG decimals): the router's usdgScale for a 6-decimal USDG. */
export const USDG_SCALE = 10n ** 12n;
export const BPS = 10_000n;
/** Leverage fixed point: leverageX100 of 450 means 4.5x. */
export const LEVERAGE_DENOM = 100n;
/** Engine dust floor: leverage below 1.1x reverts. */
export const MIN_LEVERAGE_X100 = 110;
/** Engine minimum margin at launch: 10 USDG. */
export const MIN_MARGIN = 10_000_000n;
/** Launch payout cap: max payout = 9 x margin (PerpRiskConfig.payoutCapMultiple). */
export const PAYOUT_CAP_MULTIPLE = 9n;
/** Liquidation penalty: 100 bps of notional, never more than remaining equity. */
export const LIQ_PENALTY_BPS = 100n;
/** Keeper share of the liquidation penalty (20%), with a 5 USDG floor (IF top-up). */
export const KEEPER_SHARE_BPS = 2_000n;
/** Vault share of the liquidation penalty (40%); the insurance fund takes the rest. */
export const LIQ_VAULT_SHARE_BPS = 4_000n;
export const KEEPER_FLOOR = 5_000_000n;
/** Vault deposit/withdraw fee: 10 bps, credited to vault NAV. */
export const VAULT_FEE_BPS = 10n;
/** Vault withdraw-queue epoch: 24h; per-epoch withdrawal cap 25% of TVL. */
export const VAULT_EPOCH_SECONDS = 86_400;
export const VAULT_WITHDRAW_EPOCH_CAP_BPS = 2_500n;
export const VAULT_DEPOSIT_EPOCH_CAP_BPS = 2_000n;
/** Withdrawals never push totalAssets below 1.2x totalReserved. */
export const VAULT_SOLVENCY_FLOOR_BPS = 12_000n;
/** Global utilization cap: reserved payouts <= 80% of TVL; opens revert beyond. */
export const MAX_UTILIZATION_BPS = 8_000n;
/** Per-market reserve cap: 10% of TVL (and the oracle cost-to-move bound). */
export const MARKET_RESERVE_CAP_BPS = 1_000n;

/** Funding rate per hour at 100% skew (1e18): pool-priced memecoins. */
export const KF_POOL_PER_HOUR_1E18 = 2_500_000_000_000_000n; // 0.25%/h
/** Funding rate per hour at 100% skew (1e18): majors override. */
export const KF_MAJOR_PER_HOUR_1E18 = 500_000_000_000_000n; // 0.05%/h
/**
 * BASE borrow rate per hour at 100% utilization (1e18), both sides pay the
 * vault. The engine scales this up with realized volatility (RE-ECON-1), so
 * hot markets cost more to hold; this constant is the calm-market floor.
 */
export const KB_PER_HOUR_1E18 = 100_000_000_000_000n; // 0.01%/h

// ---------------------------------------------------------------------------
// Mcap tiers: the LOCKED leverage schedule (PerpRiskConfig constants)
// ---------------------------------------------------------------------------

export interface TierParams {
  maxLeverageX100: number;
  mmrBps: number;
  openFeeBps: number;
  closeFeeBps: number;
  kFPerHour1e18: bigint;
  kBPerHour1e18: bigint;
  liqPenaltyBps: number;
  /** Per-position margin cap, USDG units. */
  maxPositionMargin: bigint;
}

export interface McapTierMeta {
  index: number;
  /** Human FDV band, e.g. "$2M to $5M". */
  band: string;
  /** Lower FDV edge in USD (0 for tier 0). */
  floorUsd: number;
  maxLeverageX100: number;
  mmrBps: number;
  maxPositionMargin: bigint;
}

/** The six LOCKED tiers: 4x / 6x / 6x / 8x / 10x / 15x by FDV band. */
export const MCAP_TIERS: McapTierMeta[] = [
  { index: 0, band: "under $500K", floorUsd: 0, maxLeverageX100: 400, mmrBps: 1_500, maxPositionMargin: 5_000_000_000n },
  { index: 1, band: "$500K to $2M", floorUsd: 500_000, maxLeverageX100: 600, mmrBps: 1_000, maxPositionMargin: 10_000_000_000n },
  { index: 2, band: "$2M to $5M", floorUsd: 2_000_000, maxLeverageX100: 600, mmrBps: 1_000, maxPositionMargin: 10_000_000_000n },
  { index: 3, band: "$5M to $10M", floorUsd: 5_000_000, maxLeverageX100: 800, mmrBps: 800, maxPositionMargin: 25_000_000_000n },
  { index: 4, band: "$10M to $50M", floorUsd: 10_000_000, maxLeverageX100: 1_000, mmrBps: 600, maxPositionMargin: 50_000_000_000n },
  { index: 5, band: "over $50M", floorUsd: 50_000_000, maxLeverageX100: 1_500, mmrBps: 400, maxPositionMargin: 50_000_000_000n },
];

/** Raw FDV (USD float) to tier index, the PerpRiskConfig band mapping. */
export function tierForFdv(fdvUsd: number): number {
  for (let i = MCAP_TIERS.length - 1; i >= 1; i--) {
    if (fdvUsd >= MCAP_TIERS[i].floorUsd) return i;
  }
  return 0;
}

/**
 * Effective tier params for a market. Majors carry the PerpRiskConfig token
 * override (tighter MMR, 5 bps fees, calmer funding, 250k position cap); the
 * override can never raise leverage above the LOCKED schedule of the tier.
 */
export function tierParams(tierIndex: number, isMajor: boolean): TierParams {
  const tier = MCAP_TIERS[Math.min(Math.max(tierIndex, 0), 5)];
  if (isMajor) {
    return {
      maxLeverageX100: tier.maxLeverageX100,
      mmrBps: Math.round(BPS_NUM / (2 * (tier.maxLeverageX100 / 100))), // 1/(2L) rule
      openFeeBps: 5,
      closeFeeBps: 5,
      kFPerHour1e18: KF_MAJOR_PER_HOUR_1E18,
      kBPerHour1e18: KB_PER_HOUR_1E18,
      liqPenaltyBps: Number(LIQ_PENALTY_BPS),
      maxPositionMargin: 250_000_000_000n,
    };
  }
  return {
    maxLeverageX100: tier.maxLeverageX100,
    mmrBps: tier.mmrBps,
    openFeeBps: 10,
    closeFeeBps: 10,
    kFPerHour1e18: KF_POOL_PER_HOUR_1E18,
    kBPerHour1e18: KB_PER_HOUR_1E18,
    liqPenaltyBps: Number(LIQ_PENALTY_BPS),
    maxPositionMargin: tier.maxPositionMargin,
  };
}

const BPS_NUM = 10_000;

/** "4x" / "15x" label from leverageX100. */
export function formatLeverageX100(leverageX100: number): string {
  const x = leverageX100 / 100;
  return Number.isInteger(x) ? `${x}x` : `${x.toFixed(1)}x`;
}

// ---------------------------------------------------------------------------
// MarginMathLib mirrors (pure, floor division except where noted)
// ---------------------------------------------------------------------------

/** Notional value of size1e18 at price1e18, USDG units (floor). */
export function notionalUsdg(size1e18: bigint, price1e18: bigint): bigint {
  return (size1e18 * price1e18) / (PRICE_SCALE * USDG_SCALE);
}

/** Size (1e18 base units) whose notional at price equals `notional` USDG (floor). */
export function sizeForNotional(notional: bigint, price1e18: bigint): bigint {
  if (price1e18 === 0n) return 0n;
  return (notional * USDG_SCALE * PRICE_SCALE) / price1e18;
}

/** Unrealized PnL in USDG units, signed. Long profits when mark > entry. */
export function uPnlUsdg(
  size1e18: bigint,
  entry1e18: bigint,
  mark1e18: bigint,
  isLong: boolean,
): bigint {
  const diff = mark1e18 >= entry1e18 ? mark1e18 - entry1e18 : entry1e18 - mark1e18;
  const magnitude = (size1e18 * diff) / (PRICE_SCALE * USDG_SCALE);
  if (magnitude === 0n) return 0n;
  const markAbove = mark1e18 > entry1e18;
  return isLong === markAbove ? magnitude : -magnitude;
}

/** The payout clamp: profit capped at maxPayout, loss capped at margin. */
export function clampPnl(pnl: bigint, margin: bigint, maxPayout: bigint): bigint {
  if (pnl > 0n && pnl > maxPayout) return maxPayout;
  if (pnl < 0n && -pnl > margin) return -margin;
  return pnl;
}

/** Equity: margin + clamped uPnL minus pending funding minus pending borrow. */
export function equityUsdg(
  margin: bigint,
  clampedPnl: bigint,
  fundingOwed: bigint,
  borrowOwed: bigint,
): bigint {
  return margin + clampedPnl - fundingOwed - borrowOwed;
}

/** Maintenance margin requirement: mmrBps of current notional (floor). */
export function maintenanceMarginUsdg(size1e18: bigint, mark1e18: bigint, mmrBps: number): bigint {
  return (notionalUsdg(size1e18, mark1e18) * BigInt(mmrBps)) / BPS;
}

/** Initial margin requirement: notional / maxLeverage, rounded UP (anti-JELLY floor). */
export function initialMarginUsdg(
  size1e18: bigint,
  mark1e18: bigint,
  maxLeverageX100: number,
): bigint {
  const notional = notionalUsdg(size1e18, mark1e18);
  const lev = BigInt(maxLeverageX100);
  return (notional * LEVERAGE_DENOM + lev - 1n) / lev;
}

/**
 * Exact liquidation price (MarginMathLib.liquidationPrice1e18).
 *   LONG:  P_liq = (S*P0 + (F minus m) * 1e18) / (S * (1e18 minus r) / 1e18)
 *   SHORT: P_liq = (S*P0 + (m minus F) * 1e18) / (S * (1e18 + r) / 1e18)
 * where m and F are 1e18-scaled via USDG_SCALE and r = mmrBps as a 1e18 fraction.
 * Returns 0n when no adverse price move can liquidate the position.
 */
export function liquidationPrice1e18(
  size1e18: bigint,
  entry1e18: bigint,
  margin: bigint,
  netOwedUsdg: bigint,
  mmrBps: number,
  isLong: boolean,
): bigint {
  if (size1e18 === 0n) return 0n;
  const r1e18 = BigInt(mmrBps) * (PRICE_SCALE / BPS);
  const sizeEntry = size1e18 * entry1e18; // 1e36 scale
  const owed1e18 = netOwedUsdg * USDG_SCALE;
  const margin1e18 = margin * USDG_SCALE;
  if (isLong) {
    const numerator = sizeEntry + (owed1e18 - margin1e18) * PRICE_SCALE;
    if (numerator <= 0n) return 0n;
    const denominator = (size1e18 * (PRICE_SCALE - r1e18)) / PRICE_SCALE;
    return numerator / denominator;
  }
  const numerator = sizeEntry + (margin1e18 - owed1e18) * PRICE_SCALE;
  if (numerator <= 0n) return 0n;
  const denominator = (size1e18 * (PRICE_SCALE + r1e18)) / PRICE_SCALE;
  return numerator / denominator;
}

/** Volume-weighted entry after adding addSize at addPrice (floor). */
export function weightedEntry1e18(
  size1e18: bigint,
  entry1e18: bigint,
  addSize1e18: bigint,
  addPrice1e18: bigint,
): bigint {
  const total = size1e18 + addSize1e18;
  if (total === 0n) return 0n;
  return (size1e18 * entry1e18 + addSize1e18 * addPrice1e18) / total;
}

// ---------------------------------------------------------------------------
// FundingLib mirrors
// ---------------------------------------------------------------------------

/** OI skew in [-1e18, +1e18]: (long minus short) / max(long + short, floor). */
export function skew1e18(oiLongUsdg: bigint, oiShortUsdg: bigint, skewFloorUsdg: bigint): bigint {
  const total = oiLongUsdg + oiShortUsdg;
  const denominator = total > skewFloorUsdg ? total : skewFloorUsdg;
  if (denominator === 0n) return 0n;
  return ((oiLongUsdg - oiShortUsdg) * PRICE_SCALE) / denominator;
}

/** Signed funding rate per hour, 1e18: kF * skew. Positive = longs pay. */
export function fundingRatePerHour1e18(skew: bigint, kFPerHour1e18: bigint): bigint {
  return (skew * kFPerHour1e18) / PRICE_SCALE;
}

/** Funding index increment for an interval: rate * mark * dt / 1 hour, 1e18 scale. */
export function fundingIndexDelta1e18(
  ratePerHour1e18: bigint,
  mark1e18: bigint,
  dtSeconds: number,
): bigint {
  if (ratePerHour1e18 === 0n || mark1e18 === 0n || dtSeconds === 0) return 0n;
  const negative = ratePerHour1e18 < 0n;
  const magnitude = negative ? -ratePerHour1e18 : ratePerHour1e18;
  const delta = (magnitude * BigInt(dtSeconds) * mark1e18) / (PRICE_SCALE * 3_600n);
  return negative ? -delta : delta;
}

/**
 * Base borrow rate per hour, 1e18: kB * reserved / vaultAssets, utilization
 * capped at 100%. On-chain the engine multiplies this by the realized-vol
 * multiplier (vol-scaled borrow), so live rates sit at or above this base.
 */
export function borrowRatePerHour1e18(
  reservedUsdg: bigint,
  vaultAssetsUsdg: bigint,
  kBPerHour1e18: bigint,
): bigint {
  if (reservedUsdg === 0n || vaultAssetsUsdg === 0n || kBPerHour1e18 === 0n) return 0n;
  let utilization = (reservedUsdg * PRICE_SCALE) / vaultAssetsUsdg;
  if (utilization > PRICE_SCALE) utilization = PRICE_SCALE;
  return (kBPerHour1e18 * utilization) / PRICE_SCALE;
}

/**
 * Pending funding owed over an index delta, USDG units, signed. POSITIVE means
 * the trader owes. Longs owe when the index rose; shorts owe when it fell.
 */
export function fundingOwedUsdg(size1e18: bigint, indexDelta1e18: bigint, isLong: boolean): bigint {
  if (indexDelta1e18 === 0n || size1e18 === 0n) return 0n;
  const deltaNegative = indexDelta1e18 < 0n;
  const magnitude = deltaNegative ? -indexDelta1e18 : indexDelta1e18;
  const owed = (size1e18 * magnitude) / (PRICE_SCALE * USDG_SCALE);
  if (owed === 0n) return 0n;
  const traderOwes = isLong ? !deltaNegative : deltaNegative;
  return traderOwes ? owed : -owed;
}

/** Pending borrow owed over an index delta, USDG units, always owed. */
export function borrowOwedUsdg(size1e18: bigint, indexDelta1e18: bigint): bigint {
  if (indexDelta1e18 === 0n || size1e18 === 0n) return 0n;
  return (size1e18 * indexDelta1e18) / (PRICE_SCALE * USDG_SCALE);
}

// ---------------------------------------------------------------------------
// Open / close previews (PerpEngine._openCore / _computeClose mirrors)
// ---------------------------------------------------------------------------

export interface OpenPreview {
  /** Fee charged on the gross notional at open, USDG (floor, like the engine). */
  openFee: bigint;
  /** Margin escrowed after the open fee. */
  marginNet: bigint;
  /** Position notional from the net margin. */
  notional: bigint;
  /** Position size, base units 1e18 (floor). */
  size1e18: bigint;
  /** Payout cap: PAYOUT_CAP_MULTIPLE x marginNet, reserved in the vault. */
  maxPayout: bigint;
  /** Exact liquidation price at open (zero accrued funding). 0n = cannot liq. */
  liqPrice1e18: bigint;
  /** Signed price move to liquidation as a fraction of mark (float, for display). */
  moveToLiqPct: number;
  /** Estimated close fee at the same notional. */
  closeFeeEst: bigint;
  /** Estimated funding per hour at the current market rate, signed USDG. Positive = you pay. */
  estFundingPerHourUsdg: bigint;
  /** Estimated borrow fee per hour, USDG, always paid. */
  estBorrowPerHourUsdg: bigint;
  /** True when the open would revert (dust margin, fee swallows margin, cap). */
  blockedReason?: "min-margin" | "fee-exceeds-margin" | "margin-cap" | "leverage";
}

/** Mirrors PerpEngine.openPosition math exactly. */
export function previewOpen(
  marginGross: bigint,
  leverageX100: number,
  mark1e18: bigint,
  params: TierParams,
  side: "long" | "short",
  marketFundingRatePerHour1e18: bigint,
  marketBorrowRatePerHour1e18: bigint,
  payoutCapMultiple: bigint = PAYOUT_CAP_MULTIPLE,
): OpenPreview {
  const empty: OpenPreview = {
    openFee: 0n,
    marginNet: 0n,
    notional: 0n,
    size1e18: 0n,
    maxPayout: 0n,
    liqPrice1e18: 0n,
    moveToLiqPct: 0,
    closeFeeEst: 0n,
    estFundingPerHourUsdg: 0n,
    estBorrowPerHourUsdg: 0n,
  };
  if (leverageX100 < MIN_LEVERAGE_X100 || leverageX100 > params.maxLeverageX100) {
    return { ...empty, blockedReason: "leverage" };
  }
  if (marginGross < MIN_MARGIN) return { ...empty, blockedReason: "min-margin" };
  const lev = BigInt(leverageX100);
  // Engine: openFee = mulDiv(margin * leverageX100 / LEVERAGE_DENOM, openFeeBps, BPS).
  const grossNotional = (marginGross * lev) / LEVERAGE_DENOM;
  const openFee = (grossNotional * BigInt(params.openFeeBps)) / BPS;
  if (openFee >= marginGross) return { ...empty, blockedReason: "fee-exceeds-margin" };
  const marginNet = marginGross - openFee;
  if (marginNet > params.maxPositionMargin) {
    return { ...empty, openFee, marginNet, blockedReason: "margin-cap" };
  }
  const notional = (marginNet * lev) / LEVERAGE_DENOM;
  const size1e18 = sizeForNotional(notional, mark1e18);
  const maxPayout = payoutCapMultiple * marginNet;
  const isLong = side === "long";
  const liqPrice = liquidationPrice1e18(size1e18, mark1e18, marginNet, 0n, params.mmrBps, isLong);
  const moveToLiqPct =
    liqPrice === 0n || mark1e18 === 0n
      ? 0
      : (Number(liqPrice - mark1e18) / Number(mark1e18)) * 100;
  const closeFeeEst = (notionalUsdg(size1e18, mark1e18) * BigInt(params.closeFeeBps)) / BPS;
  // Funding: you pay when your side matches the skew sign (rate > 0 = longs pay).
  const rate = marketFundingRatePerHour1e18;
  const hourlyIndexDelta = fundingIndexDelta1e18(rate, mark1e18, 3_600);
  const estFundingPerHourUsdg = fundingOwedUsdg(size1e18, hourlyIndexDelta, isLong);
  const borrowDelta = borrowIndexDeltaPerHour(marketBorrowRatePerHour1e18, mark1e18);
  const estBorrowPerHourUsdg = borrowOwedUsdg(size1e18, borrowDelta);
  return {
    openFee,
    marginNet,
    notional,
    size1e18,
    maxPayout,
    liqPrice1e18: liqPrice,
    moveToLiqPct,
    closeFeeEst,
    estFundingPerHourUsdg,
    estBorrowPerHourUsdg,
  };
}

function borrowIndexDeltaPerHour(ratePerHour1e18: bigint, mark1e18: bigint): bigint {
  if (ratePerHour1e18 === 0n || mark1e18 === 0n) return 0n;
  return (ratePerHour1e18 * mark1e18) / PRICE_SCALE;
}

export interface ClosePreview {
  /** Clamped realized PnL, signed USDG. */
  pnl: bigint;
  /** Pending funding owed, signed (positive = you owe). */
  fundingOwed: bigint;
  /** Pending borrow owed, always >= 0. */
  borrowOwed: bigint;
  /** Trader pot before the close fee: margin + pnl minus owed, floored at 0. */
  pot: bigint;
  /** Close fee on the closed notional, capped at the pot. */
  closeFee: bigint;
  /** What lands in the trader's wallet. */
  traderNet: bigint;
}

/** Mirrors PerpEngine._computeClose: clamp, owed, pot, fee cap, net. */
export function previewClose(
  size1e18: bigint,
  entry1e18: bigint,
  mark1e18: bigint,
  margin: bigint,
  maxPayout: bigint,
  isLong: boolean,
  fundingOwed: bigint,
  borrowOwed: bigint,
  closeFeeBps: number,
): ClosePreview {
  const pnl = clampPnl(uPnlUsdg(size1e18, entry1e18, mark1e18, isLong), margin, maxPayout);
  let pot = margin + pnl - fundingOwed - borrowOwed;
  if (pot < 0n) pot = 0n;
  // Vault-outflow bound: the win slice can never exceed the reserved maxPayout.
  const winSlice = pot > margin ? pot - margin : 0n;
  if (winSlice > maxPayout) pot = margin + maxPayout;
  const closedNotional = notionalUsdg(size1e18, mark1e18);
  let closeFee = (closedNotional * BigInt(closeFeeBps)) / BPS;
  if (closeFee > pot) closeFee = pot;
  return { pnl, fundingOwed, borrowOwed, pot, closeFee, traderNet: pot - closeFee };
}

// ---------------------------------------------------------------------------
// Liquidation danger (the add-margin warning math)
// ---------------------------------------------------------------------------

/**
 * Fraction of the entry-to-liquidation distance the mark has already traveled,
 * clamped to [0, 1.5]. 0 = at or beyond entry on the profitable side; 1 = at the
 * liquidation price. The UI warns soft at 0.5, loud at 0.75, and lights the
 * Add Margin button from 0.75.
 */
export function liqDanger(
  entry1e18: bigint,
  mark1e18: bigint,
  liq1e18: bigint,
  isLong: boolean,
): number {
  if (liq1e18 === 0n) return 0;
  const entry = Number(entry1e18);
  const mark = Number(mark1e18);
  const liq = Number(liq1e18);
  const span = isLong ? entry - liq : liq - entry;
  if (span <= 0) return 0;
  const traveled = isLong ? entry - mark : mark - entry;
  const d = traveled / span;
  return Math.min(1.5, Math.max(0, d));
}

export type DangerLevel = "safe" | "soft" | "loud" | "liquidatable";

/** Threshold mapping for the warning UX: soft at 50%, loud at 75%. */
export function dangerLevel(danger: number): DangerLevel {
  if (danger >= 1) return "liquidatable";
  if (danger >= 0.75) return "loud";
  if (danger >= 0.5) return "soft";
  return "safe";
}

// ---------------------------------------------------------------------------
// Liquidation waterfall (PerpEngine.liquidate, spec 3.2/3.3)
// ---------------------------------------------------------------------------

export interface LiquidationPreview {
  /** Penalty: min(max(equity, 0), liqPenaltyBps of notional). */
  penalty: bigint;
  /** Keeper reward: 20% of the penalty, floored at 5 USDG (floor topped up by the IF). */
  keeperReward: bigint;
  /** Vault share of the penalty: 40%. The house gets paid when leverage dies. */
  vaultShare: bigint;
  /** Insurance fund share of the penalty: the remaining 40% plus round-down dust. */
  insuranceShare: bigint;
  /** Residual equity RETURNED to the trader after the penalty (dYdX model). */
  traderResidual: bigint;
  /** Bad debt claimed from the insurance fund when equity gapped below zero. */
  shortfall: bigint;
}

/** Economics v2 penalty split: keeper 20% / vault 40% / insurance fund 40%. */
export function previewLiquidation(
  equity: bigint,
  notional: bigint,
  liqPenaltyBps: number = Number(LIQ_PENALTY_BPS),
): LiquidationPreview {
  const positiveEquity = equity > 0n ? equity : 0n;
  const penaltyCap = (notional * BigInt(liqPenaltyBps)) / BPS;
  const penalty = positiveEquity < penaltyCap ? positiveEquity : penaltyCap;
  const keeperCut = (penalty * KEEPER_SHARE_BPS) / BPS;
  const vaultShare = (penalty * LIQ_VAULT_SHARE_BPS) / BPS;
  const insuranceShare = penalty - keeperCut - vaultShare;
  // The floor top-up is paid by the insurance fund, not carved from the penalty.
  const keeperReward = keeperCut < KEEPER_FLOOR ? KEEPER_FLOOR : keeperCut;
  return {
    penalty,
    keeperReward,
    vaultShare,
    insuranceShare,
    traderResidual: positiveEquity - penalty,
    shortfall: equity < 0n ? -equity : 0n,
  };
}

// ---------------------------------------------------------------------------
// Display helpers
// ---------------------------------------------------------------------------

/** A 1e18 hourly rate to a signed percent string, e.g. "+0.0031%/h". */
export function formatRatePerHour(rate1e18: bigint, digits = 4): string {
  const pct = (Number(rate1e18) / 1e18) * 100;
  const sign = pct > 0 ? "+" : "";
  return `${sign}${pct.toFixed(digits)}%/h`;
}

/** A 1e18 hourly rate annualized to a percent string (straight-line, display only). */
export function annualizedPct(rate1e18: bigint): number {
  return (Number(rate1e18) / 1e18) * 24 * 365 * 100;
}

/** Effective leverage of a live position: notional / equity (float, display only). */
export function effectiveLeverage(notional: bigint, equity: bigint): number {
  if (equity <= 0n) return Infinity;
  return Number(notional) / Number(equity);
}
