"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { formatPoints } from "@/lib/format";

const REEL = [1, 2, 5, 20, 100];
const REPEATS = 6;
const CELL_EM = 1.4;

/**
 * The spin ceremony: a slot-style vertical reel that lands on the fulfilled
 * multiplier. Full-screen takeover, motion tokens only, no sound dependency.
 */
export function SpinCeremony({
  multiplier,
  basePoints,
  onDone,
}: {
  /** Fulfilled multiplier: 1, 2, 5, 20, or 100. */
  multiplier: number;
  /** Spin base (points earned on the fill, 1e18) the bonus scales from. */
  basePoints: bigint;
  onDone: () => void;
}) {
  const [landed, setLanded] = useState(false);
  const trackRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const targetIndex = REEL.indexOf(multiplier);
    if (targetIndex < 0) {
      onDone();
      return;
    }
    // Land in the last repeat so the reel travels the full strip.
    const finalCell = (REPEATS - 1) * REEL.length + targetIndex;
    const el = trackRef.current;
    if (!el) return;
    // Double rAF so the initial transform commits before the transition.
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        el.style.transition = "transform 2200ms var(--ease-ceremony)";
        el.style.transform = `translateY(-${finalCell * CELL_EM}em)`;
      });
    });
    const landTimer = setTimeout(() => setLanded(true), 2_300);
    return () => clearTimeout(landTimer);
  }, [multiplier, onDone]);

  const bonus = basePoints * BigInt(Math.max(0, multiplier - 1));

  // Portal to <body>: the ticket panel's backdrop-filter creates a containing
  // block that would trap this "fixed" takeover inside the panel on desktop.
  return createPortal(
    <div
      className="fixed inset-0 z-[90] bg-pit-0/95 backdrop-blur-sm flex flex-col items-center justify-center gap-6 p-6"
      role="dialog"
      aria-modal="true"
      aria-label="Multiplier spin"
      onClick={() => landed && onDone()}
    >
      <div className="display text-2xl md:text-3xl tracking-[0.24em] uppercase text-ink-dim">
        Multiplier Spin
      </div>

      <div
        className={`relative overflow-hidden border rounded-2xl px-10 md:px-16 transition-colors duration-[480ms] ${
          landed ? "border-amber" : "border-line-2"
        }`}
        style={{ height: `${CELL_EM}em`, fontSize: "clamp(3rem, 10vw, 6rem)" }}
      >
        <div ref={trackRef} className="num text-amber will-change-transform">
          {Array.from({ length: REPEATS }).flatMap((_, r) =>
            REEL.map((value) => (
              <div
                key={`${r}-${value}`}
                className="flex items-center justify-center"
                style={{ height: `${CELL_EM}em`, lineHeight: 1 }}
              >
                {value}x
              </div>
            )),
          )}
        </div>
        {/* Edge fades */}
        <div
          className="pointer-events-none absolute inset-0"
          style={{
            background:
              "linear-gradient(180deg, var(--color-pit-0) 0%, transparent 30%, transparent 70%, var(--color-pit-0) 100%)",
            opacity: 0.55,
          }}
          aria-hidden
        />
      </div>

      <div
        className={`text-center transition-opacity duration-[480ms] ${
          landed ? "opacity-100" : "opacity-0"
        }`}
      >
        {multiplier > 1 ? (
          <>
            <div className="num text-2xl text-amber">
              +{formatPoints(bonus, 1)} bonus points
            </div>
            {multiplier === 100 && (
              <div className="display text-lg tracking-[0.16em] uppercase text-amber-hot mt-1">
                100x: you are in tonight's Pit Drop
              </div>
            )}
          </>
        ) : (
          <div className="font-mono text-sm text-ink-dim">House keeps this one. Spin again on your next fill.</div>
        )}
        <button
          type="button"
          onClick={onDone}
          className="btn-ghost mt-5 px-6 py-2 font-mono text-[11px] uppercase tracking-[0.12em]"
        >
          Back to the table
        </button>
      </div>
    </div>,
    document.body,
  );
}

/** Weighted demo outcome matching the on-chain thresholds 60/25/10/4/1. */
export function rollDemoMultiplier(): number {
  const roll = Math.floor(Math.random() * 10_000);
  if (roll < 6_000) return 1;
  if (roll < 8_500) return 2;
  if (roll < 9_500) return 5;
  if (roll < 9_900) return 20;
  return 100;
}
