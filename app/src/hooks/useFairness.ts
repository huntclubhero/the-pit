"use client";

import { useQuery } from "@tanstack/react-query";
import { parseAbiItem, type Address } from "viem";
import { isMockMode, requireAddress } from "@/lib/config";
import { publicClient, spinVrfContract } from "@/lib/contracts";
import { mockSpins } from "@/lib/mock/data";
import type { SpinLedgerRow } from "@/lib/types";

const spinRequestedEvent = parseAbiItem(
  "event SpinRequested(uint256 indexed requestId, address indexed user, uint256 basePoints, address indexed token)",
);

async function fetchChainSpins(): Promise<SpinLedgerRow[]> {
  const spinVrfAddress = requireAddress("spinVrf");
  const client = publicClient();
  const logs = await client.getLogs({
    address: spinVrfAddress,
    event: spinRequestedEvent,
    fromBlock: "earliest",
    toBlock: "latest",
  });
  const recent = logs.slice(-40).reverse();
  const spinVrf = spinVrfContract(spinVrfAddress);
  const rows = await Promise.all(
    recent.map(async (log): Promise<SpinLedgerRow> => {
      const requestId = log.args.requestId ?? 0n;
      const [user, token, , fulfilled, multiplier, basePoints, word] = (await spinVrf.read.getSpin(
        [requestId],
      )) as [Address, Address, Address, boolean, bigint, bigint, bigint];
      return {
        requestId,
        user,
        token,
        symbol: "",
        fulfilled,
        word,
        multiplier: Number(multiplier),
        basePoints,
        bonusPoints: fulfilled && multiplier > 0n ? basePoints * (multiplier - 1n) : 0n,
        at: 0,
      };
    }),
  );
  return rows;
}

/** Live-verifiable spin ledger straight off SpinVRF.getSpin. */
export function useSpinLedger() {
  return useQuery({
    queryKey: ["spins"],
    queryFn: async () => (isMockMode ? mockSpins : fetchChainSpins()),
    refetchInterval: 8_000,
  });
}
