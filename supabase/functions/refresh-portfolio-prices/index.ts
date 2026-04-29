/**
 * refresh-portfolio-prices
 *
 * Daily cron-driven prefetcher: walks every distinct (ticker,
 * currency, kind) tuple that exists across all users'
 * `investment_holdings` and refreshes their `price_cache` row.
 *
 * Why a separate function instead of just inviting users to tap
 * "Pull current price" every day:
 *   * Twelve Data free-tier limit is 800 req/day per project. With
 *     50 active users and 5 unique tickers each, naive on-demand
 *     pull goes 250+ uniques. A daily prefetch dedupes per ticker
 *     so the project sees ~1 req per ticker per day, not per user.
 *   * Crypto-only portfolios benefit too — CoinGecko's public tier
 *     is rate-limited to ~30 req/min; per-user pulls during peak
 *     hours hit 429.
 *
 * Auth: cron-only — caller must present `x-cron-secret == CRON_SECRET`.
 * Refuses anonymous JWT-based callers so a regular user can't churn
 * the upstream API.
 *
 * Schedule: pg_cron job runs once a day at 06:00 UTC. See migration
 * `20260501100000_refresh_prices_cron.sql` (companion to this file).
 *
 * Per-tick logic mirrors the on-demand `fetch-price` function but
 * walks the holdings table:
 *   1. SELECT DISTINCT ticker, kind, currency FROM investment_holdings.
 *   2. Skip kinds that don't have an upstream feed (metal, other).
 *   3. For each tuple call CoinGecko (crypto) or Twelve Data (rest).
 *   4. Upsert price_cache; record per-ticker outcome for the response.
 *   5. Sleep 250ms between requests so we stay under CoinGecko's
 *      30 req/min ceiling.
 */
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const TWELVE_DATA_API_KEY = Deno.env.get("TWELVE_DATA_API_KEY") ?? "";
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const COIN_GECKO_IDS: Record<string, string> = {
  BTC: "bitcoin", ETH: "ethereum", USDT: "tether", USDC: "usd-coin",
  BNB: "binancecoin", SOL: "solana", XRP: "ripple", ADA: "cardano",
  DOGE: "dogecoin", TON: "the-open-network", TRX: "tron", DOT: "polkadot",
  MATIC: "matic-network", AVAX: "avalanche-2", LINK: "chainlink",
  LTC: "litecoin", BCH: "bitcoin-cash", ATOM: "cosmos", XLM: "stellar",
  ETC: "ethereum-classic",
};

function coinGeckoId(ticker: string): string {
  return COIN_GECKO_IDS[ticker] ?? ticker.toLowerCase();
}

async function sleep(ms: number) {
  await new Promise((r) => setTimeout(r, ms));
}

type Holding = { ticker: string; kind: string; currency: string };
type Outcome = { ticker: string; currency: string; status: "ok" | "skip" | "err"; reason?: string };

async function fetchTwelveData(ticker: string): Promise<number | null> {
  if (!TWELVE_DATA_API_KEY) return null;
  const url = `https://api.twelvedata.com/price?symbol=${encodeURIComponent(ticker)}&apikey=${TWELVE_DATA_API_KEY}`;
  try {
    const resp = await fetch(url);
    if (!resp.ok) return null;
    const body = await resp.json() as Record<string, unknown>;
    if (typeof body.status === "string" && body.status === "error") return null;
    const priceStr = body.price;
    if (typeof priceStr !== "string") return null;
    const n = Number(priceStr);
    return Number.isFinite(n) && n >= 0 ? n : null;
  } catch {
    return null;
  }
}

async function fetchCoinGecko(ticker: string, currency: string): Promise<number | null> {
  const id = coinGeckoId(ticker);
  const vs = currency.toLowerCase();
  const url = `https://api.coingecko.com/api/v3/simple/price?ids=${encodeURIComponent(id)}&vs_currencies=${encodeURIComponent(vs)}`;
  try {
    const resp = await fetch(url);
    if (!resp.ok) return null;
    const body = await resp.json() as Record<string, Record<string, number>>;
    const inner = body[id];
    if (!inner) return null;
    const raw = inner[vs];
    return typeof raw === "number" && Number.isFinite(raw) && raw >= 0 ? raw : null;
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  // Cron-only authentication. Reject anyone who didn't bring the
  // shared secret — JWT-based callers shouldn't be able to drain
  // upstream API budget.
  const cronHeader = (req.headers.get("x-cron-secret") ?? "").trim();
  if (!CRON_SECRET || cronHeader !== CRON_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Pull every (ticker, kind, currency) tuple. PostgREST doesn't have
  // a native DISTINCT — we rely on dedup-on-the-fly here.
  const { data, error } = await supabase
    .from("investment_holdings")
    .select("ticker, kind, currency:asset_id(currency)");
  if (error) {
    return json({ error: error.message }, 500);
  }

  // The asset's currency lives on `assets.currency`; use a join-like
  // select. PostgREST returns the joined row as an object — flatten.
  type Row = { ticker: string; kind: string; currency: { currency?: string } | null };
  const seen = new Set<string>();
  const tuples: Holding[] = [];
  for (const row of (data ?? []) as Row[]) {
    const ticker = (row.ticker ?? "").toUpperCase();
    const kind = (row.kind ?? "").toLowerCase();
    const currency = (row.currency?.currency ?? "").toUpperCase();
    if (!ticker || !currency) continue;
    const k = `${ticker}|${currency}|${kind}`;
    if (seen.has(k)) continue;
    seen.add(k);
    tuples.push({ ticker, kind, currency });
  }

  const outcomes: Outcome[] = [];
  for (const t of tuples) {
    if (t.kind !== "crypto" && (t.kind === "metal" || t.kind === "other")) {
      outcomes.push({ ticker: t.ticker, currency: t.currency, status: "skip", reason: "manual-only kind" });
      continue;
    }

    const price = t.kind === "crypto"
      ? await fetchCoinGecko(t.ticker, t.currency)
      : await fetchTwelveData(t.ticker);

    if (price == null) {
      outcomes.push({
        ticker: t.ticker,
        currency: t.currency,
        status: "err",
        reason: "provider returned no price",
      });
      // Still throttle so a streak of failures doesn't stampede.
      await sleep(250);
      continue;
    }

    await supabase.from("price_cache").upsert({
      ticker: t.ticker,
      currency: t.currency,
      last_price: price,
      fetched_at: new Date().toISOString(),
      source: t.kind === "crypto" ? "coingecko" : "twelvedata",
    }, { onConflict: "ticker,currency" });

    outcomes.push({ ticker: t.ticker, currency: t.currency, status: "ok" });
    // Be polite: 250ms between requests stays under CoinGecko's
    // ~30 req/min limit and is safe for Twelve Data's 8 req/min.
    await sleep(250);
  }

  const ok = outcomes.filter((o) => o.status === "ok").length;
  const skip = outcomes.filter((o) => o.status === "skip").length;
  const err = outcomes.filter((o) => o.status === "err").length;
  return json({
    refreshed: ok,
    skipped: skip,
    errors: err,
    outcomes,
  });
});
