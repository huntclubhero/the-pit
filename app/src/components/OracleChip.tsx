"use client";

import { useEffect, useState } from "react";
import { formatCountdown } from "@/lib/format";
import type { OracleStatus } from "@/lib/types";

/**
 * Oracle status chip driven by peekPrice: OK, COOLDOWN with live countdown,
 * STALE, or UNAVAILABLE.
 */
export function OracleChip({
  status,
  cooldownRemaining,
}: {
  status: OracleStatus;
  cooldownRemaining?: number;
}) {
  const [remaining, setRemaining] = useState(cooldownRemaining ?? 0);

  useEffect(() => {
    setRemaining(cooldownRemaining ?? 0);
    if (status !== "COOLDOWN") return;
    const timer = setInterval(() => setRemaining((r) => Math.max(0, r - 1)), 1_000);
    return () => clearInterval(timer);
  }, [status, cooldownRemaining]);

  if (status === "OK") {
    return (
      <span className="chip text-felt-bright border-felt">
        <span className="pulse-dot inline-block h-1.5 w-1.5 rounded-full bg-felt-bright" />
        Oracle OK
      </span>
    );
  }
  if (status === "COOLDOWN") {
    return (
      <span className="chip text-cooldown border-amber-deep">
        <span className="pulse-dot inline-block h-1.5 w-1.5 rounded-full bg-cooldown" />
        Cooldown {formatCountdown(remaining)}
      </span>
    );
  }
  if (status === "STALE") {
    return (
      <span className="chip text-stale">
        <span className="inline-block h-1.5 w-1.5 rounded-full bg-stale" />
        Stale
      </span>
    );
  }
  return (
    <span className="chip text-loss border-loss-deep">
      <span className="inline-block h-1.5 w-1.5 rounded-full bg-loss" />
      Unavailable
    </span>
  );
}
