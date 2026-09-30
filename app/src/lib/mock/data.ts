/**
 * MOCK MODE dataset: realistic, fully populated demo data so every page is
 * browsable with zero chain connection. Numbers "live": prices wiggle, the
 * jackpot pot climbs, and the demo store is MUTABLE so the trade ticket,
 * add-margin, close, and vault deposit/withdraw flows all actually work.
 */

import type {
  DrawRecord,
  JackpotState,
  LeaderboardEntry,
  LiquidationEvent,
  MarketSummary,
  MarketTier,
  PerpPositionRow,
  PointsProfile,
  Side,
  SpinLedgerRow,
  TradeRecord,
  VaultFlowEvent,
  VaultState,
} from "../types";
import { PRICE_ONE, POINTS_ONE } from "../format";
import {
  KB_PER_HOUR_1E18,
  PAYOUT_CAP_MULTIPLE,
  borrowRatePerHour1e18,
  clampPnl,
  fundingRatePerHour1e18,
  notionalUsdg,
  previewClose,
  previewLiquidation,
  sizeForNotional,
  skew1e18,
  tierParams,
  uPnlUsdg,
} from "../perp";

export const MOCK_ACCOUNT = "0xd3a94Fb8c7e21B04F5B8dD3f4A78e9C012fEB733";

const now = () => Math.floor(Date.now() / 1000);

function addr(seed: number): string {
  const hex = ((seed * 2654435761) >>> 0).toString(16).padStart(8, "0");
  return `0x${hex}${"abcdef0123".repeat(4).slice(0, 32)}`;
}

/** Price in USDG (float) to 1e18 bigint. */
function px(value: number): bigint {
  return BigInt(Math.round(value * 1e12)) * 10n ** 6n;
}

/** USDG float to native 6-decimal units. */
function usdg(value: number): bigint {
  return BigInt(Math.round(value * 1e6));
}

function pts(value: number): bigint {
  return BigInt(Math.round(value * 1e6)) * 10n ** 12n;
}

// ---------------------------------------------------------------------------
// The vault (module-level so market reserve caps can read TVL)
// ---------------------------------------------------------------------------

/** Demo vault TVL: 2.84M USDG. Per-market reserve cap = 10% of this. */
const VAULT_TVL = usdg(2_841_337.42);
const VAULT_SHARES = usdg(2_723_610.55); // share price ~1.0432
const MARKET_TVL_CAP = VAULT_TVL / 10n; // 10% of TVL per market

// ---------------------------------------------------------------------------
// Markets
// ---------------------------------------------------------------------------

interface Seed {
  symbol: string;
  name: string;
  price: number;
  change: number; // bps
  liq: number; // tracked pool liquidity, USDG
  fdv: number; // live FDV, USD (drives the mcap tier)
  oiLong: number; // USDG notional
  oiShort: number; // USDG notional
  emission: number; // points 24h
  tier: MarketTier;
  oracle: string;
  status?: MarketSummary["oracleStatus"];
  cooldownRemaining?: number;
}

const TWAP3 = "Aggregated 3-pool TWAP";
const TWAP4 = "Aggregated 4-pool TWAP";
const TWAP1 = "Single-pool TWAP";
const FEED = "Chainlink feed";

