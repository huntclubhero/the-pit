import { createConfig, http } from "wagmi";
import { robinhoodChain, robinhoodTestnet } from "./chain";

/**
 * Wallet config: injected wallets only in v1 (MetaMask, Rabby), discovered
 * via EIP-6963 (multiInjectedProviderDiscovery is on by default). No
 * WalletConnect key dependency and no connectors barrel import.
 */
export const wagmiConfig = createConfig({
  chains: [robinhoodChain, robinhoodTestnet],
  transports: {
    [robinhoodChain.id]: http(),
    [robinhoodTestnet.id]: http(),
  },
  ssr: true,
});
