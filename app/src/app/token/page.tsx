"use client";

import { useMemo, useState } from "react";
import { Odometer } from "@/components/Odometer";
import { Reveal } from "@/components/Reveal";
import { SimTag } from "@/components/SimTag";
import { useJackpot } from "@/hooks/useJackpot";
import {
  FEE_SHARE_BUYBACK_BPS,
  FEE_SHARE_JACKPOT_BPS,
  FEE_SHARE_REFERRAL_BPS,
  FEE_SHARE_TREASURY_BPS,
  FEE_SHARE_VAULT_BPS,
  formatUsdg,
  parseUsdg,
  splitFee,
} from "@/lib/format";
import { POINTS_DISCLAIMER } from "@/lib/mock/data";

const SHARES = [
  { key: "buyback", label: "Buyback + burn", bps: FEE_SHARE_BUYBACK_BPS, color: "var(--color-amber)", note: "Accrues in USDG, later swapped for $PIT and burned." },
  { key: "jackpot", label: "Jackpot", bps: FEE_SHARE_JACKPOT_BPS, color: "var(--color-felt-bright)", note: "Feeds the progressive pot, paid out by VRF." },
  { key: "vault", label: "Vault (PLP)", bps: FEE_SHARE_VAULT_BPS, color: "var(--color-tier-a)", note: "The house cut: every trade fee pays the LPs backing it." },
  { key: "treasury", label: "Treasury", bps: FEE_SHARE_TREASURY_BPS, color: "var(--color-ink-dim)", note: "Operations, audits, incentives. Keeps the round-down dust." },
  { key: "referral", label: "Referral pool", bps: FEE_SHARE_REFERRAL_BPS, color: "var(--color-cooldown)", note: "Rewards the degens who bring degens." },
] as const;

const FLYWHEEL = [
  { n: "01", title: "Trade", body: "Open or close a leveraged position. Open and close fees are charged in USDG on notional." },
  { n: "02", title: "Earn points", body: "Every fill mints Pit Points: non-transferable, no monetary value, purely an activity ledger." },
  { n: "03", title: "Airdrop", body: "Points may be considered for retroactive $PIT distributions from the community reserve: at most 12% of supply released per rolling year, and unspent reserve burns after year 4. Who qualifies stays discretionary. No entitlement, no promise." },
  { n: "04", title: "Stake", body: "Once $PIT and staking exist, staking is designed to drop you into a cheaper trading-fee tier, and staked PLP earns the LP incentive stream." },
  { n: "05", title: "Buyback + burn", body: "25% of every fee funds buying $PIT back and burning it, so supply falls as volume rises." },
];

