"use client";

import { formatAge, formatPrice, formatUsdg, formatUsdgCompact, shortAddress } from "@/lib/format";
import { useNowSecond } from "@/hooks/useNowSecond";
import type { LiquidationEvent } from "@/lib/types";

/**
 * The public liquidations feed. Liquidations are visible, penalized at 1% of
 * notional (keeper 20% / vault 40% / insurance fund 40%), and residual equity
 * goes BACK to the trader. Showing them is the honesty pitch.
 */
export function LiquidationsFeed({
  events,
  limit = 8,
  symbolFilter,
}: {
  events: LiquidationEvent[];
  limit?: number;
  symbolFilter?: string;
}) {
  const now = useNowSecond();
  const rows = (symbolFilter ? events.filter((e) => e.symbol === symbolFilter) : events).slice(
    0,
    limit,
  );

  return (
    <div className="panel">
      <div className="panel-head">
        <span>Liquidations</span>
        <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
          1% penalty : residual equity returns to the trader
        </span>
      </div>
      {rows.length === 0 ? (
        <p className="p-5 text-center font-mono text-[11px] text-ink-faint">
          Nothing liquidated{symbolFilter ? ` in ${symbolFilter}` : ""} recently.
        </p>
      ) : (
        <div className="table-scroll">
          <table className="data-table">
            <thead>
              <tr>
                <th>Market</th>
                <th>Side</th>
                <th>Notional</th>
                <th>Margin</th>
                <th>Liq price</th>
                <th>Penalty</th>
                <th>Trader</th>
                <th>Age</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((e) => (
                <tr key={e.id}>
                  <td>
                    <span className="display text-[15px] tracking-[0.04em] text-ink">
                      {e.symbol}
                    </span>
                  </td>
                  <td>
                    <span
                      className={`display text-[13px] tracking-[0.08em] uppercase ${
                        e.side === "long" ? "text-felt-bright" : "text-loss"
                      }`}
                    >
                      {e.side}
                    </span>
                  </td>
                  <td className="num text-ink">{formatUsdgCompact(e.notional)}</td>
                  <td className="num text-ink-dim">{formatUsdg(e.margin, 0)}</td>
                  <td className="num text-loss">{formatPrice(e.price1e18)}</td>
                  <td className="num text-ink-dim">{formatUsdg(e.penalty)}</td>
                  <td className="font-mono text-[10px] text-ink-faint">
                    {shortAddress(e.trader)}
                  </td>
                  <td className="num text-ink-faint">{formatAge(now - e.at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
