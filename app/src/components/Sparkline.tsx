"use client";

/**
 * Deterministic 24h sparkline: shape is seeded from the symbol so a market's
 * line is stable across renders, endpoint slope follows the 24h move.
 */
export function Sparkline({
  symbol,
  changeBps,
  width = 96,
  height = 28,
}: {
  symbol: string;
  changeBps: number;
  width?: number;
  height?: number;
}) {
  const seed = symbol.split("").reduce((a, c) => a * 31 + c.charCodeAt(0), 7) >>> 0;
  const points: number[] = [];
  let value = 0.5;
  let state = seed;
  const drift = Math.max(-0.55, Math.min(0.55, changeBps / 8_000));
  const STEPS = 28;
  for (let i = 0; i < STEPS; i++) {
    state = (state * 1_664_525 + 1_013_904_223) >>> 0;
    const noise = (state / 0xffffffff - 0.5) * 0.24;
    value += noise + drift / STEPS;
    value = Math.max(0.05, Math.min(0.95, value));
    points.push(value);
  }
  const min = Math.min(...points);
  const max = Math.max(...points);
  const span = max - min || 1;
  const path = points
    .map((p, i) => {
      const x = (i / (STEPS - 1)) * width;
      const y = height - ((p - min) / span) * (height - 4) - 2;
      return `${i === 0 ? "M" : "L"}${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(" ");
  const up = changeBps >= 0;

  return (
    <svg
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      aria-hidden
      className="block"
    >
      <path
        d={path}
        fill="none"
        stroke={up ? "var(--color-felt-bright)" : "var(--color-loss)"}
        strokeWidth="1.5"
        strokeLinejoin="round"
        strokeLinecap="round"
        opacity="0.85"
      />
    </svg>
  );
}
