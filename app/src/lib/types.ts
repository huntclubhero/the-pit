/** Shared view-model types consumed by hooks and components. */

export type Side = "long" | "short";
export type OracleStatus = "OK" | "COOLDOWN" | "STALE" | "UNAVAILABLE";

/**
 * Oracle listing tier keyed on price-source quality:
 *   A majors, priced by an independent feed (Chainlink), no cost-to-move bound
 *   B deep memecoins, aggregated cross-pool TWAP, cost-to-move gated
 *   C mid memecoins, single-pool TWAP, tighter caps
 *   D not listable: too thin or too few sources to price safely (never leveraged)
 */
export type MarketTier = "A" | "B" | "C" | "D";

export interface MarketSummary {
  /** Market key: the underlying token address (PerpEngine markets key on token). */
  address: string;
  /** Underlying token address (same as `address`; kept for explorer links). */
  token: string;
  symbol: string;
  name: string;
  /** Oracle listing tier (price-source quality). */
  tier: MarketTier;
  /** Human oracle description, e.g. "Chainlink feed" or "Aggregated 3-pool TWAP". */
  oracleKind: string;
  /** True for Tier A majors (PerpRiskConfig token override: 5 bps fees, tighter MMR). */
  isMajor: boolean;
  /** Mcap tier index 0..5 (the LOCKED leverage schedule). */
  mcapTier: number;
  /** Live FDV in USD (drives the mcap tier). */
  fdvUsd: number;
  /** Max leverage for this market, x100 (e.g. 600 = 6x). */
  maxLeverageX100: number;
  /** Maintenance margin ratio, bps of notional. */
  mmrBps: number;
  /** Open/close fee, bps of notional. */
  openFeeBps: number;
  closeFeeBps: number;
  /** Approximate USDG cost to move the price enough to drain the market reserve cap. */
  costToMoveUsd: number;
  /** Mark price (the oracle router composite), 1e18. */
  price1e18: bigint;
  /** 24h move in signed basis points. */
  change24hBps: number;
  /** Open interest by side, USDG notional at mark. */
  oiLong: bigint;
  oiShort: bigint;
  /** Per-market reserve cap: min(cost-to-move bound, 10% of vault TVL), USDG. */
  reserveCap: bigint;
  /** Sum of reserved max payouts currently held against this market, USDG. */
  reserved: bigint;
  /** Signed funding rate per hour, 1e18. Positive = longs pay shorts. */
  fundingRatePerHour1e18: bigint;
  /** Borrow rate per hour, 1e18, both sides pay the vault; scales with realized vol. */
  borrowRatePerHour1e18: bigint;
  /** Points minted from this market's activity in the last 24h, 1e18. */
  pointsEmission24h: bigint;
  oracleStatus: OracleStatus;
  /** Seconds until cooldown lifts, when status is COOLDOWN. */
  cooldownRemaining?: number;
}

/** An open leveraged position (isolated margin against the vault). */
export interface PerpPositionRow {
  /** Position key index for the UI (chain key is keccak(token, trader, isLong)). */
  id: number;
  /** Market token address. */
  marketAddress: string;
  symbol: string;
  side: Side;
  /** Isolated margin escrowed, USDG units (net of the open fee). */
  margin: bigint;
  /** Position size, base units 1e18. */
  size1e18: bigint;
  /** Entry mark, 1e18 (volume-weighted on increases). */
  entryPrice1e18: bigint;
  /** Leverage at open, x100 (display; effective leverage drifts with the mark). */
  leverageX100: number;
  /** Payout cap frozen at open/add: payoutCapMultiple x margin, USDG. */
  maxPayout: bigint;
  /** Net funding accrued so far, signed USDG (positive = you owe). */
  fundingAccrued: bigint;
  /** Borrow fees accrued so far, USDG (always owed). */
  borrowAccrued: bigint;
  /** Unix seconds. */
  openedAt: number;
}

/** A settled trade (close, reduce, or liquidation) for the history table. */
export interface TradeRecord {
  id: number;
  symbol: string;
  side: Side;
  result: "closed" | "reduced" | "liquidated";
  margin: bigint;
  leverageX100: number;
  entryPrice1e18: bigint;
  exitPrice1e18: bigint;
  /** Realized clamped PnL, signed USDG. */
  pnl: bigint;
  /** Close fee paid (or liquidation penalty for liquidations). */
  fee: bigint;
  /** Net funding + borrow paid over the position's life, signed USDG. */
  fundingPaid: bigint;
  /** What returned to the wallet. */
  payout: bigint;
  /** Points earned on this trade's fees, 1e18. */
  pointsEarned: bigint;
  settledAt: number;
  txHash: string;
}

