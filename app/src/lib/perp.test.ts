import { describe, expect, it } from "vitest";
import {
  KEEPER_FLOOR,
  MCAP_TIERS,
  MIN_MARGIN,
  PAYOUT_CAP_MULTIPLE,
  annualizedPct,
  borrowOwedUsdg,
  borrowRatePerHour1e18,
  clampPnl,
  dangerLevel,
  effectiveLeverage,
  equityUsdg,
  formatLeverageX100,
  formatRatePerHour,
  fundingIndexDelta1e18,
  fundingOwedUsdg,
  fundingRatePerHour1e18,
  initialMarginUsdg,
  liqDanger,
  liquidationPrice1e18,
  maintenanceMarginUsdg,
  notionalUsdg,
  previewClose,
  previewLiquidation,
  previewOpen,
  sizeForNotional,
  skew1e18,
  tierForFdv,
  tierParams,
  uPnlUsdg,
  weightedEntry1e18,
} from "./perp";

const ONE = 10n ** 18n;

/** Price float to 1e18. */
function px(v: number): bigint {
  return BigInt(Math.round(v * 1e12)) * 10n ** 6n;
}

// ---------------------------------------------------------------------------
// Units (MarginMathLib.notionalUsdg / sizeForNotional)
// ---------------------------------------------------------------------------

