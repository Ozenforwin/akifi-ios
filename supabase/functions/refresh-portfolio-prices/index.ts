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

/// Wall-clock budget per run, well under the platform limit (150 s).
const RUN_BUDGET_MS = 100_000;
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

  // N9: the per-ticker throttle (7.5 s on Twelve Data) used to walk every
  // ticker in id order, so with ~20 tickers the platform killed the run and
  // the same tail never refreshed. Stalest first, and stop before the wall
  // clock runs out; the next run continues where this one stopped.
  const cachedAt = new Map<string, number>();
  try {
    const cacheRows = await fetchAll<{ ticker: string; currency: string; kind: string; fetched_at: string }>(
      "price_cache",
      // (currency, kind, ticker) is the primary key: a unique total order.
      () => supabase.from("price_cache").select("ticker,currency,kind,fetched_at", { count: "exact" })
        .order("currency").order("kind"),
      { pk: "ticker" },
    );
    for (const c of cacheRows) cachedAt.set(`${c.ticker}|${c.currency}|${c.kind}`, Date.parse(c.fetched_at) || 0);
  } catch (err) {
    console.error("[refresh-prices] cache read failed:", (err as Error).message);
  }
  tuples.sort((a, b) =>
    (cachedAt.get(`${a.ticker}|${a.currency}|${a.kind}`) ?? 0) - (cachedAt.get(`${b.ticker}|${b.currency}|${b.kind}`) ?? 0)
  );
  const deadline = Date.now() + RUN_BUDGET_MS;

  const outcomes: Outcome[] = [];
  for (const t of tuples) {
    if (Date.now() > deadline) {
      outcomes.push({ ticker: t.ticker, currency: t.currency, status: "skip", reason: "next_run" });
      continue;
    }
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
        kind: t.kind,
        last_price: result.price,
        fetched_at: new Date().toISOString(),
        source: result.source,
      }, { onConflict: "ticker,currency,kind" });
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
