"use client";

import { isMockMode } from "@/lib/config";

/**
 * The simulated-data marker. Pinned next to every live-looking figure while
 * the app runs on demo data so nobody can mistake this for a live venue.
 * Renders nothing once real contract addresses are wired.
 */
export function SimTag({ className = "" }: { className?: string }) {
  if (!isMockMode) return null;
  return (
    <span
      className={`inline-flex items-center rounded-md border border-amber-deep bg-amber/10 px-1.5 py-[1px] font-mono text-[9px] font-medium uppercase tracking-[0.08em] text-amber align-middle ${className}`}
      title="Simulated demo value. Not live. No funds move."
    >
      SIM
    </span>
  );
}
