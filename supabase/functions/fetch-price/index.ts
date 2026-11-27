/**
 * fetch-price
 *
 * Returns the latest market price for a ticker IN THE ASSET'S CURRENCY,
 * used by the iOS Portfolio surface. Reads `price_cache` first (30-min
 * TTL, keyed by (ticker, currency)); on a miss it asks CoinGecko
 * (kind = 'crypto') or Twelve Data (everything else) through
 * `_shared/prices.ts`, which converts the listing-currency quote with live
 * FX — or refuses (422/503) when it cannot. A USD quote is never cached
 * under a RUB key again (S8: AAPL in a rouble asset used to cost ~230 ₽).
 *
 * Auth: the gateway verifies the JWT (verify_jwt default = true); on top
 * of that only a signed-in user may trigger an upstream call, so the
 * public anon key cannot drain the Twelve Data quota.
 *
 * Errors: `{ error: <stable code> }` — never upstream text or URLs.
 *
 * Body:     { ticker: string, kind: string, currency: string }
 * Response: { ticker, currency, last_price, fetched_at, source, cached }
 */
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";
import { fetchPriceInCurrency, MANUAL_ONLY_KINDS, type PriceSource } from "../_shared/prices.ts";
import { describeError } from "../_shared/notify.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const CACHE_TTL_SECONDS = 30 * 60;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// deno-lint-ignore no-explicit-any
type Client = any;

type CachedPrice = { last_price: number; fetched_at: string; source: PriceSource | "manual" };

async function readCache(supabase: Client, ticker: string, currency: string, kind: string): Promise<CachedPrice | null> {
  // bounded-fetch: primary-key lookup (ticker, currency, kind).
  const { data, error } = await supabase
    .from("price_cache")
    .select("last_price, fetched_at, source")
    .eq("ticker", ticker)
    .eq("currency", currency)
    .eq("kind", kind)
    .maybeSingle();
  if (error || !data) return null;
  const age = (Date.now() - new Date(String(data.fetched_at)).getTime()) / 1000;
  if (!Number.isFinite(age) || age > CACHE_TTL_SECONDS) return null;
  return { last_price: Number(data.last_price), fetched_at: String(data.fetched_at), source: data.source };
}

async function writeCache(
  supabase: Client,
  ticker: string,
  currency: string,
  kind: string,
  price: number,
  source: PriceSource,
): Promise<string> {
  const fetchedAt = new Date().toISOString();
  const { error } = await supabase.from("price_cache").upsert({
    ticker,
    currency,
    kind,
    last_price: price,
    fetched_at: fetchedAt,
    source,
  }, { onConflict: "ticker,currency,kind" });
  if (error) console.warn(`[fetch-price] cache write failed for ${ticker}/${currency}: ${error.code ?? "error"}`);
  return fetchedAt;
}

async function isSignedInUser(req: Request): Promise<boolean> {
  const authHeader = req.headers.get("authorization") ?? "";
  if (!/^bearer\s+\S+/i.test(authHeader) || !SUPABASE_ANON_KEY) return false;
  try {
    const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
      global: { headers: { Authorization: authHeader } },
    });
    const { data, error } = await client.auth.getUser();
    return !error && !!data.user?.id;
  } catch (err) {
    console.warn("[fetch-price] auth check failed:", describeError(err));
    return false;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) return json({ error: "server_misconfigured" }, 500);

  if (!(await isSignedInUser(req))) return json({ error: "unauthorized" }, 401);

  let body: { ticker?: string; kind?: string; currency?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const ticker = (body.ticker ?? "").trim().toUpperCase();
  const kind = (body.kind ?? "").trim().toLowerCase();
  const currency = (body.currency ?? "").trim().toUpperCase();
  if (!ticker || !/^[A-Z]{3}$/.test(currency) || ticker.length > 40) {
    return json({ error: "ticker_and_currency_required" }, 400);
  }
  if (MANUAL_ONLY_KINDS.has(kind)) return json({ error: "manual_only_kind" }, 422);

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const cached = await readCache(supabase, ticker, currency, kind);
  if (cached) {
    return json({ ticker, currency, ...cached, cached: true });
  }

  const result = await fetchPriceInCurrency(ticker, kind, currency);
  if (!result.ok) return json({ error: result.code }, result.status);

  const fetchedAt = await writeCache(supabase, ticker, currency, kind, result.price, result.source);
  return json({
    ticker,
    currency,
    last_price: result.price,
    fetched_at: fetchedAt,
    source: result.source,
    cached: false,
  });
});
