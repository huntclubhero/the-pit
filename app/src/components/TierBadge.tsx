"use client";

import { compactNumber } from "@/lib/format";
import type { MarketTier } from "@/lib/types";

const TIER_NAME: Record<MarketTier, string> = {
  A: "Tier A: Major",
  B: "Tier B: Deep memecoin",
  C: "Tier C: Mid memecoin",
  D: "Tier D: Not listable",
};

const TIER_WHY: Record<MarketTier, string> = {
  A: "Priced by an independent Chainlink feed, not a pool a trader could push. Deep book, no cost-to-move bound needed.",
  B: "Priced by an aggregated multi-pool TWAP. The payout cap is set below the cost to move price to the trigger, so nudging the oracle costs more than it could pay.",
  C: "Priced by a single-pool TWAP with a tighter payout cap. Listable, but size is capped harder against the cost to move it.",
  D: "Too thin or too few independent sources to price safely. It cannot open a table at all.",
};

const TIER_CLASS: Record<MarketTier, string> = {
  A: "tier-a",
  B: "tier-b",
  C: "tier-c",
  D: "tier-d",
};

/**
 * A tier badge with a plain-language "why safe to trade" tooltip keyed on the
 * cost-to-move gate. Hover or keyboard-focus reveals the note.
 */
export function TierBadge({
  tier,
  oracleKind,
  costToMoveUsd,
  align = "left",
}: {
  tier: MarketTier;
  oracleKind?: string;
  costToMoveUsd?: number;
  align?: "left" | "right";
}) {
  const costLabel =
    costToMoveUsd === undefined || !Number.isFinite(costToMoveUsd)
      ? "priced by an independent feed"
      : `~$${compactNumber(costToMoveUsd)} to move to the max-payout trigger`;
  return (
    <span className="tip inline-flex">
      <button
        type="button"
        className={`tier-badge tap ${TIER_CLASS[tier]}`}
        aria-label={`${TIER_NAME[tier]}. ${TIER_WHY[tier]}`}
      >
        {tier}
      </button>
      <span
        className="tip-body"
        style={align === "right" ? { left: "auto", right: 0 } : undefined}
        role="tooltip"
      >
        <span className={`display text-[13px] tracking-[0.06em] uppercase ${TIER_CLASS[tier]}`}>
          {TIER_NAME[tier]}
        </span>
        {oracleKind && (
          <span className="block font-mono text-[10px] text-ink-dim mt-0.5">{oracleKind}</span>
        )}
        <span className="block text-[12px] leading-relaxed text-ink-dim mt-1.5">
          {TIER_WHY[tier]}
        </span>
        <span className="block font-mono text-[10px] text-ink-faint mt-1.5">{costLabel}</span>
      </span>
    </span>
  );
}
