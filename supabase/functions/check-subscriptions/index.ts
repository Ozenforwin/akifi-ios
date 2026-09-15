import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";
import { parseDateOnly, toDateOnly } from "../_shared/utils.ts";
import { addPeriod, planCatchUp } from "../_shared/schedule.ts";
import { FALLBACK_RATES, convertCurrency, roundCurrency } from "../_shared/currency.ts";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const TELEGRAM_BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const FIREBASE_SERVICE_ACCOUNT_JSON = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") ?? "";
const DAY_MS = 24 * 60 * 60 * 1000;
// How far back a missed charge is still recovered (see planCatchUp).
const CATCH_UP_DAYS = 45;
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};
function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json"
    }
  });
}
// parseDateOnly, toDateOnly — imported from _shared/utils.ts
const toDateOnlyString = toDateOnly;
// addPeriod / planCatchUp — imported from _shared/schedule.ts
function daysBetween(fromDate, toDate) {
  const from = parseDateOnly(fromDate).getTime();
  const to = parseDateOnly(toDate).getTime();
  return Math.round((to - from) / DAY_MS);
}
function normalizeReminderDays(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return 1;
  const integer = Math.trunc(parsed);
  if (integer < 0) return 0;
  if (integer > 30) return 30;
  return integer;
}
function pluralDays(value) {
  const mod10 = value % 10;
  const mod100 = value % 100;
  if (mod10 === 1 && mod100 !== 11) return "день";
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return "дня";
  return "дней";
}
function formatAmount(amount, currency) {
  try {
    return new Intl.NumberFormat("ru-RU", {
      style: "currency",
      currency: currency.toUpperCase(),
      maximumFractionDigits: currency.toUpperCase() === "RUB" ? 0 : 2
    }).format(amount);
  } catch  {
    return `${amount} ${currency.toUpperCase()}`;
  }
}
function convertToRub(amount, currency, rates) {
  return convertCurrency(amount, currency, "RUB", rates);
}
function isAuthorized(req) {
  // Cron-only. The pg_cron job sends CRON_SECRET as the bearer token; it
  // is not a JWT, so this function MUST be deployed with verify_jwt = false
  // (supabase/config.toml) — the 2026-09-01 redeploy forgot that and the
  // gateway rejected every run for two weeks. The previous fallback
  // "accept any non-empty bearer" relied on that gateway check and would
  // have let any anon-key holder trigger charges for every user once it
  // was switched off, so it is gone: no secret, no access.
  if (!CRON_SECRET) {
    console.error("CRON_SECRET is not configured; refusing every request");
    return false;
  }
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const cronHeader = (req.headers.get("x-cron-secret") ?? "").trim();
  return bearer === CRON_SECRET || cronHeader === CRON_SECRET;
}
function reminderText(subscription, reminderDays) {
  const amount = formatAmount(Number(subscription.amount), subscription.currency);
  if (reminderDays <= 0) {
    return `🔔 Напоминание: Сегодня спишут ${amount} за подписку ${subscription.service_name}. Проверьте баланс!`;
  }
  return `🔔 Напоминание: Через ${reminderDays} ${pluralDays(reminderDays)} спишут ${amount} за подписку ${subscription.service_name}. Проверьте баланс!`;
}
async function sendTelegramMessage(chatId, text) {
  const res = await fetch(`https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      chat_id: chatId,
      text,
      disable_web_page_preview: true
    })
  });
  const payload = await res.json().catch(()=>null);
  if (!res.ok || !payload?.ok) {
    throw new Error(`Telegram API failed (${res.status}): ${JSON.stringify(payload)}`);
  }
}
// ---------------------------------------------------------------------------
// FCM Push Notification (Firebase Cloud Messaging HTTP v1 API)
// ---------------------------------------------------------------------------
let _fcmAccessToken = null;
let _fcmTokenExpiry = 0;
async function getFCMAccessToken() {
  if (_fcmAccessToken && Date.now() < _fcmTokenExpiry) return _fcmAccessToken;
  if (!FIREBASE_SERVICE_ACCOUNT_JSON) return null;
  try {
    const sa = JSON.parse(FIREBASE_SERVICE_ACCOUNT_JSON);
    const now = Math.floor(Date.now() / 1000);
    const header = btoa(JSON.stringify({
      alg: "RS256",
      typ: "JWT"
    }));
    const payload = btoa(JSON.stringify({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600
    }));
    const key = await crypto.subtle.importKey("pkcs8", pemToBuf(sa.private_key), {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256"
    }, false, [
      "sign"
    ]);
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${payload}`));
    const jwt = `${header}.${payload}.${btoa(String.fromCharCode(...new Uint8Array(sig))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '')}`;
    const res = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded"
      },
      body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`
    });
    const data = await res.json();
    _fcmAccessToken = data.access_token;
    _fcmTokenExpiry = Date.now() + (data.expires_in ?? 3500) * 1000;
    return _fcmAccessToken;
  } catch (err) {
    console.error("FCM auth error:", err);
    return null;
  }
}
function pemToBuf(pem) {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for(let i = 0; i < bin.length; i++)buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}
async function sendFCMPush(fcmToken, title, body, data) {
  const accessToken = await getFCMAccessToken();
  if (!accessToken) return false;
  try {
    const sa = JSON.parse(FIREBASE_SERVICE_ACCOUNT_JSON);
    const projectId = sa.project_id;
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        message: {
          token: fcmToken,
          notification: {
            title,
            body
          },
          data: data ?? {},
          apns: {
            payload: {
              aps: {
                sound: "default",
                badge: 1
              }
            }
          }
        }
      })
    });
    return res.ok;
  } catch (err) {
    console.error("FCM send error:", err);
    return false;
  }
}
async function fetchRubRates() {
  try {
    const res = await fetch("https://open.er-api.com/v6/latest/RUB");
    if (!res.ok) {
      return FALLBACK_RATES;
    }
    const payload = await res.json().catch(()=>null);
    const rates = payload?.rates ?? {};
    // Pass EVERY rate the provider returned through, not a hand-picked
    // five. Whitelisting dropped EUR, so a €10 subscription hit the 1:1
    // fallback and was charged as 10 ₽ instead of ~900 ₽.
    return {
      ...FALLBACK_RATES,
      ...rates,
      RUB: 1
    };
  } catch  {
    return FALLBACK_RATES;
  }
}
async function resolveTelegramChatId(supabase, userId, cache) {
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
  if (authError || !authData.user) {
    cache.set(userId, null);
    return null;
  }
  const metadata = authData.user.user_metadata ?? {};
  const candidate = metadata.telegram_id ?? metadata.telegramId ?? null;
  const resolved = candidate ? String(candidate) : null;
  cache.set(userId, resolved);
  return resolved;
}
async function resolveFCMToken(supabase, userId, cache) {
  const cacheKey = `fcm:${userId}`;
  const cached = cache.get(cacheKey);
  if (cached !== undefined) return cached;
  const { data: profileData } = await supabase.from("profiles").select("fcm_token").eq("id", userId).maybeSingle();
  const token = profileData?.fcm_token ?? null;
  cache.set(cacheKey, token);
  return token;
}
async function ensureReminderEvent(supabase, subscription, paymentDate, reminderDays) {
  const insertPayload = {
    subscription_id: subscription.id,
    user_id: subscription.user_id,
    payment_date: paymentDate,
    reminder_days: reminderDays
  };
  const inserted = await supabase.from("subscription_reminder_events").insert(insertPayload).select("id,sent_at").single();
  if (!inserted.error && inserted.data) {
    return inserted.data;
  }
  if (inserted.error?.code !== "23505") {
    throw new Error(inserted.error?.message ?? "Failed to create reminder event");
  }
  const existing = await supabase.from("subscription_reminder_events").select("id,sent_at").eq("subscription_id", subscription.id).eq("payment_date", paymentDate).eq("reminder_days", reminderDays).maybeSingle();
  if (existing.error) {
    throw new Error(existing.error.message);
  }
  return existing.data ?? null;
}
async function ensureChargeEvent(supabase, subscription, chargeDate) {
  const insertPayload = {
    subscription_id: subscription.id,
    user_id: subscription.user_id,
    charge_date: chargeDate
  };
  const inserted = await supabase.from("subscription_charge_events").insert(insertPayload).select("id,transaction_id").single();
  if (!inserted.error && inserted.data) {
    return inserted.data;
  }
  if (inserted.error?.code !== "23505") {
    throw new Error(inserted.error?.message ?? "Failed to create charge event");
  }
  const existing = await supabase.from("subscription_charge_events").select("id,transaction_id").eq("subscription_id", subscription.id).eq("charge_date", chargeDate).maybeSingle();
  if (existing.error) {
    throw new Error(existing.error.message);
  }
  return existing.data ?? null;
}
async function resolveExpenseCategoryId(supabase, userId, cache) {
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
    is_active: true
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
async function resolveWritableAccount(supabase, userId, accountId, cache) {
  if (!accountId) return null;
  const cacheKey = `${userId}:${accountId}`;
  if (cache.has(cacheKey)) {
    return cache.get(cacheKey) ?? null;
  }
  const membership = await supabase.from("account_members").select("account_id").eq("user_id", userId).eq("account_id", accountId).in("role", [
    "owner",
    "editor"
  ]).limit(1).maybeSingle();
  if (membership.error || !membership.data?.account_id) {
    cache.set(cacheKey, null);
    return null;
  }
  const account = await supabase.from("accounts").select("id,currency").eq("id", membership.data.account_id).limit(1).maybeSingle();
  if (account.error || !account.data?.id) {
    cache.set(cacheKey, null);
    return null;
  }
  const resolved = {
    id: account.data.id,
    currency: (account.data.currency ?? "RUB").toUpperCase()
  };
  cache.set(cacheKey, resolved);
  return resolved;
}
// `charge` carries the amount ALREADY expressed in the target account's
// currency, plus the original subscription amount for provenance.
/**
 * Posts one charge for `chargeDate`. Idempotent: the charge event is
 * unique per (subscription, date) and the transaction lookup dedupes on
 * (user, date, description, amount).
 *
 * Returns "posted" (new transaction), "skipped" (already charged) or
 * "failed" (recorded on the charge event).
 */
async function chargeSubscription(supabase, subscription, chargeDate, rates, categoryCache, writableAccountCache) {
  const chargeEvent = await ensureChargeEvent(supabase, subscription, chargeDate);
  if (!chargeEvent) return "skipped";
  if (chargeEvent.transaction_id) return "skipped";

  const categoryId = await resolveExpenseCategoryId(supabase, subscription.user_id, categoryCache);
  const writableAccount = await resolveWritableAccount(supabase, subscription.user_id, subscription.account_id, writableAccountCache);
  const writableAccountId = writableAccount?.id ?? null;
  const amountRaw = Number(subscription.amount);
  const subCurrency = (subscription.currency ?? "RUB").toUpperCase();
  const sourceAmount = Number.isFinite(amountRaw) && amountRaw > 0 ? amountRaw : 0;
  // Charge in the ACCOUNT's currency. Falls back to RUB only when
  // the subscription has no writable account to charge against.
  const targetCurrency = writableAccount?.currency ?? "RUB";
  const chargeAmount = convertCurrency(sourceAmount, subCurrency, targetCurrency, rates);
  const charge = {
    amount: chargeAmount,
    currency: targetCurrency,
    foreignAmount: sourceAmount,
    foreignCurrency: subCurrency
  };
  if (!Number.isFinite(chargeAmount) || chargeAmount <= 0) {
    await supabase.from("subscription_charge_events").update({
      error_message: "Invalid amount for auto charge"
    }).eq("id", chargeEvent.id);
    return "failed";
  }
  const transactionId = await ensureTransactionForCharge(supabase, subscription, chargeDate, categoryId, writableAccountId, charge);
  await supabase.from("subscription_charge_events").update({
    transaction_id: transactionId,
    error_message: null
  }).eq("id", chargeEvent.id);
  await recordPayment(supabase, subscription, chargeDate, charge);
  return "posted";
}

/**
 * What the iOS app shows as "last charge" and "payment history" —
 * `subscriptions.last_payment_date` and a `subscription_payments` row.
 * The auto-charge never wrote either, so the app kept showing the last
 * MANUAL payment (April) under a subscription charged monthly since.
 * Best-effort: a failure here must not undo the charge.
 */
async function recordPayment(supabase, subscription, chargeDate, charge) {
  const paymentAt = `${chargeDate}T00:00:00+00:00`;
  try {
    const { data: existing } = await supabase.from("subscription_payments").select("id").eq("subscription_id", subscription.id).gte("payment_date", paymentAt).lt("payment_date", `${chargeDate}T23:59:59.999+00:00`).limit(1).maybeSingle();
    if (!existing) {
      const { error: insertError } = await supabase.from("subscription_payments").insert({
        subscription_id: subscription.id,
        amount: charge.amount,
        currency: charge.currency,
        payment_date: paymentAt
      });
      if (insertError) console.error("Failed to record subscription payment:", insertError);
    }
  } catch (paymentError) {
    console.error("Failed to record subscription payment:", paymentError);
  }
  try {
    // Only move forward — a catch-up run posts dates in ascending order,
    // but a manual "record payment" in the app may already be newer.
    const { error: lastError } = await supabase.from("subscriptions").update({
      last_payment_date: paymentAt
    }).eq("id", subscription.id).or(`last_payment_date.is.null,last_payment_date.lt.${paymentAt}`);
    if (lastError) console.error("Failed to update last_payment_date:", lastError);
  } catch (lastError) {
    console.error("Failed to update last_payment_date:", lastError);
  }
}

async function ensureTransactionForCharge(supabase, subscription, chargeDate, categoryId, accountId, charge) {
  const description = `Подписка: ${subscription.service_name}`;
  const existing = await supabase.from("transactions").select("id").eq("user_id", subscription.user_id).eq("date", chargeDate).eq("type", "expense").eq("description", description).eq("amount", charge.amount).limit(1).maybeSingle();
  if (!existing.error && existing.data?.id) {
    return existing.data.id;
  }
  // `currency` and `amount_native` are NOT optional (ADR-001): the read
  // path interprets the amount as being in the account's currency, so a
  // NULL currency on a USD account turns 864 ₽ into $864.
  const row = {
    user_id: subscription.user_id,
    category_id: categoryId,
    account_id: accountId,
    type: "expense",
    amount: charge.amount,
    amount_native: charge.amount,
    currency: charge.currency,
    description,
    date: chargeDate
  };
  // Cross-currency charge: keep what the user actually subscribed for, so
  // the row can be audited and re-converted later.
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
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: corsHeaders
    });
  }
  if (req.method !== "POST") {
    return json({
      error: "Method not allowed"
    }, 405);
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !TELEGRAM_BOT_TOKEN && !FIREBASE_SERVICE_ACCOUNT_JSON) {
    return json({
      error: "Missing required environment variables"
    }, 500);
  }
  if (!isAuthorized(req)) {
    return json({
      error: "Unauthorized"
    }, 401);
  }
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: {
      autoRefreshToken: false,
      persistSession: false
    }
  });
  const now = new Date();
  const today = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const todayStr = toDateOnlyString(today);
  const rates = await fetchRubRates();
  const chatIdCache = new Map();
  const categoryCache = new Map();
  const writableAccountCache = new Map();
  try {
    const { data: rows, error } = await supabase.from("subscriptions").select("id,user_id,service_name,amount,currency,billing_period,next_payment_date,reminder_days,account_id,is_active").eq("is_active", true).not("next_payment_date", "is", null).order("next_payment_date", {
      ascending: true
    });
    if (error) {
      throw new Error(error.message);
    }
    const subscriptions = rows ?? [];
    let rolledOver = 0;
    let remindersPlanned = 0;
    let remindersSent = 0;
    let remindersSkipped = 0;
    let remindersFailed = 0;
    let chargesPlanned = 0;
    let chargesPosted = 0;
    let chargesSkipped = 0;
    let chargesFailed = 0;
    for (const subscription of subscriptions){
      let effectiveDate = subscription.next_payment_date;
      // Every period date the cron slept through is charged on its own
      // date; only dates older than CATCH_UP_DAYS are rolled past.
      const plan = planCatchUp(effectiveDate, subscription.billing_period, todayStr, CATCH_UP_DAYS);
      if (plan.skipped.length > 0 && plan.due.length === 0) {
        const { error: updateError } = await supabase.from("subscriptions").update({
          next_payment_date: plan.next
        }).eq("id", subscription.id).eq("next_payment_date", effectiveDate);
        if (!updateError) {
          rolledOver += 1;
          effectiveDate = plan.next;
        }
      } else if (plan.skipped.length > 0) {
        rolledOver += 1;
      }
      for (const chargeDate of plan.due) {
        chargesPlanned += 1;
        const nextDate = toDateOnlyString(addPeriod(parseDateOnly(chargeDate), subscription.billing_period));
        try {
          const outcome = await chargeSubscription(supabase, subscription, chargeDate, rates, categoryCache, writableAccountCache);
          if (outcome === "posted") chargesPosted += 1;
          else if (outcome === "skipped") chargesSkipped += 1;
          else chargesFailed += 1;
          // Advance past this date even when the charge itself failed:
          // the charge event keeps the error, and leaving next_payment_date
          // in the past would re-plan the same failing date every day
          // while blocking the dates after it.
          const { error: advanceError } = await supabase.from("subscriptions").update({
            next_payment_date: nextDate
          }).eq("id", subscription.id).eq("next_payment_date", effectiveDate);
          if (advanceError) {
            console.error("Failed to advance subscription after charge:", advanceError);
            break;
          }
          effectiveDate = nextDate;
        } catch (chargeError) {
          chargesFailed += 1;
          console.error("Failed to process subscription charge:", chargeError);
          break;
        }
      }
      const reminderDays = normalizeReminderDays(subscription.reminder_days);
      const daysUntilPayment = daysBetween(todayStr, effectiveDate);
      if (daysUntilPayment === reminderDays) {
        remindersPlanned += 1;
        try {
          const event = await ensureReminderEvent(supabase, subscription, effectiveDate, reminderDays);
          if (!event) {
            remindersSkipped += 1;
          } else if (event.sent_at) {
            remindersSkipped += 1;
          } else {
            const chatId = await resolveTelegramChatId(supabase, subscription.user_id, chatIdCache);
            const fcmToken = await resolveFCMToken(supabase, subscription.user_id, chatIdCache);
            if (!chatId && !fcmToken) {
              remindersSkipped += 1;
              await supabase.from("subscription_reminder_events").update({
                error_message: "No delivery channel (no Telegram chat or FCM token)"
              }).eq("id", event.id);
            } else {
              let delivered = false;
              const text = reminderText(subscription, reminderDays);
              // Send via Telegram (if user has chat_id)
              if (chatId) {
                try {
                  await sendTelegramMessage(chatId, text);
                  delivered = true;
                } catch (telegramError) {
                  console.error(`Telegram subscription reminder failed for ${subscription.user_id}:`, telegramError);
                }
              }
              // Send via FCM (if user has iOS token)
              if (fcmToken) {
                try {
                  const fcmOk = await sendFCMPush(fcmToken, "Напоминание о подписке", text, {
                    type: "subscription_reminder",
                    tab: "budget"
                  });
                  if (fcmOk) delivered = true;
                } catch (fcmError) {
                  console.error(`FCM subscription reminder failed for ${subscription.user_id}:`, fcmError);
                }
              }
              if (delivered) {
                remindersSent += 1;
                await supabase.from("subscription_reminder_events").update({
                  sent_at: new Date().toISOString(),
                  error_message: null
                }).eq("id", event.id);
              } else {
                remindersFailed += 1;
                await supabase.from("subscription_reminder_events").update({
                  error_message: "All delivery channels failed"
                }).eq("id", event.id);
              }
            }
          }
        } catch (eventError) {
          remindersFailed += 1;
          console.error("Failed to process reminder event:", eventError);
        }
      }
    }
    return json({
      success: true,
      checked: subscriptions.length,
      rolled_over: rolledOver,
      reminders: {
        planned: remindersPlanned,
        sent: remindersSent,
        skipped: remindersSkipped,
        failed: remindersFailed
      },
      charges: {
        planned: chargesPlanned,
        posted: chargesPosted,
        skipped: chargesSkipped,
        failed: chargesFailed
      },
      today: todayStr
    });
  } catch (err) {
    console.error("check-subscriptions failed:", err);
    return json({
      error: String(err)
    }, 500);
  }
});
