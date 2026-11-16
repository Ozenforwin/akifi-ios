import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";
import { toDateOnly } from "../_shared/utils.ts";

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const TELEGRAM_BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const TELEGRAM_BOT_USERNAME = Deno.env.get("TELEGRAM_BOT_USERNAME") ?? "akifiapp_bot";
const FIREBASE_SERVICE_ACCOUNT_JSON = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") ?? "";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
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

function isAuthorized(req: Request): boolean {
  // Supabase gateway already validates JWT (verify_jwt = true by default).
  // Any request that reaches this function has a valid anon/service-role key.
  const bearer = (req.headers.get("authorization") ?? "")
    .replace(/^Bearer\s+/i, "")
    .trim();
  const cronHeader = (req.headers.get("x-cron-secret") ?? "").trim();
  if (CRON_SECRET && (bearer === CRON_SECRET || cronHeader === CRON_SECRET))
    return true;
  if (bearer) return true;
  return false;
}

function formatRub(amount: number): string {
  return Math.round(amount).toLocaleString("ru-RU");
}

function plural(n: number, one: string, few: string, many: string): string {
  const abs = Math.abs(n) % 100;
  const lastDigit = abs % 10;
  if (abs >= 11 && abs <= 19) return many;
  if (lastDigit === 1) return one;
  if (lastDigit >= 2 && lastDigit <= 4) return few;
  return many;
}

// ---------------------------------------------------------------------------
// i18n — backend notifications must respect user's UI language.
// ---------------------------------------------------------------------------
type Lang = 'ru' | 'en' | 'es';

function normalizeLang(value: unknown): Lang {
  if (typeof value !== 'string') return 'ru';
  const prefix = value.toLowerCase().split(/[-_]/)[0];
  if (prefix === 'en' || prefix === 'es' || prefix === 'ru') return prefix;
  return 'ru';
}

function currencySymbol(lang: Lang): string {
  return lang === 'ru' ? '₽' : lang === 'es' ? '€' : '$';
}

function daysWord(n: number, lang: Lang): string {
  switch (lang) {
    case 'ru': return plural(n, 'день', 'дня', 'дней');
    case 'es': return n === 1 ? 'día' : 'días';
    default: return n === 1 ? 'day' : 'days';
  }
}

const T: Record<string, Record<Lang, string>> = {
  budgetHeader: { ru: 'Бюджет', en: 'Budget', es: 'Presupuesto' },
  spent: { ru: 'Потрачено', en: 'Spent', es: 'Gastado' },
  of: { ru: 'из', en: 'of', es: 'de' },
  remaining: { ru: 'Осталось', en: 'Remaining', es: 'Resta' },
  overspent: { ru: 'Перерасход', en: 'Overspent', es: 'Exceso' },
  tip5030: {
    ru: '💡 Совет: попробуйте правило 50/30/20 — выделите 50% на необходимое, 30% на желания, 20% на сбережения.',
    en: '💡 Tip: try the 50/30/20 rule — 50% needs, 30% wants, 20% savings.',
    es: '💡 Consejo: prueba la regla 50/30/20 — 50% necesidades, 30% deseos, 20% ahorros.',
  },
  tipImpulse: {
    ru: '💡 Совет: проверьте недавние траты на импульсивные покупки. Спросите ассистента «Оптимизация бюджета».',
    en: '💡 Tip: review recent spending for impulse buys. Ask the assistant about "Budget optimization".',
    es: '💡 Consejo: revisa compras impulsivas recientes. Pregunta al asistente sobre "Optimización de presupuesto".',
  },
  largeExpense: { ru: 'Крупная трата', en: 'Large expense', es: 'Gasto grande' },
  other: { ru: 'Другое', en: 'Other', es: 'Otro' },
  inactivityHeader: {
    ru: 'Давно не записывали расходы',
    en: 'No recent transactions',
    es: 'Sin operaciones recientes',
  },
  inactivityBody: {
    ru: 'Последняя запись была {n} {d} назад. Запишите расходы, чтобы не потерять контроль!',
    en: 'Last entry was {n} {d} ago. Record expenses to stay on track!',
    es: '¡Última operación hace {n} {d}! Registra gastos para no perder control.',
  },
  goalHeader: { ru: 'Цель', en: 'Goal', es: 'Meta' },
  saved: { ru: 'Накоплено', en: 'Saved', es: 'Ahorrado' },
  goalReached: {
    ru: '\nПоздравляем! Цель достигнута!',
    en: '\nCongratulations! Goal reached!',
    es: '\n¡Felicidades! ¡Meta alcanzada!',
  },
  paceHeader: {
    ru: 'Темп расходов выше нормы',
    en: 'Spending pace above normal',
    es: 'Ritmo de gastos alto',
  },
  paceBody: {
    ru: 'При текущем темпе расходы составят ~{projected} {sym} ({pct}% от лимита {limit} {sym})',
    en: 'At current pace, spending will reach ~{projected} {sym} ({pct}% of {limit} {sym} limit)',
    es: 'Al ritmo actual, gastarás ~{projected} {sym} ({pct}% del límite {limit} {sym})',
  },
  openAkifi: { ru: '📱 Открыть Akifi', en: '📱 Open Akifi', es: '📱 Abrir Akifi' },
};

