"use client";

/**
 * Route-level loading state: three pulsing amber dots over a quiet label.
 * Replaces bare "loading..." strings so even the wait feels designed.
 */
export function Boot({ label }: { label: string }) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 p-14" role="status">
      <div className="boot-dots" aria-hidden>
        <span />
        <span />
        <span />
      </div>
      <div className="font-mono text-[11px] uppercase tracking-[0.18em] text-ink-faint">
        {label}
      </div>
    </div>
  );
}
