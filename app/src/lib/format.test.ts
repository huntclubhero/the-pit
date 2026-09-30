import { describe, expect, it } from "vitest";
import {
  basePoints,
  compactNumber,
  creatorShare,
  dailyMultiplier,
  formatAge,
  formatBpsPct,
  formatCountdown,
  formatPoints,
  formatPrice,
  formatSignedUsdg,
  formatUsdg,
  lossRebate,
  multiplierForWord,
  parseUsdg,
  splitFee,
  spinBonus,
  traderPoints,
  winMultiplier,
} from "./format";

const ONE = 10n ** 18n;

// ---------------------------------------------------------------------------
// Fee split (PerpEngine._distributeFee): 25 / 10 / 20 / 25 / 20, dust to treasury
// ---------------------------------------------------------------------------

describe("fee split", () => {
  it("splits 25/10/20/25/20 exactly on a clean fee", () => {
    const s = splitFee(1_000_000n);
    expect(s.jackpot).toBe(250_000n);
    expect(s.referral).toBe(100_000n);
    expect(s.vault).toBe(200_000n);
    expect(s.buyback).toBe(250_000n);
    expect(s.treasury).toBe(200_000n);
  });

  it("always sums to the fee: treasury absorbs round-down dust", () => {
    for (const fee of [1n, 3n, 9_999n, 1_000_003n, 123_456_789n]) {
      const s = splitFee(fee);
      expect(s.jackpot + s.referral + s.vault + s.buyback + s.treasury).toBe(fee);
    }
  });

  it("floors each earmarked leg", () => {
    const s = splitFee(1_000_003n);
    expect(s.jackpot).toBe(250_000n); // floor(1000003 x 0.25)
    expect(s.vault).toBe(200_000n); // floor(1000003 x 0.20)
    expect(s.buyback).toBe(250_000n); // floor(1000003 x 0.25)
  });
});

// ---------------------------------------------------------------------------
// Points math (PitPoints, unchanged in v2)
// ---------------------------------------------------------------------------

describe("points math", () => {
  it("base = notional x 1e11 (1000 USDG notional = 100 points)", () => {
    expect(basePoints(1_000_000_000n)).toBe(100n * ONE);
  });

  it("win multiplier ladder", () => {
    expect(winMultiplier(0)).toBe(10_000n);
    expect(winMultiplier(2)).toBe(12_000n);
    expect(winMultiplier(4)).toBe(20_000n);
    expect(winMultiplier(9)).toBe(50_000n);
  });

  it("daily multiplier: +0.05x per day, capped at 1.5x", () => {
    expect(dailyMultiplier(1)).toBe(10_000n);
    expect(dailyMultiplier(6)).toBe(12_500n);
    expect(dailyMultiplier(40)).toBe(15_000n);
  });

  it("trader points compose both multipliers with floor division", () => {
    const base = 100n * ONE;
    // 4-win streak (2.0x) on day 6 (1.25x): 100 x 2.5 = 250
    expect(traderPoints(base, 4, 6)).toBe(250n * ONE);
  });

  it("loss rebate is 25% of base, creator share 5%", () => {
    expect(lossRebate(100n * ONE)).toBe(25n * ONE);
    expect(creatorShare(100n * ONE)).toBe(5n * ONE);
  });

  it("spin thresholds mirror multiplierForWord", () => {
    expect(multiplierForWord(5_999n)).toBe(1);
    expect(multiplierForWord(6_000n)).toBe(2);
    expect(multiplierForWord(8_500n)).toBe(5);
    expect(multiplierForWord(9_500n)).toBe(20);
    expect(multiplierForWord(9_900n)).toBe(100);
    expect(spinBonus(10n * ONE, 20)).toBe(190n * ONE);
  });
});

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

describe("formatting", () => {
  it("formatUsdg groups and fixes decimals", () => {
    expect(formatUsdg(1_234_567_890n)).toBe("1,234.56");
    expect(formatUsdg(-50_000_000n)).toBe("-50.00");
    expect(formatUsdg(999n, 6)).toBe("0.000999");
  });

  it("formatSignedUsdg carries an explicit plus", () => {
    expect(formatSignedUsdg(412_200_000n)).toBe("+412.20");
    expect(formatSignedUsdg(-88_100_000n)).toBe("-88.10");
    expect(formatSignedUsdg(0n)).toBe("+0.00");
  });

  it("formatPrice keeps 4 sig figs on sub-unit memecoin prices", () => {
    expect(formatPrice(4_217_000_000_000_000n)).toBe("0.004217");
    expect(formatPrice(871_000_000_000_000n)).toBe("0.0008710");
    expect(formatPrice(64_213n * ONE + ONE / 2n)).toBe("64,213.50");
  });

  it("formatPoints, bps, compact, countdown, age", () => {
    expect(formatPoints(1_500n * ONE)).toBe("1,500");
    expect(formatBpsPct(1_843)).toBe("+18.43%");
    expect(formatBpsPct(-723)).toBe("-7.23%");
    expect(compactNumber(2_841_337)).toBe("2.84M");
    expect(compactNumber(48_200)).toBe("48.2K");
    expect(formatCountdown(90_061)).toBe("1d 01:01:01");
    expect(formatAge(59)).toBe("59s");
    expect(formatAge(3_599)).toBe("59m");
    expect(formatAge(90_000)).toBe("1d");
  });

  it("parseUsdg parses and floors extra precision, rejects junk", () => {
    expect(parseUsdg("1,234.5678999")).toBe(1_234_567_899n);
    expect(parseUsdg("0.000001")).toBe(1n);
    expect(parseUsdg("")).toBeUndefined();
    expect(parseUsdg("abc")).toBeUndefined();
    expect(parseUsdg(".")).toBeUndefined();
  });
});