// 13 memecoins (CASHCAT first) followed by the Tier A majors. Indexes are
// load-bearing: positions, history, and spins reference markets by index.
const seeds: Seed[] = [
  { symbol: "CASHCAT", name: "Cash Cat", price: 0.004217, change: 1843, liq: 1_842_000, fdv: 4_200_000, oiLong: 128_400, oiShort: 61_200, emission: 48_210, tier: "B", oracle: TWAP3 },
  { symbol: "FWA", name: "FWA", price: 0.000871, change: -723, liq: 923_500, fdv: 1_640_000, oiLong: 22_100, oiShort: 47_900, emission: 22_960, tier: "C", oracle: TWAP1 },
  { symbol: "MOONDOG", name: "Moon Dog", price: 0.03119, change: 4212, liq: 2_411_000, fdv: 7_800_000, oiLong: 171_300, oiShort: 88_600, emission: 71_040, tier: "B", oracle: TWAP3 },
  { symbol: "GIGA", name: "Gigachad", price: 1.2405, change: 312, liq: 5_120_000, fdv: 28_400_000, oiLong: 204_800, oiShort: 187_100, emission: 96_780, tier: "B", oracle: TWAP4 },
  { symbol: "PONZU", name: "Ponzu", price: 0.006731, change: 981, liq: 684_200, fdv: 920_000, oiLong: 19_400, oiShort: 11_200, emission: 12_330, tier: "C", oracle: TWAP1 },
  { symbol: "WAGMI", name: "Wagmi", price: 0.05213, change: -142, liq: 1_204_000, fdv: 3_100_000, oiLong: 31_900, oiShort: 36_400, emission: 25_610, tier: "C", oracle: TWAP1 },
  { symbol: "COPE", name: "Cope", price: 0.001092, change: 548, liq: 451_800, fdv: 640_000, oiLong: 12_300, oiShort: 7_800, emission: 8_140, tier: "C", oracle: TWAP1 },
  {
    symbol: "RUGRAT",
    name: "Rug Rat",
    price: 0.000194,
    change: -2361,
    liq: 312_400,
    fdv: 410_000,
    oiLong: 6_400,
    oiShort: 9_100,
    emission: 6_020,
    tier: "C",
    oracle: TWAP1,
    status: "COOLDOWN",
    cooldownRemaining: 14 * 60 + 22,
  },
  { symbol: "HOPIUM", name: "Hopium", price: 0.008926, change: 2731, liq: 1_566_000, fdv: 5_600_000, oiLong: 98_700, oiShort: 41_300, emission: 39_870, tier: "B", oracle: TWAP3 },
  { symbol: "SNIPER", name: "Sniper", price: 0.4411, change: -484, liq: 3_240_000, fdv: 13_200_000, oiLong: 96_200, oiShort: 141_800, emission: 58_990, tier: "B", oracle: TWAP3 },
  { symbol: "DEGEN", name: "Degen", price: 0.01922, change: 121, liq: 987_600, fdv: 2_400_000, oiLong: 28_800, oiShort: 24_100, emission: 19_480, tier: "C", oracle: TWAP1 },
  {
    symbol: "NPC",
    name: "NPC",
    price: 0.000341,
    change: -1288,
    liq: 264_100,
    fdv: 380_000,
    oiLong: 4_100,
    oiShort: 5_900,
    emission: 3_910,
    tier: "C",
    oracle: TWAP1,
    status: "STALE",
  },
  { symbol: "FELT", name: "Felt", price: 0.000612, change: 6404, liq: 388_900, fdv: 780_000, oiLong: 14_800, oiShort: 5_100, emission: 17_260, tier: "C", oracle: TWAP1 },
  // Tier A majors: independent feeds, PerpRiskConfig token overrides (5 bps, 15x).
  { symbol: "WBTC", name: "Wrapped Bitcoin", price: 64_213.5, change: 142, liq: 48_200_000, fdv: 1_260_000_000_000, oiLong: 1_264_000, oiShort: 876_000, emission: 214_800, tier: "A", oracle: FEED },
  { symbol: "WETH", name: "Wrapped Ether", price: 3_418.22, change: 231, liq: 31_600_000, fdv: 411_000_000_000, oiLong: 792_400, oiShort: 659_600, emission: 168_400, tier: "A", oracle: FEED },
  { symbol: "WSOL", name: "Wrapped Solana", price: 168.44, change: -88, liq: 12_400_000, fdv: 78_000_000_000, oiLong: 341_200, oiShort: 385_300, emission: 98_700, tier: "A", oracle: FEED },
];

/** Mcap tier index from a seed's FDV against the LOCKED bands. */
function mcapTierOf(fdv: number): number {
  if (fdv >= 50_000_000) return 5;
  if (fdv >= 10_000_000) return 4;
  if (fdv >= 5_000_000) return 3;
  if (fdv >= 2_000_000) return 2;
  if (fdv >= 500_000) return 1;
  return 0;
}

export const mockMarkets: MarketSummary[] = seeds.map((s, i) => {
  const isMajor = s.tier === "A";
  const mcapTier = mcapTierOf(s.fdv);
  const params = tierParams(mcapTier, isMajor);
  const oiLong = usdg(s.oiLong);
  const oiShort = usdg(s.oiShort);
  const skewFloor = isMajor ? usdg(50_000) : usdg(10_000);
  const skew = skew1e18(oiLong, oiShort, skewFloor);
  // Cost-to-move bound (TWAP tiers): ~10% of tracked liquidity after the safety
  // factor. Majors have no cost-to-move bound: the TVL leg alone caps them.
  const costToMove = isMajor ? Number.POSITIVE_INFINITY : s.liq * 0.1;
  const costLeg = isMajor ? MARKET_TVL_CAP : usdg(costToMove);
  const reserveCap = costLeg < MARKET_TVL_CAP ? costLeg : MARKET_TVL_CAP;
  // Reserved max payouts trail OI (payout cap 9x on a slice of positions).
  const reserved = ((oiLong + oiShort) * 6n) / 10n;
  return {
    address: addr(1000 + i),
    token: addr(1000 + i),
    symbol: s.symbol,
    name: s.name,
    tier: s.tier,
    oracleKind: s.oracle,
    isMajor,
    mcapTier,
    fdvUsd: s.fdv,
    maxLeverageX100: params.maxLeverageX100,
    mmrBps: params.mmrBps,
    openFeeBps: params.openFeeBps,
    closeFeeBps: params.closeFeeBps,
    costToMoveUsd: costToMove,
    price1e18: px(s.price),
    change24hBps: s.change,
    oiLong,
    oiShort,
    reserveCap,
    reserved: reserved < reserveCap ? reserved : (reserveCap * 9n) / 10n,
    fundingRatePerHour1e18: fundingRatePerHour1e18(skew, params.kFPerHour1e18),
    borrowRatePerHour1e18: borrowRatePerHour1e18(reserved, VAULT_TVL, KB_PER_HOUR_1E18),
    pointsEmission24h: pts(s.emission),
    oracleStatus: s.status ?? "OK",
    cooldownRemaining: s.cooldownRemaining,
  };
});

