"use client";

import { useState } from "react";
import { type Address } from "viem";
import { useWriteContract } from "wagmi";
import { perpEngineAbi } from "@/lib/contracts";
import { addresses, isMockMode } from "@/lib/config";
import {
  formatPrice,
  formatSignedUsdg,
  formatUsdg,
  parseUsdg,
} from "@/lib/format";
import {
  clampPnl,
  dangerLevel,
  effectiveLeverage,
  equityUsdg,
  formatLeverageX100,
  liqDanger,
  liquidationPrice1e18,
  notionalUsdg,
  previewClose,
  tierParams,
  uPnlUsdg,
  type DangerLevel,
} from "@/lib/perp";
import type { MarketSummary, PerpPositionRow } from "@/lib/types";
import { Odometer } from "../Odometer";
import { DangerBar } from "../DangerBar";
import { BigWinCeremony } from "../BigWinCeremony";
import { SimTag } from "../SimTag";
import { usePerpDemoActions } from "@/hooks/usePerpPositions";

/**
 * Open perp positions with live clamped PnL, the exact liquidation price, a
 * filling distance-to-liquidation bar, accrued funding, ADD MARGIN, and close.
 *
 * The warning ladder (the point of this product): within 50% of the distance
 * to liquidation the row warns softly; at 75% it warns LOUDLY and the Add
 * Margin button lights up amber and pulses. You can see the liquidation
 * coming, and you can buy it off.
 */
export function PositionsPanel({
  positions,
  markets,
  title = "Your Positions",
}: {
  positions: PerpPositionRow[];
  markets: MarketSummary[];
  title?: string;
}) {
  const demo = usePerpDemoActions();
  const { writeContract, isPending } = useWriteContract();
  const [win, setWin] = useState<{
    profit: bigint;
    payout: bigint;
    stake: bigint;
    symbol: string;
    leverageLabel: string;
  } | null>(null);

  const marketBySymbol = new Map(markets.map((m) => [m.symbol, m]));

  if (positions.length === 0) {
    return (
      <div className="panel">
        <div className="panel-head">
          <span>{title}</span>
        </div>
        <p className="p-6 text-center text-sm text-ink-faint font-mono">
          No open positions. The ticket is right there.
        </p>
      </div>
    );
  }

  return (
    <div className="panel">
      {win && (
        <BigWinCeremony
          profit={win.profit}
          payout={win.payout}
          stake={win.stake}
          symbol={win.symbol}
          leverageLabel={win.leverageLabel}
          onDone={() => setWin(null)}
        />
      )}
      <div className="panel-head">
        <span className="flex items-center gap-2">
          {title}
          <SimTag />
        </span>
        <span className="num text-[11px] text-ink-faint">{positions.length} open</span>
      </div>
      <div className="flex flex-col divide-y divide-[var(--color-line)]">
        {positions.map((p) => {
          const market = marketBySymbol.get(p.symbol);
          if (!market) return null;
          return (
            <PositionCard
              key={p.id}
              position={p}
              market={market}
              busy={isPending}
              onClose={(mark, feeBps) => {
                if (isMockMode) {
                  const record = demo.close(p.id, mark, feeBps);
                  if (record && record.pnl > 0n && record.payout > record.margin) {
                    setWin({
                      profit: record.payout - record.margin,
                      payout: record.payout,
                      stake: record.margin,
                      symbol: record.symbol,
                      leverageLabel: `${formatLeverageX100(record.leverageX100)} ${record.side.toUpperCase()}`,
                    });
                  }
                } else {
                  writeContract({
                    address: addresses.engine as Address,
                    abi: perpEngineAbi,
                    functionName: "closePosition",
                    args: [p.marketAddress as Address, p.side === "long"],
                  });
                }
              }}
              onAddMargin={(amount) => {
                if (isMockMode) {
                  demo.addMargin(p.id, amount);
                } else {
                  writeContract({
                    address: addresses.engine as Address,
                    abi: perpEngineAbi,
                    functionName: "addMargin",
                    args: [p.marketAddress as Address, p.side === "long", amount],
                  });
                }
              }}
            />
          );
        })}
      </div>
    </div>
  );
}

