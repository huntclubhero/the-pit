/**
 * Unit math and formatting for THE PIT.
 *
 * Perp position math lives in ./perp (mirrors MarginMathLib / FundingLib /
 * PerpEngine). This module keeps the shared rails: the fee split, the points
 * math (PitPoints is unchanged in v2), and every display formatter.
 *
 * Scales:
 *   USDG collateral: native 6 decimals (uint)
 *   Prices:          1e18 (USDG per token)
 *   Points:          1e18
 */

// ---------------------------------------------------------------------------
// Protocol constants (mirrors PerpEngine fee split / PitPoints / SpinVRF)
// ---------------------------------------------------------------------------

export const USDG_DECIMALS = 6;
export const USDG_ONE = 1_000_000n;
export const PRICE_ONE = 10n ** 18n;
export const POINTS_ONE = 10n ** 18n;

export const BPS_DENOM = 10_000n;

// ---- Fee split of EVERY protocol fee (open + close fees). Sums to 10_000. ----
// Economics v2: the vault takes a 20% carve of every trade fee (the house edge
// an audit found missing), alongside jackpot, referral, buyback, and treasury.
export const FEE_SHARE_JACKPOT_BPS = 2_500n; // 25% feeds the progressive jackpot
export const FEE_SHARE_REFERRAL_BPS = 1_000n; // 10% to the referral pool
export const FEE_SHARE_VAULT_BPS = 2_000n; // 20% straight to the PitVault (PLP)
export const FEE_SHARE_BUYBACK_BPS = 2_500n; // 25% to buyback-and-burn ($PIT)
export const FEE_SHARE_TREASURY_BPS = 2_000n; // 20% base to treasury (keeps round-down dust)

export const POINTS_PER_NOTIONAL_UNIT = 10n ** 11n;
export const NOTIONAL_CAP = 10n ** 38n;
export const MULT_SCALE = 10_000n;
export const LOSS_REBATE_BPS = 2_500n;
export const CREATOR_SHARE_BPS = 500n;
export const DAILY_STEP = 500n;
export const DAILY_MULT_CAP = 15_000n;

/** Oracle listing floor when no override is set: 25,000 USDG of tracked liquidity. */
export const DEFAULT_LIQUIDITY_FLOOR_1E18 = 25_000n * PRICE_ONE;

// ---------------------------------------------------------------------------
// Fee split (mirrors PerpEngine._distributeFee): the tokenomics centerpiece.
// Every open and close fee splits five ways. Jackpot / referral / vault /
// buyback floor; treasury takes the remainder so the shares always sum exactly.
// (The vol surcharge on opens is separate: 100% of it goes to the vault.)
// ---------------------------------------------------------------------------

export interface FeeSplit {
  jackpot: bigint;
  referral: bigint;
  vault: bigint;
  buyback: bigint;
  treasury: bigint;
}

export function splitFee(fee: bigint): FeeSplit {
  const jackpot = (fee * FEE_SHARE_JACKPOT_BPS) / BPS_DENOM;
  const referral = (fee * FEE_SHARE_REFERRAL_BPS) / BPS_DENOM;
  const vault = (fee * FEE_SHARE_VAULT_BPS) / BPS_DENOM;
  const buyback = (fee * FEE_SHARE_BUYBACK_BPS) / BPS_DENOM;
  const treasury = fee - jackpot - referral - vault - buyback;
  return { jackpot, referral, vault, buyback, treasury };
}

// ---------------------------------------------------------------------------
// Points math (mirrors PitPoints; unchanged in v2, engine is the registrar)
// ---------------------------------------------------------------------------

/** base = clamp(notional, NOTIONAL_CAP) * 1e11, in 1e18-scale points. */
export function basePoints(notionalNative: bigint): bigint {
  const clamped = notionalNative > NOTIONAL_CAP ? NOTIONAL_CAP : notionalNative;
  return clamped * POINTS_PER_NOTIONAL_UNIT;
}

/** Win streak multiplier table (MULT_SCALE = 1.0x). */
export function winMultiplier(wins: number): bigint {
  if (wins < 2) return 10_000n;
  if (wins === 2) return 12_000n;
  if (wins === 3) return 15_000n;
  if (wins === 4) return 20_000n;
  if (wins === 5) return 30_000n;
  return 50_000n;
}

/** Daily streak multiplier: 1.0x day 1, +0.05x per consecutive day, cap 1.5x. */
export function dailyMultiplier(count: number): bigint {
  if (count <= 1) return MULT_SCALE;
  const mult = MULT_SCALE + DAILY_STEP * BigInt(count - 1);
  return mult > DAILY_MULT_CAP ? DAILY_MULT_CAP : mult;
}

/** Trader earn on a fill = base * winMult * dailyMult / (MULT_SCALE^2), floor. */
export function traderPoints(base: bigint, wins: number, dailyCount: number): bigint {
  return (base * winMultiplier(wins) * dailyMultiplier(dailyCount)) / (MULT_SCALE * MULT_SCALE);
}

/** Loss rebate = base * 2_500 / 10_000: no multipliers. The house tips the fallen. */
export function lossRebate(base: bigint): bigint {
  return (base * LOSS_REBATE_BPS) / MULT_SCALE;
}

/** Creator share = 5% of any mint attributable to the creator's token. */
export function creatorShare(amount: bigint): bigint {
  return (amount * CREATOR_SHARE_BPS) / MULT_SCALE;
}

/** Spin bonus = spinBase * (multiplier - 1). */
export function spinBonus(spinBase: bigint, multiplier: number): bigint {
  return spinBase * BigInt(multiplier - 1);
}

