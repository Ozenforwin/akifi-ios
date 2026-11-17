/**
 * refresh-portfolio-prices
 *
 * Daily cron-driven prefetcher: walks every distinct (ticker, currency,
 * kind) tuple across all users' `investment_holdings` (currency = the
 * parent asset's) and refreshes its `price_cache` row, so the project
 * spends ~1 Twelve Data request per ticker per day instead of one per
 * user tap (free tier: 800/day; CoinGecko public: ~30/min).
 *
 * Prices are written IN THE ASSET'S CURRENCY via `_shared/prices.ts`
 * (same code path as fetch-price): the listing-currency quote is
 * converted with live FX, or the tuple is reported as an error and the
 * cache left untouched (S8).
 *
 * Auth: cron-only — CRON_SECRET in `x-cron-secret` or as the bearer
 * (`_shared/auth.ts`, constant-time). Deployed with verify_jwt = false
 * (supabase/config.toml): the cron does not send a JWT, so with gateway
 * verification on every run would be rejected before reaching this code.
 *
 * Schedule: migration 20260911120000_refresh_prices_cron_vault.sql.
 */
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";
import { isCronAuthorized } from "../_shared/auth.ts";
import { fetchAll } from "../_shared/paging.ts";
import { fetchPriceInCurrency, MANUAL_ONLY_KINDS } from "../_shared/prices.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function sleep(ms: number) {
  await new Promise((r) => setTimeout(r, ms));
}

type Holding = { ticker: string; kind: string; currency: string };
type Outcome = { ticker: string; currency: string; status: "ok" | "skip" | "err"; reason?: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!(await isCronAuthorized(req))) return json({ error: "unauthorized" }, 401);

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  type Row = { id: string; ticker: string; kind: string; asset: { currency?: string } | null };
  let rows: Row[];
  try {
    rows = await fetchAll<Row>("investment_holdings", () =>
      supabase.from("investment_holdings").select("id, ticker, kind, asset:asset_id(currency)", { count: "exact" }));
  } catch (err) {
    console.error("[refresh-prices] holdings read failed:", (err as Error).message);
    return json({ error: "holdings_read_failed" }, 500);
  }

  const seen = new Set<string>();
  const tuples: Holding[] = [];
  for (const row of rows) {
    const ticker = (row.ticker ?? "").trim().toUpperCase();
    const kind = (row.kind ?? "").trim().toLowerCase();
    const currency = (row.asset?.currency ?? "").trim().toUpperCase();
    if (!ticker || !currency) continue;
    const k = `${ticker}|${currency}|${kind}`;
    if (seen.has(k)) continue;
    seen.add(k);
    tuples.push({ ticker, kind, currency });
  }

  const outcomes: Outcome[] = [];
  for (const t of tuples) {
    if (MANUAL_ONLY_KINDS.has(t.kind)) {
      outcomes.push({ ticker: t.ticker, currency: t.currency, status: "skip", reason: "manual_only_kind" });
      continue;
    }
    const result = await fetchPriceInCurrency(t.ticker, t.kind, t.currency);
    if (!result.ok) {
      outcomes.push({ ticker: t.ticker, currency: t.currency, status: "err", reason: result.code });
    } else {
      const { error } = await supabase.from("price_cache").upsert({
        ticker: t.ticker,
        currency: t.currency,
        last_price: result.price,
        fetched_at: new Date().toISOString(),
        source: result.source,
      }, { onConflict: "ticker,currency" });
      outcomes.push(error
        ? { ticker: t.ticker, currency: t.currency, status: "err", reason: "cache_write_failed" }
        : { ticker: t.ticker, currency: t.currency, status: "ok" });
    }
    // Throttle: Twelve Data's free tier allows 8 requests/minute, CoinGecko's
    // public API ~30. A 429 is reported as provider_unavailable and simply
    // leaves that cache row for the next run / an on-demand fetch.
    await sleep(t.kind === "crypto" ? 2_000 : 7_500);
  }

  return json({
    refreshed: outcomes.filter((o) => o.status === "ok").length,
    skipped: outcomes.filter((o) => o.status === "skip").length,
    errors: outcomes.filter((o) => o.status === "err").length,
    outcomes,
  });
});
