"use client";

import { Odometer } from "@/components/Odometer";
import { Reveal } from "@/components/Reveal";
import { SimTag } from "@/components/SimTag";
import { useJackpot } from "@/hooks/useJackpot";
import { useNowSecond } from "@/hooks/useNowSecond";
import { explorerTxUrl } from "@/lib/chain";
import { formatCountdown, formatUsdg, shortAddress } from "@/lib/format";

export default function JackpotPage() {
  const { data: jackpot } = useJackpot();
  const now = useNowSecond();

  if (!jackpot) {
    return <div className="p-10 text-center font-mono text-ink-faint">Counting the pot...</div>;
  }

  return (
    <div>
      {/* The pot: oversized odometer, full bleed */}
      <section className="border-b border-line bg-pit-1 relative overflow-hidden">
        <div
          className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 pointer-events-none rays"
          style={{ width: "150vmax", height: "150vmax", opacity: 0.35 }}
          aria-hidden
        />
        <div
          className="absolute inset-0 pointer-events-none"
          style={{
            background:
              "radial-gradient(820px 340px at 50% 100%, rgba(237,162,59,0.1), transparent 70%)",
          }}
          aria-hidden
        />
        <div className="relative px-4 md:px-6 py-14 md:py-20 text-center">
          <div className="font-mono text-[11px] uppercase tracking-[0.3em] text-ink-faint rise-in">
            The pot right now (USDG) <SimTag />
          </div>
          <div className="num gold jackpot-throb text-[14vw] md:text-[9vw] leading-none mt-3 rise-in rise-in-1">
            <Odometer value={formatUsdg(jackpot.pot)} />
          </div>
          <p className="mt-4 font-mono text-[11px] text-ink-dim rise-in rise-in-2">
            Fed by 25% of every fee, open and close. Paid out by verifiable on-chain
            randomness. Nobody can touch it, including us.
          </p>
        </div>
      </section>

      {/* Countdowns */}
      <Reveal>
      <section className="grid grid-cols-1 md:grid-cols-2 gap-px bg-line border-b border-line">
        <div className="bg-pit-2 px-4 md:px-6 py-8 text-center">
          <div className="display text-2xl tracking-[0.08em] text-ink uppercase">
            Daily Mini-Drop
          </div>
          <div className="num text-4xl md:text-5xl text-ink mt-3">
            <Odometer value={formatCountdown(jackpot.nextDailyAt - now)} />
          </div>
          <p className="mt-3 font-mono text-[11px] leading-relaxed text-ink-dim max-w-md mx-auto">
            10% of the pot, daily. Drawn uniformly among the day's 100x spinners:{" "}
            <span className="num text-amber">{jackpot.entrantCount}</span> entrant
            {jackpot.entrantCount === 1 ? "" : "s"} so far. No 100x spins today? It falls back
            to a points-weighted draw over the running epoch.
          </p>
        </div>
        <div className="bg-pit-2 px-4 md:px-6 py-8 text-center">
          <div className="display text-2xl tracking-[0.08em] text-amber uppercase">
            Weekly Pit Drop
          </div>
          <div className="num text-4xl md:text-5xl text-ink mt-3">
            <Odometer value={formatCountdown(jackpot.nextWeeklyAt - now)} />
          </div>
          <p className="mt-3 font-mono text-[11px] leading-relaxed text-ink-dim max-w-md mx-auto">
            50% of the pot, weekly. Weighted by last epoch's points: every point you grind is a
            ticket. More grind, better odds. That simple.
          </p>
        </div>
      </section>

      </Reveal>

      {/* Past draws */}
      <Reveal>
      <section className="px-4 md:px-6 py-6">
        <h2 className="display text-2xl tracking-[0.06em] text-ink uppercase mb-4">
          Past Draws
        </h2>
        <div className="panel">
          <div className="table-scroll">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Draw</th>
                  <th>Kind</th>
                  <th>Mode</th>
                  <th>Winner</th>
                  <th>Amount (USDG)</th>
                  <th>VRF Request</th>
                  <th>Tx</th>
                </tr>
              </thead>
              <tbody>
                {jackpot.draws.map((d) => (
                  <tr key={d.drawId}>
                    <td className="num text-ink-dim">#{d.drawId}</td>
                    <td>
                      <span
                        className={`chip ${
                          d.kind === "weekly"
                            ? "text-amber border-amber-deep"
                            : "text-ink-dim"
                        }`}
                      >
                        {d.kind === "weekly" ? "Pit Drop" : "mini-drop"}
                      </span>
                    </td>
                    <td className="font-mono text-[11px] text-ink-faint">
                      {d.mode === "entrants" ? "100x entrants" : `epoch ${d.epoch} weighted`}
                    </td>
                    <td className="num text-ink">{shortAddress(d.winner)}</td>
                    <td className="num text-felt-bright">+{formatUsdg(d.amount)}</td>
                    <td className="num text-ink-faint" title={d.requestId.toString()}>
                      {d.requestId.toString()}
                    </td>
                    <td>
                      {d.txHash ? (
                        <a
                          href={explorerTxUrl(d.txHash)}
                          target="_blank"
                          rel="noreferrer"
                          className="font-mono text-[10px] text-ink-faint hover:text-amber transition-colors"
                        >
                          {d.txHash.slice(0, 10)}..
                        </a>
                      ) : (
                        <span className="font-mono text-[10px] text-ink-faint">view</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
        <p className="mt-4 font-mono text-[10px] leading-relaxed text-ink-faint max-w-3xl">
          Every draw is a randomness request pinned to the coordinator that accepted it: the
          admin cannot influence an in-flight or past draw. Verify any result yourself on the{" "}
          <a href="/fairness" className="text-amber hover:text-amber-hot">
            fairness page
          </a>
          .
        </p>
      </section>
      </Reveal>
    </div>
  );
}
