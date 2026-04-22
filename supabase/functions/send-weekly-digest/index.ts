import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.95.3";
import { toDateOnly } from "../_shared/utils.ts";

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const TELEGRAM_BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
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
  const bearer = (req.headers.get("authorization") ?? "")
    .replace(/^Bearer\s+/i, "")
    .trim();
  const cronHeader = (req.headers.get("x-cron-secret") ?? "").trim();
  if (CRON_SECRET && (bearer === CRON_SECRET || cronHeader === CRON_SECRET))
    return true;
  if (bearer) return true;
  return false;
}

// toDateOnly — imported from _shared/utils.ts

function plural(n: number, one: string, few: string, many: string): string {
  const abs = Math.abs(n) % 100;
  const lastDigit = abs % 10;
  if (abs >= 11 && abs <= 19) return many;
  if (lastDigit === 1) return one;
  if (lastDigit >= 2 && lastDigit <= 4) return few;
  return many;
}

function formatAmount(amount: number): string {
  return Math.round(amount).toLocaleString("ru-RU");
}

// ---------------------------------------------------------------------------
// Telegram
// ---------------------------------------------------------------------------
async function sendTelegramMessage(
  chatId: string | number,
  text: string,
): Promise<void> {
  const res = await fetch(
    `https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: chatId,
        text,
        parse_mode: "HTML",
        disable_web_page_preview: true,
      }),
    },
  );
  const payload = await res.json().catch(() => null);
  if (!res.ok || !payload?.ok) {
    throw new Error(
      `Telegram API failed (${res.status}): ${JSON.stringify(payload)}`,
    );
  }
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
// Types
// ---------------------------------------------------------------------------
interface UserRow {
  id: string;
  telegram_chat_id: string | number | null;
  fcm_token: string | null;
}

interface SettingsRow {
  user_id: string;
  digest_opt_in: boolean;
  quiet_hours_start: number | null;
}

interface TransactionRow {
  user_id: string;
  type: "income" | "expense";
  amount: number;
  amount_native?: number;
  category_id: string;
  date: string;
}

interface CategoryRow {
  id: string;
  name: string;
  icon: string;
}

// ---------------------------------------------------------------------------
// i18n
// ---------------------------------------------------------------------------
type Lang = 'ru' | 'en' | 'es';

function normalizeLang(value: unknown): Lang {
  if (typeof value !== 'string') return 'ru';
  const prefix = value.toLowerCase().split(/[-_]/)[0];
  if (prefix === 'en' || prefix === 'es' || prefix === 'ru') return prefix;
  return 'ru';
}

const digestI18n: Record<string, Record<Lang, string>> = {
  pushTitle: {
    ru: "Еженедельная сводка",
    en: "Weekly digest",
    es: "Resumen semanal",
  },
  header: {
    ru: "📊 <b>Еженедельная сводка</b>",
    en: "📊 <b>Weekly digest</b>",
    es: "📊 <b>Resumen semanal</b>",
  },
  transactions: { ru: "Операций", en: "Transactions", es: "Operaciones" },
  income: { ru: "Доходы", en: "Income", es: "Ingresos" },
  expense: { ru: "Расходы", en: "Expense", es: "Gastos" },
  balance: { ru: "Баланс", en: "Balance", es: "Balance" },
  topExpenses: { ru: "Топ расходов:", en: "Top expenses:", es: "Mayores gastos:" },
  dailyAvg: { ru: "Среднедневной расход", en: "Daily average", es: "Promedio diario" },
  perDay: { ru: "/день", en: "/day", es: "/día" },
  closing: { ru: "Хорошей недели! 💪", en: "Have a great week! 💪", es: "¡Buena semana! 💪" },
  other: { ru: "Другое", en: "Other", es: "Otro" },
};

function currencySymbol(lang: Lang): string {
  return lang === 'ru' ? '₽' : lang === 'es' ? '€' : '$';
}

// ---------------------------------------------------------------------------
// Digest builder
// ---------------------------------------------------------------------------
function buildDigest(
  userTransactions: TransactionRow[],
  categoryMap: Map<string, CategoryRow>,
  lang: Lang = 'ru',
): string | null {
  if (userTransactions.length === 0) return null;

  let totalIncome = 0;
  let totalExpense = 0;
  const catExpense = new Map<string, number>();

  for (const tx of userTransactions) {
    // ADR-001: use amount_native when present (canonical in account
    // currency). Single-currency digests are unaffected; multi-currency
    // users will still see partial numbers until the digest is upgraded
    // to accept per-user fx rates — tracked in Phase 5 follow-up.
    const amt = tx.amount_native ?? tx.amount; // allowlisted-amount: digest reads amount_native with legacy fallback per ADR-001
    if (tx.type === "income") {
      totalIncome += amt;
    } else {
      totalExpense += amt;
      catExpense.set(
        tx.category_id,
        (catExpense.get(tx.category_id) ?? 0) + amt,
      );
    }
  }

  const txCount = userTransactions.length;
  const net = totalIncome - totalExpense;
  const t = (key: string) => digestI18n[key][lang];
  const sym = currencySymbol(lang);

  const topCategories = [...catExpense.entries()]
    .sort(([, a], [, b]) => b - a)
    .slice(0, 3)
    .map(([catId, amount]) => {
      const cat = categoryMap.get(catId);
      const name = cat ? `${cat.icon} ${cat.name}` : t('other');
      return `  ${name}: ${formatAmount(amount)} ${sym}`;
    });

  const lines: string[] = [
    t('header'),
    "",
    `${t('transactions')}: ${txCount}`,
    `${t('income')}: +${formatAmount(totalIncome)} ${sym}`,
    `${t('expense')}: -${formatAmount(totalExpense)} ${sym}`,
    `${t('balance')}: ${net >= 0 ? "+" : ""}${formatAmount(net)} ${sym}`,
  ];

  if (topCategories.length > 0) {
    lines.push("", t('topExpenses'));
    lines.push(...topCategories);
  }

  if (totalExpense > 0) {
    const dailyAvg = totalExpense / 7;
    lines.push("", `${t('dailyAvg')}: ${formatAmount(dailyAvg)} ${sym}${t('perDay')}`);
  }

  lines.push("", t('closing'));

  return lines.join("\n");
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
    // 1. Get users with at least one delivery channel (Telegram or FCM)
    const { data: profiles, error: profilesError } = await supabase
      .from("profiles")
      .select("id,telegram_chat_id,fcm_token,preferred_language")
      .or("telegram_chat_id.not.is.null,fcm_token.not.is.null");

    if (profilesError) throw profilesError;

    const users = (profiles ?? []) as UserRow[];
    if (users.length === 0) {
      return json({ ok: true, sent: 0, message: "No users with delivery channels" });
    }

    // 2. Get opt-in settings
    const { data: settingsRows } = await supabase
      .from("ai_user_settings")
      .select("user_id,digest_opt_in,quiet_hours_start");

    const settingsMap = new Map<string, SettingsRow>();
    for (const row of (settingsRows ?? []) as SettingsRow[]) {
      settingsMap.set(row.user_id, row);
    }

    // 3. Filter users who opted in (default = true)
    const eligibleUsers = users.filter((u) => {
      const settings = settingsMap.get(u.id);
      return settings ? settings.digest_opt_in : true;
    });

    if (eligibleUsers.length === 0) {
      return json({ ok: true, sent: 0, message: "All users opted out" });
    }

    // 4. Get last 7 days of transactions
    const now = new Date();
    const weekAgo = new Date(now);
    weekAgo.setDate(weekAgo.getDate() - 7);
    const fromDate = toDateOnly(weekAgo);

    const userIds = eligibleUsers.map((u) => u.id);

    const { data: txRows, error: txError } = await supabase
      .from("transactions")
      .select("user_id,type,amount,amount_native,category_id,date")
      .in("user_id", userIds)
      .gte("date", fromDate)
      .is("transfer_group_id", null)
      .order("date", { ascending: false });

    if (txError) throw txError;
    const transactions = (txRows ?? []) as TransactionRow[];

    // 5. Get categories
    const { data: catRows } = await supabase
      .from("categories")
      .select("id,name,icon");

    const categoryMap = new Map<string, CategoryRow>();
    for (const c of (catRows ?? []) as CategoryRow[]) {
      categoryMap.set(c.id, c);
    }

    // 6. Group transactions by user
    const txByUser = new Map<string, TransactionRow[]>();
    for (const tx of transactions) {
      const arr = txByUser.get(tx.user_id) ?? [];
      arr.push(tx);
      txByUser.set(tx.user_id, arr);
    }

    // 7. Send digests
    let sent = 0;
    let errors = 0;

    for (const user of eligibleUsers) {
      const userTx = txByUser.get(user.id) ?? [];
      const userLang = normalizeLang((user as { preferred_language?: unknown }).preferred_language);
      const digest = buildDigest(userTx, categoryMap, userLang);
      if (!digest) continue;

      let delivered = false;

      // Send via Telegram (if user has chat_id)
      if (user.telegram_chat_id) {
        try {
          await sendTelegramMessage(user.telegram_chat_id, digest);
          delivered = true;
        } catch (err) {
          console.error(`Telegram digest failed for ${user.id}:`, err);
        }
      }

      // Send via FCM (if user has iOS token)
      if (user.fcm_token) {
        try {
          const plainText = digest.replace(/<[^>]+>/g, "");
          const title = digestI18n.pushTitle[userLang];
          const body = plainText.substring(0, 200);
          const fcmOk = await sendFCMPush(user.fcm_token, title, body, { type: "weekly_digest", tab: "home" });
          if (fcmOk) delivered = true;
        } catch (err) {
          console.error(`FCM digest failed for ${user.id}:`, err);
        }
      }

      if (delivered) {
        sent++;
      } else {
        errors++;
      }
    }

    return json({ ok: true, sent, errors, eligible: eligibleUsers.length });
  } catch (err) {
    console.error("Weekly digest failed:", err);
    return json({ error: String(err) }, 500);
  }
});
