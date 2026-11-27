import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";
import { MAX_UPSTREAM_PER_USER_PER_DAY, parseRequest, rateFromUpstream } from "./logic.ts";

// Historical exchange rate for one (from, to, date) — used by the iOS
// currency-reconciliation screen.
//
// Review 2026-11-27, S4: the paid APILayer key used to ship inside every IPA
// (Info.plist), so anyone could burn the quota. It now lives only in the
// EXCHANGE_RATE_API_KEY function secret and is sent as a header, never in
// the URL. Answers are cached forever in public.fx_rates_historical
// (historical quotes don't change); only cache misses reach APILayer, and
// each user may cause at most MAX_UPSTREAM_PER_USER_PER_DAY of those per 24 h.
//
// POST {from, to, date: "YYYY-MM-DD"} with the user's session
// → 200 {rate} (units of `to` per 1 `from`) | 400 | 401 | 429 | 502.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const EXCHANGE_RATE_API_KEY = Deno.env.get("EXCHANGE_RATE_API_KEY") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) return json({ error: "misconfigured" }, 500);

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // A real session, not just any JWT (the anon key is a JWT too).
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!bearer) return json({ error: "unauthorized" }, 401);
  const { data: auth, error: authError } = await admin.auth.getUser(bearer);
  if (authError || !auth?.user?.id) return json({ error: "unauthorized" }, 401);
  const userId = auth.user.id;

  const parsed = parseRequest(await req.json().catch(() => null), new Date().toISOString().slice(0, 10));
  if (typeof parsed === "string") return json({ error: parsed }, 400);
  const { from, to, date } = parsed;
  if (from === to) return json({ rate: 1 });

  const cached = await admin
    .from("fx_rates_historical")
    .select("rate")
    .eq("rate_date", date).eq("base", from).eq("quote", to)
    .maybeSingle();
  if (cached.data?.rate != null) return json({ rate: Number(cached.data.rate) });

  if (!EXCHANGE_RATE_API_KEY) return json({ error: "unavailable" }, 502);

  const since = new Date(Date.now() - 86_400_000).toISOString();
  const { count } = await admin
    .from("fx_rates_historical")
    .select("rate_date", { count: "exact", head: true })
    .eq("fetched_by", userId)
    .gte("fetched_at", since);
  if ((count ?? 0) >= MAX_UPSTREAM_PER_USER_PER_DAY) return json({ error: "rate_limited" }, 429);

  let rate: number | null = null;
  try {
    const res = await fetch(
      `https://api.apilayer.com/exchangerates_data/${date}?base=${from}&symbols=${to}`,
      { headers: { apikey: EXCHANGE_RATE_API_KEY }, signal: AbortSignal.timeout(10_000) },
    );
    if (res.ok) rate = rateFromUpstream(await res.json(), to);
    else console.error("fx-historical: upstream status", res.status);
  } catch (err) {
    console.error("fx-historical: upstream failed:", err instanceof Error ? err.name : "unknown");
  }
  if (rate == null) return json({ error: "unavailable" }, 502);

  const { error: upsertError } = await admin.from("fx_rates_historical").upsert({
    rate_date: date, base: from, quote: to, rate, fetched_by: userId, fetched_at: new Date().toISOString(),
  }, { onConflict: "rate_date,base,quote", ignoreDuplicates: true });
  if (upsertError) console.error("fx-historical: cache write failed:", upsertError.code ?? "unknown");

  return json({ rate });
});