describe("notional and size", () => {
  it("2 tokens at 3 USDG = 6 USDG notional", () => {
    expect(notionalUsdg(2n * ONE, 3n * ONE)).toBe(6_000_000n);
  });

  it("sizeForNotional inverts notionalUsdg exactly on clean inputs", () => {
    const size = sizeForNotional(6_000_000n, 3n * ONE);
    expect(size).toBe(2n * ONE);
    expect(notionalUsdg(size, 3n * ONE)).toBe(6_000_000n);
  });

  it("floor division: opened size is never larger than paid-for notional", () => {
    // 100 USDG at price 0.000871: size = 1e8 * 1e12 * 1e18 / 871e12
    const size = sizeForNotional(100_000_000n, px(0.000871));
    expect(notionalUsdg(size, px(0.000871)) <= 100_000_000n).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// PnL + clamp + equity (spec 1.4)
// ---------------------------------------------------------------------------

describe("uPnL and the payout clamp", () => {
  const size = 500n * ONE; // 500 base units
  it("long profits when mark > entry; short mirrors", () => {
    expect(uPnlUsdg(size, ONE, 2n * ONE, true)).toBe(500_000_000n); // +500 USDG
    expect(uPnlUsdg(size, ONE, 2n * ONE, false)).toBe(-500_000_000n);
    expect(uPnlUsdg(size, 2n * ONE, ONE, false)).toBe(500_000_000n);
  });

  it("profit clamps at maxPayout (9x margin), loss clamps at margin", () => {
    const margin = 100_000_000n; // 100 USDG
    const maxPayout = PAYOUT_CAP_MULTIPLE * margin; // 900 USDG
    // A 99x pump: raw uPnL 49,500 USDG, clamped to 900.
    const raw = uPnlUsdg(size, ONE, 100n * ONE, true);
    expect(raw).toBe(49_500_000_000n);
    expect(clampPnl(raw, margin, maxPayout)).toBe(900_000_000n);
    // A wipeout: raw -250, clamped to -100.
    const down = uPnlUsdg(size, ONE, ONE / 2n, true);
    expect(down).toBe(-250_000_000n);
    expect(clampPnl(down, margin, maxPayout)).toBe(-100_000_000n);
  });

  it("equity = margin + clamped pnl minus funding minus borrow", () => {
    expect(equityUsdg(100_000_000n, 50_000_000n, 10_000_000n, 5_000_000n)).toBe(135_000_000n);
    expect(equityUsdg(100_000_000n, -100_000_000n, -3_000_000n, 0n)).toBe(3_000_000n);
  });
});

// ---------------------------------------------------------------------------
// Margin requirements (MMR floor, IM ceil: the anti-JELLY direction)
// ---------------------------------------------------------------------------

describe("maintenance and initial margin", () => {
  it("maintenance = mmrBps of notional, floor", () => {
    // 500 units at 1.0, 10% MMR = 50 USDG
    expect(maintenanceMarginUsdg(500n * ONE, ONE, 1_000)).toBe(50_000_000n);
  });

  it("initial margin rounds UP (removeMargin floor can never round in the trader's favor)", () => {
    // notional 1000 USDG at 6x: 1000/6 = 166.666667 rounded up
    const size = sizeForNotional(1_000_000_000n, ONE);
    expect(initialMarginUsdg(size, ONE, 600)).toBe(166_666_667n);
  });
});

// ---------------------------------------------------------------------------
// Liquidation price (MarginMathLib.liquidationPrice1e18, spec 1.7)
// ---------------------------------------------------------------------------

describe("liquidation price, exact closed form", () => {
  // 100 USDG margin, 5x long at entry 1.0, 10% MMR, no funding:
  // P_liq = (S*P0 minus m*scale) / (S * 0.9) with S = 500e18
  const size = 500n * ONE;
  const margin = 100_000_000n;

  it("long: 5x at 10% MMR liquidates at 0.888888888888888888", () => {
    const liq = liquidationPrice1e18(size, ONE, margin, 0n, 1_000, true);
    expect(liq).toBe(888_888_888_888_888_888n);
    // Boundary check: equity == maintenance at the returned price, within one
    // unit of floor dust, and strictly liquidatable one step further down.
    const pnl = uPnlUsdg(size, ONE, liq, true);
    const equity = margin + pnl;
    const maintenance = maintenanceMarginUsdg(size, liq, 1_000);
    expect(equity - maintenance <= 1n).toBe(true);
    const below = liq - 1_000_000_000_000n; // 1e-6 lower
    const equityBelow = margin + uPnlUsdg(size, ONE, below, true);
    expect(equityBelow < maintenanceMarginUsdg(size, below, 1_000)).toBe(true);
  });

  it("short: 5x at 10% MMR liquidates at 1.090909090909090909", () => {
    const liq = liquidationPrice1e18(size, ONE, margin, 0n, 1_000, false);
    expect(liq).toBe(1_090_909_090_909_090_909n);
  });

  it("accrued funding drags the liquidation price toward entry", () => {
    const base = liquidationPrice1e18(size, ONE, margin, 0n, 1_000, true);
    const withOwed = liquidationPrice1e18(size, ONE, margin, 10_000_000n, 1_000, true);
    expect(withOwed).toBe(911_111_111_111_111_111n);
    expect(withOwed > base).toBe(true);
    // A funding CREDIT (negative owed) pushes it further away instead.
    const withCredit = liquidationPrice1e18(size, ONE, margin, -10_000_000n, 1_000, true);
    expect(withCredit < base).toBe(true);
  });

  it("returns 0 when no adverse move can liquidate (overcollateralized long)", () => {
    // Margin worth more than the whole position: numerator goes non-positive.
    expect(liquidationPrice1e18(size, ONE, 600_000_000n, 0n, 1_000, true)).toBe(0n);
  });

  it("adding margin moves the liquidation price away (the add-margin promise)", () => {
    const before = liquidationPrice1e18(size, ONE, margin, 0n, 1_000, true);
    const after = liquidationPrice1e18(size, ONE, margin + 50_000_000n, 0n, 1_000, true);
    expect(after < before).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Funding (FundingLib: skew, rate, index, owed signs)
// ---------------------------------------------------------------------------

describe("skew funding", () => {
  it("skew = (L minus S) / max(L+S, floor)", () => {
    expect(skew1e18(60_000_000_000n, 40_000_000_000n, 10_000_000_000n)).toBe(
      200_000_000_000_000_000n, // +0.2
    );
    // Empty market with a floor: zero, not noise.
    expect(skew1e18(0n, 0n, 10_000_000_000n)).toBe(0n);
    // Tiny OI: the floor damps the rate.
    expect(skew1e18(1_000_000_000n, 0n, 10_000_000_000n)).toBe(100_000_000_000_000_000n);
  });

  it("rate = kF x skew, |rate| <= kF by construction", () => {
    const kF = 2_500_000_000_000_000n; // 0.25%/h
    expect(fundingRatePerHour1e18(200_000_000_000_000_000n, kF)).toBe(500_000_000_000_000n);
    expect(fundingRatePerHour1e18(-(10n ** 18n), kF)).toBe(-kF);
  });

  it("index delta accrues rate x mark x dt / 1h, sign preserved", () => {
    const rate = 500_000_000_000_000n; // 0.05%/h
    expect(fundingIndexDelta1e18(rate, 2n * ONE, 3_600)).toBe(1_000_000_000_000_000n);
    expect(fundingIndexDelta1e18(-rate, 2n * ONE, 3_600)).toBe(-1_000_000_000_000_000n);
    expect(fundingIndexDelta1e18(rate, 2n * ONE, 0)).toBe(0n);
  });

  it("longs owe when the index rose; shorts receive the mirror", () => {
    const size = 2_487_500_000_000_000_000_000n; // 2487.5 base units
    const delta = 1_000_000_000_000_000n;
    const longOwes = fundingOwedUsdg(size, delta, true);
    expect(longOwes).toBe(2_487_500n); // 2.4875 USDG owed
    expect(fundingOwedUsdg(size, delta, false)).toBe(-2_487_500n);
    expect(fundingOwedUsdg(size, -delta, true)).toBe(-2_487_500n);
  });
});

describe("borrow fees", () => {
  it("rate = kB x utilization, capped at 100%", () => {
    const kB = 100_000_000_000_000n; // 0.01%/h
    expect(borrowRatePerHour1e18(400_000_000n, 1_000_000_000n, kB)).toBe(40_000_000_000_000n);
    // Utilization over 100% clamps.
    expect(borrowRatePerHour1e18(2_000_000_000n, 1_000_000_000n, kB)).toBe(kB);
    expect(borrowRatePerHour1e18(0n, 1_000_000_000n, kB)).toBe(0n);
  });

  it("borrow owed is always positive (both sides pay)", () => {
    expect(borrowOwedUsdg(500n * ONE, 1_000_000_000_000n)).toBe(500n);
  });
});

// ---------------------------------------------------------------------------
// Open preview (PerpEngine.openPosition math)
// ---------------------------------------------------------------------------

describe("previewOpen mirrors the engine", () => {
  const params = tierParams(2, false); // 6x cap, 10 bps, 10% MMR, 10k cap

  it("fee on gross notional, size from net margin, 9x payout cap", () => {
    const p = previewOpen(1_000_000_000n, 500, 2n * ONE, params, "long", 0n, 0n);
    expect(p.blockedReason).toBeUndefined();
    expect(p.openFee).toBe(5_000_000n); // 5000 notional x 10 bps = 5 USDG
    expect(p.marginNet).toBe(995_000_000n);
    expect(p.notional).toBe(4_975_000_000n);
    expect(p.size1e18).toBe(2_487_500_000_000_000_000_000n);
    expect(p.maxPayout).toBe(8_955_000_000n);
    // Liq price at open matches the closed form with zero owed.
    expect(p.liqPrice1e18).toBe(
      liquidationPrice1e18(p.size1e18, 2n * ONE, p.marginNet, 0n, params.mmrBps, true),
    );
    expect(p.moveToLiqPct).toBeLessThan(0); // long liquidates below entry
  });

  it("blocks dust margin, over-cap margin, and out-of-band leverage", () => {
    expect(previewOpen(MIN_MARGIN - 1n, 500, ONE, params, "long", 0n, 0n).blockedReason).toBe(
      "min-margin",
    );
    expect(
      previewOpen(10_100_000_000n, 500, ONE, params, "long", 0n, 0n).blockedReason,
    ).toBe("margin-cap");
    expect(previewOpen(1_000_000_000n, 100, ONE, params, "long", 0n, 0n).blockedReason).toBe(
      "leverage",
    );
    expect(previewOpen(1_000_000_000n, 700, ONE, params, "long", 0n, 0n).blockedReason).toBe(
      "leverage",
    );
  });

  it("funding estimate signs by side against the market rate", () => {
    const rate = 500_000_000_000_000n; // longs pay
    const long = previewOpen(1_000_000_000n, 500, 2n * ONE, params, "long", rate, 0n);
    const short = previewOpen(1_000_000_000n, 500, 2n * ONE, params, "short", rate, 0n);
    expect(long.estFundingPerHourUsdg > 0n).toBe(true); // you pay
    expect(short.estFundingPerHourUsdg < 0n).toBe(true); // you receive
    expect(long.estFundingPerHourUsdg).toBe(-short.estFundingPerHourUsdg);
  });
});

// ---------------------------------------------------------------------------
// Close preview (PerpEngine._computeClose: pot, fee cap, conservation)
// ---------------------------------------------------------------------------

describe("previewClose mirrors _computeClose", () => {
  const size = 500n * ONE;
  const margin = 100_000_000n;
  const maxPayout = 900_000_000n;

  it("win at the cap: pot = margin + maxPayout, fee on closed notional", () => {
    const p = previewClose(size, ONE, 100n * ONE, margin, maxPayout, true, 0n, 0n, 10);
    expect(p.pnl).toBe(900_000_000n);
    expect(p.pot).toBe(1_000_000_000n);
    // Closed notional 50,000 USDG x 10 bps = 50 USDG.
    expect(p.closeFee).toBe(50_000_000n);
    expect(p.traderNet).toBe(950_000_000n);
    // Conservation: net + fee == pot, always.
    expect(p.traderNet + p.closeFee).toBe(p.pot);
  });

  it("full wipe: pot floors at zero, fee cannot exceed the pot", () => {
    const p = previewClose(size, ONE, ONE / 2n, margin, maxPayout, true, 0n, 0n, 10);
    expect(p.pnl).toBe(-100_000_000n);
    expect(p.pot).toBe(0n);
    expect(p.closeFee).toBe(0n);
    expect(p.traderNet).toBe(0n);
  });

  it("funding owed comes out of the pot; a credit adds to it", () => {
    const flat = previewClose(size, ONE, ONE, margin, maxPayout, true, 0n, 0n, 10);
    const owing = previewClose(size, ONE, ONE, margin, maxPayout, true, 10_000_000n, 2_000_000n, 10);
    expect(owing.pot).toBe(flat.pot - 12_000_000n);
    const credited = previewClose(size, ONE, ONE, margin, maxPayout, true, -10_000_000n, 0n, 10);
    expect(credited.pot).toBe(flat.pot + 10_000_000n);
  });

  it("the win slice never exceeds the reserved maxPayout (vault outflow bound)", () => {
    // Capped price win + a big funding credit would overshoot the reserve.
    const p = previewClose(size, ONE, 100n * ONE, margin, maxPayout, true, -500_000_000n, 0n, 0);
    expect(p.pot).toBe(margin + maxPayout);
  });
});

// ---------------------------------------------------------------------------
// Liquidation waterfall (spec 3.2 / 3.3)
// ---------------------------------------------------------------------------

describe("previewLiquidation waterfall", () => {
  it("penalty = min(equity, 1% notional); keeper 20% / vault 40% / IF 40%; residual returns", () => {
    const p = previewLiquidation(50_000_000n, 5_000_000_000n);
    expect(p.penalty).toBe(50_000_000n);
    expect(p.keeperReward).toBe(10_000_000n);
    expect(p.vaultShare).toBe(20_000_000n);
    expect(p.insuranceShare).toBe(20_000_000n);
    expect(p.traderResidual).toBe(0n);
    expect(p.shortfall).toBe(0n);
  });

  it("residual equity above the penalty goes BACK to the trader", () => {
    const p = previewLiquidation(80_000_000n, 5_000_000_000n);
    expect(p.penalty).toBe(50_000_000n);
    expect(p.traderResidual).toBe(30_000_000n);
  });

  it("keeper floor: 5 USDG minimum even when 20% of penalty is smaller", () => {
    const p = previewLiquidation(3_000_000n, 200_000_000n);
    expect(p.penalty).toBe(2_000_000n);
    expect(p.keeperReward).toBe(KEEPER_FLOOR); // floor top-up paid by the IF
    expect(p.vaultShare).toBe(800_000n); // 40% of the 2 USDG penalty
    expect(p.insuranceShare).toBe(800_000n); // penalty minus keeper cut minus vault cut
    expect(p.traderResidual).toBe(1_000_000n);
  });

  it("gap through the margin becomes an insurance-fund shortfall", () => {
    const p = previewLiquidation(-25_000_000n, 5_000_000_000n);
    expect(p.penalty).toBe(0n);
    expect(p.shortfall).toBe(25_000_000n);
  });
});

// ---------------------------------------------------------------------------
// Danger math (the 50% / 75% warning ladder)
// ---------------------------------------------------------------------------

describe("liqDanger and the warning ladder", () => {
  const entry = ONE;
  const liqLong = 900_000_000_000_000_000n; // 0.9

  it("long: halfway to liquidation = 0.5 (soft), 3/4 = loud, at liq = liquidatable", () => {
    expect(liqDanger(entry, 950_000_000_000_000_000n, liqLong, true)).toBeCloseTo(0.5, 10);
    expect(dangerLevel(liqDanger(entry, 950_000_000_000_000_000n, liqLong, true))).toBe("soft");
    expect(dangerLevel(liqDanger(entry, 925_000_000_000_000_000n, liqLong, true))).toBe("loud");
    expect(dangerLevel(liqDanger(entry, 899_000_000_000_000_000n, liqLong, true))).toBe(
      "liquidatable",
    );
  });

  it("profitable side clamps to 0 (safe), and no-liq positions are safe", () => {
    expect(liqDanger(entry, 1_050_000_000_000_000_000n, liqLong, true)).toBe(0);
    expect(liqDanger(entry, 1_050_000_000_000_000_000n, 0n, true)).toBe(0);
    expect(dangerLevel(0.49)).toBe("safe");
  });

  it("short mirrors: mark rising toward the liq price fills the bar", () => {
    const liqShort = 1_100_000_000_000_000_000n;
    expect(liqDanger(entry, 1_080_000_000_000_000_000n, liqShort, false)).toBeCloseTo(0.8, 10);
  });
});

// ---------------------------------------------------------------------------
// Tiers (the LOCKED schedule)
// ---------------------------------------------------------------------------

describe("mcap tiers", () => {
  it("band mapping matches PerpRiskConfig.tierForFdv", () => {
    expect(tierForFdv(499_999)).toBe(0);
    expect(tierForFdv(500_000)).toBe(1);
    expect(tierForFdv(2_000_000)).toBe(2);
    expect(tierForFdv(5_000_000)).toBe(3);
    expect(tierForFdv(10_000_000)).toBe(4);
    expect(tierForFdv(50_000_000)).toBe(5);
  });

  it("LOCKED leverage schedule: 4x / 6x / 6x / 8x / 10x / 15x", () => {
    expect(MCAP_TIERS.map((t) => t.maxLeverageX100)).toEqual([400, 600, 600, 800, 1_000, 1_500]);
  });

  it("pool-priced MMR defaults: 15/10/10/8/6/4 percent", () => {
    expect(MCAP_TIERS.map((t) => t.mmrBps)).toEqual([1_500, 1_000, 1_000, 800, 600, 400]);
  });

  it("majors override: 5 bps fees, 1/(2L) MMR, 250k position cap, calmer funding", () => {
    const major5 = tierParams(5, true);
    expect(major5.openFeeBps).toBe(5);
    expect(major5.closeFeeBps).toBe(5);
    expect(major5.mmrBps).toBe(333); // 1/(2 x 15) in bps
    expect(major5.maxPositionMargin).toBe(250_000_000_000n);
    const major4 = tierParams(4, true);
    expect(major4.mmrBps).toBe(500); // 1/(2 x 10)
    const pool = tierParams(5, false);
    expect(pool.openFeeBps).toBe(10);
    expect(major5.kFPerHour1e18 < pool.kFPerHour1e18).toBe(true);
  });

  it("MMR always sits strictly below initial margin at max leverage", () => {
    for (const t of MCAP_TIERS) {
      // mmr < 1/L  <=>  mmrBps x maxLeverageX100 < 10000 x 100
      expect(t.mmrBps * t.maxLeverageX100).toBeLessThan(1_000_000);
    }
  });
});

// ---------------------------------------------------------------------------
// Misc helpers
// ---------------------------------------------------------------------------

describe("helpers", () => {
  it("weightedEntry averages by size", () => {
    expect(weightedEntry1e18(ONE, ONE, ONE, 3n * ONE)).toBe(2n * ONE);
    expect(weightedEntry1e18(0n, 0n, 0n, 0n)).toBe(0n);
  });

  it("effectiveLeverage = notional / equity", () => {
    expect(effectiveLeverage(1_000_000_000n, 100_000_000n)).toBe(10);
    expect(effectiveLeverage(1_000_000_000n, 0n)).toBe(Infinity);
  });

  it("rate + leverage formatters", () => {
    expect(formatLeverageX100(1_500)).toBe("15x");
    expect(formatLeverageX100(450)).toBe("4.5x");
    expect(formatRatePerHour(500_000_000_000_000n)).toBe("+0.0500%/h");
    expect(formatRatePerHour(-2_500_000_000_000_000n)).toBe("-0.2500%/h");
    expect(annualizedPct(500_000_000_000_000n)).toBeCloseTo(438, 1); // 0.05%/h x 8760h
  });
});
