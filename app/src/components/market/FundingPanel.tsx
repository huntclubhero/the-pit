"use client";

import { formatUsdg, formatUsdgCompact } from "@/lib/format";
import { annualizedPct, formatRatePerHour } from "@/lib/perp";
import type { MarketSummary } from "@/lib/types";
import { Odometer } from "../Odometer";
import { OracleEdgeCompact } from "../OracleEdge";

/**
 * Funding + open-interest panel: the skew bar (who is crowded), the live
 * skew-based funding rate (crowded side pays), the borrow rate, and how much
 * of the market's capped vault reserve is in use. Transparency is the product.
 */
export function FundingPanel({ market }: { market: MarketSummary }) {
  const oiTotal = market.oiLong + market.oiShort;
  const longPct = oiTotal === 0n ? 50 : Number((market.oiLong * 10_000n) / oiTotal) / 100;
  const rate = market.fundingRatePerHour1e18;
  const longsPay = rate > 0n;
  const capUsedPct =
    market.reserveCap === 0n
      ? 0
      : Math.min(100, Number((market.reserved * 10_000n) / market.reserveCap) / 100);

  return (
    <div className="panel">
      <div className="panel-head">
        <span>Funding + Open Interest</span>
        <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
          skew-based: the crowded side pays
        </span>
      </div>
      <div className="p-4 grid grid-cols-1 md:grid-cols-3 gap-5">
        {/* Skew */}
        <div className="flex flex-col gap-2">
          <div className="flex items-baseline justify-between font-mono text-[10px] uppercase tracking-[0.14em]">
            <span className="text-felt-bright">Long {formatUsdgCompact(market.oiLong)}</span>
            <span className="text-loss">Short {formatUsdgCompact(market.oiShort)}</span>
          </div>
          <div className="skew-track" role="img" aria-label={`Open interest skew: ${longPct.toFixed(1)}% long`}>
            <div className="skew-long" style={{ width: `${longPct}%` }} />
            <div className="skew-short" style={{ width: `${100 - longPct}%` }} />
          </div>
          <p className="font-mono text-[10px] leading-relaxed text-ink-faint">
            {longPct.toFixed(1)}% of open interest is long. The vault carries the net side; skew
            funding taxes the crowd until the book rebalances.
          </p>
        </div>

        {/* Funding rate */}
        <div className="flex flex-col gap-1">
          <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">
            Funding rate (per hour)
          </span>
          <span className={`num text-2xl ${longsPay ? "text-loss" : rate < 0n ? "text-felt-bright" : "text-ink-dim"}`}>
            <Odometer value={formatRatePerHour(rate)} />
          </span>
          <span className="font-mono text-[10px] text-ink-dim">
            {rate === 0n
              ? "balanced book: nobody pays"
              : longsPay
                ? `longs pay shorts (~${annualizedPct(rate).toFixed(1)}% annualized)`
                : `shorts pay longs (~${Math.abs(annualizedPct(rate)).toFixed(1)}% annualized)`}
          </span>
          <span className="font-mono text-[10px] text-ink-faint mt-1">
            borrow {formatRatePerHour(market.borrowRatePerHour1e18, 5)} : both sides pay the
            vault, and the rate scales up with realized vol
          </span>
        </div>

        {/* Reserve cap */}
        <div className="flex flex-col gap-2">
          <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">
            Market reserve cap
          </span>
          <div className="util-track">
            <div className="util-fill" style={{ width: `${capUsedPct}%` }} />
          </div>
          <span className="num text-[13px] text-ink">
            {formatUsdg(market.reserved, 0)} / {formatUsdg(market.reserveCap, 0)} USDG
          </span>
          <p className="font-mono text-[10px] leading-relaxed text-ink-faint">
            The sum of every position&apos;s max payout here can never exceed{" "}
            {Number.isFinite(market.costToMoveUsd)
              ? "the cost of moving this token's price (or 10% of vault TVL, whichever is lower)"
              : "10% of vault TVL"}
            . Pumping the oracle costs more than it could ever extract.
          </p>
        </div>
      </div>

      {/* The manipulation inequality, drawn */}
      <div className="border-t border-line px-4 py-3.5">
        <OracleEdgeCompact market={market} />
      </div>
    </div>
  );
}
