"use client";

import Link from "next/link";
import { useState } from "react";
import { Boot } from "@/components/Boot";
import { LiveTape } from "@/components/LiveTape";
import { TradeTerminal } from "@/components/TradeTerminal";
import { useMarkets } from "@/hooks/useMarkets";

/**
 * Root IS the trading terminal (Hyperliquid style). It opens straight into the
 * featured memecoin market; the switcher swaps markets in place, and
 * /market/[address] deep links land on the same terminal. The story lives at
 * /about, one click away, never in front of the trade.
 */
const DEFAULT_SYMBOL = "CASHCAT";

export default function TerminalPage() {
  const { data: markets, isLoading } = useMarkets();
  const [selected, setSelected] = useState<string | null>(null);

  const market =
    (selected
      ? markets?.find((m) => m.address.toLowerCase() === selected.toLowerCase())
      : undefined) ??
    markets?.find((m) => m.symbol === DEFAULT_SYMBOL) ??
    markets?.[0];

  return (
    <div>
      {/* Slim promise strip: the pitch in one line, the story one click away. */}
      <div className="border-b border-line bg-pit-1 px-4 md:px-6 py-2 flex flex-wrap items-baseline gap-x-4 gap-y-1">
        <span className="display text-[13px] uppercase tracking-[0.04em] text-ink">
          Long or short the memes nobody else will list.
        </span>
        <span className="hidden md:inline font-mono text-[10px] text-ink-faint">
          Up to 15x on Robinhood Chain. Isolated margin. Liquidations you can see coming.
        </span>
        <Link
          href="/about"
          className="ml-auto font-mono text-[10px] uppercase tracking-[0.1em] text-amber hover:text-amber-hot transition-colors"
        >
          How THE PIT works
        </Link>
      </div>

      {/* The live tape: every mark and the freshest liquidations, drifting
          across the top of the desk. */}
      <LiveTape />

      {market ? (
        <TradeTerminal
          market={market}
          onSelectMarket={(m) => setSelected(m.address)}
        />
      ) : isLoading ? (
        <Boot label="Opening the terminal" />
      ) : (
        <div className="p-10 text-center font-mono text-ink-faint">
          No markets listed yet.
        </div>
      )}
    </div>
  );
}
