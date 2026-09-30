/**
 * Typed viem contract helpers. ABIs are extracted from the Foundry build
 * (forge inspect <Contract> abi --json) and checked in under ./abi.
 *
 * v2 set: PerpEngine, PitVault, InsuranceFund, PerpRiskConfig + the reused
 * OracleRouter / PitPoints / SpinVRF / Jackpot rails.
 */

import {
  createPublicClient,
  getContract,
  http,
  type Abi,
  type Address,
  type PublicClient,
} from "viem";
import { activeChain } from "./config";

import perpEngineAbiJson from "./abi/PerpEngine.json";
import pitVaultAbiJson from "./abi/PitVault.json";
import insuranceFundAbiJson from "./abi/InsuranceFund.json";
import perpRiskConfigAbiJson from "./abi/PerpRiskConfig.json";
import pitPointsAbiJson from "./abi/PitPoints.json";
import spinVrfAbiJson from "./abi/SpinVRF.json";
import jackpotAbiJson from "./abi/Jackpot.json";
import oracleRouterAbiJson from "./abi/OracleRouter.json";

export const perpEngineAbi = perpEngineAbiJson as Abi;
export const pitVaultAbi = pitVaultAbiJson as Abi;
export const insuranceFundAbi = insuranceFundAbiJson as Abi;
export const perpRiskConfigAbi = perpRiskConfigAbiJson as Abi;
export const pitPointsAbi = pitPointsAbiJson as Abi;
export const spinVrfAbi = spinVrfAbiJson as Abi;
export const jackpotAbi = jackpotAbiJson as Abi;
export const oracleRouterAbi = oracleRouterAbiJson as Abi;

let cachedClient: PublicClient | undefined;

/** Shared public client on the active Robinhood chain. */
export function publicClient(): PublicClient {
  if (!cachedClient) {
    cachedClient = createPublicClient({
      chain: activeChain,
      transport: http(),
    });
  }
  return cachedClient;
}

export function perpEngineContract(address: Address) {
  return getContract({ address, abi: perpEngineAbi, client: publicClient() });
}

export function pitVaultContract(address: Address) {
  return getContract({ address, abi: pitVaultAbi, client: publicClient() });
}

export function insuranceFundContract(address: Address) {
  return getContract({ address, abi: insuranceFundAbi, client: publicClient() });
}

export function perpRiskConfigContract(address: Address) {
  return getContract({ address, abi: perpRiskConfigAbi, client: publicClient() });
}

export function pointsContract(address: Address) {
  return getContract({ address, abi: pitPointsAbi, client: publicClient() });
}

export function spinVrfContract(address: Address) {
  return getContract({ address, abi: spinVrfAbi, client: publicClient() });
}

export function jackpotContract(address: Address) {
  return getContract({ address, abi: jackpotAbi, client: publicClient() });
}

export function oracleRouterContract(address: Address) {
  return getContract({ address, abi: oracleRouterAbi, client: publicClient() });
}
