# Wave 3 Re-Audit: W2-9 nonrefundable open bond
Auditor: re-bond (Fable) | 2026-07-23 | Verdict: mechanically correct, NO new engine bug, but ships DISABLED and cannot fully close W2-9. Relevant suites 41/41 green.

## Q1: closes W2-9? PARTIALLY
WORKS: bond = mulDiv(makerStake+takerStake, openBondBps, BPS_DENOM), charged to the TAKER on TOTAL fill OI, routed to treasury. Scales with OI (not flat), truly nonrefundable (never written to a position field, never re-enters cancel/settle/forcedUnwind). Billed on total OI regardless of sybil count, so the per-address-cap bypass no longer gets OI free. Real cost.

### F1 (MEDIUM, efficacy/launch-config): bond defaults 0, immutable per market, NOT retroactive
MarketFactory.openBondBps = 0 at deploy (DEFAULT_OPEN_BOND_BPS=0), baked immutable per market, createMarket PERMISSIONLESS. Test proves a market created before arming stays bond-0 forever. So (a) as-scripted launch ships every genesis market with bond OFF; post-deploy arming runs through the 2-day timelock, leaving a window where anyone creates a thin-token market at bond 0 that is then unfixable; (b) an attacker front-runs createMarket before arming. LAUNCH ACTION: openBondBps MUST be armed at the FACTORY at/before deploy (set OPEN_BOND_BPS env), not left to a later timelock action. Any value-bearing market CAN and by default WILL ship at bond 0.

### F2 (design ceiling, keeps W2-9 at MEDIUM): one-time cost, not recurring rent
Max 5% buys locking a market up to the 30-day max duration for a single payment plus recoverable locked capital. Raises monopolization cost meaningfully, does not eliminate a determined griefer. Mitigation, not closure.

## Q2: new bug? No HIGH/CRITICAL
CLEAN: conservation/escrow-solvency intact (bond flows taker->contract->treasury, never touches _openInterest/_addressOpenCollateral/stakes; openInterest()==totalStake asserted with live 200bps bond; settlement math never sees the bond; credit-on-failure keeps _totalCredit balanced). OI measured BEFORE the bond (Effects precede _chargeOpenBond in Interactions), so odds/OI unaffected. Constructor wiring correct (openBondBps_ last param, factory passes it last). MAX_OPEN_BOND_BPS(500) enforced in BOTH Market ctor (OpenBondTooHigh) and factory (InvalidOpenBondBps). Under-approval reverts the whole fill.

### F3 (LOW, new): tiny-fill bond ROUNDING DISCOUNT
bond = floor(totalStake*bps/10000) with if(bond==0) return. Min-non-dust fills pay less than intended: ~10% discount at 500bps, up to ~50% at ~100bps. Full bypass (floors to 0 while OI accrues) only if governance sets bond very low (<=~5bps at multiple 1, <=~50bps at multiple 10). Document a sane armed floor.

### F4 (LOW/INFO, ECON): bond billed entirely to the TAKER but computed on BOTH legs, so maker pays no open cost and honest takers subsidize maker OI. At a meaningful rate this taxes the legitimate taker flow in the thin/new markets where the bond is armed. Liquidity-chill tradeoff, accepted cost.

### F5 (INFO): Deploy validates OPEN_BOND_BPS only against uint16 max, missing the mirrored MAX_OPEN_BOND_BPS(500) early revert that settlement-fee has (setOpenBondBps reverts later, so not a hole; minor consistency gap).

## Bottom line
Well-built, no regression to conservation/wiring/bound, adds a real nonrefundable OI-scaling cost. Does NOT fully close W2-9 (F1 default-0/non-retroactive/permissionless-creation is load-bearing; F2 one-time ceiling). Keep W2-9 MEDIUM. LAUNCH ACTION: arm openBondBps at the FACTORY at deploy for genesis markets, value well above the F3 rounding floor.
