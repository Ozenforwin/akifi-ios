/**
 * fetch-price
 *
 * Returns the latest market price for a given ticker / currency, used
 * by the iOS Portfolio surface (Sprint 3 of the BETA "Активы → инвест-
 * инструмент" plan). Reads first from the `price_cache` table (30-min
 * TTL); on miss falls through to one of two free providers depending
 * on `kind`:
 *
 *   - kind = 'crypto'  → CoinGecko `/api/v3/simple/price` (no API key,
 *                        ~30 req/min on the public endpoint).
 *   - everything else  → Twelve Data `/price` (requires
 *                        TWELVE_DATA_API_KEY env var; 800 req/day on
 *                        the free tier with 4-hour delayed quotes).
 *
 * On a successful upstream call we upsert the cache row so the next
 * caller within 30 minutes is served from the DB; on rate-limit /
 * provider error we return 503 and the iOS client gracefully falls
 * back to manual entry.
 *
 * The function gateway already validates JWT (`verify_jwt = true` in
 * the dashboard), so any request that reaches us is authenticated.
 *
 * Body shape:
 *   { ticker: string, kind: string, currency: string }
 * Response:
 *   { ticker, currency, last_price: number, fetched_at: ISO8601, source }
 */
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const TWELVE_DATA_API_KEY = Deno.env.get("TWELVE_DATA_API_KEY") ?? "";

const CACHE_TTL_SECONDS = 30 * 60; // 30 minutes

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Crypto ticker → CoinGecko id mapping. Top-20 retail names cover ~95%
// of what beta users will type. Anything outside this list still
// works if the user types the CoinGecko slug directly (e.g. "near-
// protocol"). For unknowns we return 503 so the iOS form falls back
// to manual entry.
// ---------------------------------------------------------------------------
const COIN_GECKO_IDS: Record<string, string> = {
  BTC: "bitcoin",
  ETH: "ethereum",
  USDT: "tether",
  USDC: "usd-coin",
  BNB: "binancecoin",
  SOL: "solana",
  XRP: "ripple",
  ADA: "cardano",
  DOGE: "dogecoin",
  TON: "the-open-network",
  TRX: "tron",
  DOT: "polkadot",
  MATIC: "matic-network",
  AVAX: "avalanche-2",
  LINK: "chainlink",
  LTC: "litecoin",
  BCH: "bitcoin-cash",
  ATOM: "cosmos",
  XLM: "stellar",
  ETC: "ethereum-classic",
};

function coinGeckoId(ticker: string): string {
  const upper = ticker.trim().toUpperCase();
  return COIN_GECKO_IDS[upper] ?? ticker.trim().toLowerCase();
}

// ---------------------------------------------------------------------------
// Cache helpers
// ---------------------------------------------------------------------------
type CachedPrice = {
  last_price: number;
  fetched_at: string;
  source: "twelvedata" | "coingecko" | "manual";
};

async function readCache(
  supabase: ReturnType<typeof createClient>,
  ticker: string,
  currency: string,
): Promise<CachedPrice | null> {
  const { data, error } = await supabase
    .from("price_cache")
    .select("last_price, fetched_at, source")
    .eq("ticker", ticker)
    .eq("currency", currency)
    .maybeSingle();

  if (error || !data) return null;

  const fetchedAt = new Date(data.fetched_at as string).getTime();
  const age = (Date.now() - fetchedAt) / 1000;
  if (age > CACHE_TTL_SECONDS) return null;

  return {
    last_price: Number(data.last_price),
    fetched_at: data.fetched_at as string,
    source: data.source as CachedPrice["source"],
  };
}

async function writeCache(
  supabase: ReturnType<typeof createClient>,
  ticker: string,
  currency: string,
  price: number,
  source: CachedPrice["source"],
): Promise<string> {
  const fetchedAt = new Date().toISOString();
  await supabase.from("price_cache").upsert({
    ticker,
    currency,
    last_price: price,
    fetched_at: fetchedAt,
    source,
  }, { onConflict: "ticker,currency" });
  return fetchedAt;
}

// ---------------------------------------------------------------------------
// Provider calls
// ---------------------------------------------------------------------------

/**
 * Twelve Data `/price` returns the latest quote in the listing currency.
 * For example `?symbol=VOO` returns USD; cross-currency conversion is a
 * paid endpoint. To stay on the free tier we only return the price as
 * quoted by Twelve Data — the iOS client should pass the currency it
 * expects (which equals the parent Asset's currency); a mismatch
 * surfaces as a 4xx rather than silent FX guesswork.
 */
