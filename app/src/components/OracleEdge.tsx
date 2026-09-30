"use client";

import { useEffect, useRef, useState } from "react";
import { compactNumber } from "@/lib/format";
import type { MarketSummary } from "@/lib/types";
import { SimTag } from "./SimTag";

/**
 * One-shot in-view trigger so the bars rise from the baseline the first time
 * the chart is actually seen (not at hydration, hidden below the fold).
 */
function useInViewOnce<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  const [seen, setSeen] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (typeof IntersectionObserver === "undefined") {
      setSeen(true);
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          setSeen(true);
          io.disconnect();
        }
      },
      { threshold: 0.25 },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);
  return { ref, seen };
}

/**
 * The one chart that explains the whole security model: what it costs to push
 * a market's price to the payout trigger (tall bar) against the most the vault
 * can ever pay that market's traders combined (short bar). The cap is set at
 * or below the cost, so manipulation is a guaranteed loss before fees, and
 * strictly negative after round-trip slippage, fees, and the cooldown breaker.
 */
export function OracleEdgeShowcase({ market }: { market: MarketSummary }) {
  const { ref, seen } = useInViewOnce<HTMLDivElement>();
  const cost = market.costToMoveUsd;
  const cap = Number(market.reserveCap) / 1e6;
  if (!Number.isFinite(cost) || cost <= 0) return null;
  const capPct = Math.max(6, Math.min(100, (cap / cost) * 100));
  const shortfall = cost - cap;

  return (
    <div className="panel overflow-hidden" ref={ref}>
      <div className="panel-head">
        <span>Why pumping the oracle loses money</span>
        <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
          {market.symbol} : {market.oracleKind.toLowerCase()}
        </span>
      </div>
      <div className="p-5">
        <div className="flex gap-6 sm:gap-10">
          <Bar
            heightPct={100}
            color="var(--color-loss)"
            tint="rgba(229, 96, 94, 0.14)"
            amount={cost}
            label="cost to push the price to the payout trigger"
            grown={seen}
            delayMs={0}
          />
          <Bar
            heightPct={capPct}
            color="var(--color-amber)"
            tint="rgba(237, 162, 59, 0.14)"
            amount={cap}
            label="max the vault can ever pay this market, all positions combined"
            grown={seen}
            delayMs={140}
          />
        </div>
        <div className="mt-4 flex flex-wrap items-baseline gap-x-4 gap-y-1.5">
          <span className="font-mono text-[11px] text-loss">
            attacker&apos;s best case: {shortfall > 0 ? `-$${compactNumber(shortfall)}` : "$0"} before fees
          </span>
          <SimTag />
        </div>
        <p className="mt-2 max-w-xl text-[13px] leading-relaxed text-ink-dim">
          Moving the price costs more than you could ever win. That is the whole game.
          Every market&apos;s total payout capacity is hard-capped below the cost of moving
          its oracle, and the attacker still pays round-trip slippage, fees, and eats the
          cooldown breaker on outlier prints.
        </p>
      </div>
    </div>
  );
}

function Bar({
  heightPct,
  color,
  tint,
  amount,
  label,
  grown,
  delayMs,
}: {
  heightPct: number;
  color: string;
  tint: string;
  amount: number;
  label: string;
  /** Rises from the baseline once the chart scrolls into view. */
  grown: boolean;
  delayMs: number;
}) {
  return (
    <div className="flex flex-1 flex-col min-w-0">
      {/* Fixed-height track so the two bars scale true to their numbers. */}
      <div className="h-[170px] md:h-[210px] flex flex-col justify-end">
        <div
          className="num text-lg md:text-xl mb-1.5"
          style={{
            color,
            opacity: grown ? 1 : 0,
            transition: `opacity 480ms var(--ease-snap) ${delayMs + 320}ms`,
          }}
        >
          ${compactNumber(amount)}
        </div>
        <div
          className="w-full rounded-t-xl border border-b-0"
          style={{
            height: `${heightPct * 0.82}%`,
            background: `linear-gradient(180deg, ${tint}, transparent)`,
            borderColor: color,
            boxShadow: `inset 0 1px 0 rgba(255,255,255,0.1), 0 0 32px -18px ${color}`,
            transform: grown ? "scaleY(1)" : "scaleY(0.02)",
            transformOrigin: "bottom",
            transition: `transform 850ms var(--ease-snap) ${delayMs}ms`,
          }}
        />
      </div>
      <div className="border-t pt-1.5 font-mono text-[9px] uppercase tracking-[0.1em] leading-relaxed text-ink-faint" style={{ borderColor: "var(--color-line-2)" }}>
        {label}
      </div>
    </div>
  );
}

/**
 * Compact strip version for the trade terminal's funding / market-info panel.
 * Horizontal bars, same inequality, per-market numbers.
 */
export function OracleEdgeCompact({ market }: { market: MarketSummary }) {
  const cost = market.costToMoveUsd;
  const cap = Number(market.reserveCap) / 1e6;

  if (!Number.isFinite(cost)) {
    return (
      <p className="font-mono text-[10px] leading-relaxed text-ink-faint">
        <span className="text-tier-a uppercase tracking-[0.1em]">Manipulation math:</span>{" "}
        {market.symbol} prices off an independent Chainlink feed. There is no pool to push,
        and payouts stay capped at 10% of vault TVL regardless.
      </p>
    );
  }

  const capPct = Math.max(4, Math.min(100, (cap / cost) * 100));
  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-baseline justify-between font-mono text-[10px] uppercase tracking-[0.12em]">
        <span className="text-ink-faint">Manipulation math</span>
        <span className="text-ink-faint normal-case tracking-normal">
          cost to move vs max payout
        </span>
      </div>
      <MiniBar
        pct={100}
        color="var(--color-loss)"
        label="cost to push the price to the trigger"
        value={`$${compactNumber(cost)}`}
      />
      <MiniBar
        pct={capPct}
        color="var(--color-amber)"
        label="max the vault can ever pay here"
        value={`$${compactNumber(cap)}`}
      />
      <p className="font-mono text-[10px] leading-relaxed text-ink-faint">
        {cap >= cost * 0.98
          ? "The payout cap sits pinned at the cost bound: an attacker breaks even at best before fees, and round-trip slippage, fees, and the cooldown breaker make it strictly negative."
          : "Moving the price costs more than you could ever win, before fees and slippage even start counting. That is the whole game."}
      </p>
    </div>
  );
}

function MiniBar({
  pct,
  color,
  label,
  value,
}: {
  pct: number;
  color: string;
  label: string;
  value: string;
}) {
  return (
    <div className="flex items-center gap-2">
      <div className="h-2 flex-1 rounded-full bg-pit-2 overflow-hidden">
        <div
          className="h-full rounded-full transition-[width] duration-[600ms]"
          style={{ width: `${pct}%`, background: color, opacity: 0.75 }}
        />
      </div>
      <span className="num text-[11px] w-[64px] text-right" style={{ color }}>
        {value}
      </span>
      <span className="hidden md:inline font-mono text-[9px] text-ink-faint w-[190px]">
        {label}
      </span>
    </div>
  );
}
