import { NextRequest, NextResponse } from "next/server";

/**
 * Geofence middleware.
 *
 * Reads BLOCKED_COUNTRIES (comma-separated ISO 3166-1 alpha-2 codes, default
 * "US,GB,CA,CH,AE,SG") and rewrites blocked visitors to the full-screen
 * /blocked page. Country detection uses the geo headers set by the hosting
 * edge (Vercel: x-vercel-ip-country, Cloudflare: cf-ipcountry). When no geo
 * header is present (local dev, unknown edge) the request passes: the chain
 * itself is the final arbiter of who can transact.
 */

const DEFAULT_BLOCKED = "US,GB,CA,CH,AE,SG";

function blockedCountries(): Set<string> {
  const raw = process.env.BLOCKED_COUNTRIES ?? DEFAULT_BLOCKED;
  return new Set(
    raw
      .split(",")
      .map((c) => c.trim().toUpperCase())
      .filter((c) => c.length === 2),
  );
}

function requestCountry(request: NextRequest): string | undefined {
  return (
    request.headers.get("x-vercel-ip-country") ??
    request.headers.get("cf-ipcountry") ??
    undefined
  )?.toUpperCase();
}

export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  if (pathname.startsWith("/blocked")) {
    return NextResponse.next();
  }
  const country = requestCountry(request);
  if (country && blockedCountries().has(country)) {
    const url = request.nextUrl.clone();
    url.pathname = "/blocked";
    return NextResponse.rewrite(url, { status: 451 });
  }
  return NextResponse.next();
}

export const config = {
  // Everything except Next internals and static assets.
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|woff2?)).*)"],
};
