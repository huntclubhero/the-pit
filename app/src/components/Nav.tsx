"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "./ConnectButton";
import { isMockMode } from "@/lib/config";

const LINKS = [
  { href: "/", label: "Trade" },
  { href: "/vault", label: "Vault" },
  { href: "/portfolio", label: "Portfolio" },
  { href: "/pit-boss", label: "Pit Boss" },
  { href: "/jackpot", label: "Jackpot" },
  { href: "/token", label: "$PIT" },
  { href: "/fairness", label: "Fairness" },
  { href: "/whitepaper", label: "Paper" },
  { href: "/about", label: "About" },
];

export function Nav() {
  const pathname = usePathname();

  return (
    <>
      {isMockMode && (
        <div className="bg-amber text-pit-0 text-center text-[12px] font-semibold uppercase tracking-[0.14em] py-1.5 px-3">
          Demo: simulated data. Not live. No funds.
        </div>
      )}
      <header className="sticky top-0 z-50 glass-nav">
        <div className="flex items-center gap-2 px-4 md:px-6 h-14">
          <Link href="/" className="flex items-baseline gap-2 mr-4 shrink-0">
            <span className="display text-xl leading-none tracking-[-0.02em] text-amber">
              THE PIT
            </span>
            <span className="hidden sm:inline font-mono text-[9px] uppercase tracking-[0.22em] text-ink-faint">
              Built on Robinhood Chain
            </span>
          </Link>
          <nav className="flex items-center gap-1 overflow-x-auto min-w-0 nav-scroll">
            {LINKS.map((link) => {
              const active =
                link.href === "/"
                  ? pathname === "/" || pathname.startsWith("/market")
                  : pathname.startsWith(link.href);
              return (
                <Link
                  key={link.href}
                  href={link.href}
                  className={`nav-link display tap px-3 py-1.5 text-[13px] tracking-[0.04em] uppercase whitespace-nowrap transition-colors duration-[120ms] ${
                    active ? "nav-active text-amber" : "text-ink-dim hover:text-ink"
                  }`}
                >
                  {link.label === "$PIT" ? (
                    <>
                      <span className="font-mono text-[12px] align-[1px]">$</span>PIT
                    </>
                  ) : (
                    link.label
                  )}
                </Link>
              );
            })}
          </nav>
          <div className="ml-auto shrink-0">
            <ConnectButton />
          </div>
        </div>
      </header>
    </>
  );
}
