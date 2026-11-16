import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";
import { formatMoney, toDateOnly } from "../_shared/utils.ts";
import { addDaysTo, daysBetween, planCatchUp } from "../_shared/schedule.ts";
import { convertCurrency } from "../_shared/currency.ts";
import { getRubRates } from "../_shared/fx.ts";
import { isCronAuthorized } from "../_shared/auth.ts";
import { fetchAll } from "../_shared/paging.ts";
import {
  describeError,
  fcmConfigured,
  sendFcmPush,
  sendTelegramMessage,
  telegramConfigured,
} from "../_shared/notify.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// How far back a missed charge is still recovered (see planCatchUp).
const CATCH_UP_DAYS = 45;
// Two reminders whose payment dates are this close belong to the same
// billing cycle (reminder_days edited mid-cycle, or a drifted date snapped
// back to its anchor) — the second one is not sent.
const SAME_CYCLE_DAYS = 3;

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

// deno-lint-ignore no-explicit-any
type Client = any;

interface SubscriptionRow {
  id: string;
  user_id: string;
  service_name: string;
  amount: number | string;
  currency: string | null;
  billing_period: string;
  start_date: string | null;
  next_payment_date: string;
  reminder_days: number | null;
  account_id: string | null;
  is_active: boolean;
}

interface Charge {
  amount: number;
  currency: string;
  foreignAmount: number;
  foreignCurrency: string;
}

type WritableAccount = { id: string; currency: string } | null;

function normalizeReminderDays(value: unknown): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return 1;
  const integer = Math.trunc(parsed);
  if (integer < 0) return 0;
  if (integer > 30) return 30;
  return integer;
}

function pluralDays(value: number): string {
  const mod10 = value % 10;
  const mod100 = value % 100;
  if (mod10 === 1 && mod100 !== 11) return "день";
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return "дня";
  return "дней";
}

function reminderText(subscription: SubscriptionRow, reminderDays: number): string {
  const amount = formatMoney(Number(subscription.amount), subscription.currency ?? "RUB");
  if (reminderDays <= 0) {
    return `🔔 Напоминание: Сегодня спишут ${amount} за подписку ${subscription.service_name}. Проверьте баланс!`;
  }
  return `🔔 Напоминание: Через ${reminderDays} ${pluralDays(reminderDays)} спишут ${amount} за подписку ${subscription.service_name}. Проверьте баланс!`;
}

async function resolveTelegramChatId(supabase: Client, userId: string, cache: Map<string, string | null>) {
  const cached = cache.get(userId);
  if (cached !== undefined) return cached;
  const { data: profileData } = await supabase.from("profiles").select("telegram_chat_id,telegram_user_id").eq("id", userId).maybeSingle();
  const profileChatId = profileData?.telegram_chat_id ? String(profileData.telegram_chat_id) : null;
  if (profileChatId) {
    cache.set(userId, profileChatId);
    return profileChatId;
  }
  const fallbackUserId = profileData?.telegram_user_id ? String(profileData.telegram_user_id) : null;
  if (fallbackUserId) {
    cache.set(userId, fallbackUserId);
    return fallbackUserId;
  }
  const { data: authData, error: authError } = await supabase.auth.admin.getUserById(userId);
  if (authError || !authData?.user) {
    cache.set(userId, null);
    return null;
  }
  const metadata = authData.user.user_metadata ?? {};
  const candidate = metadata.telegram_id ?? metadata.telegramId ?? null;
  const resolved = candidate ? String(candidate) : null;
  cache.set(userId, resolved);
  return resolved;
}

async function resolveFCMToken(supabase: Client, userId: string, cache: Map<string, string | null>) {
  const cacheKey = `fcm:${userId}`;
  const cached = cache.get(cacheKey);
  if (cached !== undefined) return cached;
  const { data: profileData } = await supabase.from("profiles").select("fcm_token").eq("id", userId).maybeSingle();
  const token: string | null = profileData?.fcm_token ?? null;
  cache.set(cacheKey, token);
  return token;
}

/**
 * True when a reminder for this billing cycle was already delivered — any
 * sent event whose payment date is within SAME_CYCLE_DAYS of `paymentDate`,
 * whatever its reminder_days. The unique key (subscription, payment_date,
 * reminder_days) alone let a reminder_days edit re-send for the same charge.
 */
