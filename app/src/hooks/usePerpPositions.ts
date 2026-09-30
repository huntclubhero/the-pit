"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { isMockMode } from "@/lib/config";
import {
  demoAddMargin,
  demoClosePosition,
  demoOpenPosition,
  mockLiquidations,
  mockPerpPositions,
} from "@/lib/mock/data";
import type { LiquidationEvent, PerpPositionRow, Side, TradeRecord } from "@/lib/types";

/**
 * Chain mode (documented follow-up): positions come from
 * engine.getPosition(token, trader, isLong) per side per market, with
 * equityOf / liquidationPrice / pendingOwedOf for the live numbers. The
 * PerpEngine ABI is checked in and perpEngineContract() is ready; the market
 * enumeration dependency is the same indexer follow-up as useMarkets.
 */
async function fetchChainPositions(): Promise<PerpPositionRow[]> {
  return [];
}

/** The viewer's open perp positions in one market. */
export function useMarketPositions(marketAddress: string) {
  return useQuery({
    queryKey: ["perp-positions", marketAddress.toLowerCase()],
    queryFn: async () =>
      isMockMode
        ? mockPerpPositions.filter(
            (p) => p.marketAddress.toLowerCase() === marketAddress.toLowerCase(),
          )
        : fetchChainPositions(),
    refetchInterval: 4_000,
  });
}

/** Every open perp position for the viewer, across markets. */
export function useAllPositions() {
  return useQuery({
    queryKey: ["perp-positions", "all"],
    queryFn: async () => (isMockMode ? [...mockPerpPositions] : fetchChainPositions()),
    refetchInterval: 4_000,
  });
}

/** The public liquidations feed. */
export function useLiquidations() {
  return useQuery({
    queryKey: ["liquidations"],
    queryFn: async (): Promise<LiquidationEvent[]> =>
      isMockMode ? [...mockLiquidations] : [],
    refetchInterval: 8_000,
  });
}

/** Demo-store mutations, wrapped so every consumer invalidates the same keys. */
export function usePerpDemoActions() {
  const queryClient = useQueryClient();
  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ["perp-positions"] });
    queryClient.invalidateQueries({ queryKey: ["portfolio-history"] });
  };
  return {
    open(input: {
      marketAddress: string;
      symbol: string;
      side: Side;
      marginNet: bigint;
      size1e18: bigint;
      entryPrice1e18: bigint;
      leverageX100: number;
      maxPayout: bigint;
    }): PerpPositionRow {
      const row = demoOpenPosition(input);
      invalidate();
      return row;
    },
    close(id: number, mark1e18: bigint, closeFeeBps: number): TradeRecord | undefined {
      const record = demoClosePosition(id, mark1e18, closeFeeBps);
      invalidate();
      return record;
    },
    addMargin(id: number, amount: bigint): void {
      demoAddMargin(id, amount);
      invalidate();
    },
  };
}
