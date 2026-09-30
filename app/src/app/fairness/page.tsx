"use client";

import { Reveal } from "@/components/Reveal";
import { useJackpot } from "@/hooks/useJackpot";
import { useSpinLedger } from "@/hooks/useFairness";
import { EXPLORER_URL } from "@/lib/chain";
import { addresses, isMockMode } from "@/lib/config";
import { formatPoints, shortAddress } from "@/lib/format";
import { POINTS_DISCLAIMER } from "@/lib/mock/data";

const SPIN_TABLE = [
  { mult: "1x", odds: "60%", range: "roll 0 to 5999" },
  { mult: "2x", odds: "25%", range: "roll 6000 to 8499" },
  { mult: "5x", odds: "10%", range: "roll 8500 to 9499" },
  { mult: "20x", odds: "4%", range: "roll 9500 to 9899" },
  { mult: "100x", odds: "1%", range: "roll 9900 to 9999" },
];

const TRUST_STATEMENTS = [
  {
    title: "Max loss = your margin",
    body: "Margin is isolated per position. Profit is capped at 9x margin and reserved in the vault the moment you open; loss is capped at your own margin, always. No cross-margin contagion, no account-level wipeout, no insurance-fund clawback against winners.",
  },
  {
    title: "Liquidations you can see coming",
    body: "Your exact liquidation price is a closed-form number shown before you open and live on every position. We warn at 50% of the distance, warn loudly at 75%, and the Add Margin button lights up. Adding margin works even while a market is paused: de-risking is never blocked.",
  },
  {
    title: "No admin price path",
    body: "Every mark is a median of independent sources through the oracle router. There is no function, owner-only or otherwise, that lets anyone hand-set a price. If sources disagree, the breaker PAUSES liquidations and new opens instead of trusting anyone: a manipulated print can never force-close you.",
  },
  {
    title: "The vault cannot be drained",
    body: "Each market's total possible payout is capped below the cost of moving its oracle price. Pumping a token to milk the vault costs more than it can extract, by construction. Liquidation penalties split between the vault and an insurance fund before any other backstop.",
  },
];

