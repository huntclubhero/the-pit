# Wave 2 Red-Team: Pull-Payment Credit / Withdraw Accounting
Attacker: red-pullpay | 2026-07-23 | Scope: Market.sol credit/withdraw, Jackpot.sol claim/pot

## Verdict: NO SURVIVORS. Pull-payment surface is accounting-airtight.

Escrow-solvency invariant proven to hold EXACTLY (not just >=) across every USDG-moving path:
`balanceOf(Market) == sum(offer.collateralRemaining) + _openInterest + _totalCredit`
- postOffer / cancelOffer / fillOffer / _settleAtPrice (decisive) / flat / _forcedUnwind / withdraw: LHS delta == RHS delta on every path (traced with numbers). Every settlement credits at most that position's own escrow (escrow - fee); no position credits against another's stake.

Sub-angles all REFUTED:
- (a) withdraw-more/double-claim/claim-another: keyed on msg.sender credit, zeroed before transfer, nonReentrant, CEI. Re-entry sees 0.
- (b) wrong-party/amount under odds: _resolve assigns winner/loser by exit-vs-entry, transferAmt clamped to loserStake; verified with 2:1 worked example, credits land correctly, total == escrow.
- (c) break solvency / drain other escrow: invariant equality guarantees balance >= openInterest + otherCredits always; SelfFill makes long!=short so per-address ledger never underflows; settled flag blocks double-credit.
- (d) jackpot re-draw/double-pay: pot = balanceOf - totalClaimable; award credited + totalClaimable bumped atomically with no transfer, excluded from future pots; potBalance cannot underflow; concurrent daily+weekly safe.
- (e) reentrancy/ordering: single nonReentrant guard on all mutators, CEI holds.
- (f) rounding: exact integer credits, takerGross ceils in taker's disfavor (over-collateralized), fees floor with dust-to-treasury, jackpot floors dust into pot.

## ADJACENT NOTE (carried to red-feebuyback / chief; LOW; NOT this angle)
`_settleDecisive` still PUSHES the fee to the 4 immutable recipients via `_distributeFee` (Market.sol:779) AFTER crediting parties. D1 made PARTY payouts pull-based but the FEE leg still pushes. If USDG (Diamond-proxy, freeze-capable) freezes a fee-recipient address, a DECISIVE settlement reverts and cannot settle while the oracle is OK, partially undermining D1's "every position reaches terminal payout." LOW: recipients are protocol-owned (not attacker-chosen/triggerable); flat settle and forced-unwind use fee=0 / no _distributeFee and stay live. Fix candidate: make fee distribution also credit-based (pull), or catch a failed fee transfer and credit it.

Locations: Market.sol (_creditPayout:931, withdraw:963, _settleDecisive:749), Jackpot.sol (rawFulfillRandomWords:406, claim:455, potBalance:470).
