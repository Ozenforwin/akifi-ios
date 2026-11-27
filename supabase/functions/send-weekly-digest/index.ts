import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";
import { isCronAuthorized } from "../_shared/auth.ts";
import { fetchAll, fetchAllIn } from "../_shared/paging.ts";
import { getRubRates } from "../_shared/fx.ts";
import { lastFullDays, localDate, resolveTimeZones } from "../_shared/timezone.ts";
import {
  describeError,
  fcmConfigured,
  sendFcmPush,
  sendTelegramMessage,
  telegramConfigured,
} from "../_shared/notify.ts";
import { buildDigest, DIGEST_DAYS, type DigestTx, type CategoryRow, digestI18n, normalizeLang } from "./digest.ts";

// ---------------------------------------------------------------------------
// Weekly digest: the last 7 FULL days in each user's time zone (yesterday
// and the six days before it — never 8 partial days), every amount
// converted into the user's display currency (`profiles.default_currency`)
// before it is added up: $50 + 5 000 ₽ used to print as «5 050 ₽» (M4).
//
// Auth: cron-only, CRON_SECRET (`_shared/auth.ts`); verify_jwt = false.
// The old "any non-empty bearer" fallback let anyone with the public anon
// key re-send the digest to every user (bot-ban risk, S4). A digest is
// additionally deduplicated per user and week in notification_log.
// ---------------------------------------------------------------------------
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

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

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------
interface UserRow {
  id: string;
  telegram_chat_id: string | number | null;
  fcm_token: string | null;
  preferred_language: string | null;
  default_currency: string | null;
}

interface SettingsRow {
  user_id: string;
  digest_opt_in: boolean | null;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || (!telegramConfigured() && !fcmConfigured())) {
    return json({ error: "Missing required environment variables" }, 500);
  }

  if (!(await isCronAuthorized(req))) {
    return json({ error: "Unauthorized" }, 401);
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    // 1. Users with at least one delivery channel — every one of them,
    //    paged (ADR-003: PostgREST truncates at max-rows without an error).
    const users = await fetchAll<UserRow>("profiles.delivery", () =>
      supabase
        .from("profiles")
        .select("id,telegram_chat_id,fcm_token,preferred_language,default_currency", { count: "exact" })
        .or("telegram_chat_id.not.is.null,fcm_token.not.is.null"));
    if (users.length === 0) {
      return json({ ok: true, sent: 0, message: "No users with delivery channels" });
    }

    // 2. Explicit opt-in only. iOS shows the toggle OFF when there is no
    //    ai_user_settings row, so treating "no row" as opted in would send
    //    a digest to people who see it switched off (26 of 29 users had no
    //    row when the schedule was first added, 2026-11-27).
    const settingsRows = await fetchAllIn<SettingsRow>(
      "ai_user_settings",
      users.map((u) => u.id),
      (ids) => supabase.from("ai_user_settings").select("user_id,digest_opt_in", { count: "exact" }).in("user_id", ids),
      { pk: "user_id" },
    );
    const settingsMap = new Map(settingsRows.map((row) => [row.user_id, row]));
    const eligibleUsers = users.filter((u) => settingsMap.get(u.id)?.digest_opt_in === true);
    if (eligibleUsers.length === 0) {
      return json({ ok: true, sent: 0, message: "Nobody opted in" });
    }

    // 3. Each user's own 7-day window in their own time zone.
    const now = new Date();
    const zones = await resolveTimeZones(supabase, eligibleUsers.map((u) => u.id));
    const windows = new Map<string, { start: string; endExclusive: string }>();
    for (const u of eligibleUsers) {
      windows.set(u.id, lastFullDays(localDate(now, zones.get(u.id) ?? "UTC"), DIGEST_DAYS));
    }
    const allWindows = [...windows.values()];
    const minStart = allWindows.reduce((m, w) => (w.start < m ? w.start : m), allWindows[0].start);
    const maxEnd = allWindows.reduce((m, w) => (w.endExclusive > m ? w.endExclusive : m), allWindows[0].endExclusive);

    // 4. Transactions of the union window, paged; trimmed per user below.
    //    `date` is local wall-clock time, so the date prefix is the user's day.
    const transactions = await fetchAllIn<DigestTx>(
      "transactions.digest",
      eligibleUsers.map((u) => u.id),
      (ids) =>
        supabase
          .from("transactions")
          .select("id,user_id,type,amount,amount_native,category_id,date,account:accounts!transactions_account_id_fkey(currency)", { count: "exact" })
          .in("user_id", ids)
          .gte("date", minStart)
          .lt("date", maxEnd)
          .is("transfer_group_id", null),
    );

    const txByUser = new Map<string, DigestTx[]>();
    for (const tx of transactions) {
      const w = windows.get(tx.user_id);
      const day = String(tx.date).slice(0, 10);
      if (!w || day < w.start || day >= w.endExclusive) continue;
      const arr = txByUser.get(tx.user_id) ?? [];
      arr.push(tx);
      txByUser.set(tx.user_id, arr);
    }

    // 5. Only the categories the digests mention (the full table is
    //    shared by every user and well past max-rows).
    const categoryIds = [...new Set(transactions.map((tx) => tx.category_id).filter((id): id is string => !!id))];
    const categories = await fetchAllIn<CategoryRow>(
      "categories.digest",
      categoryIds,
      (ids) => supabase.from("categories").select("id,name,icon", { count: "exact" }).in("id", ids),
    );
    const categoryMap = new Map(categories.map((c) => [c.id, c]));

    const { rates } = await getRubRates();

    // 6. Send digests
    let sent = 0;
    let errors = 0;
    let duplicates = 0;

    for (const user of eligibleUsers) {
      const userTx = txByUser.get(user.id) ?? [];
      const userLang = normalizeLang(user.preferred_language);
      const digest = buildDigest(userTx, categoryMap, userLang, user.default_currency ?? "RUB", rates);
      if (!digest) continue;

      // One digest per user per week, whoever calls the function.
      const week = windows.get(user.id)!.start;
      const { data: logged, error: logError } = await supabase
        .from("notification_log")
        .insert({
          user_id: user.id,
          notification_type: "weekly_digest",
          notification_key: `weekly_digest:${week}`,
          payload: { period_start: week },
        })
        .select("id")
        .maybeSingle();
      if (logError || !logged) {
        duplicates++;
        continue;
      }

      let delivered = false;

      if (user.telegram_chat_id && telegramConfigured()) {
        try {
          await sendTelegramMessage(user.telegram_chat_id, digest, { html: true });
          delivered = true;
        } catch (err) {
          console.error(`Telegram digest failed for ${user.id}:`, describeError(err));
        }
      }

      if (user.fcm_token && fcmConfigured()) {
        const plainText = digest.replace(/<[^>]+>/g, "")
          .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
        if (await sendFcmPush(user.fcm_token, digestI18n.pushTitle[userLang], plainText.substring(0, 200), { type: "weekly_digest", tab: "home" })) {
          delivered = true;
        }
      }

      await supabase
        .from("notification_log")
        .update(delivered ? { delivered: true } : { delivery_error: "All delivery channels failed" })
        .eq("id", logged.id);

      if (delivered) {
        sent++;
      } else {
        errors++;
      }
    }

    return json({ ok: true, sent, errors, duplicates, eligible: eligibleUsers.length });
  } catch (err) {
    console.error("Weekly digest failed:", describeError(err));
    return json({ error: "weekly_digest_failed" }, 500);
  }
}

Deno.serve(handler);