export function mockMarketByAddress(address: string): MarketSummary | undefined {
  return mockMarkets.find((m) => m.address.toLowerCase() === address.toLowerCase());
}

export function mockMarketBySymbol(symbol: string): MarketSummary | undefined {
  return mockMarkets.find((m) => m.symbol === symbol);
}

// ---------------------------------------------------------------------------
// Open perp positions (MUTABLE demo store: ticket opens, add-margin mutates,
// close removes; hooks re-read on their poll interval)
// ---------------------------------------------------------------------------

interface PositionSeed {
  symbol: string;
  side: Side;
  margin: number; // USDG, net
  leverageX100: number;
  entry: number;
  fundingAccrued: number; // USDG, signed (positive = owed)
  borrowAccrued: number; // USDG
  ageSeconds: number;
}

/**
 * The FWA short sits deep in the danger zone (mark has traveled ~85% of the
 * way to its liquidation price) to showcase the loud warning + pulsing
 * Add Margin button. The CASHCAT long sits at ~55% for the soft warning.
 */
const positionSeeds: PositionSeed[] = [
  // CASHCAT long 5x, entered above the current mark: ~55% to liquidation (soft).
  { symbol: "CASHCAT", side: "long", margin: 1_200, leverageX100: 500, entry: 0.004491, fundingAccrued: 14.21, borrowAccrued: 1.94, ageSeconds: 3_600 * 26 },
  // FWA short 6x, mark ripped against it: ~85% to liquidation (loud + pulsing).
  { symbol: "FWA", side: "short", margin: 750, leverageX100: 600, entry: 0.000828, fundingAccrued: -6.4, borrowAccrued: 1.12, ageSeconds: 3_600 * 41 },
  // GIGA long 10x, comfortably in profit.
  { symbol: "GIGA", side: "long", margin: 2_500, leverageX100: 1_000, entry: 1.1846, fundingAccrued: 8.77, borrowAccrued: 3.05, ageSeconds: 86_400 * 3 },
  // WBTC long 15x major, small profit.
  { symbol: "WBTC", side: "long", margin: 5_000, leverageX100: 1_500, entry: 63_710.0, fundingAccrued: 11.32, borrowAccrued: 6.41, ageSeconds: 3_600 * 9 },
  // WSOL short 8x, mildly against.
  { symbol: "WSOL", side: "short", margin: 1_800, leverageX100: 800, entry: 167.1, fundingAccrued: -2.9, borrowAccrued: 1.66, ageSeconds: 3_600 * 15 },
];

let nextPositionId = 512;

function buildPosition(s: PositionSeed): PerpPositionRow {
  const market = mockMarketBySymbol(s.symbol)!;
  const margin = usdg(s.margin);
  const entry = px(s.entry);
  const notional = (margin * BigInt(s.leverageX100)) / 100n;
  return {
    id: nextPositionId++,
    marketAddress: market.address,
    symbol: s.symbol,
    side: s.side,
    margin,
    size1e18: sizeForNotional(notional, entry),
    entryPrice1e18: entry,
    leverageX100: s.leverageX100,
    maxPayout: PAYOUT_CAP_MULTIPLE * margin,
    fundingAccrued: usdg(s.fundingAccrued),
    borrowAccrued: usdg(s.borrowAccrued),
    openedAt: now() - s.ageSeconds,
  };
}

export const mockPerpPositions: PerpPositionRow[] = positionSeeds.map(buildPosition);

/** Demo: open a new position from the ticket. Returns the created row. */
export function demoOpenPosition(input: {
  marketAddress: string;
  symbol: string;
  side: Side;
  marginNet: bigint;
  size1e18: bigint;
  entryPrice1e18: bigint;
  leverageX100: number;
  maxPayout: bigint;
}): PerpPositionRow {
  const row: PerpPositionRow = {
    id: nextPositionId++,
    marketAddress: input.marketAddress,
    symbol: input.symbol,
    side: input.side,
    margin: input.marginNet,
    size1e18: input.size1e18,
    entryPrice1e18: input.entryPrice1e18,
    leverageX100: input.leverageX100,
    maxPayout: input.maxPayout,
    fundingAccrued: 0n,
    borrowAccrued: 0n,
    openedAt: now(),
  };
  mockPerpPositions.unshift(row);
  return row;
}

