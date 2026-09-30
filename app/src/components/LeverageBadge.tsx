"use client";

import { compactNumber } from "@/lib/format";
import { MCAP_TIERS, formatLeverageX100 } from "@/lib/perp";
import type { MarketSummary } from "@/lib/types";

/**
 * The mcap-tier max-leverage badge with the "why this cap" tooltip: the
 * LOCKED leverage schedule made legible. Hover or keyboard-focus reveals the
 * FDV band, the maintenance margin, and the reasoning.
 */
export function LeverageBadge({
  market,
  align = "left",
}: {
  market: MarketSummary;
  align?: "left" | "right";
}) {
  const tier = MCAP_TIERS[market.mcapTier];
  const label = formatLeverageX100(market.maxLeverageX100);
  return (
    <span className="tip inline-flex">
      <button
        type="button"
        className="chip tap text-amber border-amber-deep num"
        aria-label={`Max leverage ${label}. Mcap tier ${market.mcapTier}: FDV ${tier.band}.`}
      >
        {label}
      </button>
      <span
        className="tip-body"
        style={align === "right" ? { left: "auto", right: 0 } : undefined}
        role="tooltip"
      >
        <span className="display text-[13px] tracking-[0.06em] uppercase text-amber">
          Max leverage {label}
        </span>
        <span className="block font-mono text-[10px] text-ink-dim mt-0.5">
          Mcap tier {market.mcapTier}: FDV {tier.band} (live ~${compactNumber(market.fdvUsd)})
        </span>
        <span className="block text-[12px] leading-relaxed text-ink-dim mt-1.5">
          Leverage caps follow market cap: 4x under $500K up to 15x over $50M. Smaller caps
          move harder and their oracles are easier to push, so the schedule keeps the max
          loss the vault can take below the cost of moving the price. The schedule is locked;
          tier upgrades go through a 2 day timelock, so a pump cannot raise its own cap.
        </span>
        <span className="block font-mono text-[10px] text-ink-faint mt-1.5">
          Maintenance margin {(market.mmrBps / 100).toFixed(2)}% of notional : fees{" "}
          {market.openFeeBps}/{market.closeFeeBps} bps open/close
        </span>
      </span>
    </span>
  );
}