async function fetchTwelveData(
  ticker: string,
  currency: string,
): Promise<{ price: number; source: "twelvedata" } | { error: string; status: number }> {
  if (!TWELVE_DATA_API_KEY) {
    return { error: "TWELVE_DATA_API_KEY not configured", status: 503 };
  }

  const symbol = encodeURIComponent(ticker.trim().toUpperCase());
  const url =
    `https://api.twelvedata.com/price?symbol=${symbol}&apikey=${TWELVE_DATA_API_KEY}`;

  let resp: Response;
  try {
    resp = await fetch(url, { method: "GET" });
  } catch (e) {
    return { error: `Network error: ${(e as Error).message}`, status: 503 };
  }

  if (!resp.ok) {
    return { error: `Provider HTTP ${resp.status}`, status: 503 };
  }

  let body: Record<string, unknown>;
  try {
    body = await resp.json();
  } catch {
    return { error: "Provider returned non-JSON body", status: 503 };
  }

  // Twelve Data error shape: { code, message, status: "error" }.
  if (typeof body.status === "string" && body.status === "error") {
    return {
      error: String(body.message ?? "Twelve Data error"),
      status: typeof body.code === "number" && body.code >= 400 && body.code < 500
        ? 404
        : 503,
    };
  }

  const priceStr = body.price;
  if (typeof priceStr !== "string") {
    return { error: "Provider response missing 'price'", status: 503 };
  }
  const price = Number(priceStr);
  if (!Number.isFinite(price) || price < 0) {
    return { error: "Provider returned invalid price", status: 503 };
  }

  return { price, source: "twelvedata" };
}

async function fetchCoinGecko(
  ticker: string,
  currency: string,
): Promise<{ price: number; source: "coingecko" } | { error: string; status: number }> {
  const id = coinGeckoId(ticker);
  const vs = currency.trim().toLowerCase();
  const url =
    `https://api.coingecko.com/api/v3/simple/price?ids=${encodeURIComponent(id)}&vs_currencies=${encodeURIComponent(vs)}`;

  let resp: Response;
  try {
    resp = await fetch(url, { method: "GET" });
  } catch (e) {
    return { error: `Network error: ${(e as Error).message}`, status: 503 };
  }

  if (!resp.ok) {
    return { error: `Provider HTTP ${resp.status}`, status: 503 };
  }

  let body: Record<string, Record<string, number>>;
  try {
    body = await resp.json();
  } catch {
    return { error: "Provider returned non-JSON body", status: 503 };
  }

  const inner = body[id];
  if (!inner) {
    return {
      error: `Unknown CoinGecko id "${id}". Try entering the slug directly.`,
      status: 404,
    };
  }
  const raw = inner[vs];
  if (typeof raw !== "number" || !Number.isFinite(raw) || raw < 0) {
    return {
      error: `CoinGecko has no ${currency.toUpperCase()} quote for ${ticker.toUpperCase()}.`,
      status: 404,
    };
  }

  return { price: raw, source: "coingecko" };
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  let body: { ticker?: string; kind?: string; currency?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const ticker = (body.ticker ?? "").trim().toUpperCase();
  const kind = (body.kind ?? "").trim().toLowerCase();
  const currency = (body.currency ?? "").trim().toUpperCase();

  if (!ticker || !currency) {
    return json({ error: "ticker and currency are required" }, 400);
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Cache lookup — keyed (ticker, currency).
  const cached = await readCache(supabase, ticker, currency);
  if (cached) {
    return json({
      ticker,
      currency,
      last_price: cached.last_price,
      fetched_at: cached.fetched_at,
      source: cached.source,
      cached: true,
    });
  }

  // Provider routing.
  const result = kind === "crypto"
    ? await fetchCoinGecko(ticker, currency)
    : await fetchTwelveData(ticker, currency);

  if ("error" in result) {
    return json({ error: result.error }, result.status);
  }

  const fetchedAt = await writeCache(
    supabase,
    ticker,
    currency,
    result.price,
    result.source,
  );

  return json({
    ticker,
    currency,
    last_price: result.price,
    fetched_at: fetchedAt,
    source: result.source,
    cached: false,
  });
});