/** Demo: close a position and append the trade record. Returns the record. */
export function demoClosePosition(
  id: number,
  mark1e18: bigint,
  closeFeeBps: number,
): TradeRecord | undefined {
  const idx = mockPerpPositions.findIndex((p) => p.id === id);
  if (idx === -1) return undefined;
  const p = mockPerpPositions[idx];
  const preview = previewClose(
    p.size1e18,
    p.entryPrice1e18,
    mark1e18,
    p.margin,
    p.maxPayout,
    p.side === "long",
    p.fundingAccrued,
    p.borrowAccrued,
    closeFeeBps,
  );
  mockPerpPositions.splice(idx, 1);
  const record: TradeRecord = {
    id: p.id,
    symbol: p.symbol,
    side: p.side,
    result: "closed",
    margin: p.margin,
    leverageX100: p.leverageX100,
    entryPrice1e18: p.entryPrice1e18,
    exitPrice1e18: mark1e18,
    pnl: preview.pnl,
    fee: preview.closeFee,
    fundingPaid: p.fundingAccrued + p.borrowAccrued,
    payout: preview.traderNet,
    pointsEarned: pts(Number(notionalUsdg(p.size1e18, mark1e18) / 1_000_000n) * 0.1),
    settledAt: now(),
    txHash: `0xdem0${(p.id * 2654435761 >>> 0).toString(16).padStart(8, "0")}c1o5e${"ab12".repeat(11)}`.slice(0, 66),
  };
  mockTradeHistory.unshift(record);
  return record;
}

/** Demo: add margin to a live position (maxPayout grows by 9x the added amount). */
export function demoAddMargin(id: number, amount: bigint): void {
  const p = mockPerpPositions.find((row) => row.id === id);
  if (!p) return;
  p.margin += amount;
  p.maxPayout += PAYOUT_CAP_MULTIPLE * amount;
}

// ---------------------------------------------------------------------------
// Trade history (closes + one liquidation), derived through the exact math
// ---------------------------------------------------------------------------

interface HistorySeed {
  id: number;
  symbol: string;
  side: Side;
  margin: number;
  leverageX100: number;
  entry: number;
  exit: number;
  fundingPaid: number; // signed USDG over the position's life
  liquidated?: boolean;
  points: number;
  ageSeconds: number;
  txHash: string;
}

const historySeeds: HistorySeed[] = [
  // The leverage win: HOPIUM long 6x, +38% move, profit clamped nowhere near cap.
  { id: 431, symbol: "HOPIUM", side: "long", margin: 800, leverageX100: 600, entry: 0.006471, exit: 0.008926, fundingPaid: 21.4, points: 74.6, ageSeconds: 3_600 * 9, txHash: "0x8f14a7c2d9e6b3518a0f4c7d2e9b6a3518f0c4d7e2a9b6c3518f0a4c7d2e9b63" },
  { id: 424, symbol: "GIGA", side: "short", margin: 1_500, leverageX100: 400, entry: 1.1984, exit: 1.2409, fundingPaid: -4.2, points: 7.45, ageSeconds: 86_400 + 3_600 * 3, txHash: "0x2c9b6a3518f0c4d7e2a9b6c3518f0a4c7d2e9b638f14a7c2d9e6b3518a0f4c7d" },
  // A 15x major scalp: WBTC long, +5.2% move = ~78% on margin.
  { id: 512, symbol: "WBTC", side: "long", margin: 2_000, leverageX100: 1_500, entry: 61_050, exit: 64_230, fundingPaid: 9.8, points: 41.2, ageSeconds: 3_600 * 14, txHash: "0x5a1c9b6a3518f0c4d7e2a9b6c3518f0a4c7d2e9b638f14a7c2d9e6b3518a0f4c" },
  { id: 419, symbol: "WAGMI", side: "long", margin: 400, leverageX100: 600, entry: 0.04788, exit: 0.05102, fundingPaid: 3.1, points: 49.75, ageSeconds: 86_400 * 2 + 3_600 * 5, txHash: "0xa3518f0c4d7e2a9b6c3518f0a4c7d2e9b638f14a7c2d9e6b3518a0f4c7d2c9b6" },
  // The liquidation: MOONDOG short 6x into a +42% rip. Margin gone, penalty paid.
  { id: 397, symbol: "MOONDOG", side: "short", margin: 950, leverageX100: 600, entry: 0.02198, exit: 0.02561, fundingPaid: -11.6, liquidated: true, points: 6.0, ageSeconds: 86_400 * 3 + 3_600 * 6, txHash: "0x1f0a4c7d2e9b638f14a7c2d9e6b3518a0f4c7d2c9b6a3518f0c4d7e2a9b6c351" },
  { id: 391, symbol: "RUGRAT", side: "long", margin: 300, leverageX100: 400, entry: 0.000261, exit: 0.000203, fundingPaid: 5.9, points: 9.9, ageSeconds: 86_400 * 4 + 3_600 * 7, txHash: "0xc7d2e9b638f14a7c2d9e6b3518a0f4c7d2c9b6a3518f0c4d7e2a9b6c3518f0a4" },
  { id: 366, symbol: "MOONDOG", side: "long", margin: 1_100, leverageX100: 600, entry: 0.02244, exit: 0.02719, fundingPaid: 18.2, points: 29.82, ageSeconds: 86_400 * 6 + 3_600 * 2, txHash: "0xe2a9b6c3518f0a4c7d2e9b638f14a7c2d9e6b3518a0f4c7d2c9b6a3518f0c4d7" },
  { id: 341, symbol: "COPE", side: "long", margin: 250, leverageX100: 400, entry: 0.000982, exit: 0.001071, fundingPaid: 1.7, points: 49.75, ageSeconds: 86_400 * 8, txHash: "0xf0a4c7d2e9b638f14a7c2d9e6b3518a0f4c7d2c9b6a3518f0c4d7e2a9b6c3518" },
];