export default function FairnessPage() {
  const { data: spins } = useSpinLedger();
  const { data: jackpot } = useJackpot();

  return (
    <div className="px-4 md:px-6 py-8 flex flex-col gap-10 max-w-6xl mx-auto">
      {/* Manifesto */}
      <section className="rise-in">
        <h1 className="display text-4xl md:text-6xl leading-[0.95] text-ink">
          The house shows
          <span className="text-amber"> its cards.</span>
        </h1>
        <p className="mt-4 max-w-2xl text-sm md:text-base text-ink-dim leading-relaxed">
          THE PIT is a perps DEX where you trade against a transparent LP vault at the oracle
          mark: no order book games, no hidden spread, no admin who can set a price. Your
          liquidation price is exact and visible, the warnings come before the keeper, and the
          vault&apos;s worst case is a hard-coded number. Here is exactly how, with the receipts
          on-chain.
        </p>
      </section>

      {/* Trust statements */}
      <section className="grid grid-cols-1 md:grid-cols-2 gap-px bg-line border border-line rounded-2xl overflow-hidden rise-in rise-in-1">
        {TRUST_STATEMENTS.map((s) => (
          <div key={s.title} className="bg-pit-2 p-5">
            <h2 className="display text-xl tracking-[0.06em] text-ink uppercase">{s.title}</h2>
            <p className="mt-2 text-[13px] leading-relaxed text-ink-dim">{s.body}</p>
          </div>
        ))}
      </section>

      {/* The position lifecycle, plain language */}
      <Reveal>
      <section className="panel">
        <div className="panel-head">
          <span>How a position works</span>
        </div>
        <div className="p-5 grid grid-cols-1 md:grid-cols-3 gap-5 font-mono text-[12px] leading-relaxed text-ink-dim">
          <div>
            <div className="display text-lg text-ink uppercase tracking-[0.06em] mb-1">
              1. Open
            </div>
            Post isolated USDG margin and pick leverage up to your token&apos;s mcap-tier cap (4x to
            15x). You fill against the vault at the oracle mark: no spread, no slippage games. A
            5 to 10 bps open fee on notional comes off up front; the vault reserves your full 9x
            max payout the same block.
          </div>
          <div>
            <div className="display text-lg text-ink uppercase tracking-[0.06em] mb-1">
              2. Hold
            </div>
            PnL marks continuously at the oracle median. Skew funding flows hourly from the
            crowded side to the other (residual to the vault); a borrow fee that scales with
            realized vol pays the vault for the reserved capacity. Your liquidation price is
            exact and drifts only as funding accrues: watch the bar, add margin any time.
          </div>
          <div>
            <div className="display text-lg text-ink uppercase tracking-[0.06em] mb-1">
              3. Close (or get closed)
            </div>
            Close at the mark whenever a live or fallback print exists: profit clamps at 9x
            margin, loss at your margin. Fall under maintenance and any keeper may liquidate:
            1% penalty (keeper 20%, vault 40%, insurance fund 40%), and the residual equity
            comes back to you. Losses still earn the 25% points rebate.
          </div>
        </div>
      </section>

      </Reveal>

      {/* Spin thresholds */}
      <Reveal>
      <section>
        <h2 className="display text-2xl tracking-[0.06em] text-ink uppercase mb-4">
          Spin odds, hard-coded
        </h2>
        <div className="grid grid-cols-2 md:grid-cols-5 gap-px bg-line border border-line rounded-2xl overflow-hidden">
          {SPIN_TABLE.map((row) => (
            <div
              key={row.mult}
              className={`bg-pit-2 p-4 text-center ${row.mult === "100x" ? "col-span-2 md:col-span-1" : ""}`}
            >
              <div
                className={`num text-3xl ${row.mult === "100x" ? "text-amber" : "text-ink"}`}
              >
                {row.mult}
              </div>
              <div className="num text-sm text-felt-bright mt-1">{row.odds}</div>
              <div className="font-mono text-[9px] text-ink-faint mt-1">{row.range}</div>
            </div>
          ))}
        </div>
        <p className="mt-3 font-mono text-[10px] leading-relaxed text-ink-faint max-w-3xl">
          Every position open requests one random word from the on-chain commit-reveal
          coordinator (no VRF service exists on this chain yet; the coordinator speaks the
          VRF interface and swaps out the day one does). multiplierForWord(word) is public
          and pure: take any word from the ledger below, compute word mod 10000, read the
          table. A 100x also enters you in the daily Pit Drop. Bonus points minted = spin base
          x (multiplier - 1).
        </p>
      </section>

      </Reveal>

      {/* Spin ledger */}
      <Reveal>
      <section className="panel">
        <div className="panel-head">
          <span>Spin Ledger</span>
          <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
            live from SpinVRF.getSpin(requestId)
          </span>
        </div>
        <div className="table-scroll">
          <table className="data-table">
            <thead>
              <tr>
                <th>Request ID</th>
                <th>Spinner</th>
                <th>Market</th>
                <th>VRF Word</th>
                <th>Roll</th>
                <th>Mult</th>
                <th>Base</th>
                <th>Bonus</th>
              </tr>
            </thead>
            <tbody>
              {spins?.map((s) => (
                <tr key={s.requestId.toString()}>
                  <td className="num text-ink-dim">{s.requestId.toString()}</td>
                  <td className="num text-ink">{shortAddress(s.user)}</td>
                  <td className="display text-[14px] tracking-[0.04em] text-ink-dim">
                    {s.symbol || shortAddress(s.token)}
                  </td>
                  <td className="num text-ink-faint max-w-[160px] truncate" title={s.word.toString()}>
                    {s.fulfilled ? s.word.toString() : "pending"}
                  </td>
                  <td className="num text-ink-dim">
                    {s.fulfilled ? (s.word % 10_000n).toString() : ".."}
                  </td>
                  <td>
                    {s.fulfilled ? (
                      <span
                        className={`num ${
                          s.multiplier >= 20
                            ? "text-amber"
                            : s.multiplier > 1
                              ? "text-felt-bright"
                              : "text-ink-dim"
                        }`}
                      >
                        {s.multiplier}x
                      </span>
                    ) : (
                      <span className="chip text-cooldown border-amber-deep">
                        <span className="pulse-dot inline-block h-1.5 w-1.5 rounded-full bg-cooldown" />
                        VRF
                      </span>
                    )}
                  </td>
                  <td className="num text-ink-dim">{formatPoints(s.basePoints, 1)}</td>
                  <td className="num text-amber">
                    {s.fulfilled && s.bonusPoints > 0n
                      ? `+${formatPoints(s.bonusPoints, 1)}`
                      : "0"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      </Reveal>

      {/* Draw ledger cross-link */}
      <Reveal>
      <section className="panel">
        <div className="panel-head">
          <span>Draw Ledger</span>
          <a href="/jackpot" className="font-mono text-[10px] text-amber hover:text-amber-hot normal-case tracking-normal">
            full history on the jackpot page
          </a>
        </div>
        <div className="p-5 font-mono text-[12px] leading-relaxed text-ink-dim">
          {jackpot ? (
            <>
              <span className="num text-ink">{jackpot.draws.length}</span> completed draws on
              record. Each stores its VRF request id, random word, mode, winner, and payout
              on-chain forever: getDraw(drawId) returns the whole record.
            </>
          ) : (
            "Loading draw records..."
          )}
        </div>
      </section>

      </Reveal>

      {/* Verify yourself */}
      <Reveal>
      <section>
        <h2 className="display text-2xl tracking-[0.06em] text-ink uppercase mb-4">
          Verify it yourself
        </h2>
        <div className="flex flex-wrap gap-2">
          <ExplorerLink label="Explorer" href={EXPLORER_URL} />
          {!isMockMode && (
            <>
              <ExplorerLink label="PerpEngine" href={`${EXPLORER_URL}/address/${addresses.engine}`} />
              <ExplorerLink label="PitVault" href={`${EXPLORER_URL}/address/${addresses.vault}`} />
              <ExplorerLink label="PitPoints" href={`${EXPLORER_URL}/address/${addresses.points}`} />
              <ExplorerLink label="SpinVRF" href={`${EXPLORER_URL}/address/${addresses.spinVrf}`} />
              <ExplorerLink label="Jackpot" href={`${EXPLORER_URL}/address/${addresses.jackpot}`} />
              <ExplorerLink label="OracleRouter" href={`${EXPLORER_URL}/address/${addresses.router}`} />
            </>
          )}
          {isMockMode && (
            <span className="font-mono text-[11px] text-ink-faint self-center">
              Contract links appear here once addresses are configured.
            </span>
          )}
        </div>
        <p className="mt-6 font-mono text-[10px] leading-relaxed text-ink-faint max-w-3xl">
          {POINTS_DISCLAIMER}
        </p>
      </section>
      </Reveal>
    </div>
  );
}

function ExplorerLink({ label, href }: { label: string; href: string }) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className="btn-ghost px-4 py-2 font-mono text-[11px] uppercase tracking-[0.1em]"
    >
      {label} ↗
    </a>
  );
}
