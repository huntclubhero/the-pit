"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { use } from "react";
import { TradeTerminal } from "@/components/TradeTerminal";
import { useMarket } from "@/hooks/useMarkets";

/**
 * Deep link to one market's terminal. Renders the exact same TradeTerminal as
 * the root; the switcher here navigates so the URL stays shareable.
 */
export default function MarketDetailPage({
  params,
}: {
  params: Promise<{ address: string }>;
}) {
  const { address } = use(params);
  const router = useRouter();
  const { data: market } = useMarket(address);

  if (!market) {
    return (
      <div className="p-10 text-center font-mono text-ink-faint">
        {market === null ? (
          <>
            Unknown market.{" "}
            <Link href="/" className="text-amber hover:text-amber-hot">
              Back to the terminal
            </Link>
          </>
        ) : (
          "Loading market..."
        )}
      </div>
    );
  }

  return (
    <TradeTerminal
      market={market}
      onSelectMarket={(m) => router.push(`/market/${m.address}`)}
    />
  );
}
