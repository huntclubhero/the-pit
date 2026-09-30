"use client";

import { useState } from "react";
import { CreateMarketDialog } from "./CreateMarketDialog";
import { Odometer } from "./Odometer";
import { OracleChip } from "./OracleChip";
import { TierBadge } from "./TierBadge";
import { LeverageBadge } from "./LeverageBadge";
import { LiquidationsFeed } from "./LiquidationsFeed";
import { MarketSelector } from "./MarketSelector";
import { SimTag } from "./SimTag";
import { FundingPanel } from "./market/FundingPanel";
import { PositionsPanel } from "./market/PositionsPanel";
import { Ticket } from "./market/Ticket";
import { useViewerAddress } from "./ConnectButton";
import { useMarkets } from "@/hooks/useMarkets";
import { useLiquidations, useMarketPositions } from "@/hooks/usePerpPositions";
import { usePointsProfile } from "@/hooks/usePoints";
import { isMockMode } from "@/lib/config";
import { explorerAddressUrl } from "@/lib/chain";
import { formatBpsPct, formatPrice, formatUsdgCompact } from "@/lib/format";
import { formatRatePerHour } from "@/lib/perp";
import type { MarketSummary } from "@/lib/types";

/**
 * The full trading terminal for one market: header band with the market
 * switcher, chart, the ticket, funding/OI/oracle, your positions, and the
 * liquidations feed. Root renders this directly (Hyperliquid style); the
 * /market/[address] deep link renders the same terminal.
 */
export function TradeTerminal({
  market,
  onSelectMarket,
}: {
  market: MarketSummary;
  onSelectMarket: (market: MarketSummary) => void;
}) {
  const viewer = useViewerAddress();
  const { data: markets } = useMarkets();
  const { data: positions } = useMarketPositions(market.address);
  const { data: liquidations } = useLiquidations();
  const { data: profile } = usePointsProfile(viewer);
  const [showCreate, setShowCreate] = useState(false);

  const rate = market.fundingRatePerHour1e18;

  return (
    <div>
      {/* Market header band */}
      <section className="border-b border-line bg-pit-1 px-4 md:px-6 py-4">
        <div className="flex flex-wrap items-end gap-x-8 gap-y-3">
          <div>
            <div className="flex items-center gap-3">
              <MarketSelector
                markets={markets ?? [market]}
                current={market}
                onSelect={onSelectMarket}
                onRequestListing={() => setShowCreate(true)}
              />
              <TierBadge
                tier={market.tier}
                oracleKind={market.oracleKind}
                costToMoveUsd={market.costToMoveUsd}
              />
              <LeverageBadge market={market} />
              <span className="hidden md:inline text-sm text-ink-faint">{market.name}</span>
            </div>
            <a
              href={explorerAddressUrl(market.token)}
              target="_blank"
              rel="noreferrer"
              className="mt-1 inline-block font-mono text-[10px] text-ink-faint hover:text-amber transition-colors"
            >
              {market.token}
            </a>
          </div>
          <div>
            <div className="font-mono text-[10px] uppercase tracking-[0.16em] text-ink-faint">
              Mark (USDG) <SimTag />
            </div>
            <div className="num text-3xl text-ink">
              <Odometer value={formatPrice(market.price1e18)} />
            </div>
          </div>
          <div>
            <div className="font-mono text-[10px] uppercase tracking-[0.16em] text-ink-faint">
              24h
            </div>
            <div
              className={`num text-xl ${
                market.change24hBps >= 0 ? "text-felt-bright" : "text-loss"
              }`}
            >
              <Odometer value={formatBpsPct(market.change24hBps)} />
            </div>
          </div>
          <div>
            <div className="font-mono text-[10px] uppercase tracking-[0.16em] text-ink-faint">
              Funding /h
            </div>
            <div
              className={`num text-xl ${
                rate > 0n ? "text-loss" : rate < 0n ? "text-felt-bright" : "text-ink-dim"
              }`}
              title={rate > 0n ? "longs pay shorts" : rate < 0n ? "shorts pay longs" : "balanced"}
            >
              <Odometer value={formatRatePerHour(rate)} />
            </div>
          </div>
          <Stat label="OI Long" value={formatUsdgCompact(market.oiLong)} />
          <Stat label="OI Short" value={formatUsdgCompact(market.oiShort)} />
          <div className="ml-auto">
            <OracleChip
              status={market.oracleStatus}
              cooldownRemaining={market.cooldownRemaining}
            />
          </div>
        </div>
      </section>

      {/* Trading grid */}
      {/* On phones the ticket leads (the action is the page); on xl it docks
          sticky to the right rail beside the data column. */}
      <section className="px-4 md:px-6 py-6 grid grid-cols-1 xl:grid-cols-[1fr_400px] gap-5">
        <div className="order-2 xl:order-1 flex flex-col gap-5 min-w-0">
          <PriceChart token={market.token} symbol={market.symbol} />
          <FundingPanel market={market} />
          <PositionsPanel
            positions={positions ?? []}
            markets={markets ?? [market]}
          />
          <LiquidationsFeed
            events={liquidations ?? []}
            limit={5}
            symbolFilter={market.symbol}
          />
        </div>
        <div className="order-1 xl:order-2 min-w-0">
          <div className="xl:sticky xl:top-16">
            <Ticket market={market} profile={profile} />
          </div>
        </div>
      </section>

      {showCreate && <CreateMarketDialog onClose={() => setShowCreate(false)} />}
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="font-mono text-[10px] uppercase tracking-[0.16em] text-ink-faint">
        {label}
      </div>
      <div className="num text-xl text-ink">
        <Odometer value={value} />
      </div>
    </div>
  );
}

/**
 * Price chart panel, wired for the DexScreener embed. In mock mode (or until
 * DexScreener indexes the pair) it renders the designed placeholder frame.
 */
function PriceChart({ token, symbol }: { token: string; symbol: string }) {
  const embedUrl = `https://dexscreener.com/robinhoodchain/${token}?embed=1&theme=dark&info=0`;
  return (
    <div className="panel overflow-hidden">
      <div className="panel-head">
        <span>{symbol} / USDG</span>
        <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
          chart: DexScreener
        </span>
      </div>
      {isMockMode ? (
        <div className="h-[280px] md:h-[340px] relative flex items-center justify-center bg-pit-1">
          <ChartGrid />
          <div className="relative text-center">
            <div className="display text-xl tracking-[0.02em] text-ink-faint uppercase">
              DexScreener embed
            </div>
            <div className="font-mono text-[10px] text-ink-faint mt-1">
              simulated frame: connects automatically when contract addresses are set
            </div>
          </div>
        </div>
      ) : (
        <iframe
          src={embedUrl}
          title={`${symbol} price chart`}
          className="w-full h-[280px] md:h-[340px] border-0"
        />
      )}
    </div>
  );
}

function ChartGrid() {
  return (
    <svg className="absolute inset-0 w-full h-full opacity-40" aria-hidden>
      <defs>
        <pattern id="grid" width="48" height="48" patternUnits="userSpaceOnUse">
          <path
            d="M 48 0 L 0 0 0 48"
            fill="none"
            stroke="var(--color-line)"
            strokeWidth="1"
          />
        </pattern>
      </defs>
      <rect width="100%" height="100%" fill="url(#grid)" />
    </svg>
  );
}
