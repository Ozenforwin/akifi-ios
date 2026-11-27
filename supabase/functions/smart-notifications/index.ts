import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";
import { formatMoney, toDateOnly } from "../_shared/utils.ts";
import { isCronAuthorized } from "../_shared/auth.ts";
import { fetchAll } from "../_shared/paging.ts";
import { selectCandidates } from "./select.ts";
import { getRubRates } from "../_shared/fx.ts";
import { tryConvertCurrency } from "../_shared/currency.ts";
import { localDate, localHour, resolveTimeZone, startOfLocalDayUtc } from "../_shared/timezone.ts";
import {
  describeError,
  escapeHtml,
  fcmConfigured,
  type InlineButton,
  pushTextFromHtml,
  sendFcmPush,
  sendTelegramMessage,
  telegramConfigured,
} from "../_shared/notify.ts";

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const TELEGRAM_BOT_USERNAME = Deno.env.get("TELEGRAM_BOT_USERNAME") ?? "akifiapp_bot";

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

// Auth: only the DB trigger and pg_cron call this function, with
// CRON_SECRET (`_shared/auth.ts`). verify_jwt = false (config.toml), so the
// old "any non-empty bearer is fine" fallback let anyone holding the public
// anon key push a fake «крупная трата» to any user (S4).

function formatRub(amount: number): string {
  return Math.round(amount).toLocaleString("ru-RU");
}

