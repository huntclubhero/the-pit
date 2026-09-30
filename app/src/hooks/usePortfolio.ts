"use client";

import { useQuery } from "@tanstack/react-query";
import { isMockMode } from "@/lib/config";
import { mockTradeHistory } from "@/lib/mock/data";
import type { TradeRecord } from "@/lib/types";

/**
 * Chain mode (documented follow-up): trade history reconstructs from the
 * engine's PositionClosed / PositionReduced / PositionLiquidated events
 * (perpEngineAbi is checked in). Until the event indexer lands, chain mode
 * shows an empty history rather than a partial one.
 */
async function fetchChainHistory(): Promise<TradeRecord[]> {
  return [];
}

/** Settled trades (closes, reduces, liquidations) with exact fee breakdowns. */
export function useTradeHistory(owner?: string) {
  return useQuery({
    queryKey: ["portfolio-history", owner?.toLowerCase() ?? "mock"],
    queryFn: async () => (isMockMode || !owner ? [...mockTradeHistory] : fetchChainHistory()),
    refetchInterval: 8_000,
  });
}
