"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { isMockMode } from "@/lib/config";
import {
  demoVaultClaim,
  demoVaultDeposit,
  demoVaultRequestWithdraw,
  mockVaultState,
} from "@/lib/mock/data";
import type { VaultState } from "@/lib/types";

/**
 * Chain mode (documented follow-up): vault state reads
 *   vault.totalAssets() / totalSupply()   NAV + share price
 *   vault.totalReserved()                 reserved payout capacity
 *   vault.currentEpoch() / epochEndsAt()  the withdraw-queue clock
 *   vault.queuedOf(user) / claimableOf    the viewer's queue position
 * pitVaultAbi is checked in and pitVaultContract() is ready in lib/contracts.
 */
async function fetchChainVault(): Promise<VaultState | null> {
  return null;
}

export function useVault() {
  return useQuery({
    queryKey: ["vault"],
    queryFn: async () => (isMockMode ? mockVaultState() : fetchChainVault()),
    refetchInterval: 5_000,
  });
}

/** Demo-store vault mutations with shared invalidation. */
export function useVaultDemoActions() {
  const queryClient = useQueryClient();
  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["vault"] });
  return {
    deposit(assets: bigint) {
      demoVaultDeposit(assets);
      invalidate();
    },
    requestWithdraw(shares: bigint) {
      demoVaultRequestWithdraw(shares);
      invalidate();
    },
    claim() {
      demoVaultClaim();
      invalidate();
    },
  };
}
