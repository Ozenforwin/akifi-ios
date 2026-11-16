import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";
import { formatMoney, toDateOnly } from "../_shared/utils.ts";
import { isCronAuthorized } from "../_shared/auth.ts";
import { fetchAll } from "../_shared/paging.ts";
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
async function isRateLimited(
  supabase: SupabaseClient,
  userId: string,
  dailyLimit: number,
): Promise<boolean> {
  const todayStart = startOfLocalDayUtc(new Date(), await userTimeZone(supabase, userId));

  const { count } = await supabase
    .from("notification_log")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .gte("sent_at", todayStart.toISOString());

  return (count ?? 0) >= dailyLimit;
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
// Evaluator: Budget Warning
// ---------------------------------------------------------------------------
interface BudgetRow {
  id: string;
  user_id: string;
  category_ids: string[];
  amount: number;
  period_type: string;
  alert_thresholds: number[] | null;
  custom_start_date: string | null;
  custom_end_date: string | null;
  is_active: boolean;
}

async function evaluateBudgetWarning(
  supabase: SupabaseClient,
  userId: string,
  categoryId: string,
  warningPercent: number,
  lang: Lang = 'ru',
): Promise<NotificationCandidate[]> {
  const candidates: NotificationCandidate[] = [];

  // Find active budgets that contain this category
  const { data: budgets } = await supabase
    .from("budgets")
    .select(
      "id,user_id,category_ids,amount,period_type,alert_thresholds,custom_start_date,custom_end_date,is_active",
    )
    .eq("user_id", userId)
    .eq("is_active", true);

  if (!budgets || budgets.length === 0) return candidates;

  const now = new Date();

  for (const budget of budgets as BudgetRow[]) {
    // Check if budget contains this category
    if (
      !budget.category_ids ||
      !budget.category_ids.includes(categoryId)
    )
      continue;

    const thresholds = budget.alert_thresholds ?? [warningPercent, 100];
    const period = resolvePeriodWindow(
      budget.period_type ?? "monthly",
      now,
      budget.custom_start_date,
      budget.custom_end_date,
    );
    const periodStart = toDateOnly(period.start);
    const periodEnd = toDateOnly(period.end);

    // Calculate spent in current period — ADR-001: prefer amount_native
    // so multi-currency rows sum in the account's own currency rather than
    // the raw foreign value.
    const { data: txRows } = await supabase
      .from("transactions")
      .select("amount,amount_native")
      .eq("user_id", userId)
      .eq("type", "expense")
      .is("transfer_group_id", null)
      .in("category_id", budget.category_ids)
      .gte("date", periodStart)
      .lt("date", periodEnd);

    const spent = (txRows ?? []).reduce(
      (sum: number, t: { amount: number; amount_native?: number }) => sum + (t.amount_native ?? t.amount), // allowlisted-amount: read amount_native with legacy fallback
      0,
    );
    const percent = budget.amount > 0 ? (spent / budget.amount) * 100 : 0;

    // Check thresholds (descending) — pick the highest crossed
    const sortedThresholds = [...thresholds].sort((a, b) => b - a);
    for (const threshold of sortedThresholds) {
      if (percent >= threshold) {
        const key = `budget_warning:${budget.id}:${periodStart}:${threshold}`;

        let emoji = "⚠️";
        if (threshold >= 120) emoji = "🚨";
        else if (threshold >= 100) emoji = "🔴";

        const remaining = budget.amount - spent;
        const sym = currencySymbol(lang);
        const coachingTip = threshold >= 100
          ? '\n\n' + tt('tip5030', lang)
          : threshold >= 80
          ? '\n\n' + tt('tipImpulse', lang)
          : '';
        const message =
          `${emoji} <b>${tt('budgetHeader', lang)} ${threshold}%</b>\n\n` +
          `${tt('spent', lang)}: ${formatRub(spent)} ${sym} ${tt('of', lang)} ${formatRub(budget.amount)} ${sym}\n` +
          (remaining > 0
            ? `${tt('remaining', lang)}: ${formatRub(remaining)} ${sym}`
            : `${tt('overspent', lang)}: ${formatRub(Math.abs(remaining))} ${sym}`) +
          coachingTip;

        candidates.push({
          type: "budget_warning",
          key,
          message,
          tab: "budget",
        });
        break; // Only one notification per budget per transaction
      }
    }
  }

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
async function evaluateWeeklyPace(
  supabase: SupabaseClient,
  userId: string,
  lang: Lang = 'ru',
): Promise<NotificationCandidate[]> {
  const candidates: NotificationCandidate[] = [];
  const now = new Date();

  // Only run on Wednesdays
  if (now.getDay() !== 3) return candidates;

  const { data: budgets } = await supabase
    .from("budgets")
    .select("id,amount,category_ids,period_type,custom_start_date,custom_end_date,is_active")
    .eq("user_id", userId)
    .eq("is_active", true);

  if (!budgets || budgets.length === 0) return candidates;

  for (const budget of budgets as BudgetRow[]) {
    const period = resolvePeriodWindow(
      budget.period_type ?? "monthly",
      now,
      budget.custom_start_date,
      budget.custom_end_date,
    );

    const periodStart = toDateOnly(period.start);
    const periodEnd = toDateOnly(period.end);
    const totalDays = Math.max(1, (period.end.getTime() - period.start.getTime()) / (1000 * 60 * 60 * 24));
    const daysPassed = Math.max(1, (now.getTime() - period.start.getTime()) / (1000 * 60 * 60 * 24));

    const { data: txRows } = await supabase
      .from("transactions")
      .select("amount,amount_native")
      .eq("user_id", userId)
      .eq("type", "expense")
      .is("transfer_group_id", null)
      .in("category_id", budget.category_ids)
      .gte("date", periodStart)
      .lt("date", periodEnd);

    const spent = (txRows ?? []).reduce(
      (sum: number, t: { amount: number; amount_native?: number }) => sum + (t.amount_native ?? t.amount), // allowlisted-amount: budget projection prefers amount_native
      0,
    );

    // Project to end of period
    const dailyPace = spent / daysPassed;
    const projected = dailyPace * totalDays;
    const projectedPercent = budget.amount > 0 ? (projected / budget.amount) * 100 : 0;

    if (projectedPercent > 120) {
      // Week start for dedup key
      const weekDay = now.getDay();
      const weekDiff = weekDay === 0 ? 6 : weekDay - 1;
      const weekStart = new Date(now);
      weekStart.setDate(weekStart.getDate() - weekDiff);
      const weekStartStr = toDateOnly(weekStart);

      const key = `weekly_pace:${budget.id}:${weekStartStr}`;

      const sym = currencySymbol(lang);
      const message =
        `📊 <b>${tt('paceHeader', lang)}</b>\n\n` +
        tt('paceBody', lang, {
          projected: formatRub(projected),
          pct: Math.round(projectedPercent),
          limit: formatRub(budget.amount),
          sym,
        });

      candidates.push({
        type: "weekly_pace",
        key,
        message,
        tab: "budget",
      });
    }
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
