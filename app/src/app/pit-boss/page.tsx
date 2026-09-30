"use client";

import { useEffect, useRef, useState } from "react";
import { Boot } from "@/components/Boot";
import { Odometer } from "@/components/Odometer";
import { RankUpCeremony } from "@/components/RankUpCeremony";
import { useViewerAddress } from "@/components/ConnectButton";
import { isMockMode } from "@/lib/config";
import { useLeaderboards, usePointsProfile, rankForPoints, RANK_TIERS } from "@/hooks/usePoints";
import {
  formatCountdown,
  formatMultiplier,
  formatPoints,
  formatPointsCompact,
  shortAddress,
} from "@/lib/format";
import { POINTS_DISCLAIMER } from "@/lib/mock/data";

export default function PitBossPage() {
  const viewer = useViewerAddress();
  const { data: profile } = usePointsProfile(viewer);
  const { data: boards } = useLeaderboards();
  const [board, setBoard] = useState<"global" | "weekly">("global");
  const [ceremony, setCeremony] = useState<string | null>(null);
  const prevTierIndex = useRef<number | null>(null);

  // Full-screen rank-up ceremony whenever the lifetime tier climbs mid-session.
  const tierIndexNow = profile ? rankForPoints(profile.lifetime).tierIndex : null;
  useEffect(() => {
    if (tierIndexNow === null) return;
    if (prevTierIndex.current !== null && tierIndexNow > prevTierIndex.current) {
      setCeremony(RANK_TIERS[tierIndexNow].name);
    }
    prevTierIndex.current = tierIndexNow;
  }, [tierIndexNow]);

  if (!profile) {
    return <Boot label="Dealing you in" />;
  }

  const rank = rankForPoints(profile.lifetime);
  const entries = board === "global" ? boards?.global : boards?.weekly;

  return (
    <div className="px-4 md:px-6 py-6 flex flex-col gap-6">
      {ceremony && <RankUpCeremony rankName={ceremony} onDone={() => setCeremony(null)} />}
      {/* Header: lifetime + season */}
      <section className="flex flex-col md:flex-row md:items-end gap-6 rise-in">
        <div>
          <div className="font-mono text-[10px] uppercase tracking-[0.2em] text-ink-faint">
            Lifetime Pit Points
          </div>
          <div className="num text-5xl md:text-6xl text-amber mt-1">
            <Odometer value={formatPoints(profile.lifetime)} />
          </div>
        </div>
        <div>
          <div className="font-mono text-[10px] uppercase tracking-[0.2em] text-ink-faint">
            Season (epoch {profile.seasonEpoch})
          </div>
          <div className="num text-3xl text-ink mt-1">
            <Odometer value={formatPoints(profile.season)} />
          </div>
        </div>
        <div className="md:ml-auto">
          <div className="display text-4xl tracking-[0.06em] text-ink uppercase">
            {rank.tier.name}
          </div>
          <div className="font-mono text-[10px] text-ink-faint">current rank</div>
        </div>
      </section>

      {/* Rank track */}
      <section className="panel rise-in rise-in-1">
        <div className="panel-head">
          <span>Rank Track</span>
          <div className="flex items-center gap-3">
            {rank.next && (
              <span className="font-mono text-[10px] text-ink-faint normal-case tracking-normal">
                {formatPointsCompact(rank.next.threshold - profile.lifetime)} points to{" "}
                {rank.next.name}
              </span>
            )}
            {isMockMode && rank.next && (
              <button
                type="button"
                onClick={() => setCeremony(rank.next!.name)}
                className="btn-ghost px-2.5 py-1 font-mono text-[9px] uppercase tracking-[0.1em] normal-case"
                title="Demo the rank-up ceremony"
              >
                Preview rank-up
              </button>
            )}
          </div>
        </div>
        <div className="p-5">
          <div className="relative h-1.5 bg-pit-4 rounded-full overflow-hidden">
            <div
              className="absolute inset-y-0 left-0 bg-amber transition-[width] duration-[900ms]"
              style={{
                width: `${((rank.tierIndex + rank.progress) / (RANK_TIERS.length - 1)) * 100}%`,
              }}
            />
          </div>
          <div className="mt-3 grid grid-cols-5 gap-1">
            {RANK_TIERS.map((tier, i) => {
              const reached = profile.lifetime >= tier.threshold;
              const current = tier.name === rank.tier.name;
              return (
                <div key={tier.name} className={i === 0 ? "text-left" : i === 4 ? "text-right" : "text-center"}>
                  <div
                    className={`display text-[15px] md:text-lg tracking-[0.06em] uppercase ${
                      current ? "text-amber" : reached ? "text-ink" : "text-ink-faint"
                    }`}
                  >
                    {tier.name}
                  </div>
                  <div className="num text-[10px] text-ink-faint">
                    {formatPointsCompact(tier.threshold)}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      </section>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-5">
        {/* Win streak */}
        <section className="panel rise-in rise-in-2">
          <div className="panel-head">
            <span>Win Streak</span>
          </div>
          <div className="p-5 flex items-center gap-5">
            <div className="flame text-5xl" aria-hidden>
              {profile.winStreak > 0 ? "\u{1F525}" : "\u{1FAB5}"}
            </div>
            <div>
              <div className="num text-4xl text-ink">{profile.winStreak}</div>
              <div className="font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">
                consecutive wins
              </div>
              <div className="mt-2">
                {profile.shieldAvailable ? (
                  <span className="chip text-felt-bright border-felt">Shield up</span>
                ) : (
                  <span className="chip text-stale">
                    Shield back in {formatCountdown(profile.shieldRefreshIn ?? 0)}
                  </span>
                )}
              </div>
            </div>
            <div className="ml-auto text-right">
              <div className="num text-2xl text-amber">
                {formatMultiplier(profile.winMultiplier)}
              </div>
              <div className="font-mono text-[10px] text-ink-faint">streak multiplier</div>
            </div>
          </div>
          <p className="px-5 pb-4 font-mono text-[10px] leading-relaxed text-ink-faint">
            One loss per 24h is absorbed by the shield. A second loss inside the window resets
            the streak. 6+ wins locks the 5.00x cap.
          </p>
        </section>

        {/* Daily streak calendar */}
        <section className="panel rise-in rise-in-3">
          <div className="panel-head">
            <span>Daily Streak</span>
            <span className="num text-[11px] text-amber">
              {formatMultiplier(profile.dailyMultiplier)}
            </span>
          </div>
          <div className="p-5">
            <div className="flex items-baseline gap-2">
              <span className="num text-4xl text-ink">{profile.dailyStreak}</span>
              <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">
                days in the pit
              </span>
            </div>
            <div className="mt-4 grid grid-cols-14 gap-1" style={{ gridTemplateColumns: "repeat(14, 1fr)" }}>
              {profile.dailyCalendar.map((active, i) => (
                <div
                  key={i}
                  className={`aspect-square rounded-sm ${
                    active ? "bg-amber" : "bg-pit-4"
                  } ${i === profile.dailyCalendar.length - 1 && active ? "ring-1 ring-amber-hot" : ""}`}
                  title={active ? "active day" : "missed day"}
                />
              ))}
            </div>
            <p className="mt-4 font-mono text-[10px] leading-relaxed text-ink-faint">
              +0.05x per consecutive day, capped at 1.50x on day 11. Miss a day and it resets.
            </p>
          </div>
        </section>

        {/* Referral card */}
        <section className="panel rise-in rise-in-4">
          <div className="panel-head">
            <span>Referrals</span>
          </div>
          <div className="p-5">
            <div className="font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">
              Your code
            </div>
            <div className="mt-1 flex items-center gap-2">
              <span className="num text-xl text-amber border border-amber-deep bg-amber/5 rounded-xl px-3 py-1.5">
                {profile.referralCode}
              </span>
              <CopyButton text={profile.referralCode} />
            </div>
            <div className="mt-4 grid grid-cols-2 gap-4">
              <div>
                <div className="num text-2xl text-ink">{profile.referrals}</div>
                <div className="font-mono text-[10px] text-ink-faint">degens referred</div>
              </div>
              <div>
                <div className="num text-2xl text-ink">
                  {formatPoints(profile.referralPoints)}
                </div>
                <div className="font-mono text-[10px] text-ink-faint">points from referrals</div>
              </div>
            </div>
            <p className="mt-4 font-mono text-[10px] leading-relaxed text-ink-faint">
              10% of every fee routes to the referral pool. Points from referrals are non-transferable.
            </p>
          </div>
        </section>
      </div>

      {/* Leaderboard */}
      <section className="panel rise-in rise-in-3">
        <div className="panel-head">
          <span>Leaderboard</span>
          <div className="flex gap-1">
            {(["global", "weekly"] as const).map((b) => (
              <button
                key={b}
                type="button"
                onClick={() => setBoard(b)}
                className={`display tap press px-3 py-1 text-[13px] tracking-[0.08em] uppercase rounded-lg ${
                  board === b ? "bg-amber text-pit-0" : "text-ink-faint hover:text-ink"
                }`}
              >
                {b}
              </button>
            ))}
          </div>
        </div>
        <div className="table-scroll">
          <table className="data-table">
            <thead>
              <tr>
                <th>Rank</th>
                <th>Player</th>
                <th>Tier</th>
                <th>Points</th>
              </tr>
            </thead>
            <tbody>
              {entries?.map((e) => {
                const tier = board === "global" ? rankForPoints(e.points).tier.name : "";
                return (
                  <tr key={e.rank} className={e.isYou ? "bg-pit-3" : ""}>
                    <td className="num text-ink-dim">#{e.rank}</td>
                    <td>
                      <span className={`font-mono text-[12px] ${e.isYou ? "text-amber" : "text-ink"}`}>
                        {e.alias ?? shortAddress(e.address)}
                      </span>
                      {e.isYou && (
                        <span className="ml-2 chip text-amber border-amber-deep">you</span>
                      )}
                    </td>
                    <td className="display text-[14px] tracking-[0.06em] uppercase text-ink-dim">
                      {board === "global" ? tier : ""}
                    </td>
                    <td className="num text-ink">{formatPoints(e.points)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>

      <p className="font-mono text-[10px] leading-relaxed text-ink-faint max-w-3xl">
        {POINTS_DISCLAIMER}
      </p>
    </div>
  );
}

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      className="btn-ghost tap px-3 py-1.5 text-[11px] font-mono uppercase tracking-[0.08em]"
      onClick={() => {
        navigator.clipboard?.writeText(text).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1_500);
        });
      }}
    >
      {copied ? "Copied" : "Copy"}
    </button>
  );
}
