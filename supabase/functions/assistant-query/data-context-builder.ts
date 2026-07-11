/**
 * data-context-builder.ts
 *
 * Prepares structured financial data context for LLM analysis.
 * Converts raw transactions into a compact, token-efficient format
 * that GPT-4o can analyze meaningfully.
 */

import type {
  TxRow,
  PeriodWindow,
  CategoryRow,
  AccountRow,
  BudgetRow,
  ConversationMessage,
  AiTone,
} from './types.ts';
import {
  inWindow,
  safeNumber,
  formatMoney,
  formatMoneyIn,
  periodLabel,
} from './utils.ts';

// ── Intent-specific configuration ──

interface DataContextConfig {
  includeRawTx: boolean;
  maxTx: number;
  includeMerchants: boolean;
  previousPeriod: boolean;
  budgets: boolean;
  savingsGoals: boolean;
}

const DEFAULT_CONFIG: DataContextConfig = {
  includeRawTx: false,
  maxTx: 30,
  includeMerchants: false,
  previousPeriod: false,
  budgets: false,
  savingsGoals: false,
};

const INTENT_CONFIGS: Record<string, Partial<DataContextConfig>> = {
  'spend_summary':         {},
  'top_categories':        {},
  'top_expenses':          { includeRawTx: true, maxTx: 15, includeMerchants: true },
  'trend_compare':         { previousPeriod: true },
  'by_category':           { includeRawTx: true, maxTx: 50, includeMerchants: true },
  'by_account':            { includeRawTx: true, maxTx: 50, includeMerchants: true },
  'budget_remaining':      { budgets: true },
  'budget_risk':           { budgets: true, previousPeriod: true },
  'average_check':         { includeRawTx: true, maxTx: 20 },
  'forecast':              { previousPeriod: true },
  'anomalies':             { includeRawTx: true, maxTx: 30, includeMerchants: true, previousPeriod: true },
  'seasonal_forecast':     { previousPeriod: true },
  'recurring_patterns':    { includeRawTx: true, maxTx: 50, includeMerchants: true },
  'smart_budget_create':   { budgets: true },
  'spending_optimization': { includeRawTx: true, maxTx: 30, includeMerchants: true, previousPeriod: true },
  'savings_advice':        { savingsGoals: true },
};

function getConfig(intent: string): DataContextConfig {
  return { ...DEFAULT_CONFIG, ...(INTENT_CONFIGS[intent] ?? {}) };
}

// ── Main builder ──

export interface SubscriptionRow {
  service_name: string;
  amount: number;
  currency: string | null;
  billing_period: string | null;
  status: string;
}

export interface DataContextInput {
  intent: string;
  period: string;
  customDays?: number;
  entity?: string;
  transactions: TxRow[];
  currentWindow: PeriodWindow;
  previousWindow: PeriodWindow;
  categories?: CategoryRow[];
  accounts?: AccountRow[];
  budgets?: BudgetRow[];
  savingsGoals?: Array<{ name: string; target_amount: number; current_amount: number; deadline: string | null; status: string }>;
  subscriptions?: SubscriptionRow[];
  /// Caller's user id — lets the context split shared-account activity
  /// into «ваши» vs «партнёра» instead of silently merging both.
  currentUserId?: string;
  /// user_id → display name for co-members of shared accounts.
  memberNames?: Record<string, string>;
  /// FX-converted sum of all account balances in base currency, computed
  /// by the caller (who owns the fx rates). The LLM must not add USD to
  /// RUB itself — it did, and produced a 5× understated net worth.
  accountsTotalBase?: number;
}

