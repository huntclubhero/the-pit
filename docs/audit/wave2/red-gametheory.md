# Wave 2 Red-Team: Economic / Game-Theory Edge
Attacker: red-gametheory | 2026-07-23 | No protocol insolvency (conservation exact, payout capped). All findings are maker-vs-taker wealth transfer. The primary one attacks the capital-attraction thesis.

## FINDING 1 (HIGH for maker capital / house-vault viability; LOW for solvency; conf HIGH math)
Shared `multiple` makes every high-odds offer +EV for the TAKER. The maker is the sucker, not the house.
Settlement uses ONE shared `multiple` for both sides: loserNotional = loserStake * multiple in either direction (_resolve Market:792-819, _settleDecisive :764, _absPnl :943-950 symmetric). But stakes are asymmetric: makerStake = k * takerStake, k = payoffRatioBps/10000 in [1,20].
Math: taker stake s, maker k*s, multiple m, symmetric return r. Winner gets loserStake*min(m|r|,1). Up (taker wins): +k*s*min(mr,1). Down (taker loses): -s*min(m|r|,1). Under any driftless symmetric distribution, taker gross EV = (k-1)*s*Q > 0 for every k>1 (Q=E[min(m|r|,1)*1{r>0}]>0). The win BARRIER (m|r|>=1) is identical for both sides (shared m); only payoff SIZE differs (k), so k>1 over-compensates the taker. Concrete: k=20, m=1, +/-5%: up wins 1.0s (+100%), down loses 0.05s (-5%); even 50/50 = +47.5% stake gross EV. k=20,m=10 over a 30-day hold approaches ~7x stake.
Consequence: NO fair symmetric high-odds offer exists. A maker only posts one with strong directional conviction (m can't make the taker's barrier harder). Each offer is one-sided directional, not a book. So maker capital is structurally -EV unless the maker out-forecasts takers: inverts "the house always wins" and undermines odds attracting maker/LP capital.
Refutations survive: rational makers avoid it (so not insolvency) but it IS free money vs (a) a MECHANICAL house vault (E3) posting model odds, (b) naive retail makers, (c) the Finding-2 straddle. Fees (0.1-1% entry + ~m*0.5% settle) are an order of magnitude below the (k-1)Q edge. MIN_HOLD only adds volatility (raises Q).

## FINDING 2 (HIGH vs two-sided vault, MED in human book; conf HIGH)
Near-risk-free STRADDLE. Fill a bearish maker's high-odds offer as LONG (win up to k*s if up) AND a bullish maker's as SHORT (win up to k*s if down), same token/m/entry. Net payoff at move r is (k-1)*s*min(m|r|,1)>0 either direction; only dead-flat loses (~2 entry fees). Downside ~fees, upside ~19x at k=20. Precondition: two opposite high-odds makers live (a book of disagreeing bulls/bears, or a two-sided house vault, provides it for free). Bookmaker arbitrage.

## FINDING 3 (MEDIUM maker-vs-taker; conf MED)
Resting offer + limitEntry + settle-at-will = a stack of free options the 10 bps entry fee underprices. (b) Entry timing: a resting offer is a free option; taker fills only when the oracle entry is favorable within the maker's limitEntry band. A_MAJOR has NO opening breaker (spotSource 0), so a stale-median fill is possible (blunted by MIN_HOLD + 3-source median). Memecoins blunted by breaker + TWAP lag. (c) Settle timing: after MIN_HOLD either party settles at current price = an American option; countered by the counterparty's equal right + TWAP lag. Through-line: a 30-day resting offer is a long-dated option worth far more than 10 bps; loose-limitEntry makers get adversely selected. Recommend tight limitEntry + short expiry + UI pricing/warnings.

## Refuted
(e) Sybil self-match to farm points/fees via odds: high odds shrink takerGross, shrinking BOTH taker entry fee AND minted points (notional = takerStake*multiple); anti-wash coupling holds, odds do NOT lower wash cost per point. Residual self-referral/jackpot-recovery wash is real but NOT odds-driven (hand to red-feebuyback). Rounding: takerGross ceils against taker, dust gate reverts zero-fee. Maker fleecing takers via bad odds: only works on irrational takers.

## Recommendations
1. House vault (E3) MUST NOT post mechanical symmetric high-odds: load odds with drift + realized-vol + adverse-selection margin, prefer ONE side, cap odds well below 20:1 for symmetric tokens. As-specified it is a taker money-pump.
2. m is inherently shared, so the fair-odds burden falls on the maker's k. Surface a "fair odds given m and this token's vol" UI helper, or add a protocol-side minimum vig on k as a function of m.
3. Reframe the sec-5 narrative: makers are directional bettors, not a book. Do not market "be the house, earn the edge" to LPs; the edge accrues to informed TAKERS.
4. The 10 bps entry fee prices wash, not the option value of resting/high-odds offers: those are UI-guardrail problems, not fee problems.
