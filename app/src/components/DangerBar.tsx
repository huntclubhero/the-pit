"use client";

import { dangerLevel } from "@/lib/perp";

/**
 * The distance-to-liquidation bar. Fills from entry (0%) toward the
 * liquidation price (100%), through the 50% (soft) and 75% (loud) warning
 * ticks. At loud the fill throbs.
 */
export function DangerBar({ danger, className }: { danger: number; className?: string }) {
  const level = dangerLevel(danger);
  const loud = level === "loud" || level === "liquidatable";
  const pct = Math.min(100, Math.max(0, danger * 100));
  return (
    <div
      className={`danger-track ${loud ? "danger-loud" : ""} ${className ?? ""}`}
      role="meter"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(pct)}
      aria-label={`Distance to liquidation: ${Math.round(pct)}% of the way there`}
    >
      <div className="danger-fill" style={{ width: `${pct}%` }} />
      {loud && <div className="danger-sweep" aria-hidden />}
    </div>
  );
}