export function buildDataContext(input: DataContextInput): string {
  const config = getConfig(input.intent);
  const parts: string[] = [];

  // ALL non-transfer transactions (full lookback, not just current window)
  const allTxs = input.transactions.filter((tx) => !tx.transfer_group_id);

  // Current window transactions for summary
  const currentTxs = allTxs.filter((tx) => inWindow(tx.date, input.currentWindow));

  // ── Tier 1: Summary for current window ──
  parts.push(buildSummary(currentTxs, input.currentWindow, input.period, input.customDays));

  // ── Tier 1a: Per-member split on shared accounts ──
  // Totals include partner activity on shared accounts; without this
  // line «сколько потратила Оля» got answered with the OVERALL total.
  if (input.currentUserId) {
    parts.push(buildMemberSplit(currentTxs, input.currentUserId, input.memberNames));
  }

  // ── Tier 1b: Account context (always included — small and critical for filtering) ──
  if (input.accounts?.length) {
    parts.push(buildAccountContext(input.accounts, allTxs, input.currentWindow, input.accountsTotalBase));
  }

  // ── Tier 2: Category breakdown for current window ──
  parts.push(buildCategoryBreakdown(currentTxs, input.categories));

  // ── Tier 3: Raw transactions — search ALL loaded data, not just current window ──
  // This allows LLM to answer questions about any date range mentioned by the user
  if (config.includeRawTx) {
    let filtered = filterByEntity(allTxs, input.entity, input.categories, config.includeMerchants);
    // «Самая большая трата» needs the LARGEST rows in view — recency
    // order hid an April rent payment behind 15 recent coffees.
    if (input.intent === 'top_expenses') {
      filtered = [...filtered].sort((a, b) =>
        safeNumber(b.amount_in_base ?? b.amount_native ?? b.amount)
        - safeNumber(a.amount_in_base ?? a.amount_native ?? a.amount));
    }
    const limited = filtered.slice(0, config.maxTx);
    if (limited.length > 0) {
      parts.push(buildRawTransactions(limited, input.entity, filtered.length));
    }
  }

  // ── Tier 4: Previous period comparison ──
  if (config.previousPeriod) {
    const prevTxs = allTxs.filter((tx) => inWindow(tx.date, input.previousWindow));
    parts.push(buildPreviousPeriodSummary(prevTxs, input.previousWindow));
  }

  // ── Tier 4: Budgets ──
  if (config.budgets && input.budgets?.length) {
    parts.push(buildBudgetContext(input.budgets, currentTxs, input.categories));
  }

  // ── Tier 4: Savings goals ──
  if (config.savingsGoals && input.savingsGoals?.length) {
    parts.push(buildSavingsContext(input.savingsGoals));
  }

  // ── Tier 4: Subscription tracker (source of truth for «мои подписки») ──
  if (input.subscriptions?.length) {
    parts.push(buildSubscriptionsContext(input.subscriptions));
  }

  // ── Data range note for LLM ──
  if (allTxs.length > 0) {
    const dates = allTxs.map((tx) => tx.date.slice(0, 10)).sort();
    parts.push(`Доступные данные: с ${dates[0]} по ${dates[dates.length - 1]} (${allTxs.length} операций без переводов)`);
  } else {
    // No rows loaded at all (e.g. the user asked about a future year) —
    // say so explicitly, or the LLM praises «zero spending».
    parts.push(`Доступные данные: в диапазоне ${input.currentWindow.start} — ${input.currentWindow.end} операций НЕТ. Если запрошенный период в будущем или вне истории пользователя — скажи об этом прямо, не выдумывай выводы из нулей.`);
  }

  return parts.filter(Boolean).join('\n\n');
}

// ── Tier 1: Summary ──

function buildSummary(txs: TxRow[], window: PeriodWindow, period: string, customDays?: number): string {
  const expenses = txs.filter((tx) => tx.type === 'expense');
  const income = txs.filter((tx) => tx.type === 'income');

  const totalExpense = expenses.reduce((s, tx) => s + safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount), 0);
  const totalIncome = income.reduce((s, tx) => s + safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount), 0);
  const net = totalIncome - totalExpense;

  const days = daysBetween(window.start, window.end);
  const dailyAvg = days > 0 ? Math.round(totalExpense / days) : 0;

  return [
    `=== ДАННЫЕ ПОЛЬЗОВАТЕЛЯ ===`,
    `Период: ${window.start} — ${window.end} (${periodLabel(period, customDays)})`,
    `Расходы: ${formatMoney(totalExpense)} (${expenses.length} операций)`,
    `Доходы: ${formatMoney(totalIncome)} (${income.length} операций)`,
    `Баланс: ${net >= 0 ? '+' : ''}${formatMoney(net)}`,
    dailyAvg > 0 ? `Средний расход в день: ${formatMoney(dailyAvg)}` : '',
  ].filter(Boolean).join('\n');
}