/** One liquidation event for the public feed. */
export interface LiquidationEvent {
  id: number;
  symbol: string;
  side: Side;
  /** Liquidated notional, USDG. */
  notional: bigint;
  /** Margin wiped or residual returned context. */
  margin: bigint;
  /** The mark it liquidated at, 1e18. */
  price1e18: bigint;
  /** Penalty collected (keeper 20% / vault 40% / insurance fund 40%). */
  penalty: bigint;
  /** Unix seconds. */
  at: number;
  /** Short address of the liquidated trader. */
  trader: string;
}

// ---------------------------------------------------------------------------
// Vault (PitVault / PLP)
// ---------------------------------------------------------------------------

export interface VaultWithdrawRequest {
  /** PLP shares locked in the queue. */
  shares: bigint;
  /** Epoch the request settles at (priced at that epoch's NAV). */
  epoch: number;
  /** Unix seconds when the epoch settles and claim opens. */
  claimableAt: number;
}

export interface VaultState {
  /** NAV: totalAssets in USDG units. */
  totalAssets: bigint;
  /** Total PLP supply, 6-decimal share units. */
  totalShares: bigint;
  /** PLP share price, 1e18 fixed point (assets per share). */
  sharePrice1e18: bigint;
  /** Sum of reserved max payouts across all markets, USDG. */
  totalReserved: bigint;
  /** Aggregate trader unrealized PnL marked against the vault, signed USDG. */
  aggTraderUpnl: bigint;
  /** Your PLP balance, share units. */
  yourShares: bigint;
  /** Your pending withdraw request, if any. */
  yourRequest?: VaultWithdrawRequest;
  /** USDG already crystallized and claimable. */
  yourClaimable: bigint;
  /** Trailing-30d annualized yield components, percent floats (display only). */
  apr: {
    /** Net trader losses: the counterparty edge. */
    traderLosses: number;
    /** Skew-funding residual on the vault's net exposure. */
    fundingResidual: number;
    /** Vol-scaled borrow fees, both sides pay. */
    borrowFees: number;
    /** The 20% carve of every open/close fee, plus the open vol surcharge. */
    tradeFees: number;
    /** The 40% share of every liquidation penalty. */
    liqPenalties: number;
  };
  /** Unique depositor count. */
  depositors: number;
  /** Current 24h epoch index and when it rolls. */
  epoch: number;
  epochEndsAt: number;
  /** Recent vault flow events for the activity feed. */
  flows: VaultFlowEvent[];
}

export interface VaultFlowEvent {
  id: number;
  kind:
    | "deposit"
    | "withdraw-request"
    | "claim"
    | "trader-loss"
    | "trader-win"
    | "funding"
    | "borrow"
    | "fee-share"
    | "liq-penalty";
  /** USDG amount (or share count for withdraw-request). */
  amount: bigint;
  /** Counterparty short address or market symbol. */
  who: string;
  at: number;
}

// ---------------------------------------------------------------------------
// Points, jackpot, fairness (unchanged casino rails)
// ---------------------------------------------------------------------------

export interface RankTier {
  name: string;
  /** Lifetime points threshold, 1e18. */
  threshold: bigint;
}

export interface PointsProfile {
  lifetime: bigint;
  season: bigint;
  seasonEpoch: number;
  winStreak: number;
  shieldAvailable: boolean;
  /** Seconds until the shield refreshes, when consumed. */
  shieldRefreshIn?: number;
  dailyStreak: number;
  /** UTC day flags for the current calendar strip, oldest first. */
  dailyCalendar: boolean[];
  winMultiplier: bigint;
  dailyMultiplier: bigint;
  referralCode: string;
  referrals: number;
  referralPoints: bigint;
}

export interface LeaderboardEntry {
  rank: number;
  address: string;
  /** Display alias when known. */
  alias?: string;
  points: bigint;
  isYou?: boolean;
}

export interface DrawRecord {
  drawId: number;
  kind: "daily" | "weekly";
  mode: "entrants" | "weighted";
  winner: string;
  amount: bigint;
  word: bigint;
  requestId: bigint;
  epoch: number;
  completedAt: number;
  txHash: string;
}

export interface JackpotState {
  /** Current pot, native USDG units. */
  pot: bigint;
  /** Unix seconds of next daily mini-drop eligibility. */
  nextDailyAt: number;
  /** Unix seconds of next weekly Pit Drop eligibility. */
  nextWeeklyAt: number;
  /** Entrants in the accumulating Pit Drop round (100x spinners). */
  entrantCount: number;
  draws: DrawRecord[];
}

export interface SpinLedgerRow {
  requestId: bigint;
  user: string;
  token: string;
  symbol: string;
  fulfilled: boolean;
  word: bigint;
  multiplier: number;
  /** Spin base, 1e18 points. */
  basePoints: bigint;
  /** Minted bonus, 1e18 points. */
  bonusPoints: bigint;
  at: number;
}
