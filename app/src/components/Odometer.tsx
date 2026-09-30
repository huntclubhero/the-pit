"use client";

import { useEffect, useRef, useState } from "react";

/**
 * Odometer: mono, tabular numerals where every digit rolls vertically to its
 * new value on change. Non-digit characters (separators, units) render static.
 * On change the whole figure also gives one soft settle pop (count-pop), so
 * live data reads as a pulse. Consumes motion tokens: duration-roll/ease-roll.
 */

const DIGITS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];

function DigitColumn({ digit }: { digit: string }) {
  const index = DIGITS.indexOf(digit);
  return (
    <span className="odo-digit" aria-hidden>
      <span
        className="odo-track"
        // Live values (countdowns, drifting marks) legitimately differ between
        // server render and hydration; the client value wins silently.
        suppressHydrationWarning
        style={{ transform: `translateY(-${index}em)` }}
      >
        {DIGITS.map((d) => (
          <span key={d} className="odo-cell">
            {d}
          </span>
        ))}
      </span>
    </span>
  );
}

export function Odometer({
  value,
  className,
}: {
  /** Preformatted numeric string, e.g. "142,557.83". */
  value: string;
  className?: string;
}) {
  const [pop, setPop] = useState(false);
  const prev = useRef(value);

  useEffect(() => {
    if (prev.current === value) return;
    prev.current = value;
    setPop(true);
    const t = setTimeout(() => setPop(false), 400);
    return () => clearTimeout(t);
  }, [value]);

  return (
    <span
      className={`odo ${pop ? "odo-pop" : ""} ${className ?? ""}`}
      role="text"
      aria-label={value}
      suppressHydrationWarning
    >
      {value.split("").map((char, i) =>
        /\d/.test(char) ? (
          <DigitColumn key={`${i}`} digit={char} />
        ) : (
          <span key={`${i}`} aria-hidden>
            {char}
          </span>
        ),
      )}
    </span>
  );
}
