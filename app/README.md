# THE PIT: web app

Peer to peer capped-payout long/short arena for memecoins on Robinhood Chain.
Next.js 15 (App Router, TypeScript), Tailwind CSS v4, wagmi v2 + viem,
TanStack Query. No UI kit: every component is hand-built on the token system
defined in `src/app/globals.css`.

## Commands

```bash
npm install     # install dependencies
npm run dev     # dev server on http://localhost:3000
npm run build   # production build (type checks + lint)
npm test        # vitest: contract-math mirror tests (fees, payouts, points)
npm start       # serve the production build
```

## Environment variables

Copy `.env.example` to `.env.local` and fill in what you have.

| Variable | Purpose |
| --- | --- |
| `NEXT_PUBLIC_FACTORY` | MarketFactory address |
| `NEXT_PUBLIC_POINTS` | PitPoints address |
| `NEXT_PUBLIC_SPINVRF` | SpinVRF address |
| `NEXT_PUBLIC_JACKPOT` | Jackpot address |
| `NEXT_PUBLIC_USDG` | USDG collateral token address |
| `NEXT_PUBLIC_ROUTER` | OracleRouter address |
| `NEXT_PUBLIC_CHAIN` | `mainnet` (default, chain id 4663) or `testnet` (46630) |
| `BLOCKED_COUNTRIES` | Geofence list, comma-separated ISO alpha-2 codes. Default: `US,GB,CA,CH,AE,SG` |

## Mock mode

If ANY of the six contract addresses is unset, the app runs in **mock mode**:

- An amber banner appears under the nav ("Demo data...").
- Every page renders fully populated with realistic demo data (13 markets
  including CASHCAT and FWA, offer books, positions, points, jackpot, spins).
- Prices wiggle and the jackpot pot climbs on an interval so the odometers
  demonstrate their roll animation.
- Trade buttons produce a "demo receipt" describing the exact call that would
  be submitted; no transaction is ever sent.

Set all six addresses and the same hooks read the chain directly (viem public
client + wagmi for writes). Wallets: injected connector only (MetaMask, Rabby).

## Geofence

`src/middleware.ts` reads `BLOCKED_COUNTRIES` and rewrites blocked visitors to
the full-screen `/blocked` page with HTTP 451. Country comes from the hosting
edge's geo header (`x-vercel-ip-country` or `cf-ipcountry`); requests without
a geo header (local dev) pass through.

## Contract math

`src/lib/format.ts` mirrors the on-chain math exactly (floor division
included): 10 bps per-side entry fee at fill, 70 bps settlement fee from
winnings only, PnL clamp at matched collateral, points base/multipliers/rebate,
spin thresholds. `npm test` checks it against hand-computed vectors derived
from the contract constants.

ABIs in `src/lib/abi/` are extracted from the Foundry build:

```bash
cd ../contracts && forge build
forge inspect Market abi --json > ../app/src/lib/abi/Market.json
# ... MarketFactory, PitPoints, SpinVRF, Jackpot, OracleRouter
```

## Routes

| Route | Page |
| --- | --- |
| `/` | Markets table + create-market flow |
| `/market/[address]` | Trading screen: book, ticket, positions, chart, oracle status |
| `/portfolio` | Open positions across markets + settlement history |
| `/pit-boss` | Points hub: ranks, streaks, multipliers, leaderboard, referrals |
| `/jackpot` | Pot odometer, draw countdowns, past draws |
| `/fairness` | Trust page: mechanics, spin ledger, draw ledger, explorer links |
| `/blocked` | Geofence landing (HTTP 451) |
