# THE PIT

**Peer-to-peer long/short markets for memecoins on Robinhood Chain.** Traders take opposite sides of a memecoin's price with no order book, priced from on-chain TWAP oracles, with a points and jackpot layer on top.

- Contracts: core markets (Market, MarketFactory, PauseGuardian), oracle routing over Uniswap v3 TWAPs, perps, and a casino layer (points, VRF spins, jackpot)
- 750+ Foundry tests: unit, fuzz, invariants, and full-stack integration
- `contracts/` Foundry project, `app/` Next.js front end, `docs/` fee model and audit notes
- Status: in development, not deployed

> Public snapshot of a private working repo, without its history. All rights reserved.
