"use client";

import { useMemo, useState } from "react";
import { Boot } from "@/components/Boot";
import { Odometer } from "@/components/Odometer";
import { Reveal } from "@/components/Reveal";
import { useNowSecond } from "@/hooks/useNowSecond";
import { useMarkets } from "@/hooks/useMarkets";
import { useVault, useVaultDemoActions } from "@/hooks/useVault";
import { SimTag } from "@/components/SimTag";
import { isMockMode } from "@/lib/config";
import {
  formatCountdown,
  formatUnits,
  formatUsdg,
  formatUsdgCompact,
  parseUsdg,
} from "@/lib/format";
import { MAX_UTILIZATION_BPS, PRICE_SCALE } from "@/lib/perp";

/**
 * The PitVault (PLP) page: deposit USDG, be the counterparty to every trade.
 * A serious yield product: NAV, share price, the revenue decomposition, the
 * utilization envelope, the two-step withdraw queue, and the exact safety
 * rails that bound what the vault can ever lose.
 */
export default function VaultPage() {
  const { data: vault } = useVault();
  const { data: markets } = useMarkets();
  const actions = useVaultDemoActions();
  const now = useNowSecond();
  const [depositInput, setDepositInput] = useState("10000");
  const [withdrawInput, setWithdrawInput] = useState("5000");
  const [receipt, setReceipt] = useState<string | null>(null);

  const aprTotal = vault
    ? vault.apr.traderLosses +
      vault.apr.fundingResidual +
      vault.apr.borrowFees +
      vault.apr.tradeFees +
      vault.apr.liqPenalties
    : 0;

  const utilizationPct = vault
    ? Math.min(100, Number((vault.totalReserved * 10_000n) / vault.totalAssets) / 100)
    : 0;
  const utilizationCapPct = Number(MAX_UTILIZATION_BPS) / 100;

  const yourValue = vault
    ? (vault.yourShares * vault.sharePrice1e18) / PRICE_SCALE
    : 0n;
  const yourSharePct = vault && vault.totalShares > 0n
    ? Number((vault.yourShares * 100_000n) / vault.totalShares) / 1000
    : 0;

  const depositParsed = parseUsdg(depositInput);
  const withdrawParsed = parseUsdg(withdrawInput);

  const topReserved = useMemo(
    () =>
      [...(markets ?? [])]
        .sort((a, b) => (b.reserved > a.reserved ? 1 : -1))
        .slice(0, 5),
    [markets],
  );

  if (!vault) {
    return <Boot label="Opening the vault" />;
  }

  const aprSlices = [
    { key: "losses", label: "Trader losses", pct: vault.apr.traderLosses, color: "var(--color-amber)", note: "You are the counterparty: every trader loss is vault gain (and every win is vault loss, capped per market)." },
    { key: "funding", label: "Funding residual", pct: vault.apr.fundingResidual, color: "var(--color-felt-bright)", note: "Skew funding: the crowded side pays, and the imbalance residual lands on the vault carrying the net exposure." },
    { key: "borrow", label: "Borrow fees (vol-scaled)", pct: vault.apr.borrowFees, color: "var(--color-tier-a)", note: "Both sides pay per hour for reserved payout capacity, and the rate climbs with realized vol: hot markets pay the house more." },
    { key: "feecarve", label: "Trade-fee carve", pct: vault.apr.tradeFees, color: "var(--color-loss)", note: "20% of every open and close fee routes straight here, plus 100% of the vol surcharge on fresh and volatile opens." },
    { key: "liqshare", label: "Liquidation penalties", pct: vault.apr.liqPenalties, color: "var(--color-ink-dim)", note: "40% of every liquidation penalty lands in the vault (keeper takes 20%, insurance fund the other 40%)." },
  ];

  return (
    <div>
      {/* Hero */}
      <section className="relative border-b border-line bg-pit-1 overflow-hidden">
        <div className="feltgrid absolute inset-0 opacity-40" aria-hidden />
        <div
          className="absolute inset-0 pointer-events-none"
          style={{
            background:
              "radial-gradient(1000px 420px at 22% -120px, rgba(63,195,137,0.07), transparent 66%)",
          }}
          aria-hidden
        />
        <div className="relative px-4 md:px-6 py-10 md:py-14 grid grid-cols-1 lg:grid-cols-[1.05fr_0.95fr] gap-8 lg:gap-12 items-center">
          <div>
            <div className="font-mono text-[10px] uppercase tracking-[0.24em] text-ink-faint rise-in">
              PitVault : PLP : ERC-4626 (modified)
            </div>
            <h1 className="display text-5xl md:text-7xl leading-[0.88] text-ink mt-3 rise-in">
              Be the <span className="text-amber">house.</span>
            </h1>
            <p className="mt-4 max-w-2xl text-sm md:text-base text-ink-dim leading-relaxed rise-in rise-in-1">
              Deposit USDG, mint PLP, and take the other side of every leveraged trade in THE PIT.
              The vault quotes every fill at the oracle mark and earns the flows that never stop:
              trader losses, funding residual, vol-scaled borrow, a 20% cut of every trade fee, and
              40% of every liquidation penalty. Its downside is engineered: per-market outflow is
              capped below the cost of moving that market&apos;s price.
            </p>
          </div>

          {/* The bankroll: one oversized number, then the vitals. */}
          <div className="rise-in rise-in-1">
            <div className="panel-raised box-glow-amber sheen overflow-hidden">
              <div className="px-5 pt-4 pb-5">
                <div className="flex items-baseline justify-between gap-3">
                  <span className="font-mono text-[10px] uppercase tracking-[0.24em] text-ink-faint">
                    House bankroll (USDG)
                  </span>
                  {isMockMode ? (
                    <span className="chip text-amber border-amber-deep">Simulated</span>
                  ) : (
                    <span className="chip text-felt-bright border-felt">LIVE</span>
                  )}
                </div>
                <div
                  className="num gold leading-none mt-2"
                  style={{ fontSize: "clamp(2.6rem, 6vw, 4.4rem)" }}
                >
                  <Odometer value={formatUsdg(vault.totalAssets, 0)} />
                </div>
                <div className="mt-4 grid grid-cols-3 gap-px bg-line border border-line rounded-xl overflow-hidden">
                  <HeroCell label="PLP price">
                    <span className="num text-ink text-lg md:text-xl">
                      <Odometer value={formatUnits(vault.sharePrice1e18, 18, 4)} />
                    </span>
                  </HeroCell>
                  <HeroCell label="30d yield, ann.">
                    <span className="num text-felt-bright text-lg md:text-xl">
                      {aprTotal.toFixed(1)}%
                    </span>
                  </HeroCell>
                  <HeroCell label="Depositors">
                    <span className="num text-ink text-lg md:text-xl">{vault.depositors}</span>
                  </HeroCell>
                </div>
                <div className="mt-3 font-mono text-[10px] leading-relaxed text-ink-faint">
                  Every trade in the arena settles against this number. Trailing yield is
                  history, not a promise: the house can lose a hand, never the building.
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="px-4 md:px-6 py-6 grid grid-cols-1 xl:grid-cols-[1fr_400px] gap-5">
        {/* Left: the yield story + risk envelope */}
        <div className="flex flex-col gap-5 min-w-0">
          {/* Where the yield comes from */}
          <Reveal>
          <div className="panel">
            <div className="panel-head">
              <span>Where the yield comes from</span>
              <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
                real revenue, not emissions
              </span>
            </div>
            <div className="p-4">
              <div className="h-10 w-full rounded-xl overflow-hidden border border-line-2 flex">
                {aprSlices.map((s) => (
                  <div
                    key={s.key}
                    className="relative flex items-center justify-center transition-[width] duration-[600ms]"
                    style={{ width: `${(s.pct / aprTotal) * 100}%`, background: s.color }}
                    title={`${s.label}: ${s.pct.toFixed(1)}%`}
                  >
                    <span className="num text-[11px] text-pit-0 font-bold">
                      {s.pct.toFixed(1)}%
                    </span>
                  </div>
                ))}
              </div>
              <div className="mt-3 grid grid-cols-1 sm:grid-cols-2 gap-3">
                {aprSlices.map((s) => (
                  <div key={s.key} className="panel p-3">
                    <div className="flex items-center gap-2">
                      <span
                        className="inline-block h-2.5 w-2.5 rounded-full"
                        style={{ background: s.color }}
                      />
                      <span className="display text-[14px] tracking-[0.06em] uppercase text-ink">
                        {s.label}
                      </span>
                      <span className="num text-sm text-amber ml-auto">{s.pct.toFixed(1)}%</span>
                    </div>
                    <p className="mt-1.5 font-mono text-[10px] leading-relaxed text-ink-faint">
                      {s.note}
                    </p>
                  </div>
                ))}
              </div>
              <p className="mt-3 font-mono text-[10px] leading-relaxed text-ink-faint">
                Staked PLP additionally earns the $PIT liquidity-mining tranche (15% of supply,
                streamed; details at token launch). Trailing figures are historical, not a
                promise of future yield: the vault carries the net trader PnL and can lose.
              </p>
            </div>
          </div>
          </Reveal>

          {/* Utilization + per-market caps */}
          <Reveal>
          <div className="panel">
            <div className="panel-head">
              <span>Risk envelope</span>
              <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
                what the vault can ever lose, bounded
              </span>
            </div>
            <div className="p-4 flex flex-col gap-4">
              <div>
                <div className="flex items-baseline justify-between font-mono text-[10px] uppercase tracking-[0.14em]">
                  <span className="text-ink-faint">
                    Reserved payout capacity: {formatUsdgCompact(vault.totalReserved)} of{" "}
                    {formatUsdgCompact(vault.totalAssets)}
                  </span>
                  <span className="text-amber">cap {utilizationCapPct}%</span>
                </div>
                <div className="util-track mt-1.5">
                  <div className="util-fill" style={{ width: `${utilizationPct}%` }} />
                  <div className="util-cap" style={{ left: `${utilizationCapPct}%` }} />
                </div>
                <p className="mt-1.5 font-mono text-[10px] leading-relaxed text-ink-faint">
                  {utilizationPct.toFixed(1)}% utilized. Every position reserves its full max
                  payout (9x margin) up front; opens revert past the {utilizationCapPct}% cap.
                  Closes and liquidations always work.
                </p>
              </div>

              <div className="table-scroll">
                <table className="data-table">
                  <thead>
                    <tr>
                      <th>Market</th>
                      <th>Reserved</th>
                      <th>Cap</th>
                      <th>Bound by</th>
                    </tr>
                  </thead>
                  <tbody>
                    {topReserved.map((m) => (
                      <tr key={m.address}>
                        <td>
                          <span className="display text-[15px] tracking-[0.04em] text-ink">
                            {m.symbol}
                          </span>
                        </td>
                        <td className="num text-ink">{formatUsdgCompact(m.reserved)}</td>
                        <td className="num text-ink-dim">{formatUsdgCompact(m.reserveCap)}</td>
                        <td className="font-mono text-[10px] text-ink-faint">
                          {Number.isFinite(m.costToMoveUsd)
                            ? "cost-to-move / 10% TVL"
                            : "10% TVL (independent feed)"}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 font-mono text-[10px] leading-relaxed text-ink-faint">
                <div className="warn-soft p-3">
                  <span className="text-amber uppercase tracking-[0.1em]">The core inequality.</span>{" "}
                  Sum of max payouts per market stays below that market&apos;s cost-to-move
                  estimate. An attacker who pumps an oracle spends more moving the price than
                  the vault could ever pay out. This is the invariant Drift and Mango lacked.
                </div>
                <div className="warn-soft p-3">
                  <span className="text-amber uppercase tracking-[0.1em]">Loss waterfall.</span>{" "}
                  Trader margin first, liquidation penalties second (40% vault, 40% insurance
                  fund, 20% keeper), ADL against ranked winners last. LP losses beyond
                  per-market reserves are impossible while the caps hold. No socialized haircut
                  path exists in code.
                </div>
              </div>
            </div>
          </div>

          </Reveal>

          {/* Vault activity */}
          <Reveal>
          <div className="panel">
            <div className="panel-head">
              <span>Vault activity</span>
            </div>
            <div className="table-scroll">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>Flow</th>
                    <th>Amount</th>
                    <th>Counterparty</th>
                    <th>Age</th>
                  </tr>
                </thead>
                <tbody>
                  {vault.flows.map((f) => (
                    <tr key={f.id}>
                      <td>
                        <FlowBadge kind={f.kind} />
                      </td>
                      <td
                        className={`num ${
                          f.kind === "trader-loss" || f.kind === "deposit" || f.kind === "funding" || f.kind === "borrow" || f.kind === "fee-share" || f.kind === "liq-penalty"
                            ? "text-felt-bright"
                            : f.kind === "trader-win"
                              ? "text-loss"
                              : "text-ink-dim"
                        }`}
                      >
                        {f.kind === "trader-win" ? "-" : "+"}
                        {formatUsdg(f.amount)}
                      </td>
                      <td className="font-mono text-[10px] text-ink-faint">
                        {f.who.startsWith("0x") ? `${f.who.slice(0, 6)}..${f.who.slice(-4)}` : f.who}
                      </td>
                      <td className="num text-ink-faint">
                        {Math.max(0, Math.floor((now - f.at) / 60))}m
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
          </Reveal>
        </div>

        {/* Right: your position + deposit/withdraw */}
        <div className="min-w-0">
          <div className="xl:sticky xl:top-16 flex flex-col gap-4">
            {/* Your position */}
            <div className="panel-raised sheen overflow-hidden">
              <div className="px-4 pt-3.5 pb-4">
                <div className="font-mono text-[10px] uppercase tracking-[0.2em] text-ink-faint">
                  Your PLP position <SimTag />
                </div>
                <div className="num gold leading-none mt-1.5" style={{ fontSize: "clamp(2rem, 7vw, 2.8rem)" }}>
                  <Odometer value={formatUsdg(yourValue)} />
                </div>
                <div className="mt-1 font-mono text-[11px] text-ink-dim">
                  {formatUsdg(vault.yourShares)} PLP : {yourSharePct.toFixed(3)}% of the vault
                </div>
                {vault.yourClaimable > 0n && (
                  <div className="mt-2 font-mono text-[11px] text-felt-bright">
                    {formatUsdg(vault.yourClaimable)} USDG claimed to wallet
                  </div>
                )}
              </div>
            </div>

            {/* Deposit */}
            <div className="panel">
              <div className="panel-head">
                <span>Deposit</span>
                <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
                  instant : 10 bps fee to NAV
                </span>
              </div>
              <div className="p-4 flex flex-col gap-3">
                <div className="flex flex-col gap-1.5">
                  <label htmlFor="vault-deposit" className="field-label">
                    Amount (USDG)
                  </label>
                  <input
                    id="vault-deposit"
                    className="field-input"
                    inputMode="decimal"
                    value={depositInput}
                    onChange={(e) => {
                      setDepositInput(e.target.value);
                      setReceipt(null);
                    }}
                  />
                </div>
                <div className="font-mono text-[10px] text-ink-faint">
                  mints ~
                  <span className="text-ink">
                    {depositParsed !== undefined && vault.sharePrice1e18 > 0n
                      ? formatUsdg(
                          (((depositParsed * 9_990n) / 10_000n) * PRICE_SCALE) /
                            vault.sharePrice1e18,
                        )
                      : "0.00"}
                  </span>{" "}
                  PLP : deposit cap 20% of TVL per 24h epoch
                </div>
                <button
                  type="button"
                  className="btn-amber py-2.5 text-base"
                  disabled={depositParsed === undefined || depositParsed === 0n || !isMockMode}
                  onClick={() => {
                    if (depositParsed !== undefined && depositParsed > 0n) {
                      actions.deposit(depositParsed);
                      setReceipt(
                        `Simulated deposit of ${formatUsdg(depositParsed)} USDG into PLP. No funds moved.`,
                      );
                    }
                  }}
                >
                  Deposit USDG{isMockMode ? " (SIM)" : ""}
                </button>
              </div>
            </div>

            {/* Withdraw queue */}
            <div className="panel">
              <div className="panel-head">
                <span>Withdraw queue</span>
                <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
                  two-step : epoch rolls in {formatCountdown(vault.epochEndsAt - now)}
                </span>
              </div>
              <div className="p-4 flex flex-col gap-3">
                {vault.yourRequest ? (
                  <div className="border border-amber-deep bg-amber/5 rounded-xl p-3 font-mono text-[11px] leading-relaxed text-ink-dim rise-in">
                    <span className="text-amber uppercase tracking-[0.1em]">Queued.</span>{" "}
                    {formatUsdg(vault.yourRequest.shares)} PLP locked into epoch{" "}
                    {vault.yourRequest.epoch}. Prices at the epoch-boundary NAV, claimable in{" "}
                    {formatCountdown(Math.max(0, vault.yourRequest.claimableAt - now))}
                    {isMockMode ? " (demo settles instantly)" : ""}.
                    <button
                      type="button"
                      className="btn-amber w-full mt-3 py-2 text-sm"
                      onClick={() => {
                        actions.claim();
                        setReceipt("Simulated claim at epoch NAV. No funds moved.");
                      }}
                    >
                      Claim USDG
                    </button>
                  </div>
                ) : (
                  <>
                    <div className="flex flex-col gap-1.5">
                      <label htmlFor="vault-withdraw" className="field-label">
                        Shares to queue (PLP)
                      </label>
                      <input
                        id="vault-withdraw"
                        className="field-input"
                        inputMode="decimal"
                        value={withdrawInput}
                        onChange={(e) => {
                          setWithdrawInput(e.target.value);
                          setReceipt(null);
                        }}
                      />
                    </div>
                    <button
                      type="button"
                      className="btn-ghost py-2.5 text-sm font-mono uppercase tracking-[0.08em]"
                      disabled={
                        withdrawParsed === undefined ||
                        withdrawParsed === 0n ||
                        withdrawParsed > vault.yourShares ||
                        !isMockMode
                      }
                      onClick={() => {
                        if (withdrawParsed !== undefined && withdrawParsed > 0n) {
                          actions.requestWithdraw(withdrawParsed);
                          setReceipt(
                            `Simulated: queued ${formatUsdg(withdrawParsed)} PLP for withdrawal. No funds moved.`,
                          );
                        }
                      }}
                    >
                      Request withdrawal{isMockMode ? " (SIM)" : ""}
                    </button>
                  </>
                )}
                <p className="font-mono text-[10px] leading-relaxed text-ink-faint">
                  Requests price at the NEXT epoch boundary NAV (24h epochs), capped at 25% of
                  TVL per epoch pro-rata; the remainder rolls. Withdrawals also never push
                  assets below 1.2x reserved payouts. Nobody front-runs a loss, and nobody
                  flash-drains the counterparty.
                </p>
                {receipt && (
                  <div className="border border-felt-bright/35 bg-felt-bright/10 rounded-xl p-2.5 font-mono text-[11px] text-felt-bright rise-in">
                    {receipt}
                  </div>
                )}
              </div>
            </div>

            {/* Counterparty framing */}
            <div className="panel p-4">
              <div className="display text-lg tracking-[0.06em] uppercase text-ink">
                You are the counterparty
              </div>
              <p className="mt-2 text-[12px] leading-relaxed text-ink-dim">
                Every long and every short in THE PIT executes against this vault at the oracle
                mark. There is no order book and no market maker: PLP holders collectively take
                the other side of the net open interest and keep everything traders pay to hold
                it. When leverage wins big, the vault pays (capped, reserved up front); when
                leverage dies, the vault eats the margin AND banks 40% of the penalty. Add the
                20% fee carve, vol-scaled borrow, and the funding residual: the house has a real
                edge now, on every trade, win or lose. Trailing, not a promise.
              </p>
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}

function HeroCell({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="bg-pit-2 p-4">
      <div className="font-mono text-[10px] uppercase tracking-[0.16em] text-ink-faint">
        {label}
      </div>
      <div className="mt-1">{children}</div>
    </div>
  );
}

function FlowBadge({ kind }: { kind: string }) {
  const map: Record<string, { label: string; cls: string }> = {
    deposit: { label: "deposit", cls: "text-felt-bright border-felt" },
    "withdraw-request": { label: "withdraw req", cls: "text-cooldown border-amber-deep" },
    claim: { label: "claim", cls: "text-ink-dim" },
    "trader-loss": { label: "trader loss", cls: "text-felt-bright border-felt" },
    "trader-win": { label: "trader win", cls: "text-loss border-loss-deep" },
    funding: { label: "funding", cls: "text-amber border-amber-deep" },
    borrow: { label: "borrow fees", cls: "text-amber border-amber-deep" },
    "fee-share": { label: "fee carve", cls: "text-amber border-amber-deep" },
    "liq-penalty": { label: "liq penalty", cls: "text-amber border-amber-deep" },
  };
  const it = map[kind] ?? { label: kind, cls: "text-ink-dim" };
  return <span className={`chip ${it.cls}`}>{it.label}</span>;
}
