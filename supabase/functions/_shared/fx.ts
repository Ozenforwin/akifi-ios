// Live FX rates for edge functions.
//
// Source: open.er-api.com (free, no key — nothing secret in the URL), the
// same provider check-subscriptions has used since 2026-09. RUB-pivoted to
// match `FALLBACK_RATES`: `rates[CODE]` = units of CODE per 1 RUB. Every
// rate the provider returns is passed through (a hand-picked whitelist
// once dropped EUR and charged €10 as 10 ₽); the fallback table fills only
// currencies the provider did not return.
//
// Cached per isolate for an hour: a cron run converting hundreds of rows
// makes one request, not hundreds.
//
// TODO(budgets stream): once `public.fx_rates` (filled by refresh-fx-rates)
// exists, read it here first and keep this fetch as the fallback.

import { FALLBACK_RATES } from "./currency.ts";

const FX_URL = "https://open.er-api.com/v6/latest/RUB";
const TTL_MS = 60 * 60 * 1000;

export interface FxRates {
  /** Units of CODE per 1 RUB, upper-case codes. */
  rates: Record<string, number>;
  /** false when the provider was unreachable and only the fallback table is used. */
  live: boolean;
}

let cached: { value: FxRates; at: number } | null = null;

/** For tests. */
export function resetFxCache(): void {
  cached = null;
}

function normalize(raw: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  if (!raw || typeof raw !== "object") return out;
  for (const [code, value] of Object.entries(raw as Record<string, unknown>)) {
    const n = Number(value);
    if (Number.isFinite(n) && n > 0) out[code.toUpperCase()] = n;
  }
  return out;
}

export async function getRubRates(
  fetchImpl: typeof fetch = fetch,
  now: number = Date.now(),
): Promise<FxRates> {
  if (cached && now - cached.at < TTL_MS) return cached.value;
  let value: FxRates = { rates: { ...FALLBACK_RATES }, live: false };
  try {
    const res = await fetchImpl(FX_URL, { signal: AbortSignal.timeout(8000) });
    if (res.ok) {
      const payload = await res.json().catch(() => null);
      const live = normalize(payload?.rates);
      if (Object.keys(live).length > 0) {
        value = { rates: { ...FALLBACK_RATES, ...live, RUB: 1 }, live: true };
      }
    } else {
      console.warn(`[fx] provider HTTP ${res.status}; using fallback rates`);
    }
  } catch (err) {
    console.warn(`[fx] provider unreachable (${(err as Error)?.name ?? "error"}); using fallback rates`);
  }
  // Only cache live rates for the full TTL; retry a failed fetch sooner.
  cached = { value, at: value.live ? now : now - TTL_MS + 5 * 60 * 1000 };
  return value;
}

/**
 * Re-pivots RUB-based rates to USD (units of CODE per 1 USD) — the
 * convention assistant-query and the iOS client use.
 */
export function toUsdPivot(rubRates: Record<string, number>): Record<string, number> {
  const usd = rubRates.USD;
  if (!usd || usd <= 0) return {};
  const out: Record<string, number> = {};
  for (const [code, rate] of Object.entries(rubRates)) out[code] = rate / usd;
  return out;
}
