"use client";

import { useEffect, useMemo, useState } from "react";
import { createPortal } from "react-dom";
import { formatUsdg } from "@/lib/format";
import { Odometer } from "./Odometer";

/**
 * Big-win celebration: fires on a profitable close. The spectacle scales to the
 * return multiple on margin (a 15x winner rains harder). Full-screen takeover,
 * shared motion tokens, dismiss by click or button. Reduced-motion users still
 * get the number and the copy, just without the confetti travel.
 */
export function BigWinCeremony({
  profit,
  payout,
  stake,
  symbol,
  leverageLabel,
  onDone,
}: {
  /** Net profit, native USDG units. */
  profit: bigint;
  /** Total returned to the winner, native USDG units. */
  payout: bigint;
  /** The margin that was risked, native USDG units. */
  stake: bigint;
  symbol: string;
  /** Optional leverage chip shown under the headline, e.g. "15x LONG". */
  leverageLabel?: string;
  onDone: () => void;
}) {
  const [shown, setShown] = useState(false);

  // Payout multiple drives the intensity. Guard against a zero stake.
  const mult = stake > 0n ? Number(payout) / Number(stake) : 2;
  const pieces = Math.min(120, Math.round(24 + mult * 6));
  const headline = mult >= 5 ? "LEVERAGE PAID" : mult >= 2 ? "MASSIVE HIT" : "WINNER";

  const confetti = useMemo(
    () =>
      Array.from({ length: pieces }, (_, i) => {
        const left = (i * 37 + ((i * i) % 53)) % 100;
        const delay = ((i * 91) % 900) / 1000;
        const dur = 2.4 + (((i * 17) % 20) / 10);
        const hue = i % 3;
        return { left, delay, dur, hue, i };
      }),
    [pieces],
  );

  useEffect(() => {
    const t = setTimeout(() => setShown(true), 60);
    return () => clearTimeout(t);
  }, []);

  // Portal to <body>: the positions panel's backdrop-filter creates a
  // containing block that would trap this "fixed" takeover inside the panel.
  return createPortal(
    <div
      className="fixed inset-0 z-[95] flex flex-col items-center justify-center gap-4 p-6 text-center"
      role="dialog"
      aria-modal="true"
      aria-label="Big win"
      onClick={onDone}
      style={{ background: "rgba(8,9,11,0.94)" }}
    >
      {/* Turning rays */}
      <div
        className="pointer-events-none absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 rays"
        style={{ width: "160vmax", height: "160vmax", opacity: 0.5 }}
        aria-hidden
      />
      {/* Confetti / coins */}
      <div className="pointer-events-none absolute inset-0 overflow-hidden" aria-hidden>
        {confetti.map((c) => (
          <span
            key={c.i}
            className="absolute block"
            style={{
              left: `${c.left}%`,
              top: "-6vh",
              width: c.hue === 2 ? "10px" : "7px",
              height: c.hue === 2 ? "10px" : "12px",
              borderRadius: c.hue === 2 ? "50%" : "1px",
              background:
                c.hue === 0
                  ? "var(--color-amber)"
                  : c.hue === 1
                    ? "var(--color-amber-hot)"
                    : "var(--color-felt-bright)",
              animation: `confetti-fall ${c.dur}s var(--ease-roll) ${c.delay}s both`,
            }}
          />
        ))}
      </div>

      <div className="relative flex flex-col items-center gap-3">
        <div
          className={`display tracking-[0.24em] uppercase text-amber-hot transition-all duration-[480ms] ${
            shown ? "opacity-100 translate-y-0" : "opacity-0 translate-y-2"
          }`}
          style={{ fontSize: "clamp(1.5rem, 5vw, 2.75rem)" }}
        >
          {headline}
        </div>

        <div className="big-burst">
          <div className="font-mono text-[10px] uppercase tracking-[0.3em] text-ink-dim">
            {leverageLabel ? `${symbol} : ${leverageLabel}` : `${symbol} payout`}
          </div>
          <div
            className="num gold glow-amber leading-none"
            style={{ fontSize: "clamp(3.5rem, 15vw, 9rem)" }}
          >
            <Odometer value={formatUsdg(payout)} />
          </div>
        </div>

        <div
          className={`transition-opacity duration-[480ms] ${shown ? "opacity-100" : "opacity-0"}`}
        >
          <div className="num text-2xl md:text-3xl text-felt-bright glow-win">
            +{formatUsdg(profit)} <span className="text-ink-dim text-lg">profit</span>
          </div>
          <div className="mt-1 font-mono text-[12px] text-ink-dim">
            risked {formatUsdg(stake)} : returned {mult.toFixed(2)}x
          </div>
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              onDone();
            }}
            className="btn-amber mt-6 px-8 py-2.5 text-base"
          >
            Rack it up
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
