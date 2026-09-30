# Wave 3 Re-Audit: numerical conservation after W2-12 / W2-9 / W2-2
Auditor: re-conservation (Fable) | 2026-07-23 | Verdict: ALL FOUR INVARIANTS HOLD WEI-EXACT. 0 CRITICAL, 0 fund-moving breaks. Re-derived from scratch at HEAD; re-ran non-fork suite 438/438.

## 1. Settlement conservation: SOLID, unchanged
Diff does not touch _settleAtPrice/_resolve/_settleDecisive/_absPnl/_fillMath (verified). winnerPayout+loserPayout+fee = winnerStake+loserStake = longStake+shortStake, exact for all inputs incl odds. W2-12: split arithmetic unchanged; each share goes through _payFee delivering exactly `share` whether pushed (balance-share) or credited (_credit+share, _totalCredit+share, balance unchanged); sum of deliveries = fee on every branch incl all-four-frozen. W2-9 bond: a SEPARATE additional safeTransferFrom on the taker, computed after and independent of stakes/OI, never enters escrow accounting; unit test asserts openInterest==totalStake and treasury==entryShare+bond wei-exact.

## 2. Escrow-solvency: EXACT on every path
balanceOf(Market) == sum(live offer remainders) + _openInterest + _totalCredit (now holds party AND fee credits, same mapping/accumulator, withdraw handles both). Per-path deltas equal on fill (all push/credit combos), cancel, flat, forced-unwind, withdraw, decisive settle. No held-bond state outside _totalCredit (bond exits or credits atomically in the fill tx). Donations make LHS>RHS (protocol slack). pushFee OnlySelf-gated. MarketInvariant asserts equality incl totalUnwithdrawnCredit; MarketPullPayment exercises frozen-treasury credit path end-to-end wei-exact.

## 3. Jackpot (W2-2/W2-4): no underflow, no over-pay, monotonic
potBalance underflow impossible by induction (amount<=fractionCap<=pot/2, claim decrements both sides, no owner sweep). epochInflow only grows (delta = rise in balanceOf+cumulativePaidOut, guarded >0; claims invariant; seed() syncs then advances watermark by the deposit so seeds are never in any budget; each wei attributed to exactly ONE epoch, so sum(epochPaidOut) <= 0.5 x sum(non-seed inflow)). epochPaidOut incremented by post-guard amount (no phantom consumption). Outflow guard inWindow'<=cap by construction; fresh-window potRef claimable-excluded so worst case geometric 50%/day decay, never negative. Overflow: (USDG supply<2^96) x (bps<=5000) safe.

## 4. Rounding (new divisions, direction audited)
Bond mulDiv floors (favors taker <1 unit/fill); farming it strictly unprofitable (avoiding B units needs ~B extra fills each >=2 units entry fee; dust gate forces bond>=1 for openBondBps>=~5). Drip budget / fractionCap / outflow cap all floor, favor pot/protocol. Fee-split unchanged, dust to treasury.

## 5. Overflow: consultMeanQuoteReserve
meanLiquidity = mulDiv(window,2^128,splDelta) <= 2^160; quoteReserve <= ~2^224 < 2^256 (FullMath 512-bit intermediate): cannot overflow. splDelta==0 returns not-ok. Downstream _trackedLiquidity quoteAmount*usdgScale*2 overflow-reverts only at ~2^204 (unreachable, governance-registered pools, revert blocks listing conservatively, moves no funds). maxMarketPayoutCap floor-div by safetyFactor>=1.

## Self-refutation (all failed to break conservation; INFO)
Gas-grief forced credit: conservation exact either mode, recovers via withdraw, delivery-mode grief only. pushFee not nonReentrant: OnlySelf + no USDG callback + outer nonReentrant, no path. Jackpot donation-inflation of an old epoch budget: expected recapture 0.5*X*share < X, negative EV, no double-attribution. USDG freeze/clawback ON Market/Jackpot itself: exogenous trust class already accepted, not introduced here.
Coverage note (optional): MarketInvariant fuzz runs bond=0 on a never-failing mock, so the bond + catch branch are exercised only by unit tests, not the random walk; a bonded + BlockableUSDG handler variant would close that in a later hardening pass.

Bottom line: the three fund-moving fixes preserved wei-exact accounting on every path. Nothing to fix.