function buildTrade(s: HistorySeed): TradeRecord {
  const market = mockMarketBySymbol(s.symbol)!;
  const margin = usdg(s.margin);
  const entry = px(s.entry);
  const exit = px(s.exit);
  const notional = (margin * BigInt(s.leverageX100)) / 100n;
  const size = sizeForNotional(notional, entry);
  const maxPayout = PAYOUT_CAP_MULTIPLE * margin;
  const fundingPaid = usdg(s.fundingPaid);
  const base = {
    id: s.id,
    symbol: s.symbol,
    side: s.side,
    margin,
    leverageX100: s.leverageX100,
    entryPrice1e18: entry,
    exitPrice1e18: exit,
    fundingPaid,
    pointsEarned: pts(s.points),
    settledAt: now() - s.ageSeconds,
    txHash: s.txHash,
  };
  if (s.liquidated) {
    // Liquidation at the mark: equity has decayed under maintenance. Waterfall:
    // penalty out of any residual, remainder back to the trader (dYdX model).
    const pnl = clampPnl(uPnlUsdg(size, entry, exit, s.side === "long"), margin, maxPayout);
    const equity = margin + pnl - fundingPaid;
    const flow = previewLiquidation(equity, notionalUsdg(size, exit));
    return {
      ...base,
      result: "liquidated",
      pnl,
      fee: flow.penalty,
      payout: flow.traderResidual,
    };
  }
  const preview = previewClose(
    size,
    entry,
    exit,
    margin,
    maxPayout,
    s.side === "long",
    fundingPaid,
    0n,
    market.closeFeeBps,
  );
  return { ...base, result: "closed", pnl: preview.pnl, fee: preview.closeFee, payout: preview.traderNet };
}

export const mockTradeHistory: TradeRecord[] = historySeeds.map(buildTrade);

// ---------------------------------------------------------------------------
// Liquidations feed (public, protocol-wide)
// ---------------------------------------------------------------------------

const liqSeeds: Array<[string, Side, number, number, number, number]> = [
  // symbol, side, notional USDG, margin, price, minutesAgo
  ["MOONDOG", "short", 5_712, 950, 0.02561, 4],
  ["FELT", "long", 1_920, 480, 0.000534, 22],
  ["SNIPER", "long", 11_400, 1_900, 0.4179, 51],
  ["CASHCAT", "short", 3_260, 815, 0.004402, 74],
  ["WSOL", "long", 27_150, 1_810, 163.2, 118],
  ["DEGEN", "long", 2_480, 620, 0.01844, 161],
  ["HOPIUM", "short", 6_840, 1_140, 0.009212, 209],
  ["GIGA", "short", 14_200, 1_420, 1.2671, 263],
  ["FWA", "long", 1_310, 328, 0.000811, 340],
  ["WBTC", "long", 96_300, 6_420, 62_890, 421],
];

export const mockLiquidations: LiquidationEvent[] = liqSeeds.map(
  ([symbol, side, notional, margin, price, minutesAgo], i) => ({
    id: 900 - i,
    symbol,
    side,
    notional: usdg(notional),
    margin: usdg(margin),
    price1e18: px(price),
    penalty: usdg(notional * 0.01),
    at: now() - minutesAgo * 60,
    trader: addr(6100 + i * 13),
  }),
);

// ---------------------------------------------------------------------------
// Vault state (MUTABLE demo store: deposit / request / claim all work)
// ---------------------------------------------------------------------------