async function reminderAlreadySent(supabase: Client, subscriptionId: string, paymentDate: string): Promise<boolean> {
  // bounded-fetch: existence check (limit 1).
  const { data, error } = await supabase.from("subscription_reminder_events")
    .select("id")
    .eq("subscription_id", subscriptionId)
    .not("sent_at", "is", null)
    .gte("payment_date", addDaysTo(paymentDate, -SAME_CYCLE_DAYS))
    .lte("payment_date", addDaysTo(paymentDate, SAME_CYCLE_DAYS))
    .limit(1);
  if (error) throw new Error(error.message);
  return (data ?? []).length > 0;
}

async function ensureReminderEvent(supabase: Client, subscription: SubscriptionRow, paymentDate: string, reminderDays: number) {
  const inserted = await supabase.from("subscription_reminder_events").insert({
    subscription_id: subscription.id,
    user_id: subscription.user_id,
    payment_date: paymentDate,
    reminder_days: reminderDays,
  }).select("id,sent_at").single();
  if (!inserted.error && inserted.data) return inserted.data as { id: string; sent_at: string | null };
  if (inserted.error?.code !== "23505") {
    throw new Error(inserted.error?.message ?? "Failed to create reminder event");
  }
  const existing = await supabase.from("subscription_reminder_events").select("id,sent_at")
    .eq("subscription_id", subscription.id).eq("payment_date", paymentDate).eq("reminder_days", reminderDays).maybeSingle();
  if (existing.error) throw new Error(existing.error.message);
  return (existing.data ?? null) as { id: string; sent_at: string | null } | null;
}

async function ensureChargeEvent(supabase: Client, subscription: SubscriptionRow, chargeDate: string) {
  const inserted = await supabase.from("subscription_charge_events").insert({
    subscription_id: subscription.id,
    user_id: subscription.user_id,
    charge_date: chargeDate,
  }).select("id,transaction_id").single();
  if (!inserted.error && inserted.data) return inserted.data as { id: string; transaction_id: string | null };
  if (inserted.error?.code !== "23505") {
    throw new Error(inserted.error?.message ?? "Failed to create charge event");
  }
  const existing = await supabase.from("subscription_charge_events").select("id,transaction_id")
    .eq("subscription_id", subscription.id).eq("charge_date", chargeDate).maybeSingle();
  if (existing.error) throw new Error(existing.error.message);
  return (existing.data ?? null) as { id: string; transaction_id: string | null } | null;
}

async function resolveExpenseCategoryId(supabase: Client, userId: string, cache: Map<string, string>): Promise<string> {
  const cached = cache.get(userId);
  if (cached) return cached;
  const subscriptionsCategory = await supabase.from("categories").select("id").eq("user_id", userId).eq("type", "expense").ilike("name", "Подписки").eq("is_active", true).limit(1).maybeSingle();
  if (!subscriptionsCategory.error && subscriptionsCategory.data?.id) {
    cache.set(userId, subscriptionsCategory.data.id);
    return subscriptionsCategory.data.id;
  }
  const fallbackCategory = await supabase.from("categories").select("id").eq("user_id", userId).eq("type", "expense").ilike("name", "Другое").eq("is_active", true).limit(1).maybeSingle();
  if (!fallbackCategory.error && fallbackCategory.data?.id) {
    cache.set(userId, fallbackCategory.data.id);
    return fallbackCategory.data.id;
  }
  const created = await supabase.from("categories").insert({
    user_id: userId,
    name: "Подписки",
    type: "expense",
    color: "#F59E0B",
    icon: "🔁",
    is_active: true,
  }).select("id").single();
  if (created.error || !created.data?.id) {
    throw new Error(created.error?.message ?? "Failed to ensure subscription category");
  }
  cache.set(userId, created.data.id);
  return created.data.id;
}

