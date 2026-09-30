"use client";

import { useState } from "react";
import { type Address } from "viem";
import { addresses, isMockMode } from "@/lib/config";

type CheckState =
  | { phase: "idle" }
  | { phase: "checking" }
  | { phase: "listable" }
  | { phase: "rejected"; reason: "liquidity" | "sources" }
  | { phase: "invalid" };

/**
 * v2 listing gate explainer + oracle pre-check. Listing a perp market is a
 * governance action behind the 2 day timelock: the oracle router's isListable
 * gate (source count, depth floor, pool seasoning) plus an on-chain FDV
 * assert that assigns the mcap tier (and with it the leverage cap). This
 * dialog runs the oracle pre-check so a proposer knows before proposing.
 */
export function CreateMarketDialog({ onClose }: { onClose: () => void }) {
  const [token, setToken] = useState("");
  const [check, setCheck] = useState<CheckState>({ phase: "idle" });

  function runCheck() {
    if (!/^0x[0-9a-fA-F]{40}$/.test(token.trim())) {
      setCheck({ phase: "invalid" });
      return;
    }
    setCheck({ phase: "checking" });
    if (isMockMode) {
      // Deterministic demo outcome so the flow is fully browsable.
      const nibble = parseInt(token.trim().slice(-1), 16);
      setTimeout(() => {
        if (nibble < 6) setCheck({ phase: "rejected", reason: "liquidity" });
        else if (nibble < 8) setCheck({ phase: "rejected", reason: "sources" });
        else setCheck({ phase: "listable" });
      }, 700);
      return;
    }
    // Chain mode: router.isListable is the source of truth.
    import("@/lib/contracts").then(async ({ oracleRouterContract }) => {
      try {
        const router = oracleRouterContract(addresses.router as Address);
        const listable = (await router.read.isListable([token.trim() as Address])) as boolean;
        setCheck(listable ? { phase: "listable" } : { phase: "rejected", reason: "liquidity" });
      } catch {
        setCheck({ phase: "rejected", reason: "sources" });
      }
    });
  }

  return (
    <div
      className="fixed inset-0 z-[80] flex items-center justify-center bg-pit-0/80 backdrop-blur-sm p-4"
      role="dialog"
      aria-modal="true"
      aria-label="List a market"
      onClick={onClose}
    >
      <div className="panel w-full max-w-lg rise-in" onClick={(e) => e.stopPropagation()}>
        <div className="panel-head">
          <span>List a Perp Market</span>
          <button
            type="button"
            onClick={onClose}
            className="font-mono tap px-2 text-ink-faint hover:text-ink transition-colors"
            aria-label="Close"
          >
            x
          </button>
        </div>
        <div className="p-5 flex flex-col gap-4">
          <p className="text-sm text-ink-dim leading-relaxed">
            Listing is governed, not permissionless: every new market goes through the{" "}
            <span className="text-ink">2 day timelock</span> with an oracle pre-check and an
            on-chain FDV assert that pins the mcap tier (and the leverage cap) at execution.
            The oracle gate: 3+ independent price sources, a{" "}
            <span className="num text-ink">$25,000</span> tracked-liquidity floor, and pool
            seasoning. New markets ramp at 2% of vault TVL for their first 7 days.
          </p>

          <div className="flex flex-col gap-1.5">
            <label htmlFor="create-token" className="field-label">
              Token contract address
            </label>
            <input
              id="create-token"
              className="field-input"
              placeholder="0x..."
              value={token}
              onChange={(e) => {
                setToken(e.target.value);
                setCheck({ phase: "idle" });
              }}
              spellCheck={false}
            />
          </div>

          {check.phase === "invalid" && (
            <p className="font-mono text-[11px] text-loss">Not a valid contract address.</p>
          )}
          {check.phase === "checking" && (
            <p className="font-mono text-[11px] text-ink-dim">
              <span className="pulse-dot inline-block h-1.5 w-1.5 rounded-full bg-amber mr-2" />
              Checking listing rules against the oracle router...
            </p>
          )}
          {check.phase === "rejected" && (
            <div className="border border-loss-deep bg-loss/5 rounded-xl p-3 font-mono text-[11px] leading-relaxed text-ink-dim rise-in">
              <span className="text-loss uppercase tracking-[0.1em]">Not listable.</span>{" "}
              {check.reason === "liquidity" ? (
                <>
                  Tracked pool liquidity is below the{" "}
                  <span className="text-ink">$25,000 USDG floor</span>. The floor exists so a
                  market can never pay out more than its price costs to move. Add liquidity or
                  wait for the pools to grow, then try again.
                </>
              ) : (
                <>
                  Fewer than 3 independent price sources are configured for this token. Every
                  mark in THE PIT is a median of independent sources: no source count, no
                  market. Single-thin-pool tokens never list.
                </>
              )}
            </div>
          )}
          {check.phase === "listable" && (
            <div className="border border-felt-bright/35 bg-felt-bright/10 rounded-xl p-3 font-mono text-[11px] leading-relaxed text-felt-bright rise-in">
              Oracle gate clears. Next step: a governance listing proposal through the timelock
              (tier assignment + market registration). Ping the Pit crew with this address.
            </div>
          )}

          <button
            type="button"
            onClick={runCheck}
            className="btn-amber py-2.5 text-base"
          >
            Check oracle listing gate
          </button>
        </div>
      </div>
    </div>
  );
}