// ── Tier 1a: Per-member split (shared accounts) ──

function buildMemberSplit(
  txs: TxRow[],
  currentUserId: string,
  memberNames?: Record<string, string>,
): string {
  const partner = txs.filter((tx) => tx.user_id && tx.user_id !== currentUserId);
  if (partner.length === 0) return '';

  const own = txs.filter((tx) => !tx.user_id || tx.user_id === currentUserId);
  const sum = (rows: TxRow[], type: 'income' | 'expense') =>
    rows.filter((tx) => tx.type === type)
      .reduce((s, tx) => s + safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount), 0);

  const byUser = new Map<string, TxRow[]>();
  for (const tx of partner) {
    const uid = tx.user_id as string;
    byUser.set(uid, [...(byUser.get(uid) ?? []), tx]);
  }
  const partnerLines = [...byUser.entries()].map(([uid, rows]) => {
    const name = memberNames?.[uid] ?? 'Партнёр';
    return `  ${name} (операции на общих счетах): расходы ${formatMoney(sum(rows, 'expense'))} (${rows.filter((t) => t.type === 'expense').length} оп.), доходы ${formatMoney(sum(rows, 'income'))}`;
  });

  return [
    'Разбивка по участникам (общие счета входят в итоги выше):',
    `  Ваши операции: расходы ${formatMoney(sum(own, 'expense'))} (${own.filter((t) => t.type === 'expense').length} оп.), доходы ${formatMoney(sum(own, 'income'))}`,
    ...partnerLines,
    '  Вопрос о тратах конкретного человека — отвечай этой разбивкой, а не транзакциями, где имя встречается в описании.',
  ].join('\n');
}

// ── Tier 4: Subscription tracker ──

function buildSubscriptionsContext(subs: SubscriptionRow[]): string {
  const lines = subs.map((s) => {
    const cur = (s.currency ?? 'RUB').toUpperCase();
    const period = s.billing_period === 'yearly' ? 'год' : s.billing_period === 'weekly' ? 'нед' : 'мес';
    return `  ${s.service_name}: ${s.amount} ${cur}/${period}`;
  });
  return `Активные подписки из трекера (${subs.length}):\n${lines.join('\n')}`;
}

// ── Tier 2: Category Breakdown ──

function buildCategoryBreakdown(txs: TxRow[], categories?: CategoryRow[]): string {
  const expenses = txs.filter((tx) => tx.type === 'expense');
  const totalExpense = expenses.reduce((s, tx) => s + safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount), 0);
  if (totalExpense <= 0) return '';

  const catMap = new Map<string, { name: string; amount: number; count: number }>();
  for (const tx of expenses) {
    const catName = resolveCategoryName(tx, categories);
    const entry = catMap.get(catName) ?? { name: catName, amount: 0, count: 0 };
    entry.amount += safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount);
    entry.count += 1;
    catMap.set(catName, entry);
  }

  const sorted = [...catMap.values()].sort((a, b) => b.amount - a.amount);
  const lines = sorted.slice(0, 12).map((c, i) => {
    const pct = Math.round((c.amount / totalExpense) * 100);
    return `${i + 1}. ${c.name}: ${formatMoney(c.amount)} (${pct}%, ${c.count} оп.)`;
  });

  return `Категории расходов:\n${lines.join('\n')}`;
}

// ── Tier 3: Raw Transactions ──