export default function TokenPage() {
  const { data: jackpot } = useJackpot();
  const [feeInput, setFeeInput] = useState("100000");
  const fee = parseUsdg(feeInput) ?? 0n;
  const split = useMemo(() => splitFee(fee), [fee]);

  return (
    <div>
      {/* Hero */}
      <section className="relative border-b border-line bg-pit-1 overflow-hidden">
        <div className="feltgrid absolute inset-0 opacity-40" aria-hidden />
        <div
          className="absolute left-1/2 top-0 -translate-x-1/2 pointer-events-none rays"
          style={{ width: "120vmax", height: "120vmax", opacity: 0.22 }}
          aria-hidden
        />
        <div className="relative px-4 md:px-6 py-14 md:py-20 text-center">
          <div className="font-mono text-[10px] uppercase tracking-[0.3em] text-ink-faint rise-in">
            The tokenomics engine
          </div>
          <h1 className="display gold jackpot-throb leading-[0.85] mt-2 rise-in rise-in-1" style={{ fontSize: "clamp(4.5rem, 20vw, 13rem)" }}>
            $PIT
          </h1>
          <p className="mt-3 display text-2xl md:text-4xl tracking-[0.04em] text-ink uppercase rise-in rise-in-2">
            The flywheel that eats its own supply
          </p>
          <p className="mt-4 max-w-2xl mx-auto text-sm md:text-base text-ink-dim leading-relaxed rise-in rise-in-2">
            Every fee the arena collects splits five ways: a full quarter buys $PIT back and
            burns it, and a fifth pays the vault that takes every trade. More volume, less
            supply. Points you grind today are the ledger a future airdrop is designed to read
            from.
          </p>
        </div>
      </section>

      {/* Where every fee goes: the centerpiece split */}
      <Reveal>
      <section className="px-4 md:px-6 py-10 max-w-6xl mx-auto w-full">
        <h2 className="display text-2xl md:text-3xl tracking-[0.06em] text-ink uppercase">
          Where every fee goes
        </h2>
        <p className="mt-2 font-mono text-[11px] text-ink-dim max-w-2xl">
          Open and close fees (5 bps of notional on majors, 10 bps on memecoin perps) split the
          same five ways, to the wei. Jackpot, referral, vault, and buyback are floored;
          treasury takes the remainder and the round-down dust. On top of the split: the vol
          surcharge on fresh and volatile opens goes 100% to the vault, funding stays
          trader-to-trader (residual to the vault), and vol-scaled borrow pays the vault too.
        </p>

        {/* Stacked bar */}
        <div className="mt-6 h-14 w-full rounded-xl overflow-hidden border border-line-2 flex">
          {SHARES.map((s) => (
            <div
              key={s.key}
              className="relative flex items-center justify-center"
              style={{ width: `${Number(s.bps) / 100}%`, background: s.color }}
              title={`${s.label}: ${Number(s.bps) / 100}%`}
            >
              <span className="num text-[13px] text-pit-0 font-bold">{Number(s.bps) / 100}%</span>
            </div>
          ))}
        </div>
        <div className="mt-4 grid grid-cols-2 md:grid-cols-5 gap-3">
          {SHARES.map((s) => (
            <div key={s.key} className="panel p-3">
              <div className="flex items-center gap-2">
                <span className="inline-block h-2.5 w-2.5 rounded-full" style={{ background: s.color }} />
                <span className="display text-[15px] tracking-[0.06em] uppercase text-ink">
                  {s.label}
                </span>
                <span className="num text-sm text-amber ml-auto">{Number(s.bps) / 100}%</span>
              </div>
              <p className="mt-1.5 font-mono text-[10px] leading-relaxed text-ink-faint">{s.note}</p>
            </div>
          ))}
        </div>

        {/* Live split simulator */}
        <div className="mt-8 panel-raised p-5">
          <div className="flex flex-col md:flex-row md:items-end gap-4">
            <div className="flex flex-col gap-1.5">
              <label htmlFor="fee-sim" className="field-label">
                Fees collected (USDG)
              </label>
              <input
                id="fee-sim"
                className="field-input md:w-64"
                inputMode="decimal"
                value={feeInput}
                onChange={(e) => setFeeInput(e.target.value)}
              />
            </div>
            <p className="font-mono text-[11px] text-ink-dim md:pb-2">
              Drag in any fee total to see the exact split the contract would route.
            </p>
          </div>
          <div className="mt-4 grid grid-cols-2 md:grid-cols-5 gap-3">
            <SplitCell label="Buyback + burn" value={formatUsdg(split.buyback)} accent />
            <SplitCell label="Jackpot" value={formatUsdg(split.jackpot)} tone="win" />
            <SplitCell label="Vault (PLP)" value={formatUsdg(split.vault)} tone="win" />
            <SplitCell label="Treasury" value={formatUsdg(split.treasury)} />
            <SplitCell label="Referral" value={formatUsdg(split.referral)} />
          </div>
        </div>
      </section>
      </Reveal>

      {/* The flywheel */}
      <Reveal>
      <section className="px-4 md:px-6 py-10 max-w-6xl mx-auto w-full">
        <h2 className="display text-2xl md:text-3xl tracking-[0.06em] text-ink uppercase">
          The $PIT flywheel
        </h2>
        <p className="mt-2 font-mono text-[11px] text-ink-dim max-w-2xl">
          Trade to points, points to a possible airdrop, stake for a fee discount, and buyback-burn
          tightens supply the whole time. Each turn feeds the next.
        </p>
        <div className="mt-6 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-3">
          {FLYWHEEL.map((step, i) => (
            <div key={step.n} className={`panel p-4 rise-in rise-in-${Math.min(4, i + 1)} relative`}>
              <div className="num text-xs text-ink-faint">{step.n}</div>
              <div className="display text-xl tracking-[0.06em] text-ink uppercase mt-1">
                {step.title}
              </div>
              <p className="mt-2 text-[12px] leading-relaxed text-ink-dim">{step.body}</p>
              {i < FLYWHEEL.length - 1 && (
                <span
                  className="hidden lg:block absolute -right-2.5 top-1/2 -translate-y-1/2 text-amber-deep"
                  aria-hidden
                >
                  &rsaquo;
                </span>
              )}
            </div>
          ))}
        </div>
        <div className="mt-3 flex items-center justify-center gap-2 font-mono text-[10px] uppercase tracking-[0.2em] text-ink-faint">
          <span className="text-amber">&#8635;</span> supply falls as volume rises
        </div>
      </section>

      </Reveal>

      {/* Buyback + burn detail */}
      <Reveal>
      <section className="px-4 md:px-6 py-8 grid grid-cols-1 lg:grid-cols-3 gap-5 max-w-6xl mx-auto w-full">
        <div className="panel-raised sheen p-5 lg:col-span-2 overflow-hidden">
          <div className="font-mono text-[10px] uppercase tracking-[0.2em] text-ink-faint">
            Deflationary by design
          </div>
          <div className="num gold leading-none mt-2" style={{ fontSize: "clamp(2.6rem, 9vw, 4.2rem)" }}>
            25%
          </div>
          <p className="mt-2 text-sm text-ink-dim leading-relaxed max-w-2xl">
            A full quarter of every fee accrues, in USDG, to a dedicated buyback address. A
            separate executor swaps that USDG for $PIT on the open market and burns it. The trading
            engine only routes the USDG: the swap-and-burn is a distinct, later launch-time
            contract. This describes a mechanism, not a price outcome or a return.
          </p>
        </div>
        <div className="panel p-5">
          <div className="font-mono text-[10px] uppercase tracking-[0.2em] text-ink-faint">
            Jackpot fed alongside <SimTag />
          </div>
          <div className="num text-3xl text-amber mt-2">
            {jackpot ? <Odometer value={formatUsdg(jackpot.pot)} /> : "0.00"}
          </div>
          <p className="mt-2 font-mono text-[11px] leading-relaxed text-ink-dim">
            The same fee stream that funds the burn also grows the jackpot (25%). Trading feeds both
            the deflation and the pot at once.
          </p>
        </div>
      </section>

      </Reveal>

      {/* Points to airdrop, non-promissory */}
      <Reveal>
      <section className="px-4 md:px-6 py-8 max-w-6xl mx-auto w-full">
        <div className="panel p-5">
          <div className="display text-xl tracking-[0.06em] text-ink uppercase">
            Points to airdrop, in plain terms
          </div>
          <div className="mt-3 grid grid-cols-1 md:grid-cols-3 gap-4 text-[12px] leading-relaxed text-ink-dim">
            <p>
              Pit Points are a non-transferable record of activity. They carry no monetary value, no
              redemption right, and no claim on any asset, revenue, or governance.
            </p>
            <p>
              Any $PIT distribution would be retroactive, and who earns one stays entirely at the
              Foundation&apos;s discretion. The reserve itself runs inside a published envelope: at
              most 12% of total supply released per rolling year, and anything undistributed four
              years after TGE is burned. Grinding points is not a purchase and creates no
              entitlement to tokens.
            </p>
            <p>
              Nothing here is an offer, a promise of value, or investment advice. Token, staking, and
              airdrop mechanics are subject to review and may change or not ship at all.
            </p>
          </div>
        </div>
        <p className="mt-4 font-mono text-[10px] leading-relaxed text-ink-faint max-w-3xl">
          {POINTS_DISCLAIMER}
        </p>
      </section>
      </Reveal>
    </div>
  );
}

function SplitCell({
  label,
  value,
  accent,
  tone,
}: {
  label: string;
  value: string;
  accent?: boolean;
  tone?: "win";
}) {
  const color = accent ? "text-amber" : tone === "win" ? "text-felt-bright" : "text-ink";
  return (
    <div className="panel p-3">
      <div className="font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">{label}</div>
      <div className={`num text-xl mt-1 ${color}`}>
        <Odometer value={value} />
      </div>
    </div>
  );
}