const vaultFlowSeeds: Array<[VaultFlowEvent["kind"], number, string, number]> = [
  // kind, USDG amount, who, minutesAgo
  ["trader-loss", 4_312.4, "MOONDOG", 6],
  ["fee-share", 96.44, "20% of fees", 12],
  ["deposit", 25_000, addr(8101), 19],
  ["liq-penalty", 22.85, "MOONDOG", 38],
  ["funding", 611.08, "residual", 62],
  ["trader-win", 6_120.77, "HOPIUM", 96],
  ["borrow", 214.31, "all markets", 122],
  ["fee-share", 141.02, "20% of fees", 155],
  ["deposit", 100_000, addr(8102), 187],
  ["trader-loss", 1_882.02, "FWA", 241],
  ["liq-penalty", 45.6, "SNIPER", 274],
  ["withdraw-request", 40_000, addr(8103), 302],
  ["claim", 18_240.5, addr(8104), 364],
  ["trader-loss", 9_412.9, "SNIPER", 428],
];

interface VaultStore {
  totalAssets: bigint;
  totalShares: bigint;
  yourShares: bigint;
  yourRequest?: { shares: bigint; epoch: number; claimableAt: number };
  yourClaimable: bigint;
  flows: VaultFlowEvent[];
}

function epochNow(): number {
  return Math.floor(now() / 86_400);
}

function epochEnd(epoch: number): number {
  return (epoch + 1) * 86_400;
}

const vaultStore: VaultStore = {
  totalAssets: VAULT_TVL,
  totalShares: VAULT_SHARES,
  yourShares: usdg(23_960.4),
  yourRequest: undefined,
  yourClaimable: 0n,
  flows: vaultFlowSeeds.map(([kind, amount, who, minutesAgo], i) => ({
    id: 700 - i,
    kind,
    amount: usdg(amount),
    who,
    at: now() - minutesAgo * 60,
  })),
};

/** Aggregate reserved payouts across markets (drives utilization). */
function vaultTotalReserved(): bigint {
  return mockMarkets.reduce((acc, m) => acc + m.reserved, 0n);
}

export function mockVaultState(): VaultState {
  const sharePrice1e18 =
    vaultStore.totalShares === 0n
      ? PRICE_ONE
      : (vaultStore.totalAssets * PRICE_ONE) / vaultStore.totalShares;
  return {
    totalAssets: vaultStore.totalAssets,
    totalShares: vaultStore.totalShares,
    sharePrice1e18,
    totalReserved: vaultTotalReserved(),
    aggTraderUpnl: usdg(-31_240.19), // traders are collectively down: vault gain
    yourShares: vaultStore.yourShares,
    yourRequest: vaultStore.yourRequest,
    yourClaimable: vaultStore.yourClaimable,
    // Trailing-30d annualized, sums to 21.4%: trader losses lead, then funding
    // residual, vol-scaled borrow, the 20% trade-fee carve, and the 40%
    // liquidation-penalty share. Real house revenue, not emissions.
    apr: { traderLosses: 9.7, fundingResidual: 4.2, borrowFees: 3.1, tradeFees: 2.6, liqPenalties: 1.8 },
    depositors: 214,
    epoch: epochNow(),
    epochEndsAt: epochEnd(epochNow()),
    flows: vaultStore.flows.slice(0, 12),
  };
}

/** Demo: deposit USDG, mint PLP at the current share price (10 bps fee to NAV). */
export function demoVaultDeposit(assets: bigint): void {
  const fee = (assets * 10n) / 10_000n;
  const net = assets - fee;
  const shares =
    vaultStore.totalAssets === 0n
      ? net
      : (net * vaultStore.totalShares) / vaultStore.totalAssets;
  vaultStore.totalAssets += assets; // fee stays in NAV
  vaultStore.totalShares += shares;
  vaultStore.yourShares += shares;
  vaultStore.flows.unshift({
    id: Date.now() % 1_000_000,
    kind: "deposit",
    amount: assets,
    who: MOCK_ACCOUNT,
    at: now(),
  });
}

/** Demo: queue a withdraw request into the current epoch. */
export function demoVaultRequestWithdraw(shares: bigint): void {
  if (shares > vaultStore.yourShares) return;
  vaultStore.yourShares -= shares;
  const epoch = epochNow();
  vaultStore.yourRequest = { shares, epoch, claimableAt: epochEnd(epoch) };
  vaultStore.flows.unshift({
    id: Date.now() % 1_000_000,
    kind: "withdraw-request",
    amount: shares,
    who: MOCK_ACCOUNT,
    at: now(),
  });
}

