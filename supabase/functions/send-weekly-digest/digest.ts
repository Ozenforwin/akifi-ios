// Pure digest builder for send-weekly-digest (kept separate so it can be
// unit-tested without starting the HTTP server).
import { formatMoney } from "../_shared/utils.ts";
import { tryConvertCurrency } from "../_shared/currency.ts";
import { escapeHtml } from "../_shared/notify.ts";

export const DIGEST_DAYS = 7;

export interface DigestTx {
  id: string;
  user_id: string;
  type: "income" | "expense" | string;
  amount: number | string | null;
  amount_native: number | string | null;
  category_id: string | null;
  date: string;
  account: { currency: string | null } | null;
}

export interface CategoryRow {
  id: string;
  name: string;
  icon: string | null;
}

// ---------------------------------------------------------------------------
// i18n
// ---------------------------------------------------------------------------
export type Lang = 'ru' | 'en' | 'es';

export function normalizeLang(value: unknown): Lang {
  if (typeof value !== 'string') return 'ru';
  const prefix = value.toLowerCase().split(/[-_]/)[0];
  if (prefix === 'en' || prefix === 'es' || prefix === 'ru') return prefix;
  return 'ru';
}

export const digestI18n: Record<string, Record<Lang, string>> = {
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
  unconverted: {
    ru: "Не учтено операций без курса валюты: {n}",
    en: "Transactions skipped (no exchange rate): {n}",
    es: "Operaciones omitidas (sin tipo de cambio): {n}",
  },
};

// ---------------------------------------------------------------------------
// Digest builder (pure — exported for tests)
// ---------------------------------------------------------------------------
export function buildDigest(
  userTransactions: DigestTx[],
  categoryMap: Map<string, CategoryRow>,
  lang: Lang,
  displayCurrency: string,
  rates: Record<string, number>,
): string | null {
  if (userTransactions.length === 0) return null;

  const base = (displayCurrency || "RUB").toUpperCase();
  let totalIncome = 0;
  let totalExpense = 0;
  let unconverted = 0;
  const catExpense = new Map<string, number>();

  for (const tx of userTransactions) {
    // ADR-001: amount_native is in the ACCOUNT's currency; convert it to
    // the display currency before summing across accounts.
    const native = Math.abs(Number(tx.amount_native ?? tx.amount ?? 0)); // allowlisted-amount: amount_native with legacy fallback
    if (!Number.isFinite(native) || native === 0) continue;
    const amt = tryConvertCurrency(native, (tx.account?.currency ?? "RUB").toUpperCase(), base, rates);
    if (amt === null) {
      unconverted += 1;
      continue;
    }
    if (tx.type === "income") {
      totalIncome += amt;
    } else if (tx.type === "expense") {
      totalExpense += amt;
      const key = tx.category_id ?? "";
      catExpense.set(key, (catExpense.get(key) ?? 0) + amt);
    }
  }

  const txCount = userTransactions.length;
  const net = totalIncome - totalExpense;
  const t = (key: string) => digestI18n[key][lang];
  const fmt = (v: number) => formatMoney(v, base, lang);

  const topCategories = [...catExpense.entries()]
    .sort(([, a], [, b]) => b - a)
    .slice(0, 3)
    .map(([catId, amount]) => {
      const cat = categoryMap.get(catId);
      const name = cat ? escapeHtml(`${cat.icon ?? ""} ${cat.name}`.trim()) : t('other');
      return `  ${name}: ${fmt(amount)}`;
    });

  const lines: string[] = [
    t('header'),
    "",
    `${t('transactions')}: ${txCount}`,
    `${t('income')}: +${fmt(totalIncome)}`,
    `${t('expense')}: -${fmt(totalExpense)}`,
    `${t('balance')}: ${net >= 0 ? "+" : "-"}${fmt(Math.abs(net))}`,
  ];

  if (topCategories.length > 0) {
    lines.push("", t('topExpenses'));
    lines.push(...topCategories);
  }

  if (totalExpense > 0) {
    lines.push("", `${t('dailyAvg')}: ${fmt(totalExpense / DIGEST_DAYS)}${t('perDay')}`);
  }

  if (unconverted > 0) {
    lines.push("", digestI18n.unconverted[lang].replace("{n}", String(unconverted)));
  }

  lines.push("", t('closing'));

  return lines.join("\n");
}
