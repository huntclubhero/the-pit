# Perp Audit Wave 1: Access Control / Priv-Esc / Admin Abuse
Attacker: pa-access (Fable) | 2026-07-24 | External priv-esc CLEAN. Findings below.

## Authorization matrix: clean
Every owner setter onlyOwner (owner = 2-day timelock); every vault counterparty fn + IF outflow onlyEngine; pushFee onlySelf; setEngine/setVault onlyOwner + once-only. No external attacker can reach an owner setter, the counterparty/IF surface, spoof the engine (immutable/once-set), or drain vault/IF. Permissionless surfaces (liquidate/pokeFunding/tripDrawdownCircuit/requestWithdraw/settleEpoch/claim/refreshTier) correctly permissionless.

## External (untrusted)
### E1 (MEDIUM, conf ~65%): permissionless refreshTier downgrade silently tightens MMR on EXISTING positions (breaks spec grandfathering)
refreshTier permissionless; a downgrade (PerpRiskConfig:378) moves to a LOWER tier = HIGHER MMR. Liquidation reads MMR LIVE (PerpEngine.liquidate -> riskConfig.paramsFor(token).mmrBps :867,922); positions store NO MMR snapshot. So a downgrade immediately raises maintenance on all open positions and can flip borderline-healthy into liquidatable, then anyone keeper-liquidates for the penalty. Spec 8.4 promises "downgrades take effect for NEW opens (existing positions grandfathered, never force-closed)": implementation does NOT grandfather MMR. Gated by FDV falling 20% below band floor + 24h cooldown, but a transient peekPrice suppression forces a permanent downgrade (only reversible via 2-day-timelocked upgrade) = griefing. FIX: snapshot MMR (or tier) at open, OR grandfather existing positions.

### E2 (LOW-MED, conf ~60%, DoS class -> red-dos): tripDrawdownCircuit permissionless latch vs timelocked-only reset
tripDrawdownCircuit (:1292) permissionless, latches drawdownTripped=true blocking ALL opens engine-wide; only 2-day-timelocked resetDrawdownCircuit (:1021) clears it. The _drawdownGate already blocks opens while the 10% NAV drop holds (self-healing); the latch converts a transient condition into a hard 2-day freeze. Attack: settleEpoch (permissionless) on a large matured withdrawal epoch crystallizes up to 25% TVL of liability, drops totalAssets in one call, then tripDrawdownCircuit latches a 2-day protocol-wide opens freeze. Trap-anyone / free-only-slow-gov asymmetry.

## Trusted / malicious timelock owner
### T1 (MEDIUM, conf ~90%): vault owner can FREEZE all LP withdrawals indefinitely
setSolvencyFloorBps accepts up to 30000 (3x totalReserved, PitVault:652 MAX=30000). Settlement headroom = totalAssets - solvencyFloorBps/1e4 * totalReserved. At 30000, headroom=0 whenever utilization>33% (util cap allows 80%): fulfilled=0, every queued withdrawal rolls forever, no LP can claim. Freeze-NOT-theft (vault has NO owner withdrawal path; only settleTraderWin[onlyEngine] + claim[own] move vault USDG). Even DEFAULT 12000 blocks withdrawals once util>83.3% (only ~3.3% above the 80% cap, tight). FIX: lower MAX solvencyFloorBps.
### T2 (LOW, ~85%): owner raises MMR to liquidate healthy positions (live read, E1). 2-day timelock is the window to addMargin/close. Intended lever.
### T3 (INFO/MED, ~95%): InsuranceFund.governanceWithdraw drains the ENTIRE fund to an arbitrary `to` (:141). By design/timelocked, but the single largest owner blast radius, recipient UNRESTRICTED (vs cover() vault-locked). FIX: restrict recipient / add a per-period cap.
### T4 (LOW, ~90%): misc timelocked levers: trade fees up to 1% (vs 5-10bps launch); keeperShareBps up to 100% (:981, no engine cap) starving the IF 80% inflow; setRiskConfig can loosen MAJOR reserve caps toward full TVL; setCloseOnly.

## Positive (owner CANNOT)
Redirect fees (feeJackpot/Treasury/Referral/Buyback IMMUTABLE, no setter :90-96); raise leverage above LOCKED (paramsFor clamps :328-329, _validateParams rejects); assign tier inconsistent with FDV (assertion :348-351, :408-409); write a price; re-point engine after wiring; withdraw LP funds (no fn); bypass the 2-day timelock (only instant-on-existing path is permissionless refreshTier E1). Guardian correctly SEPARATE (immutable, pause only 24h/72h, no funds/prices/params).