function filterByEntity(
  txs: TxRow[],
  entity: string | undefined,
  categories: CategoryRow[] | undefined,
  includeMerchants: boolean,
): TxRow[] {
  if (!entity) return txs.filter((tx) => tx.type === 'expense');

  const needle = entity.toLowerCase().trim();

  return txs.filter((tx) => {
    const catName = resolveCategoryName(tx, categories).toLowerCase();
    if (catName.includes(needle)) return true;

    if (includeMerchants) {
      const merchant = (tx.merchant_name ?? tx.merchant_normalized ?? '').toLowerCase();
      if (merchant.includes(needle)) return true;
    }

    // User-typed descriptions carry entities that never became a
    // category — «Байк июль» sits in Транспорт, so a «на байк» query
    // found nothing by category or merchant alone.
    const descr = (tx.description ?? '').toLowerCase();
    if (descr.includes(needle)) return true;

    return false;
  });
}

function buildRawTransactions(txs: TxRow[], entity: string | undefined, totalFound: number): string {
  const header = entity
    ? `Транзакции по "${entity}" (${totalFound} найдено, показано ${txs.length}):`
    : `Транзакции (${txs.length}):`;

  const rows = txs.map((tx) => {
    const date = tx.date.slice(5); // MM-DD
    const amount = formatMoney(safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount));
    const merchant = tx.merchant_name ?? tx.merchant_normalized ?? '';
    const cat = tx.category?.name ?? '';
    const parts = [date, amount, tx.type === 'income' ? '+' : '-'];
    if (merchant) parts.push(merchant);
    if (cat && cat !== merchant) parts.push(`[${cat}]`);
    return parts.join(' | ');
  });

  return `${header}\n${rows.join('\n')}`;
}

// ── Tier 4: Previous Period ──

function buildPreviousPeriodSummary(txs: TxRow[], window: PeriodWindow): string {
  const expenses = txs.filter((tx) => tx.type === 'expense');
  const income = txs.filter((tx) => tx.type === 'income');

  const totalExpense = expenses.reduce((s, tx) => s + safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount), 0);
  const totalIncome = income.reduce((s, tx) => s + safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount), 0);

  const catMap = new Map<string, number>();
  for (const tx of expenses) {
    const catName = tx.category?.name?.trim() || 'Другое';
    catMap.set(catName, (catMap.get(catName) ?? 0) + safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount));
  }

  const sorted = [...catMap.entries()].sort((a, b) => b[1] - a[1]);
  const topCats = sorted.slice(0, 8).map(([name, amount]) => `  ${name}: ${formatMoney(amount)}`);

  return [
    `Предыдущий период (${window.start} — ${window.end}):`,
    `Расходы: ${formatMoney(totalExpense)} (${expenses.length} оп.)`,
    `Доходы: ${formatMoney(totalIncome)} (${income.length} оп.)`,
    topCats.length > 0 ? `Категории:\n${topCats.join('\n')}` : '',
  ].filter(Boolean).join('\n');
}

// ── Tier 4: Budgets ──

function buildBudgetContext(
  budgets: BudgetRow[],
  currentTxs: TxRow[],
  categories?: CategoryRow[],
): string {
  if (!budgets.length) return '';

  const lines = budgets.filter((b) => b.is_active).map((b) => {
    const catNames = b.category_ids
      .map((cid) => categories?.find((c) => c.id === cid)?.name ?? cid)
      .join(', ');

    const spent = currentTxs
      .filter((tx) => tx.type === 'expense' && b.category_ids.includes(tx.category_id))
      .reduce((s, tx) => s + safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount), 0);

    // Budget limits are denominated in the budget's own currency (may be
    // VND/USD) — spent is in base. Label each with its real currency and
    // skip the % when they differ, a VND/RUB ratio is meaningless.
    const sameCurrency = !b.currency || b.currency.toUpperCase() === 'RUB';
    const pct = sameCurrency && b.amount > 0 ? ` (${Math.round((spent / b.amount) * 100)}%)` : '';
    const label = b.name ? `${b.name} [${catNames}]` : catNames;

    return `  ${label}: потрачено ${formatMoney(spent)}, лимит ${formatMoneyIn(b.amount, b.currency)}${pct}`;
  });

  return `Бюджеты (включая общие с партнёром):\n${lines.join('\n')}`;
}

