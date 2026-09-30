"use client";

import { useEffect, useState } from "react";

/** Unix seconds, ticking every second: powers countdowns without drift. */
export function useNowSecond(): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const timer = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1_000);
    return () => clearInterval(timer);
  }, []);
  return now;
}
