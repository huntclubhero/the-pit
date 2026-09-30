"use client";

import Link from "next/link";
import { useMemo } from "react";
import { Odometer } from "@/components/Odometer";
import { SimTag } from "@/components/SimTag";
import { PositionsPanel } from "@/components/market/PositionsPanel";
import { useViewerAddress } from "@/components/ConnectButton";
import { useMarkets } from "@/hooks/useMarkets";
import { useAllPositions } from "@/hooks/usePerpPositions";
import { useTradeHistory } from "@/hooks/usePortfolio";
import { useVault } from "@/hooks/useVault";
import { explorerTxUrl } from "@/lib/chain";
import {
  formatPoints,
  formatPrice,
  formatSignedUsdg,
  formatUsdg,
} from "@/lib/format";
import { PRICE_SCALE, clampPnl, formatLeverageX100, uPnlUsdg } from "@/lib/perp";

export default function PortfolioPage() {
  const viewer = useViewerAddress();
  const { data: markets } = useMarkets();
  const { data: positions } = useAllPositions();
  const { data: history } = useTradeHistory(viewer);
  const { data: vault } = useVault();

  const priceBySymbol = useMemo(() => {
    const map = new Map<string, bigint>();
    markets?.forEach((m) => map.set(m.symbol, m.price1e18));
    return map;
  }, [markets]);

  const totals = useMemo(() => {
    let marginAtRisk = 0n;
    let livePnl = 0n;
    positions?.forEach((p) => {
      marginAtRisk += p.margin;
      const mark = priceBySymbol.get(p.symbol);
      if (mark) {
        const pnl = clampPnl(
          uPnlUsdg(p.size1e18, p.entryPrice1e18, mark, p.side === "long"),
          p.margin,
          p.maxPayout,
        );
        livePnl += pnl - p.fundingAccrued - p.borrowAccrued;
      }
    });
    return { marginAtRisk, livePnl };
  }, [positions, priceBySymbol]);

  const plpValue =
    vault && vault.totalShares > 0n
      ? (vault.yourShares * vault.sharePrice1e18) / PRICE_SCALE
      : 0n;

  return (
    <div className="px-4 md:px-6 py-6 flex flex-col gap-6">
      {/* Summary band */}
      <section className="grid grid-cols-2 md:grid-cols-4 gap-px bg-line border border-line rounded-2xl overflow-hidden rise-in">
        <SummaryCell label="Open positions" value={String(positions?.length ?? 0)} />
        <SummaryCell label="Margin at risk (USDG)" value={formatUsdg(totals.marginAtRisk)} />
        <SummaryCell
          label="Live PnL, funding incl (USDG)"
          value={formatSignedUsdg(totals.livePnl)}
          tone={totals.livePnl >= 0n ? "win" : "loss"}
          odometer
          sim
        />
        <SummaryCell
          label="PLP vault value (USDG)"
          value={formatUsdg(plpValue)}
          href="/vault"
          sim
        />
      </section>

      {/* Open positions with the full danger UX */}
      <div className="rise-in rise-in-1">
        {(positions?.length ?? 0) === 0 ? (
          <div className="panel">
            <div className="panel-head">
              <span>Open Positions</span>
            </div>
            <p className="p-6 text-center text-sm text-ink-faint font-mono">
              Nothing at risk.{" "}
              <Link href="/" className="text-amber hover:text-amber-hot">
                Pick a market.
              </Link>
            </p>
          </div>
        ) : (
          <PositionsPanel
            positions={positions ?? []}
            markets={markets ?? []}
            title="Open Positions"
          />
        )}
      </div>

      {/* Trade history */}
      <section className="panel rise-in rise-in-2">
        <div className="panel-head">
          <span>Trade History</span>
          <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
            exact fee + funding breakdowns, straight from the engine events
          </span>
        </div>
        <div className="table-scroll">
          <table className="data-table">
            <thead>
              <tr>
                <th>Market</th>
                <th>Side</th>
                <th>Lev</th>
                <th>Result</th>
                <th>Entry</th>
                <th>Exit</th>
                <th>PnL</th>
                <th>Funding</th>
                <th>Fee</th>
                <th>Payout</th>
                <th>Points</th>
                <th>Tx</th>
              </tr>
            </thead>
            <tbody>
              {history?.map((h) => (
                <tr key={h.id}>
                  <td>
                    <span className="display text-lg tracking-[0.04em] text-ink">{h.symbol}</span>
                    <span className="ml-2 font-mono text-[10px] text-ink-faint">#{h.id}</span>
                  </td>
                  <td>
                    <span
                      className={`display text-[14px] tracking-[0.08em] uppercase ${
                        h.side === "long" ? "text-felt-bright" : "text-loss"
                      }`}
                    >
                      {h.side}
                    </span>
                  </td>
                  <td className="num text-amber">{formatLeverageX100(h.leverageX100)}</td>
                  <td>
                    <ResultBadge result={h.result} />
                  </td>
                  <td className="num text-ink-dim">{formatPrice(h.entryPrice1e18)}</td>
                  <td className="num text-ink-dim">{formatPrice(h.exitPrice1e18)}</td>
                  <td className={`num ${h.pnl >= 0n ? "text-felt-bright" : "text-loss"}`}>
                    {formatSignedUsdg(h.pnl)}
                  </td>
                  <td className={`num ${h.fundingPaid > 0n ? "text-loss" : "text-felt-bright"}`}>
                    {h.fundingPaid === 0n ? "0.00" : formatSignedUsdg(-h.fundingPaid)}
                  </td>
                  <td className="num text-ink-dim">
                    {h.fee > 0n ? `-${formatUsdg(h.fee)}` : "0.00"}
                  </td>
                  <td className="num text-ink">{formatUsdg(h.payout)}</td>
                  <td className="num text-amber">+{formatPoints(h.pointsEarned, 1)}</td>
                  <td>
                    <a
                      href={explorerTxUrl(h.txHash)}
                      target="_blank"
                      rel="noreferrer"
                      className="font-mono text-[10px] text-ink-faint hover:text-amber transition-colors"
                    >
                      {h.txHash.slice(0, 10)}..
                    </a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="px-4 py-3 border-t border-line font-mono text-[10px] leading-relaxed text-ink-faint">
          Liquidations pay a 1% penalty (keeper 20%, vault 40%, insurance fund 40%) and any residual equity
          comes BACK to you: the engine never vaporizes a position past the maintenance line.
          Profit clamps at 9x margin; loss clamps at your margin, always. Losses earn a 25%
          points rebate: the house tips the fallen.
        </p>
      </section>
    </div>
  );
}

function SummaryCell({
  label,
  value,
  tone,
  odometer,
  href,
  sim,
}: {
  label: string;
  value: string;
  tone?: "win" | "loss";
  odometer?: boolean;
  href?: string;
  sim?: boolean;
}) {
  const color =
    tone === "win" ? "text-felt-bright" : tone === "loss" ? "text-loss" : "text-ink";
  const body = (
    <div
      className={`bg-pit-2 p-4 h-full ${
        href ? "transition-colors duration-[120ms] hover:bg-pit-3" : ""
      }`}
    >
      <div className="font-mono text-[10px] uppercase tracking-[0.16em] text-ink-faint">
        {label} {sim && <SimTag />}
      </div>
      <div className={`num text-2xl mt-1 ${color}`}>
        {odometer ? <Odometer value={value} /> : value}
      </div>
    </div>
  );
  return href ? <Link href={href}>{body}</Link> : body;
}

function ResultBadge({ result }: { result: "closed" | "reduced" | "liquidated" }) {
  const styles = {
    closed: "text-felt-bright border-felt",
    reduced: "text-ink-dim",
    liquidated: "text-loss border-loss-deep",
  } as const;
  return <span className={`chip ${styles[result]}`}>{result}</span>;
}