/** Demo: claim a settled request (prices at NAV, 10 bps withdraw fee to NAV). */
export function demoVaultClaim(): void {
  const req = vaultStore.yourRequest;
  if (!req) return;
  const gross = (req.shares * vaultStore.totalAssets) / vaultStore.totalShares;
  const fee = (gross * 10n) / 10_000n;
  vaultStore.totalShares -= req.shares;
  vaultStore.totalAssets -= gross - fee;
  vaultStore.yourClaimable += gross - fee;
  vaultStore.yourRequest = undefined;
  vaultStore.flows.unshift({
    id: Date.now() % 1_000_000,
    kind: "claim",
    amount: gross - fee,
    who: MOCK_ACCOUNT,
    at: now(),
  });
}

// ---------------------------------------------------------------------------
// Points profile + leaderboards
// ---------------------------------------------------------------------------

export const mockProfile: PointsProfile = {
  lifetime: pts(128_453.71),
  season: pts(23_841.06),
  seasonEpoch: 2_953,
  winStreak: 4,
  shieldAvailable: true,
  dailyStreak: 6,
  dailyCalendar: [true, true, false, true, true, true, true, true, true, false, true, true, true, true],
  winMultiplier: 20_000n, // 4 wins = 2.0x
  dailyMultiplier: 12_500n, // day 6 = 1.25x
  referralCode: "PIT-D3GEN-88",
  referrals: 7,
  referralPoints: pts(3_412.55),
};

const aliases = [
  "railgun.eth", "feltlord", "0xMaxPain", "sisyphusIntern", "ropeGirthEnjoyer",
  "clawbackKing", "ivoryTower", "wenLambeaux", "dustFillAndy", "oracleDelayEnjoyer",
  "chalkEater", "tableLimit",
];

export const mockLeaderboardGlobal: LeaderboardEntry[] = [
  { rank: 1, address: addr(7001), alias: aliases[0], points: pts(2_411_882.4) },
  { rank: 2, address: addr(7002), alias: aliases[1], points: pts(1_904_233.9) },
  { rank: 3, address: addr(7003), alias: aliases[2], points: pts(1_534_017.2) },
  { rank: 4, address: addr(7004), alias: aliases[3], points: pts(988_450.8) },
  { rank: 5, address: addr(7005), alias: aliases[4], points: pts(721_390.1) },
  { rank: 6, address: addr(7006), alias: aliases[5], points: pts(604_112.7) },
  { rank: 7, address: addr(7007), alias: aliases[6], points: pts(455_781.3) },
  { rank: 8, address: addr(7008), alias: aliases[7], points: pts(389_204.6) },
  { rank: 9, address: addr(7009), alias: aliases[8], points: pts(302_119.5) },
  { rank: 10, address: addr(7010), alias: aliases[9], points: pts(266_874.2) },
  { rank: 42, address: MOCK_ACCOUNT, points: pts(128_453.71), isYou: true },
];

export const mockLeaderboardWeekly: LeaderboardEntry[] = [
  { rank: 1, address: addr(7003), alias: aliases[2], points: pts(88_204.1) },
  { rank: 2, address: addr(7011), alias: aliases[10], points: pts(71_882.9) },
  { rank: 3, address: addr(7001), alias: aliases[0], points: pts(64_310.5) },
  { rank: 4, address: addr(7012), alias: aliases[11], points: pts(48_450.2) },
  { rank: 5, address: addr(7006), alias: aliases[5], points: pts(41_206.8) },
  { rank: 6, address: addr(7004), alias: aliases[3], points: pts(35_112.4) },
  { rank: 7, address: addr(7009), alias: aliases[8], points: pts(31_710.6) },
  { rank: 8, address: addr(7005), alias: aliases[4], points: pts(28_991.3) },
  { rank: 9, address: MOCK_ACCOUNT, points: pts(23_841.06), isYou: true },
  { rank: 10, address: addr(7008), alias: aliases[7], points: pts(19_412.7) },
];

// ---------------------------------------------------------------------------
// Jackpot + draws
// ---------------------------------------------------------------------------

function nextUtcMidnight(): number {
  const d = new Date();
  return Math.floor(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1) / 1000);
}

function nextEpochBoundary(): number {
  const EPOCH = 7 * 86_400;
  return (Math.floor(now() / EPOCH) + 1) * EPOCH;
}

const drawSeeds: Array<[DrawRecord["kind"], DrawRecord["mode"], number, number, number]> = [
  // kind, mode, amount, daysAgo, winnerSeed
  ["daily", "entrants", 12_884.51, 1, 7003],
  ["daily", "weighted", 11_204.87, 2, 7006],
  ["weekly", "weighted", 61_338.02, 3, 7001],
  ["daily", "entrants", 9_887.44, 3, 7009],
  ["daily", "weighted", 10_412.9, 4, 7012],
  ["daily", "weighted", 9_106.33, 5, 7004],
  ["daily", "entrants", 8_733.19, 6, 7008],
  ["weekly", "weighted", 48_210.66, 10, 7002],
  ["daily", "weighted", 7_918.4, 7, 7005],
];