// Returns `{ id, currency }` — the currency is required, not decorative:
// a charge row written in the wrong currency reads back inflated by the
// FX rate (a $10 subscription showed up as 22 475 255 ₫).
async function resolveWritableAccount(
  supabase: Client,
  userId: string,
  accountId: string | null,
  cache: Map<string, WritableAccount>,
): Promise<WritableAccount> {
  if (!accountId) return null;
  const cacheKey = `${userId}:${accountId}`;
  if (cache.has(cacheKey)) return cache.get(cacheKey) ?? null;
  const membership = await supabase.from("account_members").select("account_id").eq("user_id", userId).eq("account_id", accountId).in("role", ["owner", "editor"]).limit(1).maybeSingle();
  if (membership.error || !membership.data?.account_id) {
    cache.set(cacheKey, null);
    return null;
  }
  const account = await supabase.from("accounts").select("id,currency").eq("id", membership.data.account_id).limit(1).maybeSingle();
  if (account.error || !account.data?.id) {
    cache.set(cacheKey, null);
    return null;
  }
  const resolved = { id: account.data.id as string, currency: String(account.data.currency ?? "RUB").toUpperCase() };
  cache.set(cacheKey, resolved);
  return resolved;
}

/**
 * Posts one charge for `chargeDate`. Idempotent: the charge event is
 * unique per (subscription, date) and the transaction lookup dedupes on
 * (user, date, description, amount).
 *
 * Returns "posted" (new transaction), "skipped" (already charged) or
 * "failed" (recorded on the charge event).
 */
async function chargeSubscription(
  supabase: Client,
  subscription: SubscriptionRow,
  chargeDate: string,
  rates: Record<string, number>,
  categoryCache: Map<string, string>,
  writableAccountCache: Map<string, WritableAccount>,
): Promise<"posted" | "skipped" | "failed"> {
  const chargeEvent = await ensureChargeEvent(supabase, subscription, chargeDate);
  if (!chargeEvent) return "skipped";
  if (chargeEvent.transaction_id) return "skipped";

  const categoryId = await resolveExpenseCategoryId(supabase, subscription.user_id, categoryCache);
  const writableAccount = await resolveWritableAccount(supabase, subscription.user_id, subscription.account_id, writableAccountCache);
  const amountRaw = Number(subscription.amount);
  const subCurrency = (subscription.currency ?? "RUB").toUpperCase();
  const sourceAmount = Number.isFinite(amountRaw) && amountRaw > 0 ? amountRaw : 0;
  // Charge in the ACCOUNT's currency. Falls back to RUB only when the
  // subscription has no writable account to charge against.
  const targetCurrency = writableAccount?.currency ?? "RUB";
  const chargeAmount = convertCurrency(sourceAmount, subCurrency, targetCurrency, rates);
  const charge: Charge = {
    amount: chargeAmount,
    currency: targetCurrency,
    foreignAmount: sourceAmount,
    foreignCurrency: subCurrency,
  };
  if (!Number.isFinite(chargeAmount) || chargeAmount <= 0) {
    await supabase.from("subscription_charge_events").update({ error_message: "Invalid amount for auto charge" }).eq("id", chargeEvent.id);
    return "failed";
  }
  const transactionId = await ensureTransactionForCharge(supabase, subscription, chargeDate, categoryId, writableAccount?.id ?? null, charge);
  await supabase.from("subscription_charge_events").update({ transaction_id: transactionId, error_message: null }).eq("id", chargeEvent.id);
  await recordPayment(supabase, subscription, chargeDate, charge);
  return "posted";
}

/**
 * What the iOS app shows as "last charge" and "payment history" —
 * `subscriptions.last_payment_date` and a `subscription_payments` row.
 * Best-effort: a failure here must not undo the charge.
 */