/** An amount in ITS OWN currency, separators by the user's language (M4). */
function money(amount: number, currency: string | null | undefined, lang: Lang): string {
  return formatMoney(amount, (currency || "RUB").toUpperCase(), lang);
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
// User time zone (profiles.timezone → ai_user_settings.timezone → UTC),
// cached per request batch.
// ---------------------------------------------------------------------------
const tzCache = new Map<string, string>();

async function userTimeZone(supabase: SupabaseClient, userId: string): Promise<string> {
  const cached = tzCache.get(userId);
  if (cached) return cached;
  const tz = await resolveTimeZone(supabase, userId);
  tzCache.set(userId, tz);
  return tz;
}

// ---------------------------------------------------------------------------
// Quiet hours check
// ---------------------------------------------------------------------------
async function isInQuietHours(
  supabase: SupabaseClient,
  userId: string,
): Promise<boolean> {
  const { data } = await supabase
    .from("ai_user_settings")
    .select("quiet_hours_start,quiet_hours_end")
    .eq("user_id", userId)
    .maybeSingle();

  if (!data || data.quiet_hours_start === null || data.quiet_hours_end === null)
    return false;

  const hour = localHour(new Date(), await userTimeZone(supabase, userId));
  const start = data.quiet_hours_start as number;
  const end = data.quiet_hours_end as number;

  if (start <= end) {
    return hour >= start && hour < end;
  }
  // Wraps midnight (e.g. 23–7)
  return hour >= start || hour < end;
}

// ---------------------------------------------------------------------------
// Rate limit check — "per day" is the user's local day, not the server's.
// ---------------------------------------------------------------------------
async function dailyQuotaLeft(
  supabase: SupabaseClient,
  userId: string,
  dailyLimit: number,
): Promise<number> {
  const todayStart = startOfLocalDayUtc(new Date(), await userTimeZone(supabase, userId));

  const { count } = await supabase
    .from("notification_log")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .gte("sent_at", todayStart.toISOString());

  return Math.max(0, (Number(dailyLimit) || 0) - (count ?? 0));
}

async function isRateLimited(
  supabase: SupabaseClient,
  userId: string,
  dailyLimit: number,
): Promise<boolean> {
  return (await dailyQuotaLeft(supabase, userId, dailyLimit)) <= 0;
}

/// Keys of `candidates` already in notification_log for this user. One
/// bounded read (a handful of keys per event); on error nothing is assumed
/// sent — the unique (user_id, notification_key) insert still dedups.
async function alreadySentKeys(
  supabase: SupabaseClient,
  userId: string,
  candidates: { key: string }[],
): Promise<Set<string>> {
  const keys = [...new Set(candidates.map((c) => c.key))];
  if (keys.length === 0) return new Set();
  // bounded-fetch: at most one row per candidate key of this event (a handful)
  const { data, error } = await supabase
    .from("notification_log")
    .select("notification_key")
    .eq("user_id", userId)
    .in("notification_key", keys);
  if (error) {
    console.error("notification_log key lookup failed:", error.code ?? error.message);
    return new Set();
  }
  return new Set((data ?? []).map((r: { notification_key: string }) => r.notification_key));
}

/// Already-sent keys dropped first, then priority order, then the cap
/// (per-event cap and the rest of the daily limit). See select.ts.
async function pickForDelivery<T extends NotificationCandidate>(
  supabase: SupabaseClient,
  userId: string,
  candidates: T[],
  perEventCap: number,
  dailyLimit: number,
): Promise<T[]> {
  if (candidates.length === 0) return [];
  const [sent, quota] = await Promise.all([
    alreadySentKeys(supabase, userId, candidates),
    dailyQuotaLeft(supabase, userId, dailyLimit),
  ]);
  return selectCandidates(candidates, sent, Math.min(perEventCap, quota));
}

function deepLink(tab: string): string {
  return `https://t.me/${TELEGRAM_BOT_USERNAME}/app?startapp=tab_${tab}`;
}

// ---------------------------------------------------------------------------
// Notification delivery helper (Telegram + FCM via _shared/notify.ts, which
// keeps the bot token out of error logs)
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
    // Dedup via unique (user_id, notification_key) — if already logged, skip.
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

    if (chatId && telegramConfigured()) {
      try {
        const buttons: InlineButton[] = [
          { text: tt('openAkifi', lang), url: deepLink(c.tab ?? "home") },
        ];
        await sendTelegramMessage(chatId, c.message, { html: true, buttons });
        delivered = true;
      } catch (err) {
        console.error(`Telegram send failed for ${userId}:`, describeError(err));
      }
    }

    if (fcmToken && fcmConfigured()) {
      const { title, body } = pushTextFromHtml(c.message);
      if (await sendFcmPush(fcmToken, title, body, { type: c.type, tab: c.tab ?? "home" })) {
        delivered = true;
      }
    }

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
  /// Account currencies without an fx_rates row (their rows were added 1:1).
  fx_missing?: string[];
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
  // bounded-fetch: one jsonb value, not a row set — max-rows cannot truncate it (ADR-003)
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
function formatBudgetMoney(minor: number, currency: string, lang: Lang): string {
  const code = (currency || "RUB").toUpperCase();
  const whole = Math.round(Math.abs(minor) / 100);
  return `${whole.toLocaleString(localeFor(lang))} ${CURRENCY_SYMBOLS[code] ?? code}`;
}

/// «2 нояб. – 1 дек.» — the window the card shows (D4).
function formatWindow(start: string, end: string, lang: Lang): string {
  const fmt = new Intl.DateTimeFormat(localeFor(lang), { day: "numeric", month: "short", timeZone: "UTC" });
  return `${fmt.format(new Date(`${start}T00:00:00Z`))} – ${fmt.format(new Date(`${end}T00:00:00Z`))}`;
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
  // N8: without a rate for some account currency the server added those
  // rows 1:1 (500 000 ₫ as 500 000 ₽) — never alert on such a number.
  if ((m.fx_missing ?? []).length > 0) return null;
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
    `${tt("spent", lang)}: ${formatBudgetMoney(m.spent, m.currency, lang)} ${tt("of", lang)} ${formatBudgetMoney(m.effective_limit, m.currency, lang)}\n` +
    (left > 0
      ? `${tt("remaining", lang)}: ${formatBudgetMoney(left, m.currency, lang)}`
      : `${tt("overspent", lang)}: ${formatBudgetMoney(-left, m.currency, lang)}`) +
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
      const all = partnerMetrics
        .map((m) => budgetWarningFor(m, settings.budget_warning_percent ?? 80, ctx.lang))
        .filter((c): c is NotificationCandidate => c !== null);
      const candidates = await pickForDelivery(
        supabase, partnerId, all, MAX_BUDGET_ALERTS_PER_MEMBER, settings.daily_limit,
      );
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

  // Partners were already notified at the top of handleTransactionInsert.
  return candidates;
}

// ---------------------------------------------------------------------------
// Evaluator: Large Expense
// ---------------------------------------------------------------------------

/** The inserted transaction, re-read from the database (never from the request body). */
interface InsertedTx {
  id: string;
  user_id: string;
  type: string;
  amount: number | string | null;
  amount_native: number | string | null;
  category_id: string | null;
  account_id: string | null;
  transfer_group_id: string | null;
  date: string;
  account: { currency: string | null } | null;
}

const INSERTED_TX_COLUMNS =
  "id,user_id,type,amount,amount_native,category_id,account_id,transfer_group_id,date,account:accounts!transactions_account_id_fkey(currency)";

/** |amount_native| in the account's currency (ADR-001), legacy `amount` fallback. */
function nativeAmount(tx: { amount: number | string | null; amount_native: number | string | null }): number {
  const n = Number(tx.amount_native ?? tx.amount ?? 0); // allowlisted-amount: amount_native with legacy fallback
  return Number.isFinite(n) ? Math.abs(n) : 0;
}

interface MoneyContext {
  /** The user's display currency (profiles.default_currency). Thresholds are in it. */
  base: string;
  rates: Record<string, number>;
}

async function evaluateLargeExpense(
  supabase: SupabaseClient,
  tx: InsertedTx,
  threshold: number,
  lang: Lang,
  ctx: MoneyContext,
): Promise<NotificationCandidate[]> {
  const accountCurrency = (tx.account?.currency ?? "RUB").toUpperCase();
  const native = nativeAmount(tx);
  // Comparable number: every amount goes into the user's base currency
  // first — $50 and 5 000 ₽ are not "50 vs 5 000".
  const inBase = tryConvertCurrency(native, accountCurrency, ctx.base, ctx.rates);
  if (inBase === null || inBase <= 0) return [];

  let effectiveThreshold = Number(threshold) || 0;

  if (effectiveThreshold <= 0) {
    // Auto: max(mean + 2σ, 3 × mean) over the last 30 local days.
    const tz = await userTimeZone(supabase, tx.user_id);
    const since = new Date(`${localDate(new Date(), tz)}T00:00:00.000Z`);
    since.setUTCDate(since.getUTCDate() - 30);

    type RecentRow = { id: string; amount: number | null; amount_native: number | null; account: { currency: string | null } | null };
    const recent = await fetchAll<RecentRow>("large_expense.recent", () =>
      supabase
        .from("transactions")
        .select("id,amount,amount_native,account:accounts!transactions_account_id_fkey(currency)", { count: "exact" })
        .eq("user_id", tx.user_id)
        .eq("type", "expense")
        .is("transfer_group_id", null)
        .gte("date", toDateOnly(since)));

    const amounts: number[] = [];
    for (const row of recent) {
      const v = tryConvertCurrency(nativeAmount(row), (row.account?.currency ?? "RUB").toUpperCase(), ctx.base, ctx.rates);
      if (v !== null) amounts.push(v);
    }

    // Need at least 5 transactions for meaningful stats
    if (amounts.length < 5) return [];

    const mean = amounts.reduce((s, v) => s + v, 0) / amounts.length;
    const variance = amounts.reduce((s, v) => s + (v - mean) ** 2, 0) / amounts.length;
    effectiveThreshold = Math.max(mean + 2 * Math.sqrt(variance), mean * 3);
  }

  if (inBase < effectiveThreshold) return [];

  const { data: category } = tx.category_id
    ? await supabase.from("categories").select("name,icon").eq("id", tx.category_id).maybeSingle()
    : { data: null };

  const catLabel = category
    ? escapeHtml(`${category.icon ?? ""} ${category.name ?? ""}`.trim())
    : tt('other', lang);

  const approx = accountCurrency !== ctx.base.toUpperCase() ? ` (≈ ${money(inBase, ctx.base, lang)})` : "";
  const message =
    `💸 <b>${tt('largeExpense', lang)}</b>\n\n` +
    `${money(native, accountCurrency, lang)}${approx} — ${catLabel}`;

  return [{
    type: "large_expense",
    // Real transaction id from the database — one push per transaction.
    key: `large_expense:${tx.id}`,
    message,
    tab: "transactions",
  }];
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

  // bounded-fetch: the single newest row.
  const { data: lastTx } = await supabase
    .from("transactions")
    .select("date")
    .eq("user_id", userId)
    .order("date", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!lastTx) return null;

  // `date` is the user's local wall-clock time, so compare calendar days
  // in the user's zone, not instants against the server clock.
  const today = localDate(new Date(), await userTimeZone(supabase, userId));
  const daysSinceLast = Math.round(
    (Date.parse(`${today}T00:00:00Z`) - Date.parse(`${String(lastTx.date).slice(0, 10)}T00:00:00Z`)) /
      (1000 * 60 * 60 * 24),
  );

  if (daysSinceLast < 3) return null;

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

  type GoalRow = { id: string; name: string; target_amount: number; current_amount: number; icon: string; currency: string | null };
  const goals = await fetchAll<GoalRow>("savings_goals", () =>
    supabase
      .from("savings_goals")
      .select("id,name,target_amount,current_amount,icon,currency", { count: "exact" })
      .eq("user_id", userId)
      .eq("status", "active"));

  if (goals.length === 0) return candidates;

  const milestones = [25, 50, 75, 100];

  for (const goal of goals) {
    const target = Number(goal.target_amount);
    const current = Number(goal.current_amount);
    if (!(target > 0)) continue;
    const percent = (current / target) * 100;

    for (const milestone of [...milestones].reverse()) {
      if (percent >= milestone) {
        const key = `savings_milestone:${goal.id}:${milestone}`;
        const emoji = milestone >= 100 ? "🎉" : milestone >= 75 ? "🔥" : milestone >= 50 ? "💪" : "🌱";

        // The goal's own currency, not a symbol picked by language.
        const message =
          `${emoji} <b>${tt('goalHeader', lang)} «${escapeHtml(goal.name ?? "")}» — ${milestone}%!</b>\n\n` +
          `${tt('saved', lang)}: ${money(current, goal.currency, lang)} ${tt('of', lang)} ${money(target, goal.currency, lang)}` +
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
      .replace("{projected}", formatBudgetMoney(projected, m.currency, lang))
      .replace("{pct}", String(Math.round(projectedPercent)))
      .replace("{limit}", formatBudgetMoney(m.effective_limit, m.currency, lang));
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
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function handleTransactionInsert(
  supabase: SupabaseClient,
  body: Record<string, unknown>,
): Promise<Response> {
  // Only the id is taken from the request. user_id / amount / type /
  // category are re-read from the row itself (service role), so a caller
  // cannot make up a «крупная трата» for someone else (S4).
  const transactionId = typeof body.transaction_id === "string" ? body.transaction_id.trim() : "";
  if (!UUID_RE.test(transactionId)) {
    return json({ error: "Missing or invalid transaction_id" }, 400);
  }

  const { data: txRow, error: txError } = await supabase
    .from("transactions")
    .select(INSERTED_TX_COLUMNS)
    .eq("id", transactionId)
    .maybeSingle();
  if (txError) {
    console.error("transaction_insert: read failed:", txError.message);
    return json({ error: "transaction_read_failed" }, 500);
  }
  if (!txRow) {
    return json({ ok: true, skipped: true, reason: "transaction_not_found" });
  }
  const tx = txRow as unknown as InsertedTx;
  const userId = tx.user_id;
  const type = tx.type;
  const categoryId = tx.category_id ?? "";

  // Skip transfers — they are not real expenses/income
  if (tx.transfer_group_id) {
    return json({ ok: true, skipped: true, reason: 'transfer' });
  }

  // Partners in the author's shared budgets are told BEFORE the author-only
  // gates below: the author having notifications off or no delivery channel
  // must not silence the partner's 80 % / 100 % alert (B2). Dedup per
  // budget + period + threshold makes this safe to run on every expense.
  if (type === "expense") {
    try {
      await notifyBudgetPartners(supabase, userId);
    } catch (err) {
      console.error("budget partner alerts failed:", err instanceof Error ? err.message : err);
    }
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

  // Get user's delivery channels + language + display currency
  const { data: profile } = await supabase
    .from("profiles")
    .select("telegram_chat_id,fcm_token,preferred_language,default_currency")
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
    const { rates } = await getRubRates();
    const base = String((profile as { default_currency?: string | null }).default_currency || "RUB").toUpperCase();
    const largeCandidates = await evaluateLargeExpense(
      supabase,
      tx,
      Number(settings.large_expense_threshold) || 0,
      lang,
      { base, rates },
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

  // Already-sent dropped first, then priority (budget_warning >
  // large_expense > savings_milestone), then at most 2 per event and never
  // past the daily limit.
  const MAX_NOTIFICATIONS_PER_EVENT = 2;
  const limited = await pickForDelivery(
    supabase, userId, candidates, MAX_NOTIFICATIONS_PER_EVENT, settings.daily_limit,
  );
  if (limited.length === 0) {
    return json({ ok: true, candidates: candidates.length, sent: 0, reason: "already_sent_or_limit" });
  }

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
  // Get all users with at least one delivery channel (Telegram or FCM).
  // Paged (ADR-003): a bare select stops at max-rows silently.
  const users = await fetchAll<{
    id: string;
    telegram_chat_id: string | number | null;
    fcm_token: string | null;
    preferred_language: string | null;
  }>("profiles.delivery", () =>
    supabase
      .from("profiles")
      .select("id,telegram_chat_id,fcm_token,preferred_language", { count: "exact" })
      .or("telegram_chat_id.not.is.null,fcm_token.not.is.null"));

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
  // N10: every reachable profile, not the first 1000 (ADR-003).
  const profiles = await fetchAll<{ id: string; telegram_chat_id: string | number | null; fcm_token: string | null; preferred_language: string | null }>(
    "profiles(weekly_pace)",
    () => supabase.from("profiles").select("id,telegram_chat_id,fcm_token,preferred_language", { count: "exact" })
      .or("telegram_chat_id.not.is.null,fcm_token.not.is.null"),
  );

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
    const paceAll = await evaluateWeeklyPace(supabase, user.id, userLang);
    // One push per budget can exceed the daily limit; cap by what is left.
    const paceCandidates = await pickForDelivery(
      supabase, user.id, paceAll, Number.POSITIVE_INFINITY, settings.daily_limit,
    );
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

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || (!telegramConfigured() && !fcmConfigured())) {
    return json({ error: "Missing required environment variables" }, 500);
  }

  if (!(await isCronAuthorized(req))) {
    return json({ error: "Unauthorized" }, 401);
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  // Per-invocation cache; the isolate may serve many invocations.
  tzCache.clear();

  try {
    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
    const trigger = String(body.trigger ?? "");

    if (trigger === "transaction_insert") {
      return await handleTransactionInsert(supabase, body);
    }

    if (trigger === "cron_inactivity") {
      return await handleCronInactivity(supabase);
    }

    if (trigger === "cron_weekly_pace") {
      return await handleCronWeeklyPace(supabase);
    }

    return json({ error: "Unknown trigger" }, 400);
  } catch (err) {
    console.error("Smart notifications failed:", describeError(err));
    return json({ error: "smart_notifications_failed" }, 500);
  }
});
