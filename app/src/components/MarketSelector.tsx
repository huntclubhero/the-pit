"use client";

import { useEffect, useRef, useState } from "react";
import { formatBpsPct, formatPrice } from "@/lib/format";
import { formatLeverageX100 } from "@/lib/perp";
import type { MarketSummary } from "@/lib/types";

/**
 * The market switcher on the trade terminal. Memecoins are the main event and
 * lead the list; the Tier A majors sit below in their own clearly secondary
 * group. Selecting a row swaps the whole terminal to that market.
 */
export function MarketSelector({
  markets,
  current,
  onSelect,
  onRequestListing,
}: {
  markets: MarketSummary[];
  current: MarketSummary;
  onSelect: (market: MarketSummary) => void;
  onRequestListing?: () => void;
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  const memes = markets.filter((m) => !m.isMajor);
  const majors = markets.filter((m) => m.isMajor);

  useEffect(() => {
    if (!open) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    function onClick(e: MouseEvent) {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    window.addEventListener("keydown", onKey);
    window.addEventListener("mousedown", onClick);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("mousedown", onClick);
    };
  }, [open]);

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        aria-haspopup="listbox"
        className="group press flex items-center gap-2.5 rounded-xl border border-line-2 bg-pit-1 px-3 py-1.5 hover:border-amber-deep"
      >
        <span className="display text-2xl md:text-3xl leading-none text-ink tracking-[-0.02em]">
          {current.symbol}
        </span>
        <span className="hidden sm:inline font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">
          {current.isMajor ? "major" : "memecoin"}
        </span>
        <svg
          className={`h-3.5 w-3.5 text-ink-faint transition-transform duration-[120ms] group-hover:text-amber ${open ? "rotate-180" : ""}`}
          viewBox="0 0 16 16"
          fill="none"
          aria-hidden
        >
          <path d="M4 6l4 4 4-4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>

      {open && (
        <div
          role="listbox"
          aria-label="Switch market"
          className="dd-pop fixed inset-x-3 top-24 z-[60] max-h-[70dvh] overflow-y-auto rounded-2xl md:absolute md:inset-x-auto md:top-[calc(100%+8px)] md:left-0 md:w-[380px] md:max-h-[560px]"
          style={{
            background: "rgba(16, 19, 27, 0.94)",
            backdropFilter: "blur(28px) saturate(1.4)",
            WebkitBackdropFilter: "blur(28px) saturate(1.4)",
            border: "1px solid rgba(255,255,255,0.14)",
            boxShadow:
              "inset 0 1px 0 rgba(255,255,255,0.12), 0 32px 80px -24px rgba(2,4,9,0.85)",
          }}
        >
          <GroupHead
            label="Memecoins"
            note="the main event: the list nobody else will touch"
            accent
          />
          {memes.map((m) => (
            <Row
              key={m.address}
              market={m}
              active={m.address === current.address}
              onPick={() => {
                onSelect(m);
                setOpen(false);
              }}
            />
          ))}
          <GroupHead
            label="Majors"
            note="secondary: independent feeds, up to 15x"
          />
          {majors.map((m) => (
            <Row
              key={m.address}
              market={m}
              active={m.address === current.address}
              onPick={() => {
                onSelect(m);
                setOpen(false);
              }}
            />
          ))}
          {onRequestListing && (
            <button
              type="button"
              onClick={() => {
                setOpen(false);
                onRequestListing();
              }}
              className="w-full border-t border-line px-4 py-3 text-left font-mono text-[11px] uppercase tracking-[0.08em] text-ink-faint transition-colors duration-[120ms] hover:text-amber"
            >
              + Request a listing
            </button>
          )}
        </div>
      )}
    </div>
  );
}

function GroupHead({
  label,
  note,
  accent,
}: {
  label: string;
  note: string;
  accent?: boolean;
}) {
  return (
    <div className="sticky top-0 z-10 flex items-baseline gap-2.5 border-b border-line px-4 py-2.5 backdrop-blur-md" style={{ background: "rgba(16, 19, 27, 0.92)" }}>
      <span
        className={`display text-[13px] uppercase tracking-[0.1em] ${accent ? "text-amber" : "text-ink-dim"}`}
      >
        {label}
      </span>
      <span className="font-mono text-[9px] text-ink-faint">{note}</span>
    </div>
  );
}

function Row({
  market: m,
  active,
  onPick,
}: {
  market: MarketSummary;
  active: boolean;
  onPick: () => void;
}) {
  return (
    <button
      type="button"
      role="option"
      aria-selected={active}
      onClick={onPick}
      className={`dd-row flex w-full items-baseline gap-3 px-4 py-2.5 text-left hover:bg-pit-2 ${
        active ? "bg-pit-2" : ""
      }`}
    >
      <span className={`display text-[15px] tracking-[0.01em] ${active ? "text-amber" : "text-ink"}`}>
        {m.symbol}
      </span>
      <span className="hidden sm:inline font-mono text-[10px] text-ink-faint truncate max-w-[80px]">
        {m.name}
      </span>
      <span className="ml-auto num text-[12px] text-ink-dim">{formatPrice(m.price1e18)}</span>
      <span
        className={`num text-[11px] w-[52px] text-right ${
          m.change24hBps >= 0 ? "text-felt-bright" : "text-loss"
        }`}
      >
        {formatBpsPct(m.change24hBps)}
      </span>
      <span className="num text-[10px] text-ink-faint w-[30px] text-right">
        {formatLeverageX100(m.maxLeverageX100)}
      </span>
    </button>
  );
}
