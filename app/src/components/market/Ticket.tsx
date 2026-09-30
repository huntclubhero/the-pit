"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { erc20Abi, maxUint256, type Address } from "viem";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { perpEngineAbi } from "@/lib/contracts";
import { addresses, isMockMode } from "@/lib/config";
import { SpinCeremony, rollDemoMultiplier } from "../SpinCeremony";
import { Odometer } from "../Odometer";
import { LeverageBadge } from "../LeverageBadge";
import { SimTag } from "../SimTag";
import {
  basePoints,
  formatPoints,
  formatPrice,
  formatUsdg,
  parseUsdg,
  splitFee,
  traderPoints,
} from "@/lib/format";
import {
  MIN_LEVERAGE_X100,
  MIN_MARGIN,
  PAYOUT_CAP_MULTIPLE,
  formatLeverageX100,
  formatRatePerHour,
  previewOpen,
  tierParams,
} from "@/lib/perp";
import type { MarketSummary, PointsProfile, Side } from "@/lib/types";
import { usePerpDemoActions } from "@/hooks/usePerpPositions";

const MARGIN_CHIPS = [100, 500, 1_000, 5_000];

/**
 * The perp trade ticket: pick a side, post isolated USDG margin, dial leverage
 * up to the mcap-tier cap, and watch the position build LIVE: size, notional,
 * entry at the oracle mark, the exact LIQUIDATION PRICE, the move that gets
 * you there, fees, and the hourly funding estimate. Every number mirrors
 * PerpEngine math (floor division included), so the preview IS the fill.
 */
