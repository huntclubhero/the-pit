import type { Address } from "viem";
import { robinhoodChain, robinhoodTestnet } from "./chain";

/**
 * Typed contract address configuration, sourced exclusively from env.
 * When any address is missing the app runs in MOCK MODE: every page renders
 * fully from realistic demo data and no chain connection is attempted.
 *
 * v2 contract set: PerpEngine (positions), PitVault (PLP), InsuranceFund,
 * PerpRiskConfig (tiers), plus the reused OracleRouter / PitPoints / SpinVRF /
 * Jackpot rails. The v1 Market / MarketFactory pair is retired.
 */

function readAddress(value: string | undefined): Address | undefined {
  if (!value) return undefined;
  if (!/^0x[0-9a-fA-F]{40}$/.test(value)) return undefined;
  return value as Address;
}

export const addresses = {
  engine: readAddress(process.env.NEXT_PUBLIC_PERP_ENGINE),
  vault: readAddress(process.env.NEXT_PUBLIC_PIT_VAULT),
  insuranceFund: readAddress(process.env.NEXT_PUBLIC_INSURANCE_FUND),
  riskConfig: readAddress(process.env.NEXT_PUBLIC_RISK_CONFIG),
  points: readAddress(process.env.NEXT_PUBLIC_POINTS),
  spinVrf: readAddress(process.env.NEXT_PUBLIC_SPINVRF),
  jackpot: readAddress(process.env.NEXT_PUBLIC_JACKPOT),
  usdg: readAddress(process.env.NEXT_PUBLIC_USDG),
  router: readAddress(process.env.NEXT_PUBLIC_ROUTER),
} as const;

/** True when any required contract address is unset: the app runs on demo data. */
export const isMockMode: boolean =
  !addresses.engine ||
  !addresses.vault ||
  !addresses.riskConfig ||
  !addresses.points ||
  !addresses.spinVrf ||
  !addresses.jackpot ||
  !addresses.usdg ||
  !addresses.router;

/** Active chain: mainnet unless NEXT_PUBLIC_CHAIN=testnet. */
export const activeChain =
  process.env.NEXT_PUBLIC_CHAIN === "testnet" ? robinhoodTestnet : robinhoodChain;

/** Non-null address accessor for chain-wired code paths. Never call in mock mode. */
export function requireAddress(key: keyof typeof addresses): Address {
  const value = addresses[key];
  if (!value) {
    throw new Error(
      `Contract address for "${key}" is unset. This code path must not run in mock mode.`,
    );
  }
  return value;
}