function PositionCard({
  position: p,
  market,
  busy,
  onClose,
  onAddMargin,
}: {
  position: PerpPositionRow;
  market: MarketSummary;
  busy: boolean;
  onClose: (mark1e18: bigint, closeFeeBps: number) => void;
  onAddMargin: (amount: bigint) => void;
}) {
  const [addOpen, setAddOpen] = useState(false);
  const [addAmount, setAddAmount] = useState("250");

  const mark = market.price1e18;
  const params = tierParams(market.mcapTier, market.isMajor);
  const isLong = p.side === "long";
  const netOwed = p.fundingAccrued + p.borrowAccrued;
  const liq = liquidationPrice1e18(
    p.size1e18,
    p.entryPrice1e18,
    p.margin,
    netOwed,
    market.mmrBps,
    isLong,
  );
  const danger = liqDanger(p.entryPrice1e18, mark, liq, isLong);
  const level: DangerLevel = dangerLevel(danger);
  const pnl = clampPnl(uPnlUsdg(p.size1e18, p.entryPrice1e18, mark, isLong), p.margin, p.maxPayout);
  const equity = equityUsdg(p.margin, pnl, p.fundingAccrued, p.borrowAccrued);
  const notional = notionalUsdg(p.size1e18, mark);
  const effLev = effectiveLeverage(notional, equity);
  const closePrev = previewClose(
    p.size1e18,
    p.entryPrice1e18,
    mark,
    p.margin,
    p.maxPayout,
    isLong,
    p.fundingAccrued,
    p.borrowAccrued,
    market.closeFeeBps,
  );
  const distancePct =
    liq > 0n && mark > 0n ? (Number(liq - mark) / Number(mark)) * 100 : undefined;

  const wrapClass =
    level === "loud" || level === "liquidatable"
      ? "warn-loud"
      : level === "soft"
        ? "warn-soft"
        : "";

  const parsedAdd = parseUsdg(addAmount);

  return (
    <div className={`p-4 flex flex-col gap-3 ${wrapClass}`}>
      {/* Header row: side, leverage, symbol, PnL */}
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <span
          className={`display text-[15px] tracking-[0.08em] uppercase ${
            isLong ? "text-felt-bright" : "text-loss"
          }`}
        >
          {p.side}
        </span>
        <span className="chip text-amber border-amber-deep num">
          {formatLeverageX100(p.leverageX100)}
        </span>
        <span className="display text-lg tracking-[0.04em] text-ink">{p.symbol}</span>
        <span className="font-mono text-[10px] text-ink-faint">
          eff {Number.isFinite(effLev) ? `${effLev.toFixed(2)}x` : "max"}
        </span>
        <span className={`num text-lg ml-auto ${pnl >= 0n ? "text-felt-bright" : "text-loss"}`}>
          <Odometer value={formatSignedUsdg(pnl)} />
        </span>
      </div>

      {/* Numbers grid */}
      <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-x-4 gap-y-2 font-mono text-[12px]">
        <Cell label="Margin" value={formatUsdg(p.margin)} />
        <Cell label="Notional" value={formatUsdg(notional)} />
        <Cell label="Entry" value={formatPrice(p.entryPrice1e18)} dim />
        <Cell label="Mark" value={formatPrice(mark)} odometer />
        <Cell
          label="Liq price"
          value={liq > 0n ? formatPrice(liq) : "none"}
          tone="loss"
          odometer
        />
        <Cell
          label="Funding accrued"
          value={`${netOwed > 0n ? "-" : "+"}${formatUsdg(netOwed < 0n ? -netOwed : netOwed)}`}
          tone={netOwed > 0n ? "loss" : "win"}
        />
      </div>

      {/* Distance-to-liquidation bar */}
      <div className="flex flex-col gap-1">
        <div className="flex items-baseline justify-between font-mono text-[10px]">
          <span className={level === "safe" ? "text-ink-faint" : "text-amber"}>
            {level === "liquidatable"
              ? "AT LIQUIDATION: add margin or be closed by a keeper"
              : level === "loud"
                ? `LIQUIDATION APPROACHING: ${Math.round(danger * 100)}% of the way there`
                : level === "soft"
                  ? `drifting toward liquidation: ${Math.round(danger * 100)}% of the way there`
                  : `distance to liquidation: ${Math.round(danger * 100)}% traveled`}
          </span>
          {distancePct !== undefined && (
            <span className="text-ink-faint">
              {distancePct >= 0 ? "+" : ""}
              {distancePct.toFixed(2)}% to liq
            </span>
          )}
        </div>
        <DangerBar danger={danger} />
      </div>

      {/* Loud warning copy */}
      {(level === "loud" || level === "liquidatable") && (
        <p className="font-mono text-[11px] leading-relaxed text-amber">
          This is the warning other perps never give you. Add margin now and the liquidation
          price moves away instantly; wait, and a keeper takes the {(market.mmrBps / 100).toFixed(1)}%
          maintenance line for you.
        </p>
      )}

      {/* Actions */}
      <div className="flex flex-wrap items-center gap-2">
        <button
          type="button"
          onClick={() => setAddOpen((v) => !v)}
          disabled={busy}
          className={
            level === "loud" || level === "liquidatable"
              ? "btn-alarm px-4 py-1.5 text-[14px]"
              : "btn-ghost px-4 py-1.5 text-[12px] font-mono uppercase tracking-[0.08em]"
          }
        >
          + Add Margin
        </button>
        <button
          type="button"
          disabled={busy}
          onClick={() => onClose(mark, market.closeFeeBps)}
          className="btn-ghost px-4 py-1.5 text-[12px] font-mono uppercase tracking-[0.08em]"
        >
          Close ({formatSignedUsdg(closePrev.traderNet - p.margin)})
        </button>
        <span className="font-mono text-[10px] text-ink-faint ml-auto">
          receive on close: <span className="text-ink">{formatUsdg(closePrev.traderNet)}</span>{" "}
          (fee {formatUsdg(closePrev.closeFee)})
        </span>
      </div>

      {/* Inline add-margin form */}
      {addOpen && (
        <div className="flex flex-wrap items-end gap-2 rise-in">
          <div className="flex flex-col gap-1">
            <label htmlFor={`add-margin-${p.id}`} className="field-label">
              Add margin (USDG)
            </label>
            <input
              id={`add-margin-${p.id}`}
              className="field-input w-36"
              inputMode="decimal"
              value={addAmount}
              onChange={(e) => setAddAmount(e.target.value)}
            />
          </div>
          <button
            type="button"
            className="btn-amber px-4 py-2.5 text-sm"
            disabled={busy || parsedAdd === undefined || parsedAdd === 0n}
            onClick={() => {
              if (parsedAdd !== undefined && parsedAdd > 0n) {
                onAddMargin(parsedAdd);
                setAddOpen(false);
              }
            }}
          >
            Confirm
          </button>
          {parsedAdd !== undefined && parsedAdd > 0n && (
            <span className="font-mono text-[10px] text-ink-dim pb-3">
              new liq{" "}
              <span className="text-felt-bright">
                {formatPrice(
                  liquidationPrice1e18(
                    p.size1e18,
                    p.entryPrice1e18,
                    p.margin + parsedAdd,
                    netOwed,
                    market.mmrBps,
                    isLong,
                  ),
                )}
              </span>{" "}
              : works even while the market is paused (it is strictly de-risking)
            </span>
          )}
        </div>
      )}
    </div>
  );
}

function Cell({
  label,
  value,
  tone,
  dim,
  odometer,
}: {
  label: string;
  value: string;
  tone?: "loss" | "win";
  dim?: boolean;
  odometer?: boolean;
}) {
  const color =
    tone === "loss"
      ? "text-loss"
      : tone === "win"
        ? "text-felt-bright"
        : dim
          ? "text-ink-dim"
          : "text-ink";
  return (
    <div>
      <div className="font-mono text-[9px] uppercase tracking-[0.12em] text-ink-faint">
        {label}
      </div>
      <div className={`num text-[13px] ${color}`}>
        {odometer ? <Odometer value={value} /> : value}
      </div>
    </div>
  );
}