async function recordPayment(supabase: Client, subscription: SubscriptionRow, chargeDate: string, charge: Charge) {
  const paymentAt = `${chargeDate}T00:00:00+00:00`;
  try {
    const { data: existing } = await supabase.from("subscription_payments").select("id").eq("subscription_id", subscription.id).gte("payment_date", paymentAt).lt("payment_date", `${chargeDate}T23:59:59.999+00:00`).limit(1).maybeSingle();
    if (!existing) {
      const { error: insertError } = await supabase.from("subscription_payments").insert({
        subscription_id: subscription.id,
        amount: charge.amount,
        currency: charge.currency,
        payment_date: paymentAt,
      });
      if (insertError) console.error("Failed to record subscription payment:", insertError.message);
    }
  } catch (paymentError) {
    console.error("Failed to record subscription payment:", describeError(paymentError));
  }
  try {
    // Only move forward — a catch-up run posts dates in ascending order,
    // but a manual "record payment" in the app may already be newer.
    const { error: lastError } = await supabase.from("subscriptions").update({ last_payment_date: paymentAt })
      .eq("id", subscription.id).or(`last_payment_date.is.null,last_payment_date.lt.${paymentAt}`);
    if (lastError) console.error("Failed to update last_payment_date:", lastError.message);
  } catch (lastError) {
    console.error("Failed to update last_payment_date:", describeError(lastError));
  }
}

async function ensureTransactionForCharge(
  supabase: Client,
  subscription: SubscriptionRow,
  chargeDate: string,
  categoryId: string,
  accountId: string | null,
  charge: Charge,
): Promise<string> {
  const description = `Подписка: ${subscription.service_name}`;
  const existing = await supabase.from("transactions").select("id").eq("user_id", subscription.user_id).eq("date", chargeDate).eq("type", "expense").eq("description", description).eq("amount", charge.amount).limit(1).maybeSingle();
  if (!existing.error && existing.data?.id) return existing.data.id;
  // `currency` and `amount_native` are NOT optional (ADR-001): the read
  // path interprets the amount as being in the account's currency.
  const row: Record<string, unknown> = {
    user_id: subscription.user_id,
    category_id: categoryId,
    account_id: accountId,
    type: "expense",
    amount: charge.amount,
    amount_native: charge.amount,
    currency: charge.currency,
    description,
    date: chargeDate,
  };
  if (charge.foreignCurrency && charge.foreignCurrency !== charge.currency) {
    row.foreign_amount = charge.foreignAmount;
    row.foreign_currency = charge.foreignCurrency;
    row.fx_rate = charge.foreignAmount > 0 ? charge.amount / charge.foreignAmount : null;
  }
  const inserted = await supabase.from("transactions").insert(row).select("id").single();
  if (inserted.error || !inserted.data?.id) {
    throw new Error(inserted.error?.message ?? "Failed to insert subscription charge transaction");
  }
  return inserted.data.id;
}

type ReminderOutcome = "sent" | "skipped" | "failed";

