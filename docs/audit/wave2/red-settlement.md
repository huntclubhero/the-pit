# Wave 2 Red-Team: Settlement + Asymmetric Odds Math
Attacker: red-settlement | 2026-07-23 | Verdict: NO surviving findings at any severity.

Re-derived every formula from scratch (wave1 audit-math.md is STALE: it cites 70 bps / 40-40-20, the pre-odds build). Hand-computed the extreme corners.

Core result: conservation is exact by ALGEBRA, not rounding. _settleDecisive (Market:764-767): winnerPayout + loserPayout + fee = (winnerStake + transfer - fee) + (loserStake - transfer) + fee = winnerStake + loserStake = total escrow, for ALL inputs. transfer<=loserStake (clamp in _absPnl:948-949) gives loserPayout>=0 and winnerPayout<=escrow; fee=min(loserNotional*bps/1e4, transfer)<=transfer gives winnerPayout>=winnerStake. All four invariants hold unconditionally.

Vectors fired and refuted with numbers:
- (b) 20:1 x multiple 10, maker LONG 20000/taker SHORT: takerGross 1000, stakes 19800/990, escrow 20790; -10% wipes long: winner(short) 19800, loser 0, fee 990, sum 20790 exact. Taker turned 1000 into 19800 (~20x), never a wei above escrow.
- (d) entry fees carved at fill, stakes already NET, settlement never touches them: no interaction.
- fee-cap binds on small high-multiple moves: winnerPayout collapses to exactly winnerStake, never below. Intended.
- (e) sub-unit move: transfer floors to 0 -> flat branch refunds each side own stake, zero fee.
- (c) rounding: takerGross ceilDiv (taker overpays), all fees + PnL floor, dust to treasury; every event conserved, nothing extractable; dust gate forces feeMaker>=1 AND feeTaker>=1 so paying >=2 units to avoid <1 unit is strictly unprofitable.
- (f) forced unwind refunds longStake + shortStake separately, sum = escrow, zero fee.
- overflow: uint128 casts bounded; loserNotional*bps ~3.4e41 < uint256; PnL 512-bit mulDiv. No revert-in-valid-domain.

Evidence: MarketOdds + SettlementFuzz + MarketInvariant green (invariant 25600 calls, 0 reverts, fuzzes full odds band with partial fills, asserts exact solvency + no-overpay + per-address ledger + fee accounting).

INFO (= wave1 F3): collateral fuzz ceilings at 1e30; hand-verified uint128-max region overflow-safe (winnerPayout uint256-credited, never cast to uint128), economically unreachable. Document the ceiling as deliberate; no code change.

Guidance: do NOT disturb _settleAtPrice/_resolve/_settleDecisive/_absPnl/_fillMath; add gates around them, never inside.