/** SpinVRF threshold mapping on word % 10_000 (mirrors multiplierForWord). */
export function multiplierForWord(word: bigint): number {
  const roll = word % 10_000n;
  if (roll < 6_000n) return 1;
  if (roll < 8_500n) return 2;
  if (roll < 9_500n) return 5;
  if (roll < 9_900n) return 20;
  return 100;
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

function groupInt(s: string): string {
  return s.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

/** Format a bigint at `decimals` scale to a fixed-decimal grouped string. */
export function formatUnits(value: bigint, decimals: number, displayDecimals: number): string {
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  const frac = abs % base;
  let out = groupInt(whole.toString());
  if (displayDecimals > 0) {
    let fracStr = frac.toString().padStart(decimals, "0");
    if (displayDecimals >= decimals) {
      fracStr = fracStr.padEnd(displayDecimals, "0");
    } else {
      fracStr = fracStr.slice(0, displayDecimals);
    }
    out += "." + fracStr;
  }
  return (negative ? "-" : "") + out;
}

/** USDG (native 6 decimals) to a display string, default 2 decimals. */
export function formatUsdg(value: bigint, displayDecimals = 2): string {
  return formatUnits(value, USDG_DECIMALS, displayDecimals);
}

/** Signed USDG with an explicit plus on gains: "+412.20" / "-88.10". */
export function formatSignedUsdg(value: bigint, displayDecimals = 2): string {
  const abs = value < 0n ? -value : value;
  const sign = value < 0n ? "-" : "+";
  return sign + formatUsdg(abs, displayDecimals);
}

/** Points (1e18) to a display string, default 0 decimals: whole points read best. */
export function formatPoints(value: bigint, displayDecimals = 0): string {
  return formatUnits(value, 18, displayDecimals);
}

/**
 * Price (1e18) with memecoin-aware precision: large prices get 2 decimals,
 * sub-unit prices keep 4 significant figures.
 */
export function formatPrice(value1e18: bigint): string {
  if (value1e18 === 0n) return "0";
  if (value1e18 >= PRICE_ONE * 1000n) return formatUnits(value1e18, 18, 2);
  if (value1e18 >= PRICE_ONE) return formatUnits(value1e18, 18, 4);
  // Sub-unit: find leading zeros after the decimal point, keep 4 sig figs.
  const fracStr = value1e18.toString().padStart(19, "0").slice(1); // 18 frac digits
  let leadingZeros = 0;
  while (leadingZeros < fracStr.length && fracStr[leadingZeros] === "0") leadingZeros++;
  const digits = Math.min(leadingZeros + 4, 18);
  return "0." + fracStr.slice(0, digits);
}

/** Signed basis points to a percent string: 1234 -> "+12.34%". */
export function formatBpsPct(bps: number): string {
  const sign = bps > 0 ? "+" : bps < 0 ? "-" : "";
  const abs = Math.abs(bps);
  return `${sign}${(abs / 100).toFixed(2)}%`;
}

/** Compact USDG for dense tables: 1.24M, 83.1K. Input native 6 decimals. */
export function formatUsdgCompact(value: bigint): string {
  const whole = Number(value / USDG_ONE);
  return compactNumber(whole);
}

/** Compact points (1e18 in). */
export function formatPointsCompact(value: bigint): string {
  return compactNumber(Number(value / POINTS_ONE));
}

export function compactNumber(n: number): string {
  const abs = Math.abs(n);
  if (abs >= 1_000_000_000) return (n / 1_000_000_000).toFixed(2) + "B";
  if (abs >= 1_000_000) return (n / 1_000_000).toFixed(2) + "M";
  if (abs >= 10_000) return (n / 1_000).toFixed(1) + "K";
  return groupInt(Math.trunc(n).toString());
}

/** Seconds to "2d 04:31:09" or "04:31:09" countdown text. */
export function formatCountdown(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds));
  const days = Math.floor(s / 86_400);
  const hours = Math.floor((s % 86_400) / 3_600);
  const minutes = Math.floor((s % 3_600) / 60);
  const seconds = s % 60;
  const hms = [hours, minutes, seconds].map((v) => String(v).padStart(2, "0")).join(":");
  return days > 0 ? `${days}d ${hms}` : hms;
}

/** Seconds-ago to a compact age label: "34s", "12m", "4h", "3d". */
export function formatAge(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return `${s}s`;
  if (s < 3_600) return `${Math.floor(s / 60)}m`;
  if (s < 86_400) return `${Math.floor(s / 3_600)}h`;
  return `${Math.floor(s / 86_400)}d`;
}

/** Multiplier (MULT_SCALE) to "1.50x". */
export function formatMultiplier(mult: bigint): string {
  return (Number(mult) / Number(MULT_SCALE)).toFixed(2) + "x";
}

/** Shorten an address for display. */
export function shortAddress(address: string): string {
  return address.slice(0, 6) + ".." + address.slice(-4);
}

/** Parse a user-typed USDG amount into native 6-decimal units. Floors extra precision. */
export function parseUsdg(input: string): bigint | undefined {
  const trimmed = input.trim().replace(/,/g, "");
  if (!/^\d*(\.\d*)?$/.test(trimmed) || trimmed === "" || trimmed === ".") return undefined;
  const [wholeRaw, fracRaw = ""] = trimmed.split(".");
  const whole = wholeRaw === "" ? "0" : wholeRaw;
  const frac = fracRaw.slice(0, USDG_DECIMALS).padEnd(USDG_DECIMALS, "0");
  return BigInt(whole) * USDG_ONE + BigInt(frac);
}
