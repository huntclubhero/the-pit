export const metadata = {
  title: "THE PIT: not available in your region",
};

export default function BlockedPage() {
  return (
    <div className="fixed inset-0 z-[100] bg-pit-0 flex items-center justify-center p-6">
      <div className="max-w-lg text-center">
        <div className="display text-6xl text-amber leading-none">THE PIT</div>
        <h1 className="display text-3xl text-ink mt-8 uppercase tracking-[0.06em]">
          Not available in your region
        </h1>
        <p className="mt-4 text-sm leading-relaxed text-ink-dim">
          THE PIT is not offered to residents of your jurisdiction. Access from your current
          location is restricted and no exceptions are made, including through VPNs or proxies.
        </p>
        <p className="mt-6 font-mono text-[10px] uppercase tracking-[0.16em] text-ink-faint">
          HTTP 451: unavailable for legal reasons
        </p>
      </div>
    </div>
  );
}
