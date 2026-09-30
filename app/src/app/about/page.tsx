"use client";

import Link from "next/link";
import { useMemo } from "react";
import { Odometer } from "@/components/Odometer";
import { OracleEdgeShowcase } from "@/components/OracleEdge";
import { Reveal } from "@/components/Reveal";
import { SimTag } from "@/components/SimTag";
import { useMarkets } from "@/hooks/useMarkets";
import { useVault } from "@/hooks/useVault";
import { formatUsdgCompact } from "@/lib/format";
import { formatLeverageX100 } from "@/lib/perp";

/**
 * The story page. The terminal is the product; this is the pitch, kept light:
 * the promise, the safety mechanics in three cards, the manipulation math,
 * memes first / majors second, the vault teaser, and where the audit stands.
 */
export default function AboutPage() {
  const { data: markets } = useMarkets();
  const { data: vault } = useVault();

  const memes = useMemo(() => markets?.filter((m) => !m.isMajor) ?? [], [markets]);
  const majors = useMemo(() => markets?.filter((m) => m.isMajor) ?? [], [markets]);

  // The showcase market for the manipulation chart: the one with the widest
  // gap between attack cost and payout cap reads clearest.
  const showcase = useMemo(() => {
    const eligible = memes.filter((m) => Number.isFinite(m.costToMoveUsd));
    if (eligible.length === 0) return undefined;
    return [...eligible].sort((a, b) => {
      const ra = a.costToMoveUsd / (Number(a.reserveCap) / 1e6);
      const rb = b.costToMoveUsd / (Number(b.reserveCap) / 1e6);
      return rb - ra;
    })[0];
  }, [memes]);

  const vaultAprTotal = vault
    ? vault.apr.traderLosses +
      vault.apr.fundingResidual +
      vault.apr.borrowFees +
      vault.apr.tradeFees +
      vault.apr.liqPenalties
    : 0;

  return (
    <div>
      {/* Hero: the approved positioning, nothing else in the way. */}
      <section className="relative border-b border-line bg-pit-1 overflow-hidden">
        <div className="feltgrid absolute inset-0 opacity-40" aria-hidden />
        <div
          className="absolute inset-0 pointer-events-none"
          style={{
            background:
              "radial-gradient(1100px 460px at 78% -140px, rgba(237,162,59,0.09), transparent 66%)",
          }}
          aria-hidden
        />
        <div className="relative px-4 md:px-6 py-12 md:py-16 max-w-4xl">
          <div className="font-mono text-[10px] uppercase tracking-[0.24em] text-ink-faint rise-in">
            THE PIT : Robinhood Chain
          </div>
          <h1 className="display text-4xl md:text-6xl leading-[1.02] tracking-[-0.03em] text-ink mt-3 rise-in">
            Long or short the memes
            <br />
            <span className="text-amber">nobody else will list.</span>
          </h1>
          <p className="mt-4 max-w-xl text-base md:text-lg text-ink-dim leading-relaxed rise-in rise-in-1">
            Up to 15x leverage on Robinhood Chain. Isolated margin. Liquidations you can
            see coming.
          </p>
          <div className="mt-7 flex flex-wrap gap-3 rise-in rise-in-2">
            <Link href="/" className="btn-amber px-6 py-3 text-base inline-flex items-center">
              Open the terminal
            </Link>
            <Link
              href="/vault"
              className="btn-ghost px-6 py-3 text-base inline-flex items-center font-medium"
            >
              Be the house
            </Link>
          </div>
          {/* The leverage hook */}
          <div className="mt-8 inline-flex flex-wrap items-end gap-x-4 gap-y-2 rise-in rise-in-3">
            <div>
              <div className="font-mono text-[10px] uppercase tracking-[0.2em] text-ink-faint">
                Margin
              </div>
              <div className="num text-2xl md:text-3xl text-ink">$100</div>
            </div>
            <div className="display text-lg text-ink-faint pb-1">controls</div>
            <div>
              <div className="font-mono text-[10px] uppercase tracking-[0.2em] text-amber">
                at 15x on majors
              </div>
              <div className="num gold text-3xl md:text-4xl leading-none">$1,500</div>
            </div>
            <div className="pb-1 font-mono text-[10px] text-ink-faint">
              win up to 9x margin
              <br />
              lose at most the $100
            </div>
          </div>
        </div>
      </section>

      {/* Three cards: the whole risk story, no documentation wall. */}
      <section className="px-4 md:px-6 py-8">
        <Reveal>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            <PromiseCard
              title="Max loss = your margin"
              body="Every position is isolated. It can never touch your other positions, and no insurance-fund squeeze can come for the rest. The worst case is priced on the ticket before you click."
            />
            <PromiseCard
              title="Liquidations you can see coming"
              body="We warn you at 50% and 75% of the way to liquidation, and the Add Margin button lights up before the keeper ever gets a shot. You can watch it coming, and you can buy it off."
            />
            <PromiseCard
              title="Manipulation is priced out"
              body="Every market's total payout is capped below the cost of moving its oracle. Pumping the price to cash out costs more than the vault could ever pay you. Negative EV by construction."
            />
          </div>
        </Reveal>
      </section>

      {/* The manipulation chart: the security model in one picture. */}
      <section className="px-4 md:px-6 pb-8 grid grid-cols-1 lg:grid-cols-[1fr_0.9fr] gap-5 items-start">
        <Reveal>
          {showcase ? <OracleEdgeShowcase market={showcase} /> : <div className="panel p-6" />}
        </Reveal>
        <Reveal>
          <div className="flex flex-col gap-4">
            <div className="panel p-5">
              <div className="display text-lg uppercase tracking-[0.02em] text-ink">
                How the price is made
              </div>
              <p className="mt-2 text-[13px] leading-relaxed text-ink-dim">
                Every mark is a median across independent sources: Chainlink where it
                exists, Pyth, and manipulation-resistant TWAPs across multiple pools. One
                bad print gets outvoted; an outlier trips a cooldown that pauses opens and
                liquidations until sources agree again. There is no admin price path.
              </p>
              <Link
                href="/fairness"
                className="mt-3 inline-block font-mono text-[10px] uppercase tracking-[0.1em] text-amber hover:text-amber-hot transition-colors"
              >
                The full fairness story
              </Link>
            </div>
            <div className="panel p-5">
              <div className="display text-lg uppercase tracking-[0.02em] text-ink">
                Leverage follows market cap
              </div>
              <p className="mt-2 text-[13px] leading-relaxed text-ink-dim">
                4x under $500K FDV, stepping to 15x above $50M, locked at listing. Funding
                is skew-based: the crowded side pays. Tokens too thin to price safely never
                get a market at all.
              </p>
            </div>
          </div>
        </Reveal>
      </section>

      {/* Memes lead. Majors ride along, clearly second. */}
      <section className="px-4 md:px-6 pb-8">
        <Reveal>
          <div className="panel overflow-hidden">
            <div className="panel-head">
              <span>The list</span>
              <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
                memes first, on purpose
              </span>
            </div>
            <div className="p-5 flex flex-col gap-5">
              <div>
                <div className="flex items-baseline gap-3">
                  <span className="display text-[14px] uppercase tracking-[0.06em] text-amber">
                    Memecoins
                  </span>
                  <span className="font-mono text-[10px] text-ink-faint">
                    {memes.length} live markets: the reason THE PIT exists
                  </span>
                </div>
                <div className="mt-2.5 flex flex-wrap gap-2">
                  {memes.map((m) => (
                    <Link
                      key={m.address}
                      href={`/market/${m.address}`}
                      className="chip text-ink-dim border-line-2 hover:border-amber-deep hover:text-ink transition-colors"
                    >
                      <span className="text-ink">{m.symbol}</span>
                      <span className="text-ink-faint">{formatLeverageX100(m.maxLeverageX100)}</span>
                    </Link>
                  ))}
                </div>
              </div>
              <div className="border-t border-line pt-4">
                <div className="flex items-baseline gap-3">
                  <span className="display text-[14px] uppercase tracking-[0.06em] text-ink-faint">
                    Majors (secondary)
                  </span>
                  <span className="font-mono text-[10px] text-ink-faint">
                    independent Chainlink feeds, the full 15x
                  </span>
                </div>
                <div className="mt-2.5 flex flex-wrap gap-2">
                  {majors.map((m) => (
                    <Link
                      key={m.address}
                      href={`/market/${m.address}`}
                      className="chip text-ink-faint border-line hover:border-amber-deep hover:text-ink transition-colors"
                    >
                      {m.symbol}
                      <span>{formatLeverageX100(m.maxLeverageX100)}</span>
                    </Link>
                  ))}
                </div>
                <p className="mt-2.5 font-mono text-[10px] leading-relaxed text-ink-faint max-w-2xl">
                  WBTC, WETH, and WSOL carry the deep-feed 15x tier. They are here for the
                  range, not the headline. The headline is the list nobody else will touch.
                </p>
              </div>
            </div>
          </div>
        </Reveal>
      </section>

      {/* Be the house: the other side of every trade. */}
      <section className="px-4 md:px-6 pb-8">
        <Reveal>
          <Link
            href="/vault"
            className="group block panel-raised box-glow-amber sheen overflow-hidden"
          >
            <div className="px-5 py-5 grid grid-cols-1 md:grid-cols-[auto_1fr_auto] gap-x-8 gap-y-3 items-center">
              <div>
                <div className="font-mono text-[10px] uppercase tracking-[0.24em] text-ink-faint group-hover:text-amber transition-colors">
                  The Vault (PLP) : be the house
                </div>
                <div className="mt-1 flex items-baseline gap-2">
                  <span className="num gold leading-none text-4xl">
                    {vault ? <Odometer value={formatUsdgCompact(vault.totalAssets)} /> : "0"}
                  </span>
                  <span className="font-mono text-[10px] text-ink-dim">USDG TVL</span>
                  <SimTag />
                </div>
              </div>
              <p className="text-[13px] leading-relaxed text-ink-dim max-w-xl">
                Deposit USDG and take the other side of every trade: trader losses, funding
                residual, vol-scaled borrow, 20% of every fee, 40% of every liquidation
                penalty. Outflow per market is hard-capped. The house can lose a hand,
                never the building.
              </p>
              <div className="text-left md:text-right">
                <div className="num text-felt-bright text-3xl leading-none">
                  {vaultAprTotal.toFixed(1)}%
                </div>
                <div className="mt-1 font-mono text-[10px] text-ink-dim">
                  30d net yield, annualized <SimTag />
                </div>
              </div>
            </div>
          </Link>
        </Reveal>
      </section>

      {/* Security: honest, no overclaiming. */}
      <section className="px-4 md:px-6 pb-10">
        <Reveal>
          <div className="panel overflow-hidden">
            <div className="panel-head">
              <span>Where security stands</span>
              <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
                the honest version
              </span>
            </div>
            <div className="p-5 grid grid-cols-1 md:grid-cols-3 gap-4">
              <SecurityCell
                state="done"
                title="Internal adversarial audit"
                body="Multiple red-team waves across oracle manipulation, liquidations, vault accounting, reentrancy, and game theory. Full contract test suite green."
              />
              <SecurityCell
                state="planned"
                title="External audit"
                body="Planned before any deposit is possible. The contracts do not touch a dollar until it lands."
              />
              <SecurityCell
                state="live"
                title="Zero funds accepted today"
                body="Everything on this site runs on simulated data, and every number is marked SIM. No deposits, no positions, no funds move until contracts and the audit ship."
              />
            </div>
          </div>
        </Reveal>
      </section>
    </div>
  );
}

function PromiseCard({ title, body }: { title: string; body: string }) {
  return (
    <div className="panel p-5">
      <div className="display text-lg uppercase tracking-[0.02em] text-ink">{title}</div>
      <p className="mt-2 text-[13px] leading-relaxed text-ink-dim">{body}</p>
    </div>
  );
}

function SecurityCell({
  state,
  title,
  body,
}: {
  state: "done" | "planned" | "live";
  title: string;
  body: string;
}) {
  const chip =
    state === "done" ? (
      <span className="chip text-felt-bright border-felt">Done</span>
    ) : state === "planned" ? (
      <span className="chip text-amber border-amber-deep">Planned</span>
    ) : (
      <span className="chip text-ink-dim border-line-2">Right now</span>
    );
  return (
    <div className="panel p-4">
      <div className="flex items-center justify-between gap-3">
        <span className="display text-[14px] uppercase tracking-[0.04em] text-ink">{title}</span>
        {chip}
      </div>
      <p className="mt-2 font-mono text-[10px] leading-relaxed text-ink-faint">{body}</p>
    </div>
  );
}