function tt(key: string, lang: Lang, params: Record<string, string | number> = {}): string {
  let str = T[key]?.[lang] ?? T[key]?.ru ?? key;
  for (const [k, v] of Object.entries(params)) {
    str = str.replace(new RegExp(`\\{${k}\\}`, 'g'), String(v));
  }
  return str;
}

// ---------------------------------------------------------------------------
// Period resolver (inline — matches budgetPeriod.ts logic)
// ---------------------------------------------------------------------------
interface PeriodWindow {
  start: Date;
  end: Date;
}

function resolvePeriodWindow(
  periodType: string,
  now: Date,
  customStart?: string | null,
  customEnd?: string | null,
): PeriodWindow {
  if (periodType === "weekly") {
    const day = now.getDay();
    const diff = day === 0 ? 6 : day - 1; // Monday start
    const start = new Date(now);
    start.setDate(start.getDate() - diff);
    start.setHours(0, 0, 0, 0);
    const end = new Date(start);
    end.setDate(end.getDate() + 7);
    return { start, end };
  }

  if (periodType === "custom" && customStart && customEnd) {
    return {
      start: new Date(customStart),
      end: new Date(customEnd),
    };
  }

  // Default: monthly
  const start = new Date(now.getFullYear(), now.getMonth(), 1);
  const end = new Date(now.getFullYear(), now.getMonth() + 1, 1);
  return { start, end };
}

// toDateOnly — imported from _shared/utils.ts

// ---------------------------------------------------------------------------
// Quiet hours check
// ---------------------------------------------------------------------------
async function isInQuietHours(
  supabase: SupabaseClient,
  userId: string,
): Promise<boolean> {
  const { data } = await supabase
    .from("ai_user_settings")
    .select("quiet_hours_start,quiet_hours_end,timezone")
    .eq("user_id", userId)
    .maybeSingle();

  if (!data || data.quiet_hours_start === null || data.quiet_hours_end === null)
    return false;

  const tz = data.timezone || "Europe/Moscow";
  const nowInTz = new Date(
    new Date().toLocaleString("en-US", { timeZone: tz }),
  );
  const hour = nowInTz.getHours();

  const start = data.quiet_hours_start as number;
  const end = data.quiet_hours_end as number;

  if (start <= end) {
    return hour >= start && hour < end;
  }
  // Wraps midnight (e.g. 23–7)
  return hour >= start || hour < end;
}

// ---------------------------------------------------------------------------
// Rate limit check
// ---------------------------------------------------------------------------
async function isRateLimited(
  supabase: SupabaseClient,
  userId: string,
  dailyLimit: number,
): Promise<boolean> {
  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);

  const { count } = await supabase
    .from("notification_log")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .gte("sent_at", todayStart.toISOString());

  return (count ?? 0) >= dailyLimit;
}

// ---------------------------------------------------------------------------
// Telegram send
// ---------------------------------------------------------------------------
interface InlineButton {
  text: string;
  url: string;
}

async function sendTelegramMessage(
  chatId: string | number,
  text: string,
  buttons?: InlineButton[],
): Promise<void> {
  const body: Record<string, unknown> = {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
    disable_web_page_preview: true,
  };

  if (buttons && buttons.length > 0) {
    body.reply_markup = {
      inline_keyboard: [buttons.map((b) => ({ text: b.text, url: b.url }))],
    };
  }

  const res = await fetch(
    `https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    },
  );
  const payload = await res.json().catch(() => null);
  if (!res.ok || !payload?.ok) {
    throw new Error(
      `Telegram API failed (${res.status}): ${JSON.stringify(payload)}`,
    );
  }
}

function deepLink(tab: string): string {
  return `https://t.me/${TELEGRAM_BOT_USERNAME}/app?startapp=tab_${tab}`;
}

// ---------------------------------------------------------------------------
// FCM Push Notification (Firebase Cloud Messaging HTTP v1 API)
// ---------------------------------------------------------------------------
let _fcmAccessToken: string | null = null;
let _fcmTokenExpiry = 0;

async function getFCMAccessToken(): Promise<string | null> {
  if (_fcmAccessToken && Date.now() < _fcmTokenExpiry) return _fcmAccessToken;
  if (!FIREBASE_SERVICE_ACCOUNT_JSON) return null;

  try {
    const sa = JSON.parse(FIREBASE_SERVICE_ACCOUNT_JSON);
    const now = Math.floor(Date.now() / 1000);
    const header = btoa(JSON.stringify({ alg: "RS256", typ: "JWT" }));
    const payload = btoa(JSON.stringify({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    }));

    // Sign JWT with service account private key
    const key = await crypto.subtle.importKey(
      "pkcs8",
      pemToBuf(sa.private_key),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${payload}`));
    const jwt = `${header}.${payload}.${btoa(String.fromCharCode(...new Uint8Array(sig))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '')}`;

    const res = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
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

function pemToBuf(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

async function sendFCMPush(
  fcmToken: string,
  title: string,
  body: string,
  data?: Record<string, string>,
): Promise<boolean> {
  const accessToken = await getFCMAccessToken();
  if (!accessToken) return false;

  try {
    const sa = JSON.parse(FIREBASE_SERVICE_ACCOUNT_JSON);
    const projectId = sa.project_id;

    const res = await fetch(
      `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          message: {
            token: fcmToken,
            notification: { title, body },
            data: data ?? {},
            apns: {
              payload: { aps: { sound: "default", badge: 1 } },
            },
          },
        }),
      },
    );
    return res.ok;
  } catch (err) {
    console.error("FCM send error:", err);
    return false;
  }
}

