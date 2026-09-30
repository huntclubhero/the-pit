"use client";

import { useQuery } from "@tanstack/react-query";
import { isMockMode } from "@/lib/config";
import { mockMarketByAddress, mockMarkets, tickPrice } from "@/lib/mock/data";
import type { MarketSummary } from "@/lib/types";

/**
 * Chain mode (documented follow-up): market enumeration for the v2 PerpEngine
 * reads MarketListed events (or an indexer) for the token set, then per token:
 *   engine.marketState(token)        aggregates: OI, funding/borrow indices
 *   riskConfig.paramsFor(token)      leverage cap, MMR, fees
 *   riskConfig.mcapTierOf(token)     the LOCKED tier index
 *   router.peekPrice(token)          the mark + status
 *   router.maxMarketPayoutCap1e18    the cost-to-move reserve bound
 * The ABIs are checked in under lib/abi (PerpEngine.json, PerpRiskConfig.json,
 * OracleRouter.json) and the typed helpers exist in lib/contracts.ts. Until an
 * indexer is wired, chain mode returns an empty market list rather than a
 * partial or misleading one.
 */
async function fetchChainMarkets(): Promise<MarketSummary[]> {
  console.warn("THE PIT v2 chain-mode market enumeration is a documented follow-up (needs the MarketListed indexer).");
  return [];
}

function mockMarketsLive(): MarketSummary[] {
  return mockMarkets.map((m) => ({
    ...m,
    price1e18: tickPrice(m.symbol, m.price1e18),
  }));
}

/** All listed markets, refreshed on an interval so numbers feel live. */
export function useMarkets() {
  return useQuery({
    queryKey: ["markets"],
    queryFn: async () => (isMockMode ? mockMarketsLive() : fetchChainMarkets()),
    refetchInterval: 4_000,
    staleTime: 2_000,
  });
}

/** A single market's summary. */
export function useMarket(address: string) {
  return useQuery({
    queryKey: ["market", address.toLowerCase()],
    queryFn: async () => {
      if (isMockMode) {
        const seed = mockMarketByAddress(address);
        if (!seed) return null;
        return { ...seed, price1e18: tickPrice(seed.symbol, seed.price1e18) };
      }
      const all = await fetchChainMarkets();
      return all.find((m) => m.address.toLowerCase() === address.toLowerCase()) ?? null;
    },
    refetchInterval: 4_000,
    staleTime: 2_000,
  });
}
