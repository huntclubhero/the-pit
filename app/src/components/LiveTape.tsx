"use client";

import { useMarkets } from "@/hooks/useMarkets";
import { useLiquidations } from "@/hooks/usePerpPositions";
import { isMockMode } from "@/lib/config";
import { formatBpsPct, formatPrice, formatUsdgCompact } from "@/lib/format";
import type { LiquidationEvent, MarketSummary } from "@/lib/types";

/**
 * The live tape: a seamless glass marquee across the top of the terminal.
 * Every listed mark with its 24h move, interleaved with the freshest
 * liquidations, drifting right to left like a desk feed. Hover pauses it.
 * The track holds two identical copies and translates -50% (transform only);
 * reduced-motion users get a static strip via the global animation kill.
 */
export function LiveTape() {
  const { data: markets } = useMarkets();
  const { data: liquidations } = useLiquidations();

  if (!markets || markets.length === 0) return null;

  const liqs = (liquidations ?? []).slice(0, 3);

  return (
    <div className="tape border-b border-line bg-pit-1 py-1.5">
      <div className="tape-track" suppressHydrationWarning>
        <TapeGroup markets={markets} liqs={liqs} />
        <TapeGroup markets={markets} liqs={liqs} ariaHidden />
      </div>
      <div className="tape-cap">
        <span className="pulse-dot inline-block h-1.5 w-1.5 rounded-full bg-amber" aria-hidden />
        <span className="font-mono text-[9px] uppercase tracking-[0.2em] text-ink-dim">
          {isMockMode ? "Tape: SIM" : "Tape: live"}
        </span>
      </div>
    </div>
  );
}

function TapeGroup({
  markets,
  liqs,
  ariaHidden,
}: {
  markets: MarketSummary[];
  liqs: LiquidationEvent[];
  ariaHidden?: boolean;
}) {
  // Weave a liquidation entry in after every fourth market so the feed reads
  // as one desk stream, not two lists.
  const items: React.ReactNode[] = [];
  let liqIndex = 0;
  markets.forEach((m, i) => {
    items.push(<MarkItem key={`m-${m.address}`} market={m} />);
    if ((i + 1) % 4 === 0 && liqIndex < liqs.length) {
      items.push(<LiqItem key={`l-${liqs[liqIndex].id}`} event={liqs[liqIndex]} />);
      liqIndex += 1;
    }
  });
  while (liqIndex < liqs.length) {
    items.push(<LiqItem key={`l-${liqs[liqIndex].id}`} event={liqs[liqIndex]} />);
    liqIndex += 1;
  }

  return (
    // The leading gap keeps the static (reduced-motion / first-paint) state
    // clear of the LIVE cap; both copies carry it so the -50% loop stays
    // seamless.
    <span className="inline-flex items-baseline pl-[112px] md:pl-[128px]" aria-hidden={ariaHidden}>
      {items}
    </span>
  );
}

function Sep() {
  return (
    <span
      className="mx-4 inline-block h-[3px] w-[3px] translate-y-[-2px] rounded-full bg-[rgba(255,255,255,0.18)]"
      aria-hidden
    />
  );
}

function MarkItem({ market: m }: { market: MarketSummary }) {
  return (
    <span className="inline-flex items-baseline gap-2 text-[11px]">
      <span className="display tracking-[0.02em] text-ink">{m.symbol}</span>
      <span className="num text-ink-dim">{formatPrice(m.price1e18)}</span>
      <span className={`num ${m.change24hBps >= 0 ? "text-felt-bright" : "text-loss"}`}>
        {formatBpsPct(m.change24hBps)}
      </span>
      <Sep />
    </span>
  );
}

function LiqItem({ event: e }: { event: LiquidationEvent }) {
  return (
    <span className="inline-flex items-baseline gap-2 text-[11px]">
      <span className="font-mono text-[9px] uppercase tracking-[0.14em] text-loss">liq</span>
      <span className="display tracking-[0.02em] text-ink-dim">{e.symbol}</span>
      <span
        className={`font-mono text-[9px] uppercase tracking-[0.1em] ${
          e.side === "long" ? "text-felt-bright" : "text-loss"
        }`}
      >
        {e.side}
      </span>
      <span className="num text-loss">{formatUsdgCompact(e.notional)}</span>
      <Sep />
    </span>
  );
}
