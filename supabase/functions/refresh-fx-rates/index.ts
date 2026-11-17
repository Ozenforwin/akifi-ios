/**
 * refresh-fx-rates
 *
 * Hourly pg_cron job (migration 20261117130004) that refreshes
 * `public.fx_rates` from open.er-api.com `latest/USD` — the same free source
 * and USD pivot the iOS client uses for `CurrencyManager.rates`, so server
 * budget metrics and pushes convert currencies like the app does.
 *
 * Auth: cron only. The caller must present CRON_SECRET as `x-cron-secret`
 * (or `Authorization: Bearer`), compared in constant time. Deploy with
 * `--no-verify-jwt` and `[functions.refresh-fx-rates] verify_jwt = false`.
 *
 * Writes with the service role (fx_rates has no write policy for anyone
 * else). Bad upstream data never reaches the table: the whole payload is
 * refused when unusable, single codes are dropped when they look wrong
 * (see logic.ts).
 */
import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";
import { buildRows, isCronAuthorized } from "./logic.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const SOURCE_URL = "https://open.er-api.com/v6/latest/USD";

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !CRON_SECRET) {
    return json({ error: "Missing required environment variables" }, 500);
  }
  if (!(await isCronAuthorized(req, CRON_SECRET))) {
    return json({ error: "Unauthorized" }, 401);
  }

  let payload: unknown;
  try {
    const res = await fetch(SOURCE_URL, { signal: AbortSignal.timeout(15_000) });
    if (!res.ok) {
      console.error(`refresh-fx-rates: upstream HTTP ${res.status}`);
      return json({ error: "upstream_status", status: res.status }, 502);
    }
    payload = await res.json();
  } catch (err) {
    console.error("refresh-fx-rates: upstream unreachable:", err instanceof Error ? err.name : "error");
    return json({ error: "upstream_unreachable" }, 502);
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // bounded: one row per ISO currency code (~170 < max-rows 1000), not a
  // user-growing list.
  const { data: current, error: readError } = await supabase
    .from("fx_rates")
    .select("code,per_usd");
  if (readError) {
    console.error("refresh-fx-rates: read failed:", readError.code);
    return json({ error: "read_failed" }, 500);
  }
  const existing: Record<string, number> = {};
  for (const r of (current ?? []) as { code: string; per_usd: number | string }[]) {
    existing[r.code] = Number(r.per_usd);
  }

  let built;
  try {
    built = buildRows(payload, existing, new Date());
  } catch (err) {
    console.error("refresh-fx-rates: payload refused:", err instanceof Error ? err.message : "error");
    return json({ error: "bad_payload" }, 502);
  }

  const { error: writeError } = await supabase
    .from("fx_rates")
    .upsert(built.rows, { onConflict: "code" });
  if (writeError) {
    console.error("refresh-fx-rates: upsert failed:", writeError.code);
    return json({ error: "write_failed" }, 500);
  }

  if (built.skipped.length > 0) {
    console.warn("refresh-fx-rates: skipped", JSON.stringify(built.skipped));
  }
  return json({ ok: true, updated: built.rows.length, skipped: built.skipped });
});