async function sendReminder(
  supabase: Client,
  subscription: SubscriptionRow,
  paymentDate: string,
  reminderDays: number,
  cache: Map<string, string | null>,
): Promise<ReminderOutcome> {
  if (await reminderAlreadySent(supabase, subscription.id, paymentDate)) return "skipped";
  const event = await ensureReminderEvent(supabase, subscription, paymentDate, reminderDays);
  if (!event || event.sent_at) return "skipped";
  const chatId = telegramConfigured() ? await resolveTelegramChatId(supabase, subscription.user_id, cache) : null;
  const fcmToken = fcmConfigured() ? await resolveFCMToken(supabase, subscription.user_id, cache) : null;
  if (!chatId && !fcmToken) {
    await supabase.from("subscription_reminder_events").update({ error_message: "No delivery channel (no Telegram chat or FCM token)" }).eq("id", event.id);
    return "skipped";
  }
  const text = reminderText(subscription, reminderDays);
  let delivered = false;
  if (chatId) {
    try {
      await sendTelegramMessage(chatId, text);
      delivered = true;
    } catch (err) {
      console.error(`Telegram subscription reminder failed for ${subscription.user_id}:`, describeError(err));
    }
  }
  if (fcmToken) {
    if (await sendFcmPush(fcmToken, "Напоминание о подписке", text, { type: "subscription_reminder", tab: "budget" })) {
      delivered = true;
    }
  }
  await supabase.from("subscription_reminder_events").update(delivered
    ? { sent_at: new Date().toISOString(), error_message: null }
    : { error_message: "All delivery channels failed" }).eq("id", event.id);
  return delivered ? "sent" : "failed";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || (!telegramConfigured() && !fcmConfigured())) {
    return json({ error: "Missing required environment variables" }, 500);
  }
  // Cron-only. Deployed with verify_jwt = false (config.toml) — the
  // 2026-09-01 redeploy forgot that and the gateway rejected every run for
  // two weeks — so this constant-time CRON_SECRET check is the only gate.
  if (!(await isCronAuthorized(req))) return json({ error: "Unauthorized" }, 401);

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const todayStr = toDateOnly(new Date());
  const { rates } = await getRubRates();
  const chatIdCache = new Map<string, string | null>();
  const categoryCache = new Map<string, string>();
  const writableAccountCache = new Map<string, WritableAccount>();
  try {
    const subscriptions = await fetchAll<SubscriptionRow>("subscriptions", () =>
      supabase.from("subscriptions")
        .select("id,user_id,service_name,amount,currency,billing_period,start_date,next_payment_date,reminder_days,account_id,is_active", { count: "exact" })
        .eq("is_active", true)
        .not("next_payment_date", "is", null)
        .order("next_payment_date", { ascending: true }));
    const stats = {
      rolledOver: 0, rescheduled: 0,
      reminders: { planned: 0, sent: 0, skipped: 0, failed: 0 },
      charges: { planned: 0, posted: 0, skipped: 0, failed: 0 },
    };
    for (const subscription of subscriptions) {
      const stored = String(subscription.next_payment_date).slice(0, 10);
      const plan = planCatchUp({
        startDate: subscription.start_date,
        nextPaymentDate: stored,
        period: subscription.billing_period,
        today: todayStr,
        catchUpDays: CATCH_UP_DAYS,
      });

      // D9: decide the reminder BEFORE charging. Charging advances the
      // date, so "remind on the day" (reminder_days = 0) used to compare
      // against next month's date and never fire.
      const reminderDays = normalizeReminderDays(subscription.reminder_days);
      if (daysBetween(todayStr, plan.upcoming) === reminderDays) {
        stats.reminders.planned += 1;
        try {
          const outcome = await sendReminder(supabase, subscription, plan.upcoming, reminderDays, chatIdCache);
          stats.reminders[outcome] += 1;
        } catch (err) {
          stats.reminders.failed += 1;
          console.error("Failed to process reminder event:", describeError(err));
        }
      }

      if (plan.skipped.length > 0) stats.rolledOver += 1;
      let effectiveDate = stored;
      if (plan.due.length === 0) {
        // Nothing to charge, but the stored date may be stale (rolled past
        // the catch-up window) or drifted off the anchor (31 Jan → 3 Mar).
        if (plan.next !== stored) {
          const { error: updateError } = await supabase.from("subscriptions").update({ next_payment_date: plan.next })
            .eq("id", subscription.id).eq("next_payment_date", stored);
          if (updateError) console.error("Failed to reschedule subscription:", updateError.message);
          else stats.rescheduled += 1;
        }
        continue;
      }
      for (let i = 0; i < plan.due.length; i += 1) {
        const chargeDate = plan.due[i];
        const nextDate = plan.due[i + 1] ?? plan.next;
        stats.charges.planned += 1;
        try {
          const outcome = await chargeSubscription(supabase, subscription, chargeDate, rates, categoryCache, writableAccountCache);
          stats.charges[outcome] += 1;
          // Advance past this date even when the charge itself failed: the
          // charge event keeps the error, and leaving next_payment_date in
          // the past would re-plan the same failing date every day while
          // blocking the dates after it.
          const { error: advanceError } = await supabase.from("subscriptions").update({ next_payment_date: nextDate })
            .eq("id", subscription.id).eq("next_payment_date", effectiveDate);
          if (advanceError) {
            console.error("Failed to advance subscription after charge:", advanceError.message);
            break;
          }
          effectiveDate = nextDate;
        } catch (chargeError) {
          stats.charges.failed += 1;
          console.error("Failed to process subscription charge:", describeError(chargeError));
          break;
        }
      }
    }
    return json({
      success: true,
      checked: subscriptions.length,
      rolled_over: stats.rolledOver,
      rescheduled: stats.rescheduled,
      reminders: stats.reminders,
      charges: stats.charges,
      today: todayStr,
    });
  } catch (err) {
    console.error("check-subscriptions failed:", describeError(err));
    return json({ error: "check_subscriptions_failed" }, 500);
  }
});