// ---------------------------------------------------------------------------
// Notification delivery helper
// ---------------------------------------------------------------------------
interface NotificationCandidate {
  type: string;
  key: string;
  message: string;
  tab?: string;
}

async function deliverNotifications(
  supabase: SupabaseClient,
  userId: string,
  chatId: string | number,
  candidates: NotificationCandidate[],
  lang: Lang = 'ru',
): Promise<{ sent: number; skipped: number }> {
  let sent = 0;
  let skipped = 0;

  // Get FCM token for iOS push
  let fcmToken: string | null = null;
  try {
    const { data: profile } = await supabase
      .from("profiles")
      .select("fcm_token")
      .eq("id", userId)
      .maybeSingle();
    fcmToken = profile?.fcm_token ?? null;
  } catch { /* ignore */ }

  for (const c of candidates) {
    // Dedup via unique constraint — if already exists, skip
    const { data: inserted, error } = await supabase
      .from("notification_log")
      .insert({
        user_id: userId,
        notification_type: c.type,
        notification_key: c.key,
        payload: { message: c.message },
      })
      .select("id")
      .maybeSingle();

    if (error || !inserted) {
      skipped++;
      continue;
    }

    let delivered = false;

    // Send via Telegram (if user has chat_id)
    try {
      if (chatId) {
        const buttons: InlineButton[] = [
          { text: tt('openAkifi', lang), url: deepLink(c.tab ?? "home") },
        ];
        await sendTelegramMessage(chatId, c.message, buttons);
        delivered = true;
      }
    } catch (err) {
      console.error(`Telegram send failed for ${userId}:`, err);
    }

    // Send via FCM (if user has iOS token)
    try {
      if (fcmToken) {
        // Strip HTML tags for FCM notification body
        const plainText = c.message.replace(/<[^>]+>/g, "");
        const title = plainText.split("\n")[0].substring(0, 80);
        const body = plainText.split("\n").slice(1).join(" ").substring(0, 200) || title;
        const fcmOk = await sendFCMPush(fcmToken, title, body, { type: c.type, tab: c.tab ?? "home" });
        if (fcmOk) delivered = true;
      }
    } catch (err) {
      console.error(`FCM send failed for ${userId}:`, err);
    }

    // Update delivery status
    if (delivered) {
      await supabase
        .from("notification_log")
        .update({ delivered: true })
        .eq("id", inserted.id);
      sent++;
    } else {
      await supabase
        .from("notification_log")
        .update({ delivery_error: "No delivery channel available" })
        .eq("id", inserted.id);
      skipped++;
    }
  }

  return { sent, skipped };
}

// ---------------------------------------------------------------------------
// Budget metrics — the SAME numbers the app shows (findings B2, M4, D4)
// ---------------------------------------------------------------------------
// Budget pushes used to sum the author's own `amount_native` across
// currencies, over a UTC calendar month, for the author's own budgets only.
// They now read `get_budget_metrics` (migration 20261117130003) as the
// service role on behalf of each member: same window (30-day rolling month,
// inclusive end), same spend (every member, every linked account, FX via
// fx_rates), in that member's local day, and the alert goes to every member
// of a shared budget. Dedup is per user + budget + period + threshold via
// notification_log's unique (user_id, notification_key).

interface BudgetMetricRow {
  budget_id: string;
  name: string | null;
  currency: string;
  period_start: string;
  period_end: string;
  total_days: number;
  elapsed_days: number;
  remaining_days: number;
  effective_limit: number;
  spent: number;
  utilization: number;
  member_ids: string[];
  alert_thresholds: number[] | null;
}

interface MemberContext {
  tz: string;
  lang: Lang;
  chatId: string | number | null;
  fcmToken: string | null;
}

