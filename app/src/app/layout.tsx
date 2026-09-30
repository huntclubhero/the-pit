import type { Metadata, Viewport } from "next";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import "./globals.css";
import { Providers } from "./providers";
import { Nav } from "@/components/Nav";
import { isMockMode } from "@/lib/config";

export const viewport: Viewport = {
  themeColor: "#0b0d12",
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

export const metadata: Metadata = {
  title: "THE PIT: leveraged memecoin perps",
  description:
    "Long or short the memes nobody else will list. Up to 15x leverage on Robinhood Chain. Isolated margin. Liquidations you can see coming.",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${GeistSans.variable} ${GeistMono.variable}`}>
      <body>
        <Providers>
          <Nav />
          <main className="min-h-[calc(100dvh-56px)]">{children}</main>
          <footer className="border-t border-line px-4 md:px-6 py-6 pb-[max(24px,env(safe-area-inset-bottom))] flex flex-col md:flex-row gap-2 md:items-center md:justify-between">
            <span className="font-mono text-[10px] uppercase tracking-[0.16em] text-ink-faint">
              THE PIT: built on Robinhood Chain. Up to 15x. Isolated margin. Liquidations you can see coming.
              {isMockMode ? " All data simulated: no funds move." : ""}
            </span>
            <a
              href="https://robinhoodchain.blockscout.com"
              target="_blank"
              rel="noreferrer"
              className="font-mono text-[10px] uppercase tracking-[0.16em] text-ink-faint hover:text-amber transition-colors"
            >
              Blockscout explorer
            </a>
          </footer>
        </Providers>
      </body>
    </html>
  );
}
