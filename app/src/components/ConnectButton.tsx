"use client";

import { useAccount, useConnect, useDisconnect } from "wagmi";
import { isMockMode } from "@/lib/config";
import { MOCK_ACCOUNT } from "@/lib/mock/data";
import { shortAddress } from "@/lib/format";

export function ConnectButton() {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();

  if (isMockMode) {
    return (
      <span
        className="chip text-amber border-amber-deep"
        title="Demo data: no chain connection"
      >
        <span className="pulse-dot inline-block h-1.5 w-1.5 rounded-full bg-amber" />
        {shortAddress(MOCK_ACCOUNT)}
      </span>
    );
  }

  if (isConnected && address) {
    return (
      <button
        type="button"
        onClick={() => disconnect()}
        className="chip text-ink hover:text-loss transition-colors"
        title="Disconnect"
      >
        <span className="inline-block h-1.5 w-1.5 rounded-full bg-felt-bright" />
        {shortAddress(address)}
      </button>
    );
  }

  const injectedConnector = connectors[0];
  return (
    <button
      type="button"
      className="btn-amber px-4 py-1.5 text-sm"
      disabled={!injectedConnector || isPending}
      onClick={() => injectedConnector && connect({ connector: injectedConnector })}
    >
      {isPending ? "Connecting" : "Connect"}
    </button>
  );
}

/** The active viewing address: real wallet, or the demo wallet in mock mode. */
export function useViewerAddress(): string | undefined {
  const { address } = useAccount();
  if (isMockMode) return MOCK_ACCOUNT;
  return address;
}