function isValidTimeZone(tz: unknown): tz is string {
  if (typeof tz !== "string" || tz.length === 0) return false;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/// "YYYY-MM-DD" of `now` in `tz` — the member's own "today".
function localDateIn(tz: string, now: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

/// Monday of the ISO week containing `dateOnly`.
function weekStartOf(dateOnly: string): string {
  const d = new Date(`${dateOnly}T00:00:00Z`);
  const back = (d.getUTCDay() + 6) % 7;
  d.setUTCDate(d.getUTCDate() - back);
  return d.toISOString().slice(0, 10);
}

async function loadMemberContext(
  supabase: SupabaseClient,
  userId: string,
): Promise<MemberContext> {
  const { data: profile } = await supabase
    .from("profiles")
    .select("timezone,preferred_language,telegram_chat_id,fcm_token")
    .eq("id", userId)
    .maybeSingle();
  let tz: unknown = (profile as { timezone?: unknown } | null)?.timezone;
  if (!isValidTimeZone(tz)) {
    const { data: ai } = await supabase
      .from("ai_user_settings")
      .select("timezone")
      .eq("user_id", userId)
      .maybeSingle();
    tz = (ai as { timezone?: unknown } | null)?.timezone;
  }
  return {
    tz: isValidTimeZone(tz) ? tz : "UTC",
    lang: normalizeLang((profile as { preferred_language?: unknown } | null)?.preferred_language),
    chatId: (profile as { telegram_chat_id?: string | number | null } | null)?.telegram_chat_id ?? null,
    fcmToken: (profile as { fcm_token?: string | null } | null)?.fcm_token ?? null,
  };
}

async function fetchBudgetMetrics(
  supabase: SupabaseClient,
  userId: string,
  ctx: MemberContext,
  budgetIds?: string[],
): Promise<BudgetMetricRow[]> {
  // One jsonb value, not a row set — max-rows cannot truncate it (ADR-003).
  const { data, error } = await supabase.rpc("get_budget_metrics", {
    p_today: localDateIn(ctx.tz),
    p_tz: ctx.tz,
    p_budget_ids: budgetIds ?? null,
    p_user_id: userId,
  });
  if (error) {
    console.error(`get_budget_metrics failed for ${userId}:`, error.code ?? error.message);
    return [];
  }
  return ((data as { budgets?: BudgetMetricRow[] } | null)?.budgets ?? []).filter(Boolean);
}

const CURRENCY_SYMBOLS: Record<string, string> = {
  RUB: "₽", USD: "$", EUR: "€", GBP: "£", VND: "₫", THB: "฿", IDR: "Rp",
  KZT: "₸", TRY: "₺", GEL: "₾", UAH: "₴", CNY: "¥", JPY: "¥", INR: "₹", AED: "AED",
};

function localeFor(lang: Lang): string {
  return lang === "ru" ? "ru-RU" : lang === "es" ? "es-ES" : "en-US";
}

/// Minor units of `currency` → "12 345 ₽". Whole units, like the budget
/// card; the symbol follows the budget's currency, not the UI language.
function formatMoney(minor: number, currency: string, lang: Lang): string {
  const code = (currency || "RUB").toUpperCase();
  const whole = Math.round(Math.abs(minor) / 100);
  return `${whole.toLocaleString(localeFor(lang))} ${CURRENCY_SYMBOLS[code] ?? code}`;
}

/// «2 нояб. – 1 дек.» — the window the card shows (D4).
function formatWindow(start: string, end: string, lang: Lang): string {
  const fmt = new Intl.DateTimeFormat(localeFor(lang), { day: "numeric", month: "short", timeZone: "UTC" });
  return `${fmt.format(new Date(`${start}T00:00:00Z`))} – ${fmt.format(new Date(`${end}T00:00:00Z`))}`;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function budgetTitle(m: BudgetMetricRow): string {
  const name = (m.name ?? "").trim();
  return name ? ` «${escapeHtml(name)}»` : "";
}

/// The highest alert threshold this budget has crossed, as one candidate.
function budgetWarningFor(
  m: BudgetMetricRow,
  warningPercent: number,
  lang: Lang,
): NotificationCandidate | null {
  if (!(m.effective_limit > 0)) return null;
  const thresholds = m.alert_thresholds && m.alert_thresholds.length > 0
    ? m.alert_thresholds
    : [warningPercent, 100];
  const crossed = [...thresholds].sort((a, b) => b - a).find((t) => m.utilization >= t);
  if (crossed === undefined) return null;

  const emoji = crossed >= 120 ? "🚨" : crossed >= 100 ? "🔴" : "⚠️";
  const left = m.effective_limit - m.spent;
  const tip = crossed >= 100
    ? "\n\n" + tt("tip5030", lang)
    : crossed >= 80
    ? "\n\n" + tt("tipImpulse", lang)
    : "";
  const message =
    `${emoji} <b>${tt("budgetHeader", lang)}${budgetTitle(m)} ${crossed}%</b>\n\n` +
    `${tt("spent", lang)}: ${formatMoney(m.spent, m.currency, lang)} ${tt("of", lang)} ${formatMoney(m.effective_limit, m.currency, lang)}\n` +
    (left > 0
      ? `${tt("remaining", lang)}: ${formatMoney(left, m.currency, lang)}`
      : `${tt("overspent", lang)}: ${formatMoney(-left, m.currency, lang)}`) +
    `\n${formatWindow(m.period_start, m.period_end, lang)}` +
    tip;

  return {
    type: "budget_warning",
    key: `budget_warning:${m.budget_id}:${m.period_start}:${crossed}`,
    message,
    tab: "budget",
  };
}

const MAX_BUDGET_ALERTS_PER_MEMBER = 2;

/// Sends budget alerts to the OTHER members of `authorId`'s shared budgets,
/// each with their own settings, quiet hours, rate limit, language and local
/// day. Safe to call more than once per event: notification_log dedups.
/// Pass `authorMetrics` when already fetched; otherwise they are loaded.
/// (The edge stream may also call this before handleTransactionInsert's
/// author-only gates, so partners are told even when the author has
/// notifications off or no delivery channel.)
async function notifyBudgetPartners(
  supabase: SupabaseClient,
  authorId: string,
  authorMetrics?: BudgetMetricRow[],
): Promise<number> {
  let metrics = authorMetrics;
  if (!metrics) {
    metrics = await fetchBudgetMetrics(supabase, authorId, await loadMemberContext(supabase, authorId));
  }
  const budgetsByPartner = new Map<string, string[]>();
  for (const m of metrics) {
    for (const memberId of m.member_ids ?? []) {
      if (memberId === authorId) continue;
      const list = budgetsByPartner.get(memberId) ?? [];
      list.push(m.budget_id);
      budgetsByPartner.set(memberId, list);
    }
  }

  let sent = 0;
  for (const [partnerId, budgetIds] of budgetsByPartner) {
    try {
      const { data: settings } = await supabase
        .from("notification_settings")
        .select("enabled,budget_warnings,budget_warning_percent,daily_limit")
        .eq("user_id", partnerId)
        .maybeSingle();
      if (!settings || !settings.enabled || settings.budget_warnings === false) continue;

      const ctx = await loadMemberContext(supabase, partnerId);
      if (!ctx.chatId && !ctx.fcmToken) continue;
      if (await isInQuietHours(supabase, partnerId)) continue;
      if (await isRateLimited(supabase, partnerId, settings.daily_limit)) continue;

      const partnerMetrics = await fetchBudgetMetrics(supabase, partnerId, ctx, budgetIds);
      const candidates = partnerMetrics
        .map((m) => budgetWarningFor(m, settings.budget_warning_percent ?? 80, ctx.lang))
        .filter((c): c is NotificationCandidate => c !== null)
        .slice(0, MAX_BUDGET_ALERTS_PER_MEMBER);
      if (candidates.length === 0) continue;

      const result = await deliverNotifications(supabase, partnerId, ctx.chatId ?? 0, candidates, ctx.lang);
      sent += result.sent;
    } catch (err) {
      console.error(`budget partner alert failed for ${partnerId}:`, err instanceof Error ? err.message : err);
    }
  }
  return sent;
}

// ---------------------------------------------------------------------------
// Evaluator: Budget Warning
// ---------------------------------------------------------------------------
/// Candidates for the AUTHOR of a new expense (delivered by the caller) and,
/// as a side effect, alerts for the partners in the author's shared budgets.
/// Every budget the author takes part in is checked, not only the ones
/// containing this category: a budget without categories, or one pushed over
/// its threshold by a partner, must alert too. `categoryId` is kept for the
/// call-site signature.
async function evaluateBudgetWarning(
  supabase: SupabaseClient,
  userId: string,
  _categoryId: string,
  warningPercent: number,
  lang: Lang = 'ru',
): Promise<NotificationCandidate[]> {
  const ctx = await loadMemberContext(supabase, userId);
  const metrics = await fetchBudgetMetrics(supabase, userId, ctx);
  if (metrics.length === 0) return [];

  const candidates = metrics
    .map((m) => budgetWarningFor(m, warningPercent, lang))
    .filter((c): c is NotificationCandidate => c !== null);

  await notifyBudgetPartners(supabase, userId, metrics);
  return candidates;
}

// ---------------------------------------------------------------------------
// Evaluator: Large Expense
// ---------------------------------------------------------------------------
async function evaluateLargeExpense(
  supabase: SupabaseClient,
  userId: string,
  transactionId: string,
  amount: number,
  categoryId: string,
  threshold: number,
  lang: Lang = 'ru',
): Promise<NotificationCandidate[]> {
  const candidates: NotificationCandidate[] = [];

  let effectiveThreshold = threshold;

  if (effectiveThreshold <= 0) {
    // Auto-calculate: mean + 2σ over last 30 days, min 3x average
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);

    const { data: recentTx } = await supabase
      .from("transactions")
      .select("amount,amount_native")
      .eq("user_id", userId)
      .eq("type", "expense")
      .is("transfer_group_id", null)
      .gte("date", toDateOnly(thirtyDaysAgo));

    const amounts = (recentTx ?? []).map(
      (t: { amount: number; amount_native?: number }) => t.amount_native ?? t.amount, // allowlisted-amount: anomaly detector prefers amount_native
    );

    // Need at least 5 transactions for meaningful stats
    if (amounts.length < 5) return candidates;

    const mean = amounts.reduce((s: number, v: number) => s + v, 0) / amounts.length;
    const variance =
      amounts.reduce((s: number, v: number) => s + (v - mean) ** 2, 0) /
      amounts.length;
    const stdDev = Math.sqrt(variance);

    effectiveThreshold = Math.max(mean + 2 * stdDev, mean * 3);
  }

  if (amount < effectiveThreshold) return candidates;

  // Get category name
  const { data: category } = await supabase
    .from("categories")
    .select("name,icon")
    .eq("id", categoryId)
    .maybeSingle();

  const catLabel = category
    ? `${category.icon} ${category.name}`
    : tt('other', lang);

  const message =
    `💸 <b>${tt('largeExpense', lang)}</b>\n\n` +
    `${formatRub(amount)} ${currencySymbol(lang)} — ${catLabel}`;

  candidates.push({
    type: "large_expense",
    key: `large_expense:${transactionId}`,
    message,
    tab: "transactions",
  });

  return candidates;
}

// ---------------------------------------------------------------------------
// Evaluator: Inactivity Reminder
// ---------------------------------------------------------------------------
async function evaluateInactivityForUser(
  supabase: SupabaseClient,
  userId: string,
  lang: Lang = 'ru',
): Promise<NotificationCandidate | null> {
  // Skip if fewer than 3 transactions total (new user)
  const { count: totalCount } = await supabase
    .from("transactions")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId);

  if ((totalCount ?? 0) < 3) return null;

  // Check last transaction
  const { data: lastTx } = await supabase
    .from("transactions")
    .select("date")
    .eq("user_id", userId)
    .order("date", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!lastTx) return null;

  const lastDate = new Date(lastTx.date);
  const now = new Date();
  const daysSinceLast = Math.floor(
    (now.getTime() - lastDate.getTime()) / (1000 * 60 * 60 * 24),
  );

  if (daysSinceLast < 3) return null;

  const today = toDateOnly(now);
  const d = daysWord(daysSinceLast, lang);

  return {
    type: "inactivity",
    key: `inactivity:${today}`,
    message:
      `😴 <b>${tt('inactivityHeader', lang)}</b>\n\n` +
      tt('inactivityBody', lang, { n: daysSinceLast, d }),
    tab: "home",
  };
}

// ---------------------------------------------------------------------------
// Evaluator: Savings Milestone
// ---------------------------------------------------------------------------
async function evaluateSavingsMilestones(
  supabase: SupabaseClient,
  userId: string,
  lang: Lang = 'ru',
): Promise<NotificationCandidate[]> {
  const candidates: NotificationCandidate[] = [];

  const { data: goals } = await supabase
    .from("savings_goals")
    .select("id,name,target_amount,current_amount,icon")
    .eq("user_id", userId)
    .eq("status", "active");

  if (!goals || goals.length === 0) return candidates;

  const milestones = [25, 50, 75, 100];

  for (const goal of goals as { id: string; name: string; target_amount: number; current_amount: number; icon: string }[]) {
    if (goal.target_amount <= 0) continue;
    const percent = (goal.current_amount / goal.target_amount) * 100;

    for (const milestone of milestones) {
      if (percent >= milestone) {
        const key = `savings_milestone:${goal.id}:${milestone}`;
        const emoji = milestone >= 100 ? "🎉" : milestone >= 75 ? "🔥" : milestone >= 50 ? "💪" : "🌱";

        const sym = currencySymbol(lang);
        const message =
          `${emoji} <b>${tt('goalHeader', lang)} «${goal.name}» — ${milestone}%!</b>\n\n` +
          `${tt('saved', lang)}: ${formatRub(goal.current_amount)} ${sym} ${tt('of', lang)} ${formatRub(goal.target_amount)} ${sym}` +
          (milestone >= 100 ? tt('goalReached', lang) : "");

        candidates.push({
          type: "savings_milestone",
          key,
          message,
          tab: "savings",
        });
        break; // Only highest milestone per goal
      }
    }
  }

  return candidates;
}

// ---------------------------------------------------------------------------
// Evaluator: Weekly Pace
// ---------------------------------------------------------------------------
// Amounts carry their own currency symbol (formatMoney), so this replaces
// T.paceBody, whose "{sym}" placeholders assumed one symbol per language.
const PACE_BODY: Record<Lang, string> = {
  ru: 'При текущем темпе расходы составят ~{projected} ({pct}% от лимита {limit})',
  en: 'At current pace, spending will reach ~{projected} ({pct}% of the {limit} limit)',
  es: 'Al ritmo actual, gastarás ~{projected} ({pct}% del límite {limit})',
};

/// Wednesday nudge when the projected spend for the period exceeds 120 % of
/// the limit. Uses the server metrics (same window, spend and currency as
/// the app) for EVERY budget the user takes part in — shared budgets
/// included, so each member gets it — in the user's own local day.
async function evaluateWeeklyPace(
  supabase: SupabaseClient,
  userId: string,
  lang: Lang = 'ru',
): Promise<NotificationCandidate[]> {
  // The cron fires on Wednesdays (UTC); guard against off-schedule triggers.
  if (new Date().getUTCDay() !== 3) return [];

  const ctx = await loadMemberContext(supabase, userId);
  const today = localDateIn(ctx.tz);
  const weekStart = weekStartOf(today);
  const metrics = await fetchBudgetMetrics(supabase, userId, ctx);

  const candidates: NotificationCandidate[] = [];
  for (const m of metrics) {
    if (!(m.effective_limit > 0) || m.elapsed_days <= 0 || m.remaining_days <= 0) continue;

    // Same projection the card's pace uses: spend so far over the elapsed
    // days (today included), extended to the whole window.
    const projected = (m.spent / m.elapsed_days) * m.total_days;
    const projectedPercent = (projected / m.effective_limit) * 100;
    if (projectedPercent <= 120) continue;

    const body = PACE_BODY[lang]
      .replace("{projected}", formatMoney(projected, m.currency, lang))
      .replace("{pct}", String(Math.round(projectedPercent)))
      .replace("{limit}", formatMoney(m.effective_limit, m.currency, lang));
    const message =
      `📊 <b>${tt('paceHeader', lang)}${budgetTitle(m)}</b>\n\n` +
      body +
      `\n${formatWindow(m.period_start, m.period_end, lang)}`;

    candidates.push({
      type: "weekly_pace",
      key: `weekly_pace:${m.budget_id}:${weekStart}`,
      message,
      tab: "budget",
    });
  }

  return candidates;
}

// ---------------------------------------------------------------------------
// Handler: transaction_insert
// ---------------------------------------------------------------------------
async function handleTransactionInsert(
  supabase: SupabaseClient,
  body: Record<string, unknown>,
): Promise<Response> {
  const userId = body.user_id as string;
  const transactionId = body.transaction_id as string;
  const amount = body.amount as number;
  const type = body.type as string;
  const categoryId = body.category_id as string;

  if (!userId || !transactionId) {
    return json({ error: "Missing user_id or transaction_id" }, 400);
  }

  // Skip transfers — they are not real expenses/income
  const { data: txRecord } = await supabase
    .from('transactions')
    .select('transfer_group_id')
    .eq('id', transactionId)
    .maybeSingle();
  if (txRecord?.transfer_group_id) {
    return json({ ok: true, skipped: true, reason: 'transfer' });
  }

  // Load notification settings
  const { data: settings } = await supabase
    .from("notification_settings")
    .select("*")
    .eq("user_id", userId)
    .maybeSingle();

  // If no settings or disabled, exit
  if (!settings || !settings.enabled) {
    return json({ ok: true, skipped: true, reason: "disabled" });
  }

  // Get user's delivery channels + language preference
  const { data: profile } = await supabase
    .from("profiles")
    .select("telegram_chat_id,fcm_token,preferred_language")
    .eq("id", userId)
    .maybeSingle();

  if (!profile?.telegram_chat_id && !profile?.fcm_token) {
    return json({ ok: true, skipped: true, reason: "no_delivery_channel" });
  }

  const lang = normalizeLang((profile as { preferred_language?: unknown }).preferred_language);

  // Check quiet hours
  if (await isInQuietHours(supabase, userId)) {
    return json({ ok: true, skipped: true, reason: "quiet_hours" });
  }

  // Check rate limit
  if (await isRateLimited(supabase, userId, settings.daily_limit)) {
    return json({ ok: true, skipped: true, reason: "rate_limited" });
  }

  const candidates: NotificationCandidate[] = [];

  // Budget warning (only for expenses)
  if (settings.budget_warnings && type === "expense") {
    const budgetCandidates = await evaluateBudgetWarning(
      supabase,
      userId,
      categoryId,
      settings.budget_warning_percent,
      lang,
    );
    candidates.push(...budgetCandidates);
  }

  // Large expense
  if (settings.large_expenses && type === "expense") {
    const largeCandidates = await evaluateLargeExpense(
      supabase,
      userId,
      transactionId,
      amount,
      categoryId,
      settings.large_expense_threshold,
      lang,
    );
    candidates.push(...largeCandidates);
  }

  // Savings milestones
  if (settings.savings_milestones !== false) {
    const savingsCandidates = await evaluateSavingsMilestones(supabase, userId, lang);
    candidates.push(...savingsCandidates);
  }

  if (candidates.length === 0) {
    return json({ ok: true, candidates: 0 });
  }

  // Prioritize and limit notifications to avoid spamming the user.
  // Priority: budget_warning > large_expense > savings_milestone
  const PRIORITY: Record<string, number> = {
    budget_warning: 1,
    large_expense: 2,
    weekly_pace: 3,
    savings_milestone: 4,
    inactivity: 5,
  };
  const MAX_NOTIFICATIONS_PER_EVENT = 2;

  candidates.sort((a, b) => (PRIORITY[a.type] ?? 99) - (PRIORITY[b.type] ?? 99));
  const limited = candidates.slice(0, MAX_NOTIFICATIONS_PER_EVENT);

  const result = await deliverNotifications(
    supabase,
    userId,
    profile.telegram_chat_id ?? 0,
    limited,
    lang,
  );

  return json({ ok: true, ...result, totalCandidates: candidates.length, sent: result.sent });
}

// ---------------------------------------------------------------------------
// Handler: cron_inactivity
// ---------------------------------------------------------------------------
async function handleCronInactivity(
  supabase: SupabaseClient,
): Promise<Response> {
  // Get all users with at least one delivery channel (Telegram or FCM)
  const { data: profiles, error: profilesError } = await supabase
    .from("profiles")
    .select("id,telegram_chat_id,fcm_token,preferred_language")
    .or("telegram_chat_id.not.is.null,fcm_token.not.is.null");

  if (profilesError) throw profilesError;

  const users = (profiles ?? []) as {
    id: string;
    telegram_chat_id: string | number | null;
    fcm_token: string | null;
    preferred_language: string | null;
  }[];

  if (users.length === 0) {
    return json({ ok: true, checked: 0, sent: 0 });
  }

  let totalSent = 0;
  let totalSkipped = 0;
  let totalChecked = 0;

  for (const user of users) {
    totalChecked++;

    // Load notification settings
    const { data: settings } = await supabase
      .from("notification_settings")
      .select("enabled,inactivity,daily_limit")
      .eq("user_id", user.id)
      .maybeSingle();

    if (!settings || !settings.enabled || !settings.inactivity) continue;

    // Check quiet hours
    if (await isInQuietHours(supabase, user.id)) continue;

    // Check rate limit
    if (await isRateLimited(supabase, user.id, settings.daily_limit)) continue;

    const userLang = normalizeLang(user.preferred_language);
    const candidate = await evaluateInactivityForUser(supabase, user.id, userLang);
    if (!candidate) continue;

    const result = await deliverNotifications(supabase, user.id, user.telegram_chat_id ?? 0, [
      candidate,
    ], userLang);
    totalSent += result.sent;
    totalSkipped += result.skipped;
  }

  return json({
    ok: true,
    checked: totalChecked,
    sent: totalSent,
    skipped: totalSkipped,
  });
}

// ---------------------------------------------------------------------------
// Handler: cron_weekly_pace
// ---------------------------------------------------------------------------
async function handleCronWeeklyPace(
  supabase: SupabaseClient,
): Promise<Response> {
  const { data: profiles, error: profilesError } = await supabase
    .from("profiles")
    .select("id,telegram_chat_id,fcm_token,preferred_language")
    .or("telegram_chat_id.not.is.null,fcm_token.not.is.null");

  if (profilesError) throw profilesError;

  const users = (profiles ?? []) as {
    id: string;
    telegram_chat_id: string | number | null;
    fcm_token: string | null;
    preferred_language: string | null;
  }[];

  if (users.length === 0) {
    return json({ ok: true, checked: 0, sent: 0 });
  }

  let totalSent = 0;
  let totalSkipped = 0;
  let totalChecked = 0;

  for (const user of users) {
    totalChecked++;

    const { data: settings } = await supabase
      .from("notification_settings")
      .select("enabled,weekly_pace,daily_limit")
      .eq("user_id", user.id)
      .maybeSingle();

    if (!settings || !settings.enabled || settings.weekly_pace === false) continue;

    if (await isInQuietHours(supabase, user.id)) continue;
    if (await isRateLimited(supabase, user.id, settings.daily_limit)) continue;

    const userLang = normalizeLang(user.preferred_language);
    const paceCandidates = await evaluateWeeklyPace(supabase, user.id, userLang);
    if (paceCandidates.length === 0) continue;

    const result = await deliverNotifications(supabase, user.id, user.telegram_chat_id ?? 0, paceCandidates, userLang);
    totalSent += result.sent;
    totalSkipped += result.skipped;
  }

  return json({
    ok: true,
    checked: totalChecked,
    sent: totalSent,
    skipped: totalSkipped,
  });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || (!TELEGRAM_BOT_TOKEN && !FIREBASE_SERVICE_ACCOUNT_JSON)) {
    return json({ error: "Missing required environment variables" }, 500);
  }

  if (!isAuthorized(req)) {
    return json({ error: "Unauthorized" }, 401);
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    const body = (await req.json()) as Record<string, unknown>;
    const trigger = body.trigger as string;

    if (trigger === "transaction_insert") {
      return await handleTransactionInsert(supabase, body);
    }

    if (trigger === "cron_inactivity") {
      return await handleCronInactivity(supabase);
    }

    if (trigger === "cron_weekly_pace") {
      return await handleCronWeeklyPace(supabase);
    }

    return json({ error: `Unknown trigger: ${trigger}` }, 400);
  } catch (err) {
    console.error("Smart notifications failed:", err);
    return json({ error: String(err) }, 500);
  }
});