// ── Tier 4: Savings ──

function buildSavingsContext(
  goals: Array<{ name: string; target_amount: number; current_amount: number; deadline: string | null; status: string }>,
): string {
  const lines = goals.map((g) => {
    const pct = g.target_amount > 0 ? Math.round((g.current_amount / g.target_amount) * 100) : 0;
    const deadline = g.deadline ? `, дедлайн: ${g.deadline}` : '';
    return `  ${g.name}: ${formatMoney(g.current_amount)} / ${formatMoney(g.target_amount)} (${pct}%${deadline})`;
  });

  return `Цели накоплений:\n${lines.join('\n')}`;
}

// ── Account Context ──

function buildAccountContext(
  accounts: AccountRow[],
  allTxs: TxRow[],
  currentWindow: PeriodWindow,
  accountsTotalBase?: number,
): string {
  if (!accounts.length) return '';

  const currentTxs = allTxs.filter((tx) => inWindow(tx.date, currentWindow));

  const lines = accounts.map((acc, i) => {
    const accTxs = currentTxs.filter((tx) => tx.account_id === acc.id);
    const expenses = accTxs
      .filter((tx) => tx.type === 'expense')
      .reduce((s, tx) => s + safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount), 0);
    const income = accTxs
      .filter((tx) => tx.type === 'income')
      .reduce((s, tx) => s + safeNumber(tx.amount_in_base ?? tx.amount_native ?? tx.amount), 0);
    const txCount = accTxs.length;

    const sharedTag = acc.is_shared
      ? acc.member_role === 'viewer' ? ' [ОБЩИЙ, только просмотр]' : ' [ОБЩИЙ]'
      : '';
    const parts: string[] = [`${i + 1}. ${acc.name}${sharedTag} (id: ${acc.id})`];
    if (acc.balance !== undefined) {
      // Balance is native to the account — a 4 450 USD ByBit balance
      // must not read as «4 450 ₽».
      parts.push(`баланс: ${formatMoneyIn(acc.balance, acc.currency)}`);
    }
    parts.push(`расходы: ${formatMoney(expenses)}`);
    parts.push(`доходы: ${formatMoney(income)}`);
    parts.push(`операций: ${txCount}`);
    return parts.join(', ');
  });

  const totalLine = accountsTotalBase !== undefined
    ? `\nИтого по всем счетам (с конвертацией валют): ${formatMoney(accountsTotalBase)}. Используй именно эту сумму — не складывай валюты сам.`
    : '';
  return `Счета пользователя (включая общие):\n${lines.join('\n')}${totalLine}`;
}

// ── Helpers ──

function resolveCategoryName(tx: TxRow, categories?: CategoryRow[]): string {
  if (tx.category?.name) return tx.category.name.trim();
  if (categories) {
    const cat = categories.find((c) => c.id === tx.category_id);
    if (cat) return cat.name;
  }
  return 'Другое';
}

function daysBetween(start: string, end: string): number {
  const s = new Date(start);
  const e = new Date(end);
  return Math.max(1, Math.round((e.getTime() - s.getTime()) / 86400000));
}

// ── Build conversation history context ──

export function buildHistoryContext(history: ConversationMessage[]): string {
  if (!history.length) return '';

  const recent = history.slice(-6);
  const lines = recent.map((m) => {
    const role = m.role === 'user' ? 'Пользователь' : 'Ассистент';
    const content = m.content.length > 200 ? m.content.slice(0, 200) + '…' : m.content;
    return `${role}: ${content}`;
  });

  return `История диалога:\n${lines.join('\n')}`;
}
