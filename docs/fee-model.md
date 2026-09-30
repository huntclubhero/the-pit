# THE PIT: Shipped Fee Model (source of truth: contracts)

Wave-2b R-10 note: the design-era docs in Hunt's home directory
(`the-pit-economics-design-2026-07-23.md`, `the-pit-fee-jackpot-model-2026-07-23.md`)
described a 70 bps settlement fee and a 40 jackpot / 40 treasury / 20 referral
split. Those numbers were NEVER shipped. This file records what the code
actually charges; if any document disagrees with the constants below, the code
wins.

## Fees (contracts/src/core/Market.sol, MarketFactory.sol)

| Fee | Value | Constant |
| --- | --- | --- |
| Entry fee | 10 bps of each side's notional at fill | `Market.ENTRY_FEE_BPS = 10` |
| Settlement fee | 50 bps of the loser's notional, from realized winnings only | `MarketFactory.DEFAULT_SETTLEMENT_FEE_BPS = 50` (baked immutably per market at creation) |
| Settlement fee hard cap | 100 bps | `Market.MAX_FEE_BPS = 100` (factory mirrors it) |
| Open bond (wave-2b R-3) | 50 bps of a fill's total OI, taker-paid, nonrefundable, to treasury | `Deploy.DEFAULT_OPEN_BOND_BPS = 50`, cap `Market.MAX_OPEN_BOND_BPS = 500` |

Round-trip protocol take: ~20 bps entry (both sides) + up to 50 bps settle =
up to ~70 bps of notional, plus the 50 bps open bond on the taker's fill OI.

## Fee split (every fee, entry and settlement)

| Leg | Share | Constant |
| --- | --- | --- |
| Jackpot | 25% | `FEE_SHARE_JACKPOT_BPS = 2_500` |
| Referral pool | 10% | `FEE_SHARE_REFERRAL_BPS = 1_000` |
| Buyback | 39% | `FEE_SHARE_BUYBACK_BPS = 3_900` |
| Treasury | 26% (remainder: fee minus the three round-down shares, so the four legs sum EXACTLY to the fee) | derived |

Jackpot inflow is therefore 25% of all fees (not 40%): at a blended take of
~70 bps of notional the jackpot accrues ~17.5 bps of daily notional
(~$1,750/day at $1M/day, ~$17.5K/day at $10M/day), before the drip and
outflow guards shape what each draw can pay.

## Governance latitude

`settlementFeeBps` and `openBondBps` are factory parameters for FUTURE
markets only (existing markets keep their immutable creation-time rates) and
sit behind the 2-day timelock. The 25/10/39/26 split is hardcoded in Market;
changing it requires new market deployments. Volume-tiered settlement fees
remain a future economics increment (E2), not shipped.
