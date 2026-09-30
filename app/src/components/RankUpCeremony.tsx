"use client";

import { useEffect, useState } from "react";

/**
 * Rank-up ceremony: full-screen takeover when the lifetime rank tier climbs.
 * Staged reveals on motion tokens; dismiss by click or the continue button.
 */
export function RankUpCeremony({
  rankName,
  onDone,
}: {
  rankName: string;
  onDone: () => void;
}) {
  const [stage, setStage] = useState(0);

  useEffect(() => {
    const timers = [
      setTimeout(() => setStage(1), 200),
      setTimeout(() => setStage(2), 900),
      setTimeout(() => setStage(3), 1_500),
    ];
    return () => timers.forEach(clearTimeout);
  }, []);

  return (
    <div
      className="fixed inset-0 z-[90] bg-pit-0/95 backdrop-blur-sm flex flex-col items-center justify-center gap-4 p-6 text-center"
      role="dialog"
      aria-modal="true"
      aria-label="Rank up"
      onClick={() => stage >= 3 && onDone()}
    >
      <div
        className={`font-mono text-[11px] uppercase tracking-[0.34em] text-ink-dim transition-all duration-[480ms] ${
          stage >= 1 ? "opacity-100 translate-y-0" : "opacity-0 translate-y-3"
        }`}
      >
        The table respects the grind
      </div>

      <div
        className={`display uppercase leading-[0.9] text-amber transition-all duration-[900ms] ${
          stage >= 2 ? "opacity-100 scale-100" : "opacity-0 scale-90"
        }`}
        style={{ fontSize: "clamp(4rem, 16vw, 11rem)", letterSpacing: "0.04em" }}
      >
        {rankName}
      </div>

      <div
        className={`h-px bg-amber transition-all duration-[900ms] ${
          stage >= 2 ? "w-48 opacity-100" : "w-0 opacity-0"
        }`}
        aria-hidden
      />

      <div
        className={`transition-opacity duration-[480ms] ${
          stage >= 3 ? "opacity-100" : "opacity-0"
        }`}
      >
        <p className="font-mono text-sm text-ink-dim">
          New rank earned. Wear it badly.
        </p>
        <button
          type="button"
          onClick={onDone}
          className="btn-amber mt-5 px-8 py-2.5 text-base"
        >
          Back to the pit
        </button>
      </div>
    </div>
  );
}
