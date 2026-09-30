"use client";

import { useQuery } from "@tanstack/react-query";
import { isMockMode, requireAddress } from "@/lib/config";
import { jackpotContract } from "@/lib/contracts";
import { mockJackpot, tickPot } from "@/lib/mock/data";
import type { DrawRecord, JackpotState } from "@/lib/types";

interface RawDraw {
  kind: number;
  mode: number;
  fulfilled: boolean;
  coordinator: string;
  period: bigint;
  epoch: bigint;
  entrantRound: bigint;
  requestId: bigint;
  word: bigint;
  winner: string;
  amount: bigint;
}

async function fetchChainJackpot(): Promise<JackpotState> {
  const jackpot = jackpotContract(requireAddress("jackpot"));
  const [pot, drawCount, lastDailyDay, entrantRound] = await Promise.all([
    jackpot.read.potBalance() as Promise<bigint>,
    jackpot.read.drawCount() as Promise<bigint>,
    jackpot.read.lastDailyDay() as Promise<bigint>,
    jackpot.read.currentEntrantRound() as Promise<bigint>,
  ]);
  const entrantCount = (await jackpot.read.entrantCount([entrantRound])) as bigint;

  const from = drawCount > 20n ? drawCount - 20n : 0n;
  const ids: bigint[] = [];
  for (let i = from; i < drawCount; i++) ids.push(i);
  const rawDraws = await Promise.all(
    ids.map((id) => jackpot.read.getDraw([id]) as Promise<RawDraw>),
  );
  const draws: DrawRecord[] = rawDraws
    .map((d, i): DrawRecord | null =>
      d.fulfilled
        ? {
            drawId: Number(ids[i]),
            kind: d.kind === 0 ? "daily" : "weekly",
            mode: d.mode === 0 ? "entrants" : "weighted",
            winner: d.winner,
            amount: d.amount,
            word: d.word,
            requestId: d.requestId,
            epoch: Number(d.epoch),
            completedAt: 0,
            txHash: "",
          }
        : null,
    )
    .filter((d): d is DrawRecord => d !== null)
    .reverse();

  const nextDailyAt = (Number(lastDailyDay) + 1) * 86_400;
  const EPOCH = 7 * 86_400;
  const nextWeeklyAt = (Math.floor(Date.now() / 1000 / EPOCH) + 1) * EPOCH;

  return {
    pot,
    nextDailyAt,
    nextWeeklyAt,
    entrantCount: Number(entrantCount),
    draws,
  };
}

/** Jackpot pot, countdowns, and draw history. Pot refreshes fast for the odometer. */
export function useJackpot() {
  return useQuery({
    queryKey: ["jackpot"],
    queryFn: async (): Promise<JackpotState> =>
      isMockMode ? { ...mockJackpot, pot: tickPot() } : fetchChainJackpot(),
    refetchInterval: 3_000,
  });
}
