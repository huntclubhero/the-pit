import type { Metadata } from "next";
import Link from "next/link";
import { Reveal } from "@/components/Reveal";

export const metadata: Metadata = {
  title: "THE PIT: white paper",
  description:
    "The full design of THE PIT: capped payouts below manipulation cost, the PLP vault, two-way volatility pricing, and the $PIT token. Read on-site or download the PDF.",
};

/**
 * The white paper, presented in the site's own language: the document of
 * record is the PDF (served from /the-pit-whitepaper.pdf), and this page walks
 * the load-bearing numbers so nobody has to open a PDF to get the thesis.
 * Everything here mirrors the paper exactly: same figures, same caveats.
 */
export default function WhitepaperPage() {
  return (
    <div>
      {/* Hero: the document, the positioning, the downloads. */}
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
            White paper : v1.0 : July 2026
          </div>
          <h1 className="display text-4xl md:text-6xl leading-[1.02] tracking-[-0.03em] text-ink mt-3 rise-in">
            The house pays out less
            <br />
            <span className="text-amber">than it costs to rob the house.</span>
          </h1>
          <p className="mt-4 max-w-xl text-base md:text-lg text-ink-dim leading-relaxed rise-in rise-in-1">
            Long or short the memes nobody else will list. Up to 15x leverage on Robinhood
            Chain. Isolated margin. Liquidations you can see coming. The full design, every
            parameter, every caveat: seventeen pages, no fluff.
          </p>
          <div className="mt-7 flex flex-wrap gap-3 rise-in rise-in-2">
            <a
              href="/the-pit-whitepaper.pdf"
              download
              className="btn-amber px-6 py-3 text-base inline-flex items-center"
            >
              Download the white paper (PDF)
            </a>
            <a
              href="/the-pit-one-pager.pdf"
              download
              className="btn-ghost px-6 py-3 text-base inline-flex items-center font-medium"
            >
              One-pager (PDF)
            </a>
          </div>
          <p className="mt-5 font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint rise-in rise-in-3">
            Simulated / pre-launch : no funds, not an offer : figures are current parameters
          </p>
        </div>
      </section>

      {/* The thesis, in one panel. */}
      <section className="px-4 md:px-6 py-8">
        <Reveal>
          <div className="panel-raised box-glow-amber sheen overflow-hidden p-5 md:p-6">
            <div className="font-mono text-[10px] uppercase tracking-[0.24em] text-ink-faint">
              Section 04 : the moat
            </div>
            <p className="mt-2 display text-xl md:text-2xl tracking-[-0.01em] text-ink max-w-3xl">
              Every market&apos;s total possible payout is capped below the cost of moving its
              oracle. Manipulation is negative-EV by construction, not by supervision.
            </p>
            <div className="mt-4 rounded-xl border border-line bg-pit-0/60 px-4 py-3 overflow-x-auto">
              <code className="num text-[12px] md:text-[13px] text-amber-hot whitespace-pre">
                {"sum(capped payouts per market)  <=  min( costToMove / safetyFactor , 10% of vault TVL )"}
              </code>
            </div>
            <p className="mt-3 text-[13px] leading-relaxed text-ink-dim max-w-3xl">
              This is the exact quantitative property whose absence killed Drift (roughly $285M),
              Mango (roughly $110M), and squeezed Hyperliquid&apos;s HLP on JELLY, expressed as a
              contract invariant instead of a dashboard alert. Per position, payout is capped at
              9x margin. Single-thin-pool tokens are never listed, there is no admin price path,
              and every setter sits behind a 2-day timelock.
            </p>
          </div>
        </Reveal>
      </section>

      {/* Three pillars pulled from the paper. */}
      <section className="px-4 md:px-6 pb-8">
        <Reveal>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div className="panel p-5">
              <div className="display text-lg uppercase tracking-[0.02em] text-ink">
                Oracle-mark execution
              </div>
              <p className="mt-2 text-[13px] leading-relaxed text-ink-dim">
                GMX-v2 style: no orderbook, no spread. Majors price off a median of independent
                feeds; memecoins off manipulation-resistant multi-pool TWAPs. A deviation
                breaker pauses opens and liquidations the moment spot and TWAP disagree, so
                nobody gets liquidated on a lie.
              </p>
            </div>
            <div className="panel p-5">
              <div className="display text-lg uppercase tracking-[0.02em] text-ink">
                The vault is the house
              </div>
              <p className="mt-2 text-[13px] leading-relaxed text-ink-dim">
                PLP (ERC-4626, USDG) takes the other side of every trade and is paid real
                revenue for it: trader losses, a 20% carve of every fee, 40% of every
                liquidation penalty, the funding residual, and every volatility charge. Real
                yield, not emissions. Outflow per market is hard-capped.
              </p>
            </div>
            <div className="panel p-5">
              <div className="display text-lg uppercase tracking-[0.02em] text-ink">
                Convexity priced twice
              </div>
              <p className="mt-2 text-[13px] leading-relaxed text-ink-dim">
                A vol-scaled surcharge at open and a vol-scaled borrow fee while holding, so the
                straddle harvest is not free. Real-stack PoCs: the spike straddle went from
                +30.20 USDG per cycle to -0.89, and the patient straddle from +387.64 to
                -511.62. The vault captures the volatility either way.
              </p>
            </div>
          </div>
        </Reveal>
      </section>

      {/* The parameter sheet: the paper's tables, in site tables. */}
      <section className="px-4 md:px-6 pb-8 grid grid-cols-1 lg:grid-cols-2 gap-5 items-start">
        <Reveal>
          <div className="panel overflow-hidden">
            <div className="panel-head">
              <span>Leverage by market cap</span>
              <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
                locked at listing
              </span>
            </div>
            <div className="table-scroll">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>Market cap tier</th>
                    <th>Max leverage</th>
                  </tr>
                </thead>
                <tbody>
                  <tr><td>Under $500K</td><td className="num text-amber">4x</td></tr>
                  <tr><td>$500K to $2M</td><td className="num text-amber">6x</td></tr>
                  <tr><td>$2M to $5M</td><td className="num text-amber">6x</td></tr>
                  <tr><td>$5M to $10M</td><td className="num text-amber">8x</td></tr>
                  <tr><td>$10M to $50M</td><td className="num text-amber">10x</td></tr>
                  <tr><td>Over $50M</td><td className="num text-amber">15x</td></tr>
                </tbody>
              </table>
            </div>
          </div>
        </Reveal>
        <Reveal>
          <div className="panel overflow-hidden">
            <div className="panel-head">
              <span>The numbers that matter</span>
              <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
                current parameters
              </span>
            </div>
            <div className="table-scroll">
              <table className="data-table">
                <tbody>
                  <tr><td>Payout cap</td><td className="num">9x margin per position</td></tr>
                  <tr><td>Trade fees</td><td className="num">5 bps majors, 10 bps memes + vol surcharge</td></tr>
                  <tr><td>Fee split (immutable)</td><td className="num">25 jackpot / 10 referral / 20 vault / 25 buyback / 20 treasury</td></tr>
                  <tr><td>Liquidation penalty</td><td className="num">1%: 20 keeper / 40 vault / 40 insurance</td></tr>
                  <tr><td>Funding at full skew</td><td className="num">0.25%/h memes, 0.05%/h majors</td></tr>
                  <tr><td>Vault withdrawals</td><td className="num">24h queue, 25% TVL cap, 1.2x solvency floor</td></tr>
                </tbody>
              </table>
            </div>
          </div>
        </Reveal>
      </section>

      {/* Token, framed exactly like the paper frames it. */}
      <section className="px-4 md:px-6 pb-8">
        <Reveal>
          <div className="panel overflow-hidden">
            <div className="panel-head">
              <span>The $PIT token</span>
              <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
                fixed 1B supply, burn-only
              </span>
            </div>
            <div className="p-5 grid grid-cols-1 md:grid-cols-[1fr_1fr] gap-5">
              <div>
                <div className="table-scroll">
                  <table className="data-table">
                    <tbody>
                      <tr><td>Public launch</td><td className="num text-amber">30%</td><td>liquid at TGE</td></tr>
                      <tr><td>Community reserve</td><td className="num text-amber">50%</td><td>retroactive; max 12%/yr, unspent burns</td></tr>
                      <tr><td>Treasury + community</td><td className="num text-amber">15%</td><td>growth, listings, ops</td></tr>
                      <tr><td>Team</td><td className="num text-amber">5%</td><td>3-mo cliff, vested by mo 6</td></tr>
                    </tbody>
                  </table>
                </div>
              </div>
              <div className="flex flex-col gap-3">
                <p className="text-[13px] leading-relaxed text-ink-dim">
                  Deflationary via buyback-and-burn from real fee revenue: 25% of every trade
                  fee funds the buyback-and-burn and 20% goes to treasury, the immutable
                  on-chain split. A mechanism, not a price claim. Staking unlocks fee-tier
                  discounts, jackpot boosts, and vault-yield boosts.
                </p>
                <p className="font-mono text-[10px] leading-relaxed text-ink-faint">
                  Pit Points are a non-transferable activity ledger with no monetary value and
                  no entitlement to tokens. The community reserve releases at most 12% of total
                  supply per rolling year, and whatever is undistributed four years after TGE
                  is burned; who earns a distribution and what triggers eligibility stay at the
                  Foundation&apos;s discretion, and no individual distribution is promised.
                  Nothing on this page or in the paper is an offer, solicitation, or promise of
                  tokens, returns, or profits.
                </p>
              </div>
            </div>
          </div>
        </Reveal>
      </section>

      {/* Security posture + the closing CTA. */}
      <section className="px-4 md:px-6 pb-10">
        <Reveal>
          <div className="panel overflow-hidden">
            <div className="panel-head">
              <span>Where security stands</span>
              <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
                732 tests green
              </span>
            </div>
            <div className="p-5 flex flex-col gap-4">
              <p className="text-[13px] leading-relaxed text-ink-dim max-w-3xl">
                TDD with wei-exact conservation proofs, fuzzing, invariant harnesses, Slither
                and Aderyn in CI. Internal adversarial gauntlet: twelve parallel attacker
                specialists, a test-first fix wave, an adversarial re-audit, and an economics
                re-audit. Verdict: no drain, no fund lock, no reserve desync. An external audit
                precedes any deposit: zero funds are accepted until it lands.
              </p>
              <div className="flex flex-wrap gap-3">
                <a
                  href="/the-pit-whitepaper.pdf"
                  download
                  className="btn-amber px-6 py-3 text-sm inline-flex items-center"
                >
                  Read the full paper (PDF)
                </a>
                <a
                  href="/the-pit-one-pager.pdf"
                  download
                  className="btn-ghost px-6 py-3 text-sm inline-flex items-center font-medium"
                >
                  One-pager (PDF)
                </a>
                <Link
                  href="/about"
                  className="btn-ghost px-6 py-3 text-sm inline-flex items-center font-medium"
                >
                  The short version
                </Link>
              </div>
            </div>
          </div>
        </Reveal>
      </section>
    </div>
  );
}