export function Ticket({
  market,
  profile,
}: {
  market: MarketSummary;
  profile: PointsProfile | undefined;
}) {
  const { address: account } = useAccount();
  const demo = usePerpDemoActions();
  const [side, setSide] = useState<Side>("long");
  const [amount, setAmount] = useState("500");
  const [leverageX100, setLeverageX100] = useState(200);
  const [demoReceipt, setDemoReceipt] = useState<string | null>(null);
  const [spin, setSpin] = useState<{ multiplier: number; base: bigint } | null>(null);
  // Simulated-fill flourish: the CTA fires one expanding ring and reads
  // FILLED (SIM) for a beat before returning to its resting label.
  const [justFilled, setJustFilled] = useState(false);
  const filledTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(
    () => () => {
      if (filledTimer.current) clearTimeout(filledTimer.current);
    },
    [],
  );

  const params = useMemo(
    () => tierParams(market.mcapTier, market.isMajor),
    [market.mcapTier, market.isMajor],
  );
  const maxLev = market.maxLeverageX100;
  const clampedLev = Math.min(leverageX100, maxLev);

  const margin = parseUsdg(amount);
  const preview = useMemo(
    () =>
      margin !== undefined && margin > 0n
        ? previewOpen(
            margin,
            clampedLev,
            market.price1e18,
            params,
            side,
            market.fundingRatePerHour1e18,
            market.borrowRatePerHour1e18,
          )
        : undefined,
    [margin, clampedLev, market.price1e18, params, side, market.fundingRatePerHour1e18, market.borrowRatePerHour1e18],
  );

  const wins = profile?.winStreak ?? 0;
  const dailyCount = profile?.dailyStreak ?? 0;
  const pointsPreview = useMemo(() => {
    if (!preview || preview.blockedReason) return undefined;
    return traderPoints(basePoints(preview.notional), wins, dailyCount);
  }, [preview, wins, dailyCount]);

  const feeSplit = splitFee(preview?.openFee ?? 0n);
  const oracleBlocked = market.oracleStatus !== "OK";
  const blocked =
    margin === undefined ||
    margin === 0n ||
    preview === undefined ||
    preview.blockedReason !== undefined ||
    oracleBlocked;

  const { writeContract, isPending } = useWriteContract();
  const { data: allowance } = useReadContract({
    address: addresses.usdg,
    abi: erc20Abi,
    functionName: "allowance",
    args: account && addresses.engine ? [account, addresses.engine] : undefined,
    query: { enabled: !isMockMode && Boolean(account) },
  });
  const needsApproval =
    !isMockMode && margin !== undefined && (allowance === undefined || allowance < margin);

  function submit() {
    if (margin === undefined || preview === undefined || preview.blockedReason) return;
    if (isMockMode) {
      demo.open({
        marketAddress: market.address,
        symbol: market.symbol,
        side,
        marginNet: preview.marginNet,
        size1e18: preview.size1e18,
        entryPrice1e18: market.price1e18,
        leverageX100: clampedLev,
        maxPayout: preview.maxPayout,
      });
      setDemoReceipt(
        `${side.toUpperCase()} ${formatLeverageX100(clampedLev)} ${market.symbol}: ${formatUsdg(preview.marginNet)} USDG margin, liq ${formatPrice(preview.liqPrice1e18)}`,
      );
      setJustFilled(true);
      if (filledTimer.current) clearTimeout(filledTimer.current);
      filledTimer.current = setTimeout(() => setJustFilled(false), 1_400);
      if (pointsPreview !== undefined && pointsPreview > 0n) {
        setSpin({ multiplier: rollDemoMultiplier(), base: pointsPreview });
      }
      return;
    }
    if (needsApproval) {
      writeContract({
        address: addresses.usdg as Address,
        abi: erc20Abi,
        functionName: "approve",
        args: [addresses.engine as Address, maxUint256],
      });
      return;
    }
    writeContract({
      address: addresses.engine as Address,
      abi: perpEngineAbi,
      functionName: "openPosition",
      args: [market.token as Address, side === "long", margin, clampedLev],
    });
  }

  const levNotches = useMemo(() => {
    const notches: number[] = [200];
    for (let v = 400; v <= maxLev; v += 200) notches.push(v);
    if (!notches.includes(maxLev)) notches.push(maxLev);
    return notches;
  }, [maxLev]);

  return (
    <div className="panel">
      {spin && (
        <SpinCeremony
          multiplier={spin.multiplier}
          basePoints={spin.base}
          onDone={() => setSpin(null)}
        />
      )}
      <div className="panel-head">
        <span className="flex items-center gap-2">
          Trade {market.symbol}
          <SimTag />
        </span>
        <LeverageBadge market={market} align="right" />
      </div>

      <div className="p-4 flex flex-col gap-4">
        {/* Side: a glass thumb slides between LONG and SHORT and carries the
            side's tint with it; the buttons only swap text color. */}
        <div className="side-seg grid grid-cols-2 gap-1">
          <span className="side-thumb" data-side={side} aria-hidden />
          <button
            type="button"
            onClick={() => {
              setSide("long");
              setDemoReceipt(null);
            }}
            aria-pressed={side === "long"}
            className={`press relative display py-2.5 text-lg tracking-[0.1em] uppercase rounded-xl border ${
              side === "long"
                ? "border-transparent text-felt-bright"
                : "border-line-2 text-ink-faint hover:text-ink"
            }`}
          >
            Long
          </button>
          <button
            type="button"
            onClick={() => {
              setSide("short");
              setDemoReceipt(null);
            }}
            aria-pressed={side === "short"}
            className={`press relative display py-2.5 text-lg tracking-[0.1em] uppercase rounded-xl border ${
              side === "short"
                ? "border-transparent text-loss"
                : "border-line-2 text-ink-faint hover:text-ink"
            }`}
          >
            Short
          </button>
        </div>

        {/* Margin */}
        <div className="flex flex-col gap-1.5">
          <div className="flex items-baseline justify-between">
            <label htmlFor="ticket-margin" className="field-label">
              Margin (USDG, isolated)
            </label>
            <span className="font-mono text-[10px] text-ink-faint">
              min {formatUsdg(MIN_MARGIN, 0)} / cap {formatUsdg(params.maxPositionMargin, 0)}
            </span>
          </div>
          <input
            id="ticket-margin"
            className="field-input"
            inputMode="decimal"
            value={amount}
            onChange={(e) => {
              setAmount(e.target.value);
              setDemoReceipt(null);
            }}
            placeholder="0.00"
          />
          <div className="grid grid-cols-4 gap-1">
            {MARGIN_CHIPS.map((c) => (
              <button
                key={c}
                type="button"
                onClick={() => {
                  setAmount(String(c));
                  setDemoReceipt(null);
                }}
                className={`num tap press py-1 text-[12px] rounded-lg border ${
                  amount === String(c)
                    ? "border-amber text-amber"
                    : "border-line-2 text-ink-faint hover:text-ink"
                }`}
              >
                {c.toLocaleString("en-US")}
              </button>
            ))}
          </div>
        </div>

        {/* Leverage */}
        <div className="flex flex-col gap-2">
          <div className="flex items-baseline justify-between">
            <span className="field-label">Leverage</span>
            <span className="num text-lg text-amber">{formatLeverageX100(clampedLev)}</span>
          </div>
          <input
            type="range"
            min={MIN_LEVERAGE_X100}
            max={maxLev}
            step={10}
            value={clampedLev}
            onChange={(e) => {
              setLeverageX100(Number(e.target.value));
              setDemoReceipt(null);
            }}
            className="mult-slider"
            style={
              {
                "--fill": `${((clampedLev - MIN_LEVERAGE_X100) / (maxLev - MIN_LEVERAGE_X100)) * 100}%`,
              } as React.CSSProperties
            }
            aria-label={`Leverage, 1.1x to ${formatLeverageX100(maxLev)}`}
          />
          <div className="flex flex-wrap justify-between items-center gap-y-1.5">
            <div className="flex flex-wrap gap-1">
              {levNotches.map((v) => (
                <button
                  key={v}
                  type="button"
                  onClick={() => {
                    setLeverageX100(v);
                    setDemoReceipt(null);
                  }}
                  className={`num tap press px-2 py-0.5 text-[11px] rounded-lg border ${
                    clampedLev === v
                      ? "border-amber text-amber"
                      : "border-line-2 text-ink-faint hover:text-ink"
                  }`}
                >
                  {formatLeverageX100(v)}
                </button>
              ))}
            </div>
            <span className="font-mono text-[9px] text-ink-faint">
              cap {formatLeverageX100(maxLev)} (mcap tier {market.mcapTier})
            </span>
          </div>
        </div>

        {/* LIVE position build */}
        <div className="border border-line rounded-xl overflow-hidden divide-y divide-[var(--color-line)]">
          <div className="grid grid-cols-2 divide-x divide-[var(--color-line)]">
            <TicketCell label="Position size (notional)">
              <span className="num text-lg text-ink">
                <Odometer value={preview ? formatUsdg(preview.notional) : "0.00"} />
              </span>
            </TicketCell>
            <TicketCell label={`Entry (oracle mark)`}>
              <span className="num text-lg text-ink">
                <Odometer value={formatPrice(market.price1e18)} />
              </span>
            </TicketCell>
          </div>
          {/* Liquidation price: the number that matters */}
          <div className="px-3 py-2.5 bg-pit-1">
            <div className="flex items-baseline justify-between">
              <span className="font-mono text-[10px] uppercase tracking-[0.16em] text-loss">
                Liquidation price
              </span>
              <span className="font-mono text-[10px] text-ink-faint">
                {preview && preview.liqPrice1e18 > 0n
                  ? `${preview.moveToLiqPct >= 0 ? "+" : ""}${preview.moveToLiqPct.toFixed(2)}% away`
                  : "n/a"}
              </span>
            </div>
            <div className="num text-2xl text-loss mt-0.5">
              <Odometer
                value={
                  preview && preview.liqPrice1e18 > 0n ? formatPrice(preview.liqPrice1e18) : "0"
                }
              />
            </div>
            <p className="mt-1 font-mono text-[9px] leading-relaxed text-ink-faint">
              Exact closed form at {(market.mmrBps / 100).toFixed(2)}% maintenance margin. It
              drifts toward entry as funding accrues; add margin any time to push it away.
            </p>
          </div>
        </div>

        {/* MAX WIN: the payout cap, legible */}
        <div className="panel-raised sheen overflow-hidden">
          <div className="px-4 pt-3 pb-3">
            <div className="flex items-baseline justify-between">
              <span className="font-mono text-[10px] uppercase tracking-[0.2em] text-amber">
                Max win: {PAYOUT_CAP_MULTIPLE.toString()}x your margin
              </span>
              <span className="num text-[11px] text-ink-faint">
                max loss {preview ? formatUsdg(preview.marginNet) : "0.00"}
              </span>
            </div>
            <div className="num gold leading-none mt-1" style={{ fontSize: "clamp(2rem, 7vw, 2.9rem)" }}>
              +<Odometer value={preview ? formatUsdg(preview.maxPayout) : "0.00"} />
            </div>
            <div className="mt-1 font-mono text-[10px] text-ink-dim">
              profit caps at {PAYOUT_CAP_MULTIPLE.toString()}x margin: the bound that keeps the
              vault solvent through any pump
            </div>
          </div>
        </div>

        {/* Fees + funding preview */}
        <div className="flex flex-col gap-1.5 font-mono text-[12px]">
          <PreviewRow
            label={`Open fee (${params.openFeeBps} bps of notional)`}
            value={preview ? `-${formatUsdg(preview.openFee)}` : "0.00"}
            tone="dim"
          />
          <PreviewRow
            label="Margin escrowed (net)"
            value={preview ? formatUsdg(preview.marginNet) : "0.00"}
          />
          <PreviewRow
            label={`Close fee est (${params.closeFeeBps} bps)`}
            value={preview ? `-${formatUsdg(preview.closeFeeEst)}` : "0.00"}
            tone="dim"
          />
          <PreviewRow
            label={`Funding est (${formatRatePerHour(market.fundingRatePerHour1e18)})`}
            value={
              preview
                ? `${preview.estFundingPerHourUsdg > 0n ? "-" : "+"}${formatUsdg(
                    preview.estFundingPerHourUsdg < 0n
                      ? -preview.estFundingPerHourUsdg
                      : preview.estFundingPerHourUsdg,
                  )}/h`
                : "0.00"
            }
            tone={preview && preview.estFundingPerHourUsdg > 0n ? "loss" : "win"}
          />
          <PreviewRow
            label="Borrow fee est (vol-scaled, both sides pay)"
            value={preview ? `-${formatUsdg(preview.estBorrowPerHourUsdg, 4)}/h` : "0.00"}
            tone="dim"
          />
          <PreviewRow
            label="Max loss (your margin, never more)"
            value={preview ? `-${formatUsdg(preview.marginNet)}` : "0.00"}
            tone="loss"
          />
          <div className="flex items-baseline justify-between pt-1.5 border-t border-line">
            <span className="text-ink-faint">Points on open (fees pay, points mint)</span>
            <span className="text-amber">
              {pointsPreview !== undefined ? (
                <Odometer value={`+${formatPoints(pointsPreview, 1)}`} />
              ) : (
                "0"
              )}
            </span>
          </div>
        </div>

        {/* Fee split hint */}
        {preview && preview.openFee > 0n && (
          <div className="border border-line rounded-xl px-3 py-2 font-mono text-[10px] leading-relaxed text-ink-faint">
            Open fee {formatUsdg(preview.openFee)} splits{" "}
            <span className="text-amber">{formatUsdg(feeSplit.jackpot)}</span> jackpot :{" "}
            <span className="text-ink-dim">{formatUsdg(feeSplit.referral)}</span> referral :{" "}
            <span className="text-ink-dim">{formatUsdg(feeSplit.vault)}</span> vault :{" "}
            <span className="text-ink-dim">{formatUsdg(feeSplit.buyback)}</span> buyback-burn :{" "}
            <span className="text-ink-dim">{formatUsdg(feeSplit.treasury)}</span> treasury.
            Fresh and high-vol markets add a small open surcharge, 100% to the vault; borrow
            scales with realized vol. Funding stays trader-to-trader (residual to the vault).
          </div>
        )}

        {/* Warnings */}
        {preview?.blockedReason === "min-margin" && (
          <Warning text={`Minimum margin is ${formatUsdg(MIN_MARGIN, 0)} USDG.`} />
        )}
        {preview?.blockedReason === "margin-cap" && (
          <Warning
            text={`Position margin cap for this tier is ${formatUsdg(params.maxPositionMargin, 0)} USDG. Caps force whales into many positions, each paying fees and funding.`}
          />
        )}
        {preview?.blockedReason === "fee-exceeds-margin" && (
          <Warning text="The open fee would swallow this margin. Add margin or drop leverage." />
        )}
        {oracleBlocked && (
          <Warning
            text={
              market.oracleStatus === "COOLDOWN"
                ? "Oracle in cooldown: opens and liquidations pause until sources agree again. Closes and add-margin stay live."
                : "Oracle not serving a live print: opens pause. Closes and add-margin stay live."
            }
          />
        )}

        {/* Submit */}
        <button
          type="button"
          className={`btn-amber py-3 text-lg ${justFilled ? "btn-filled" : ""}`}
          disabled={blocked || isPending || justFilled}
          onClick={submit}
        >
          {justFilled
            ? "Filled: simulated"
            : isPending
              ? "Confirm in wallet"
              : needsApproval
                ? "Approve USDG"
                : `${side === "long" ? "Long" : "Short"} ${market.symbol} ${formatLeverageX100(clampedLev)}${isMockMode ? " (SIM)" : ""}`}
        </button>

        {demoReceipt && (
          <div className="border border-amber-deep bg-amber/5 rounded-xl p-3 font-mono text-[11px] text-ink-dim rise-in">
            <span className="text-amber uppercase tracking-[0.1em]">Simulated fill: no funds moved</span>:{" "}
            <span className="text-ink">{demoReceipt}</span>. It is live in Your Positions below
            (simulated too).
          </div>
        )}

        <p className="font-mono text-[10px] leading-relaxed text-ink-faint">
          Isolated margin: this position can never touch your other positions or cost more than
          its own margin. You trade against the PitVault at the oracle mark: no order book, no
          spread, no admin price path. Liquidation pauses whenever the oracle breaker trips, so
          a manipulated print can never force-close you.
        </p>
      </div>
    </div>
  );
}

function TicketCell({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="px-3 py-2.5">
      <div className="font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">
        {label}
      </div>
      <div className="mt-0.5">{children}</div>
    </div>
  );
}

function PreviewRow({
  label,
  value,
  tone,
}: {
  label: string;
  value: string;
  tone?: "win" | "loss" | "dim";
}) {
  const color =
    tone === "win"
      ? "text-felt-bright"
      : tone === "loss"
        ? "text-loss"
        : tone === "dim"
          ? "text-ink-dim"
          : "text-ink";
  return (
    <div className="flex items-baseline justify-between gap-3">
      <span className="text-ink-faint">{label}</span>
      <span className={`num ${color}`}>{value}</span>
    </div>
  );
}

function Warning({ text }: { text: string }) {
  return (
    <p className="border border-loss-deep bg-loss/5 rounded-xl px-3 py-2 font-mono text-[11px] text-loss rise-in">
      {text}
    </p>
  );
}