export const mockJackpot: JackpotState = {
  pot: usdg(142_557.83),
  nextDailyAt: nextUtcMidnight(),
  nextWeeklyAt: nextEpochBoundary(),
  entrantCount: 3,
  draws: drawSeeds.map(([kind, mode, amount, daysAgo, winnerSeed], i) => ({
    drawId: 128 - i,
    kind,
    mode,
    winner: addr(winnerSeed),
    amount: usdg(amount),
    word: BigInt("0x9e" + (winnerSeed * 7919).toString(16)) * 10n ** 30n + BigInt(i * 7 + 3),
    requestId: 88_412_003_117n + BigInt(i * 911),
    epoch: 2_952 - (kind === "weekly" ? i : 0),
    completedAt: now() - daysAgo * 86_400 - 3_600 * ((i * 5) % 23),
    txHash: `0x${(winnerSeed * 2654435761 >>> 0).toString(16).padStart(8, "0")}b638f14a7c2d9e6b3518a0f4c7d2c9b6a3518f0c4d7e2a9b6c3518f0a4c7d2e`,
  })),
};

// ---------------------------------------------------------------------------
// Spin ledger (fairness page)
// ---------------------------------------------------------------------------

const spinSeeds: Array<[number, number, string, number]> = [
  // roll (word % 10000), basePoints, symbol, minutesAgo
  [9_931, 16.5, "CASHCAT", 4],
  [412, 8.2, "MOONDOG", 11],
  [7_204, 24.9, "GIGA", 19],
  [8_866, 12.4, "FWA", 26],
  [3_155, 49.8, "SNIPER", 41],
  [9_612, 6.1, "HOPIUM", 58],
  [5_020, 18.7, "DEGEN", 74],
  [6_483, 33.2, "WAGMI", 92],
  [1_877, 9.9, "PONZU", 118],
  [8_921, 27.5, "CASHCAT", 145],
  [502, 14.3, "COPE", 171],
  [9_444, 41.6, "MOONDOG", 203],
  [2_301, 5.5, "FELT", 240],
  [7_788, 22.1, "GIGA", 268],
];

function spinMultiplier(roll: number): number {
  if (roll < 6_000) return 1;
  if (roll < 8_500) return 2;
  if (roll < 9_500) return 5;
  if (roll < 9_900) return 20;
  return 100;
}

export const mockSpins: SpinLedgerRow[] = [
  {
    requestId: 88_412_009_441n,
    user: MOCK_ACCOUNT,
    token: mockMarkets[3].token,
    symbol: "GIGA",
    fulfilled: false,
    word: 0n,
    multiplier: 0,
    basePoints: pts(31.2),
    bonusPoints: 0n,
    at: now() - 35,
  },
  ...spinSeeds.map(([roll, base, symbol, minutesAgo], i) => {
    const mult = spinMultiplier(roll);
    const market = mockMarkets.find((m) => m.symbol === symbol)!;
    const word =
      BigInt("0x" + ((roll * 48_271 + i * 131) >>> 0).toString(16)) * 10n ** 32n * 10_000n +
      BigInt(roll);
    return {
      requestId: 88_412_009_440n - BigInt(i * 173),
      user: i % 3 === 0 ? MOCK_ACCOUNT : addr(7000 + (i % 12) + 1),
      token: market.token,
      symbol,
      fulfilled: true,
      word,
      multiplier: mult,
      basePoints: pts(base),
      bonusPoints: pts(base * (mult - 1)),
      at: now() - minutesAgo * 60,
    };
  }),
];

// ---------------------------------------------------------------------------
// Live-feel tickers (advance small state each poll)
// ---------------------------------------------------------------------------

let potDrift = 0n;
let lastPotTick = 0;

/** Jackpot pot climbs a few cents to a few USDG per tick: fees keep landing. */
export function tickPot(): bigint {
  const t = Date.now();
  if (t - lastPotTick > 1_800) {
    lastPotTick = t;
    potDrift += BigInt(120_000 + Math.floor(Math.random() * 2_400_000)); // 0.12 to 2.52 USDG
  }
  return mockJackpot.pot + potDrift;
}

const priceDrift = new Map<string, number>();

/** Prices wiggle within roughly +-0.6% around the seed so PnL feels alive. */
export function tickPrice(symbol: string, base1e18: bigint): bigint {
  const prev = priceDrift.get(symbol) ?? 0;
  const next = Math.max(-0.02, Math.min(0.02, prev + (Math.random() - 0.5) * 0.0035));
  priceDrift.set(symbol, next);
  return base1e18 + (base1e18 * BigInt(Math.round(next * 1e6))) / 1_000_000n;
}

export const POINTS_DISCLAIMER =
  "Pit Points are a non-transferable activity ledger. They carry no monetary value, no redemption right, and no claim on any asset, revenue, or governance power.";

export { POINTS_ONE };
