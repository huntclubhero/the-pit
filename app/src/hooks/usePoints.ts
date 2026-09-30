"use client";

import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { isMockMode, requireAddress } from "@/lib/config";
import { pointsContract } from "@/lib/contracts";
import { dailyMultiplier } from "@/lib/format";
import {
  mockLeaderboardGlobal,
  mockLeaderboardWeekly,
  mockProfile,
} from "@/lib/mock/data";
import type { LeaderboardEntry, PointsProfile, RankTier } from "@/lib/types";

/** Rank track thresholds (lifetime points, 1e18). Frontend presentation only. */
export const RANK_TIERS: RankTier[] = [
  { name: "Railbird", threshold: 0n },
  { name: "Grinder", threshold: 10_000n * 10n ** 18n },
  { name: "Shark", threshold: 50_000n * 10n ** 18n },
  { name: "Whale", threshold: 250_000n * 10n ** 18n },
  { name: "Pit Boss", threshold: 1_000_000n * 10n ** 18n },
];

export function rankForPoints(lifetime: bigint): {
  tier: RankTier;
  tierIndex: number;
  next?: RankTier;
  /** 0..1 progress toward the next tier. */
  progress: number;
} {
  let tierIndex = 0;
  for (let i = RANK_TIERS.length - 1; i >= 0; i--) {
    if (lifetime >= RANK_TIERS[i].threshold) {
      tierIndex = i;
      break;
    }
  }
  const tier = RANK_TIERS[tierIndex];
  const next = RANK_TIERS[tierIndex + 1];
  let progress = 1;
  if (next) {
    const span = next.threshold - tier.threshold;
    progress = span === 0n ? 1 : Number(((lifetime - tier.threshold) * 1_000n) / span) / 1_000;
  }
  return { tier, tierIndex, next, progress: Math.min(1, Math.max(0, progress)) };
}

async function fetchChainProfile(owner: Address): Promise<PointsProfile> {
  const points = pointsContract(requireAddress("points"));
  const epoch = (await points.read.currentEpoch()) as bigint;
  const [lifetime, season, winStreak, daily, winMult, dailyMult] = await Promise.all([
    points.read.pointsOf([owner]) as Promise<bigint>,
    points.read.epochPointsOf([owner, epoch]) as Promise<bigint>,
    points.read.winStreakOf([owner]) as Promise<[bigint, bigint, boolean]>,
    points.read.dailyStreakOf([owner]) as Promise<[bigint, bigint]>,
    points.read.winMultiplierOf([owner]) as Promise<bigint>,
    points.read.dailyMultiplierOf([owner]) as Promise<bigint>,
  ]);
  const [wins, shieldConsumedAt, shieldAvailable] = winStreak;
  const [lastDay, count] = daily;
  const today = Math.floor(Date.now() / 1000 / 86_400);
  const activeToday = Number(lastDay) === today;
  const streakCount = activeToday || Number(lastDay) + 1 === today ? Number(count) : 0;
  const calendar = Array.from({ length: 14 }, (_, i) => {
    const day = today - (13 - i);
    return day > Number(lastDay) - streakCount && day <= Number(lastDay);
  });
  const shieldRefreshIn = shieldAvailable
    ? undefined
    : Number(shieldConsumedAt) + 24 * 3_600 - Math.floor(Date.now() / 1000);
  return {
    lifetime,
    season,
    seasonEpoch: Number(epoch),
    winStreak: Number(wins),
    shieldAvailable,
    shieldRefreshIn,
    dailyStreak: streakCount,
    dailyCalendar: calendar,
    winMultiplier: winMult,
    dailyMultiplier: dailyMult ?? dailyMultiplier(streakCount),
    referralCode: "SOON",
    referrals: 0,
    referralPoints: 0n,
  };
}

/** The connected wallet's full points profile. */
export function usePointsProfile(owner?: string) {
  return useQuery({
    queryKey: ["points-profile", owner?.toLowerCase() ?? "mock"],
    queryFn: async () =>
      isMockMode || !owner ? mockProfile : fetchChainProfile(owner as Address),
    refetchInterval: 10_000,
  });
}

/**
 * Leaderboards. On-chain enumeration of every holder needs an indexer, so the
 * chain path serves the same board shape from indexed PointsEarned events in a
 * later milestone; mock data covers design review.
 */
export function useLeaderboards() {
  return useQuery({
    queryKey: ["leaderboards"],
    queryFn: async (): Promise<{
      global: LeaderboardEntry[];
      weekly: LeaderboardEntry[];
    }> => ({ global: mockLeaderboardGlobal, weekly: mockLeaderboardWeekly }),
    staleTime: 60_000,
  });
}
