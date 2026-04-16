import type { AssistantAction, AssistantPeriod, AnomalyEvidence, RecommendedAction } from '../_shared/assistant-schema.ts';
import {
  normalizeForMatch,
  inWindow,
  safeNumber,
  formatMoney,
  periodLabel,
  formatAmountNeutral,
  diffDaysInclusive,
  parseDateOnly,
  toDateOnly,
  addDays,
  budgetWindowForToday,
} from './utils.ts';
import { extractCreateTxEntities, fuzzyMatchCategory, CATEGORY_SYNONYMS } from './entity-extraction.ts';
import type {
  TxRow,
  BudgetRow,
  CategoryRow,
  AccountRow,
  PeriodWindow,
  LLMClassificationResult,
  SavingsGoalRow,
  SavingsContributionRow,
  AnomaliesResult,
  RecurringPattern,
  SupabaseClient,
} from './types.ts';

// ── Contextual followUps based on user data ──

function buildContextualFollowUps(
  transactions: TxRow[],
  window: PeriodWindow,
  baseFollowUps: string[],
): string[] {
  const current = transactions.filter((tx) => inWindow(tx.date, window));
  const expenses = current.filter((tx) => tx.type === 'expense' && !tx.transfer_group_id);
  const income = current.filter((tx) => tx.type === 'income' && !tx.transfer_group_id);

  const totalExpense = expenses.reduce((sum, tx) => sum + safeNumber(tx.amount), 0);
  const totalIncome = income.reduce((sum, tx) => sum + safeNumber(tx.amount), 0);

  const contextual: string[] = [];

  // Expenses > income → suggest budget optimization
  if (totalIncome > 0 && totalExpense > totalIncome) {
    contextual.push('Как оптимизировать бюджет?');
  }

  // Find top category, if it's > 40% suggest drilling into it
  if (expenses.length > 0) {
    const catSpend = new Map<string, number>();
    for (const tx of expenses) {
      const name = tx.category?.name?.trim() || 'Другое';
      catSpend.set(name, (catSpend.get(name) ?? 0) + safeNumber(tx.amount));
    }
    const topEntry = [...catSpend.entries()].sort((a, b) => b[1] - a[1])[0];
    if (topEntry && totalExpense > 0) {
      const pct = Math.round((topEntry[1] / totalExpense) * 100);
      if (pct >= 40) {
        contextual.push(`Расходы на ${topEntry[0]}`);
      }
    }
  }

  // Suggest trend comparison if we have data
  if (current.length > 5) {
    contextual.push('Сравнить с прошлым месяцем');
  }

  // Merge: contextual first, then base (deduplicated), max 3
  const seen = new Set<string>();
  const result: string[] = [];
  for (const f of [...contextual, ...baseFollowUps]) {
    const key = f.toLowerCase();
    if (!seen.has(key) && result.length < 3) {
      seen.add(key);
      result.push(f);
    }
  }
  return result;
}

export function buildSpendSummaryResponse(
  transactions: TxRow[],
  window: PeriodWindow,
  period: AssistantPeriod,
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const current = transactions.filter((tx) => inWindow(tx.date, window));
  const expense = current.filter((tx) => tx.type === 'expense' && !tx.transfer_group_id).reduce((sum, tx) => sum + safeNumber(tx.amount), 0);
  const income = current.filter((tx) => tx.type === 'income' && !tx.transfer_group_id).reduce((sum, tx) => sum + safeNumber(tx.amount), 0);

  if (current.length === 0) {
    return {
      answer: `За период ${periodLabel(period)} пока нет операций.`,
      facts: ['Добавьте первую транзакцию, и я сразу посчитаю сводку.'],
      actions: [{ type: 'open_add_expense', label: 'Добавить расход' }],
      followUps: ['Топ категорий', 'Остаток бюджета'],
    };
  }

  const net = income - expense;
  const days = diffDaysInclusive(window.start, window.end);
  const dailyExpense = days > 0 ? expense / days : 0;

  const facts = [
    `Расходы: ${formatMoney(expense)}`,
    `Доходы: ${formatMoney(income)}`,
    `Операций: ${current.length}`,
  ];

  if (days > 1 && expense > 0) {
    facts.push(`В среднем ${formatMoney(dailyExpense)} в день`);
  }
  if (income > 0 && expense > 0) {
    const savingsRate = Math.round(((income - expense) / income) * 100);
    if (savingsRate > 0) {
      facts.push(`Норма сбережений: ${savingsRate}%`);
    }
  }

  const answer = net >= 0
    ? `Сводка ${periodLabel(period)}: баланс положительный, +${formatMoney(net)}.`
    : `Сводка ${periodLabel(period)}: расходов больше доходов на ${formatMoney(Math.abs(net))}.`;

  return {
    answer,
    facts,
    actions: [
      { type: 'open_transactions', label: 'Открыть транзакции' },
      { type: 'open_add_expense', label: 'Добавить расход' },
    ],
    followUps: buildContextualFollowUps(transactions, window, ['Топ категорий', 'Сравнить с прошлым периодом', 'Крупнейшие траты']),
  };
}

export function buildTopCategoriesResponse(
  transactions: TxRow[],
  window: PeriodWindow,
  period: AssistantPeriod,
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const currentExpenses = transactions.filter((tx) => tx.type === 'expense' && !tx.transfer_group_id && inWindow(tx.date, window));
  if (currentExpenses.length === 0) {
    return {
      answer: `За период ${periodLabel(period)} нет расходов для анализа категорий.`,
      facts: [],
      actions: [{ type: 'open_add_expense', label: 'Добавить расход' }],
      followUps: ['Сколько потрачено?', 'Остаток бюджета'],
    };
  }

  const map = new Map<string, number>();
  for (const tx of currentExpenses) {
    const key = tx.category?.name?.trim() || 'Без категории';
    map.set(key, (map.get(key) ?? 0) + safeNumber(tx.amount));
  }

  const totalExpense = currentExpenses.reduce((sum, tx) => sum + safeNumber(tx.amount), 0);

  const top = [...map.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3);

  const facts = top.map(([name, amount], idx) => {
    const pct = totalExpense > 0 ? Math.round((amount / totalExpense) * 100) : 0;
    return `${idx + 1}. ${name}: ${formatMoney(amount)} (${pct}% от всех расходов)`;
  });
  const [leaderName, leaderAmount] = top[0];
  const leaderPct = totalExpense > 0 ? Math.round((leaderAmount / totalExpense) * 100) : 0;

  if (leaderPct >= 40) {
    facts.push(`Категория "${leaderName}" занимает ${leaderPct}% всех расходов — стоит обратить внимание`);
  }

  return {
    answer: `Главная категория расходов ${periodLabel(period)}: ${leaderName} (${formatMoney(leaderAmount)}, ${leaderPct}%).`,
    facts,
    actions: [{ type: 'open_transactions', label: 'Посмотреть транзакции' }],
    followUps: buildContextualFollowUps(transactions, window, ['Сколько потрачено?', 'Сравни с прошлым месяцем', 'Крупнейшие траты']),
  };
}

export function buildTopExpensesResponse(
  transactions: TxRow[],
  window: PeriodWindow,
  period: AssistantPeriod,
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const currentExpenses = transactions
    .filter((tx) => tx.type === 'expense' && !tx.transfer_group_id && inWindow(tx.date, window))
    .sort((a, b) => safeNumber(b.amount) - safeNumber(a.amount));

  if (currentExpenses.length === 0) {
    return {
      answer: `За период ${periodLabel(period)} нет расходов.`,
      facts: [],
      actions: [{ type: 'open_add_expense', label: 'Добавить расход' }],
      followUps: ['Сводка расходов', 'Топ категорий'],
    };
  }

  const top5 = currentExpenses.slice(0, 5);
  const total = currentExpenses.reduce((sum, tx) => sum + safeNumber(tx.amount), 0);

  const facts = top5.map((tx, idx) => {
    const catName = tx.category?.name?.trim() || 'Без категории';
    return `${idx + 1}. ${catName}: ${formatMoney(safeNumber(tx.amount))} (${tx.date.slice(0, 10)})`;
  });

  const topAmount = safeNumber(top5[0].amount);
  const topCat = top5[0].category?.name?.trim() || 'Без категории';

  return {
    answer: `Самая крупная трата ${periodLabel(period)}: ${topCat} на ${formatMoney(topAmount)}. Топ-5 составляют ${formatMoney(top5.reduce((s, tx) => s + safeNumber(tx.amount), 0))} из ${formatMoney(total)}.`,
    facts,
    actions: [{ type: 'open_transactions', label: 'Открыть транзакции' }],
    followUps: buildContextualFollowUps(transactions, window, ['Сводка расходов', 'Есть аномалии?', 'Средний чек']),
  };
}

export function buildTrendCompareResponse(
  transactions: TxRow[],
  currentWindow: PeriodWindow,
  previousWindow: PeriodWindow,
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[]; recommendedActions?: RecommendedAction[] } {
  const currentTxs = transactions.filter((tx) => tx.type === 'expense' && !tx.transfer_group_id && inWindow(tx.date, currentWindow));
  const previousTxs = transactions.filter((tx) => tx.type === 'expense' && !tx.transfer_group_id && inWindow(tx.date, previousWindow));

  const currentExpense = currentTxs.reduce((sum, tx) => sum + safeNumber(tx.amount), 0);
  const previousExpense = previousTxs.reduce((sum, tx) => sum + safeNumber(tx.amount), 0);

  const diff = currentExpense - previousExpense;
  const percent = previousExpense > 0 ? Math.round((diff / previousExpense) * 100) : null;

  let answer: string;
  if (previousExpense <= 0 && currentExpense <= 0) {
    answer = 'Сравнивать пока нечего: в обоих периодах нет расходов.';
  } else if (previousExpense <= 0) {
    answer = `Расходы выросли: в текущем периоде ${formatMoney(currentExpense)}, в прошлом операций не было.`;
  } else if (diff > 0) {
    answer = `Расходы выросли на ${formatMoney(diff)}${percent !== null ? ` (+${percent}%)` : ''} относительно прошлого периода.`;
  } else if (diff < 0) {
    answer = `Расходы снизились на ${formatMoney(Math.abs(diff))}${percent !== null ? ` (−${Math.abs(percent)}%)` : ''} относительно прошлого периода.`;
  } else {
    answer = 'Расходы в текущем и прошлом периодах на одном уровне.';
  }

  const facts: string[] = [
    `Текущий период: ${formatMoney(currentExpense)}`,
    `Прошлый период: ${formatMoney(previousExpense)}`,
  ];

  // Category-by-category breakdown
  const currentByCategory = new Map<string, number>();
  const previousByCategory = new Map<string, number>();

  for (const tx of currentTxs) {
    const name = tx.category?.name?.trim() || 'Без категории';
    currentByCategory.set(name, (currentByCategory.get(name) ?? 0) + safeNumber(tx.amount));
  }
  for (const tx of previousTxs) {
    const name = tx.category?.name?.trim() || 'Без категории';
    previousByCategory.set(name, (previousByCategory.get(name) ?? 0) + safeNumber(tx.amount));
  }

  const allCategories = new Set([...currentByCategory.keys(), ...previousByCategory.keys()]);
  const categoryDeltas: Array<{ name: string; prev: number; curr: number; delta: number; deltaPercent: number | null }> = [];

  for (const name of allCategories) {
    const curr = currentByCategory.get(name) ?? 0;
    const prev = previousByCategory.get(name) ?? 0;
    const delta = curr - prev;
    const deltaPercent = prev > 0 ? Math.round((delta / prev) * 100) : null;
    categoryDeltas.push({ name, prev, curr, delta, deltaPercent });
  }

  // Sort by absolute delta descending, take top 5
  categoryDeltas.sort((a, b) => Math.abs(b.delta) - Math.abs(a.delta));
  const topDeltas = categoryDeltas.slice(0, 5);

  for (const cat of topDeltas) {
    if (Math.abs(cat.delta) <= 0) continue;
    const emoji = cat.delta > 0 ? '📈' : '📉';
    const deltaStr = cat.deltaPercent !== null
      ? ` (${cat.delta > 0 ? '+' : ''}${cat.deltaPercent}%)`
      : '';
    facts.push(`${emoji} ${cat.name}: ${formatMoney(cat.prev)} → ${formatMoney(cat.curr)}${deltaStr}`);
  }

  // Smart follow-ups based on findings
  const followUps: string[] = [];
  const recommendedActions: RecommendedAction[] = [];
  const expensesGrew = diff > 0;
  const growingCategories = categoryDeltas.filter((c) => c.delta > 0 && c.deltaPercent !== null && c.deltaPercent > 15);
  const spikedCategory = topDeltas.find((c) => c.delta > 0 && c.deltaPercent !== null && c.deltaPercent > 30);

  if (expensesGrew) {
    followUps.push('Хочешь создать бюджеты на основе этого анализа?');
  }
  if (spikedCategory) {
    followUps.push(`Подробнее о категории «${spikedCategory.name}»?`);
  }
  if (followUps.length === 0) {
    followUps.push('Топ категорий', 'Крупнейшие траты');
  }
  followUps.push('Прогноз');

  // Recommended actions: create budgets for growing categories
  for (const cat of growingCategories.slice(0, 3)) {
    recommendedActions.push({
      id: `budget_suggest_${cat.name.toLowerCase().replace(/\s+/g, '_')}`,
      label: `Создать бюджет для «${cat.name}»`,
      action_type: 'create_budget_suggestion',
      payload: { category: cat.name },
    });
  }

  return {
    answer,
    facts: facts.slice(0, 10),
    actions: [{ type: 'open_transactions', label: 'Разобрать расходы' }],
    followUps: followUps.slice(0, 3),
    ...(recommendedActions.length > 0 ? { recommendedActions } : {}),
  };
}

export async function buildBudgetRiskResponse(
  anonClient: SupabaseClient,
  transactions: TxRow[],
  today: string,
  userId?: string,
): Promise<{ answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] }> {
  let q = anonClient
    .from('budgets')
    .select('id,amount,category_ids,account_ids,period_type,custom_start_date,custom_end_date,is_active')
    .eq('is_active', true);
  if (userId) q = q.eq('user_id', userId);
  const { data: budgetsData, error: budgetsError } = await q.limit(300);

  if (budgetsError?.code !== '42P01' && budgetsError) {
    throw new Error(`Failed to load budgets: ${budgetsError.message}`);
  }

  const budgets = ((budgetsData ?? []) as BudgetRow[])
    .filter((b) => b.is_active && Number.isFinite(Number(b.amount)) && Number(b.amount) > 0);

  if (budgets.length === 0) {
    return {
      answer: 'Активных бюджетов пока нет. Я не могу оценить риск перерасхода.',
      facts: ['Создайте хотя бы один бюджет, чтобы получать риск-алерты.'],
      actions: [{ type: 'open_budget_tab', label: 'Открыть бюджеты' }],
      followUps: ['Сводка расходов', 'Топ категорий'],
    };
  }

  const categoryIds = [...new Set(budgets.flatMap((b) => b.category_ids ?? []))];
  const categoryNameById = new Map<string, string>();

  if (categoryIds.length > 0) {
    const { data: categoriesData, error: categoriesError } = await anonClient
      .from('categories')
      .select('id,name')
      .in('id', categoryIds)
      .limit(500);

    if (!categoriesError) {
      for (const row of (categoriesData ?? []) as CategoryRow[]) {
        categoryNameById.set(row.id, row.name);
      }
    }
  }

  const risks: Array<{ utilization: number; spent: number; limit: number; label: string }> = [];

  for (const budget of budgets) {
    const window = budgetWindowForToday(budget, today);
    if (!window) continue;

    const accountScope = budget.account_ids && budget.account_ids.length > 0
      ? new Set(budget.account_ids)
      : null;

    let spent = 0;
    for (const tx of transactions) {
      if (tx.type !== 'expense' || tx.transfer_group_id) continue;
      if (!inWindow(tx.date, window)) continue;
      if (!budget.category_ids.includes(tx.category_id)) continue;
      if (accountScope && (!tx.account_id || !accountScope.has(tx.account_id))) continue;
      spent += safeNumber(tx.amount);
    }

    const limit = safeNumber(budget.amount);
    if (limit <= 0) continue;

    const utilization = spent / limit;
    if (utilization < 0.8) continue;

    const labels = budget.category_ids
      .slice(0, 3)
      .map((id) => categoryNameById.get(id) ?? 'Категория')
      .join(', ');

    risks.push({
      utilization,
      spent,
      limit,
      label: labels,
    });
  }

  risks.sort((a, b) => b.utilization - a.utilization);

  if (risks.length === 0) {
    return {
      answer: 'Сейчас бюджеты в безопасной зоне: риск перерасхода низкий.',
      facts: [],
      actions: [{ type: 'open_budget_tab', label: 'Открыть бюджеты' }],
      followUps: ['Остаток бюджета', 'Сводка расходов', 'Прогноз'],
    };
  }

  const topFacts = risks.slice(0, 3).map((risk) => {
    const percent = Math.round(risk.utilization * 100);
    const status = percent >= 100 ? 'ПРЕВЫШЕН' : percent >= 90 ? 'критично' : 'в зоне риска';
    return `${risk.label}: ${formatMoney(risk.spent)} из ${formatMoney(risk.limit)} (${percent}%) — ${status}`;
  });

  const exceeded = risks.filter((r) => r.utilization >= 1).length;
  const critical = risks.filter((r) => r.utilization >= 0.9 && r.utilization < 1).length;
  if (exceeded > 0) {
    topFacts.push(`${exceeded} бюджет(ов) уже превышен(ы)`);
  } else if (critical > 0) {
    topFacts.push(`${critical} бюджет(ов) близок к пределу (>90%)`);
  }

  return {
    answer: `Обнаружен риск перерасхода в ${risks.length} бюджет(ах). Начните с самых нагруженных категорий.`,
    facts: topFacts,
    actions: [
      { type: 'open_budget_tab', label: 'Открыть бюджеты' },
      { type: 'open_transactions', label: 'Посмотреть операции' },
    ],
    followUps: ['Остаток бюджета', 'Прогноз до конца месяца', 'Сводка расходов'],
  };
}

export function buildByCategoryResponse(
  transactions: TxRow[],
  window: PeriodWindow,
  period: AssistantPeriod,
  entity: string,
  categories: CategoryRow[],
  llmEntities?: LLMClassificationResult['entities'],
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const entityLower = normalizeForMatch(entity);
  let matched = categories.filter((c) => normalizeForMatch(c.name).includes(entityLower));

  // LLM entities fallback: if regex entity didn't match, try llmEntities.category
  if (matched.length === 0 && llmEntities?.category) {
    const llmCatLower = normalizeForMatch(llmEntities.category);
    matched = categories.filter((c) => normalizeForMatch(c.name).includes(llmCatLower));
  }

  // Fuzzy fallback: try fuzzyMatchCategory if still no match
  if (matched.length === 0) {
    const fuzzyHint = llmEntities?.category ?? entity;
    const fuzzyResult = fuzzyMatchCategory(fuzzyHint, categories);
    if (fuzzyResult) {
      matched = [fuzzyResult];
    }
  }

  if (matched.length === 0) {
    return {
      answer: `Не нашёл категорию "${entity}". Проверьте название или спросите "Топ категорий".`,
      facts: [],
      actions: [{ type: 'open_transactions', label: 'Открыть транзакции' }],
      followUps: ['Топ категорий', 'Сколько потрачено?'],
    };
  }

  const matchedIds = new Set(matched.map((c) => c.id));
  const filtered = transactions.filter(
    (tx) => tx.type === 'expense' && !tx.transfer_group_id && inWindow(tx.date, window) && matchedIds.has(tx.category_id),
  );

  const total = filtered.reduce((sum, tx) => sum + safeNumber(tx.amount), 0);
  const categoryNames = matched.map((c) => c.name).join(', ');

  if (filtered.length === 0) {
    return {
      answer: `${periodLabel(period)} нет расходов в категории "${categoryNames}".`,
      facts: [],
      actions: [{ type: 'open_add_expense', label: 'Добавить расход' }],
      followUps: ['Топ категорий', 'Сколько потрачено?'],
    };
  }

  return {
    answer: `Расходы на "${categoryNames}" ${periodLabel(period)}: ${formatMoney(total)} (${filtered.length} операций).`,
    facts: [
      `Сумма: ${formatMoney(total)}`,
      `Операций: ${filtered.length}`,
      `Средний чек: ${formatMoney(total / filtered.length)}`,
    ],
    actions: [{ type: 'open_transactions', label: 'Посмотреть транзакции' }],
    followUps: ['Топ категорий', 'Сколько потрачено?', 'Сравни с прошлым месяцем'],
  };
}

export function buildByAccountResponse(
  transactions: TxRow[],
  window: PeriodWindow,
  period: AssistantPeriod,
  entity: string,
  accounts: AccountRow[],
  llmEntities?: LLMClassificationResult['entities'],
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const entityLower = normalizeForMatch(entity);
  let matched = accounts.filter((a) => normalizeForMatch(a.name).includes(entityLower));

  // LLM entities fallback: if regex entity didn't match, try llmEntities.account
  if (matched.length === 0 && llmEntities?.account) {
    const llmAccLower = normalizeForMatch(llmEntities.account);
    matched = accounts.filter((a) => normalizeForMatch(a.name).includes(llmAccLower));
  }

  if (matched.length === 0) {
    return {
      answer: `Не нашёл счёт "${entity}". Проверьте название.`,
      facts: [],
      actions: [{ type: 'open_transactions', label: 'Открыть транзакции' }],
      followUps: ['Сводка расходов', 'Топ категорий'],
    };
  }

  const matchedIds = new Set(matched.map((a) => a.id));
  const filtered = transactions.filter(
    (tx) => inWindow(tx.date, window) && tx.account_id && matchedIds.has(tx.account_id),
  );

  const expense = filtered.filter((tx) => tx.type === 'expense' && !tx.transfer_group_id).reduce((sum, tx) => sum + safeNumber(tx.amount), 0);
  const income = filtered.filter((tx) => tx.type === 'income' && !tx.transfer_group_id).reduce((sum, tx) => sum + safeNumber(tx.amount), 0);
  const accountNames = matched.map((a) => a.name).join(', ');

  if (filtered.length === 0) {
    return {
      answer: `${periodLabel(period)} нет операций по счёту "${accountNames}".`,
      facts: [],
      actions: [{ type: 'open_add_expense', label: 'Добавить расход' }],
      followUps: ['Сводка расходов', 'Топ категорий'],
    };
  }

  const net = income - expense;
  return {
    answer: `По счёту "${accountNames}" ${periodLabel(period)}: расходы ${formatMoney(expense)}, доходы ${formatMoney(income)}.`,
    facts: [
      `Расходы: ${formatMoney(expense)}`,
      `Доходы: ${formatMoney(income)}`,
      `Баланс за период: ${net >= 0 ? '+' : ''}${formatMoney(net)}`,
      `Операций: ${filtered.length}`,
    ],
    actions: [{ type: 'open_transactions', label: 'Посмотреть транзакции' }],
    followUps: ['Сводка расходов', 'Топ категорий'],
  };
}

export async function buildBudgetRemainingResponse(
  anonClient: SupabaseClient,
  transactions: TxRow[],
  today: string,
  userId?: string,
): Promise<{ answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] }> {
  let q = anonClient
    .from('budgets')
    .select('id,amount,category_ids,account_ids,period_type,custom_start_date,custom_end_date,is_active')
    .eq('is_active', true);
  if (userId) q = q.eq('user_id', userId);
  const { data: budgetsData, error: budgetsError } = await q.limit(300);

  if (budgetsError && budgetsError.code !== '42P01') {
    throw new Error(`Failed to load budgets: ${budgetsError.message}`);
  }

  const budgets = ((budgetsData ?? []) as BudgetRow[])
    .filter((b) => b.is_active && Number.isFinite(Number(b.amount)) && Number(b.amount) > 0);

  if (budgets.length === 0) {
    return {
      answer: 'Активных бюджетов нет. Создайте бюджет, чтобы видеть остатки.',
      facts: [],
      actions: [{ type: 'open_budget_tab', label: 'Создать бюджет' }],
      followUps: ['Сводка расходов', 'Топ категорий'],
    };
  }

  const categoryIds = [...new Set(budgets.flatMap((b) => b.category_ids ?? []))];
  const categoryNameById = new Map<string, string>();

  if (categoryIds.length > 0) {
    const { data: categoriesData } = await anonClient
      .from('categories')
      .select('id,name')
      .in('id', categoryIds)
      .limit(500);

    for (const row of (categoriesData ?? []) as CategoryRow[]) {
      categoryNameById.set(row.id, row.name);
    }
  }

  const remainings: Array<{ label: string; remaining: number; limit: number; percent: number }> = [];

  for (const budget of budgets) {
    const window = budgetWindowForToday(budget, today);
    if (!window) continue;

    const accountScope = budget.account_ids && budget.account_ids.length > 0
      ? new Set(budget.account_ids)
      : null;

    let spent = 0;
    for (const tx of transactions) {
      if (tx.type !== 'expense' || tx.transfer_group_id) continue;
      if (!inWindow(tx.date, window)) continue;
      if (!budget.category_ids.includes(tx.category_id)) continue;
      if (accountScope && (!tx.account_id || !accountScope.has(tx.account_id))) continue;
      spent += safeNumber(tx.amount);
    }

    const limit = safeNumber(budget.amount);
    if (limit <= 0) continue;

    const remaining = Math.max(0, limit - spent);
    const labels = budget.category_ids
      .slice(0, 3)
      .map((id) => categoryNameById.get(id) ?? 'Категория')
      .join(', ');

    remainings.push({
      label: labels,
      remaining,
      limit,
      percent: Math.round((remaining / limit) * 100),
    });
  }

  remainings.sort((a, b) => a.percent - b.percent);

  if (remainings.length === 0) {
    return {
      answer: 'Не удалось рассчитать остатки (бюджеты вне текущего периода).',
      facts: [],
      actions: [{ type: 'open_budget_tab', label: 'Открыть бюджеты' }],
      followUps: ['Риски по бюджетам', 'Сводка расходов'],
    };
  }

  const facts = remainings.slice(0, 5).map(
    (r) => `${r.label}: осталось ${formatMoney(r.remaining)} из ${formatMoney(r.limit)} (${r.percent}%)`,
  );

  const totalRemaining = remainings.reduce((sum, r) => sum + r.remaining, 0);

  return {
    answer: `Общий остаток по ${remainings.length} бюджет(ам): ${formatMoney(totalRemaining)}.`,
    facts,
    actions: [{ type: 'open_budget_tab', label: 'Открыть бюджеты' }],
    followUps: ['Риски по бюджетам', 'Прогноз', 'Сводка расходов'],
  };
}

export function buildAverageCheckResponse(
  transactions: TxRow[],
  window: PeriodWindow,
  period: AssistantPeriod,
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const expenses = transactions.filter((tx) => tx.type === 'expense' && !tx.transfer_group_id && inWindow(tx.date, window));

  if (expenses.length === 0) {
    return {
      answer: `${periodLabel(period)} нет расходов для расчёта среднего чека.`,
      facts: [],
      actions: [{ type: 'open_add_expense', label: 'Добавить расход' }],
      followUps: ['Сводка расходов', 'Топ категорий'],
    };
  }

  const total = expenses.reduce((sum, tx) => sum + safeNumber(tx.amount), 0);
  const avg = total / expenses.length;
  const median = (() => {
    const sorted = expenses.map((tx) => safeNumber(tx.amount)).sort((a, b) => a - b);
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 !== 0 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  })();
  const max = Math.max(...expenses.map((tx) => safeNumber(tx.amount)));
  const min = Math.min(...expenses.map((tx) => safeNumber(tx.amount)));

  return {
    answer: `Средний чек ${periodLabel(period)}: ${formatMoney(avg)} (${expenses.length} операций).`,
    facts: [
      `Средний: ${formatMoney(avg)}`,
      `Медианный: ${formatMoney(median)}`,
      `Мин: ${formatMoney(min)}, Макс: ${formatMoney(max)}`,
    ],
    actions: [{ type: 'open_transactions', label: 'Открыть транзакции' }],
    followUps: buildContextualFollowUps(transactions, window, ['Крупнейшие траты', 'Есть аномалии?', 'Топ категорий']),
  };
}

export function buildForecastResponse(
  transactions: TxRow[],
  window: PeriodWindow,
  period: AssistantPeriod,
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const today = toDateOnly(new Date());
  const expenses = transactions.filter((tx) => tx.type === 'expense' && !tx.transfer_group_id && inWindow(tx.date, window));
  const income = transactions.filter((tx) => tx.type === 'income' && !tx.transfer_group_id && inWindow(tx.date, window));

  const totalExpense = expenses.reduce((sum, tx) => sum + safeNumber(tx.amount), 0);
  const totalIncome = income.reduce((sum, tx) => sum + safeNumber(tx.amount), 0);

  const daysPassed = diffDaysInclusive(window.start, today);
  if (daysPassed <= 0) {
    return {
      answer: 'Недостаточно данных для прогноза.',
      facts: [],
      actions: [{ type: 'open_transactions', label: 'Открыть транзакции' }],
      followUps: ['Сводка расходов', 'Топ категорий'],
    };
  }

  let totalDays: number;
  if (period === 'month') {
    const date = parseDateOnly(today);
    const lastDay = new Date(date.getUTCFullYear(), date.getUTCMonth() + 1, 0);
    totalDays = lastDay.getUTCDate();
  } else if (period === 'week') {
    totalDays = 7;
  } else {
    totalDays = daysPassed;
  }

  const dailyExpense = totalExpense / daysPassed;
  const projectedExpense = dailyExpense * totalDays;
  const remainingDays = Math.max(0, totalDays - daysPassed);
  const projectedRemaining = dailyExpense * remainingDays;

  const facts = [
    `Потрачено: ${formatMoney(totalExpense)} за ${daysPassed} дн.`,
    `Средний расход в день: ${formatMoney(dailyExpense)}`,
    `Прогноз до конца периода: ещё ${formatMoney(projectedRemaining)}`,
    `Прогноз итого: ${formatMoney(projectedExpense)}`,
  ];

  let answer: string;
  if (totalIncome > 0 && projectedExpense > totalIncome) {
    answer = `При текущем темпе (${formatMoney(dailyExpense)}/день) расходы ${periodLabel(period)} составят ~${formatMoney(projectedExpense)}, что превысит доходы (${formatMoney(totalIncome)}).`;
  } else if (totalIncome > 0) {
    answer = `При текущем темпе расходы ${periodLabel(period)} составят ~${formatMoney(projectedExpense)}. Доходы (${formatMoney(totalIncome)}) покрывают с запасом.`;
  } else {
    answer = `Прогноз расходов ${periodLabel(period)}: ~${formatMoney(projectedExpense)} при текущем темпе ${formatMoney(dailyExpense)}/день. Осталось ${remainingDays} дн.`;
  }

  return {
    answer,
    facts,
    actions: [
      { type: 'open_budget_tab', label: 'Проверить бюджеты' },
      { type: 'open_transactions', label: 'Открыть транзакции' },
    ],
    followUps: buildContextualFollowUps(transactions, window, ['Остаток бюджета', 'Сравни с прошлым месяцем', 'Топ категорий']),
  };
}

export function buildAnomaliesResponse(
  transactions: TxRow[],
  window: PeriodWindow,
  previousWindow: PeriodWindow,
  period: AssistantPeriod,
): AnomaliesResult {
  const expenses = transactions.filter((tx) => tx.type === 'expense' && !tx.transfer_group_id && inWindow(tx.date, window));
  const prevExpenses = transactions.filter((tx) => tx.type === 'expense' && !tx.transfer_group_id && inWindow(tx.date, previousWindow));

  if (expenses.length < 3) {
    return {
      answer: `Недостаточно данных ${periodLabel(period)} для поиска аномалий (нужно минимум 3 расхода).`,
      facts: [],
      actions: [{ type: 'open_add_expense', label: 'Добавить расход' }],
      followUps: ['Сводка расходов', 'Топ категорий'],
      evidence: [],
      confidence: 0,
      recommendedActions: [],
      explainability: 'Мало данных для анализа.',
    };
  }

  const evidence: AnomalyEvidence[] = [];
  const recommendedActions: RecommendedAction[] = [];

  // --- 1. Category spikes (current vs baseline) ---
  const currentByCat = new Map<string, { total: number; name: string; txIds: string[] }>();
  const baselineByCat = new Map<string, { total: number; count: number }>();

  for (const tx of expenses) {
    const catName = tx.category?.name?.trim() || 'Без категории';
    const entry = currentByCat.get(tx.category_id) ?? { total: 0, name: catName, txIds: [] };
    entry.total += safeNumber(tx.amount);
    entry.txIds.push(tx.id);
    currentByCat.set(tx.category_id, entry);
  }

  for (const tx of prevExpenses) {
    const entry = baselineByCat.get(tx.category_id) ?? { total: 0, count: 0 };
    entry.total += safeNumber(tx.amount);
    entry.count++;
    baselineByCat.set(tx.category_id, entry);
  }

  for (const [catId, current] of currentByCat) {
    const baseline = baselineByCat.get(catId);
    if (!baseline || baseline.total <= 0) continue;
    const delta = ((current.total - baseline.total) / baseline.total) * 100;
    if (delta > 50) {
      evidence.push({
        type: 'category_spike',
        label: `${current.name}: рост на ${Math.round(delta)}%`,
        current_value: Math.round(current.total),
        baseline_value: Math.round(baseline.total),
        delta_percent: Math.round(delta),
        tx_refs: current.txIds.slice(0, 10),
      });
    }
  }

  // --- 2. Single large transactions (>2 sigma from mean) ---
  const amounts = expenses.map((tx) => safeNumber(tx.amount));
  const mean = amounts.reduce((s, v) => s + v, 0) / amounts.length;
  const stddev = Math.sqrt(amounts.reduce((s, v) => s + (v - mean) ** 2, 0) / amounts.length);
  const threshold = mean + 2 * stddev;

  const largeTxs = expenses
    .filter((tx) => safeNumber(tx.amount) > threshold)
    .sort((a, b) => safeNumber(b.amount) - safeNumber(a.amount))
    .slice(0, 5);

  for (const tx of largeTxs) {
    const catName = tx.category?.name?.trim() || 'Без категории';
    const amt = safeNumber(tx.amount);
    evidence.push({
      type: 'single_large_tx',
      label: `${catName}: ${formatMoney(amt)} (${(amt / mean).toFixed(1)}x от среднего)`,
      current_value: Math.round(amt),
      baseline_value: Math.round(mean),
      delta_percent: Math.round(((amt - mean) / mean) * 100),
      tx_refs: [tx.id],
    });
  }

  // --- 3. Frequency spike (tx count per day vs baseline) ---
  const days = diffDaysInclusive(window.start, window.end);
  const prevDays = diffDaysInclusive(previousWindow.start, previousWindow.end);
  let frequencySpikeDetected = false;
  if (days > 0 && prevDays > 0 && prevExpenses.length > 0) {
    const currentFreq = expenses.length / days;
    const baselineFreq = prevExpenses.length / prevDays;
    if (baselineFreq > 0 && currentFreq > baselineFreq * 1.5) {
      const delta = Math.round(((currentFreq - baselineFreq) / baselineFreq) * 100);
      frequencySpikeDetected = true;

      const dayCounts = [0, 0, 0, 0, 0, 0, 0];
      for (const tx of expenses) {
        const d = parseDateOnly(tx.date);
        const dow = d.getUTCDay();
        const normalizedDow = dow === 0 ? 6 : dow - 1;
        dayCounts[normalizedDow]++;
      }
      const heatmap = dayCounts.map((count, day) => ({ day, count }));

      evidence.push({
        type: 'frequency_spike',
        label: `Частота трат выросла: ${currentFreq.toFixed(1)} → ${baselineFreq.toFixed(1)} в день`,
        current_value: Math.round(currentFreq * 100) / 100,
        baseline_value: Math.round(baselineFreq * 100) / 100,
        delta_percent: delta,
        tx_refs: [],
        heatmap,
      });
    }
  }

  // --- 4. Merchant spikes ---
  const currentByMerchant = new Map<string, { total: number; name: string; txIds: string[] }>();
  const baselineByMerchant = new Map<string, { total: number }>();

  for (const tx of expenses) {
    const merchantKey = tx.merchant_normalized ?? (tx.merchant_name ? normalizeForMatch(tx.merchant_name) : null);
    if (!merchantKey) continue;

    const merchantLabel = tx.merchant_name?.trim() || tx.merchant_normalized || merchantKey;
    const entry = currentByMerchant.get(merchantKey) ?? { total: 0, name: merchantLabel, txIds: [] };
    entry.total += safeNumber(tx.amount);
    entry.txIds.push(tx.id);

    if ((entry.name === merchantKey || entry.name === tx.merchant_normalized) && tx.merchant_name?.trim()) {
      entry.name = tx.merchant_name.trim();
    }
    currentByMerchant.set(merchantKey, entry);
  }

  for (const tx of prevExpenses) {
    const merchantKey = tx.merchant_normalized ?? (tx.merchant_name ? normalizeForMatch(tx.merchant_name) : null);
    if (!merchantKey) continue;

    const entry = baselineByMerchant.get(merchantKey) ?? { total: 0 };
    entry.total += safeNumber(tx.amount);
    baselineByMerchant.set(merchantKey, entry);
  }

  for (const [merchantKey, current] of currentByMerchant) {
    const baseline = baselineByMerchant.get(merchantKey);
    if (!baseline || baseline.total <= 0) continue;
    const delta = ((current.total - baseline.total) / baseline.total) * 100;
    if (delta > 50) {
      evidence.push({
        type: 'merchant_spike',
        label: `${current.name}: рост на ${Math.round(delta)}%`,
        current_value: Math.round(current.total),
        baseline_value: Math.round(baseline.total),
        delta_percent: Math.round(delta),
        tx_refs: current.txIds.slice(0, 10),
      });
    }
  }

  // Sort by delta_percent desc and limit to 5
  evidence.sort((a, b) => Math.abs(b.delta_percent) - Math.abs(a.delta_percent));
  evidence.splice(5);

  // --- Confidence calculation ---
  let confidence = 0.3;
  if (expenses.length >= 10) confidence += 0.2;
  if (expenses.length >= 30) confidence += 0.1;
  if (prevExpenses.length >= 5) confidence += 0.2;
  if (evidence.length >= 2) confidence += 0.1;
  if (evidence.length >= 4) confidence += 0.1;
  confidence = Math.min(1, Math.round(confidence * 100) / 100);

  // --- Structured recommended actions ---
  const categorySpikes = evidence.filter((e) => e.type === 'category_spike');
  if (categorySpikes.length > 0) {
    const catName = categorySpikes[0].label.split(':')[0];
    recommendedActions.push({
      id: 'cat_spike_0',
      label: `Проверьте расходы по "${catName}"`,
      action_type: 'open_transactions',
      payload: { category: catName, tx_ids: categorySpikes[0].tx_refs.slice(0, 5) },
    });
  }
  if (largeTxs.length > 0) {
    recommendedActions.push({
      id: 'large_tx_0',
      label: 'Просмотрите крупные траты',
      action_type: 'open_transactions',
      payload: { tx_ids: largeTxs.map((tx) => tx.id).slice(0, 5) },
    });
  }
  if (frequencySpikeDetected) {
    recommendedActions.push({
      id: 'freq_spike',
      label: 'Мелкие частые покупки',
      action_type: 'open_transactions',
    });
  }
  const merchantSpikes = evidence.filter((e) => e.type === 'merchant_spike');
  if (merchantSpikes.length > 0) {
    const merchantName = merchantSpikes[0].label.split(':')[0];
    recommendedActions.push({
      id: 'merch_spike_0',
      label: `Рост трат у "${merchantName}"`,
      action_type: 'open_transactions',
      payload: { merchant: merchantName, tx_ids: merchantSpikes[0].tx_refs.slice(0, 5) },
    });
  }
  if (evidence.length > 0) {
    recommendedActions.push({
      id: 'budget_check',
      label: 'Скорректировать бюджеты',
      action_type: 'open_budget_tab',
    });
  }

  // --- Build facts and answer ---
  if (evidence.length === 0) {
    return {
      answer: `${periodLabel(period)} аномально крупных трат не обнаружено. Всё в рамках нормы.`,
      facts: [`Средний расход: ${formatMoney(mean)}`, `Порог аномалии: ${formatMoney(threshold)}`],
      actions: [{ type: 'open_transactions', label: 'Открыть транзакции' }],
      followUps: ['Крупнейшие траты', 'Средний чек', 'Сводка расходов'],
      evidence: [],
      confidence,
      recommendedActions: [],
      explainability: 'Расходы в пределах нормы, аномалий не обнаружено.',
    };
  }

  const facts = evidence.slice(0, 3).map((e) => e.label);

  const causes: string[] = [];
  if (categorySpikes.length > 0) {
    causes.push(`рост в категории "${categorySpikes[0].label.split(':')[0]}"`);
  }
  if (largeTxs.length > 0) {
    causes.push(`${largeTxs.length} крупных единичных трат`);
  }
  if (frequencySpikeDetected) {
    causes.push('рост частоты операций');
  }
  if (merchantSpikes.length > 0) {
    causes.push(`рост трат у "${merchantSpikes[0].label.split(':')[0]}"`);
  }
  const explainability = `Основные причины: ${causes.join(', ')}.`;

  return {
    answer: `Найдено ${evidence.length} аномалий ${periodLabel(period)}: ${causes.join(', ')}.`,
    facts,
    actions: [{ type: 'open_transactions', label: 'Разобрать расходы' }],
    followUps: ['Крупнейшие траты', 'Средний чек', 'Сводка расходов'],
    evidence,
    confidence,
    recommendedActions,
    explainability,
  };
}

export function buildCreateTransactionResponse(
  query: string,
  categories: CategoryRow[],
  llmEntities?: LLMClassificationResult['entities'],
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const regexEntities = extractCreateTxEntities(query);

  const amount = (typeof llmEntities?.amount === 'number' && llmEntities.amount > 0)
    ? llmEntities.amount
    : regexEntities.amount;

  const tx_type: 'income' | 'expense' =
    (llmEntities?.tx_type === 'income' || llmEntities?.tx_type === 'expense')
      ? llmEntities.tx_type
      : regexEntities.tx_type;

  const categoryHint = (typeof llmEntities?.category === 'string' && llmEntities.category)
    ? llmEntities.category
    : regexEntities.category_hint;

  const description = (typeof llmEntities?.description === 'string' && llmEntities.description)
    ? llmEntities.description
    : regexEntities.description;

  const currency = regexEntities.currency;

  if (!amount) {
    return {
      answer: 'Укажите сумму транзакции. Например: "Запиши 500 на обед".',
      facts: [],
      actions: [
        { type: tx_type === 'income' ? 'open_add_income' : 'open_add_expense', label: 'Добавить вручную' },
      ],
      followUps: ['Запиши 500 на обед', 'Доход 50000 зарплата'],
    };
  }

  const matchedCategory = categoryHint
    ? fuzzyMatchCategory(categoryHint, categories, tx_type)
    : null;

  const typeLabel = tx_type === 'income' ? 'Доход' : 'Расход';
  const amountStr = formatAmountNeutral(amount);
  const categoryLabel = matchedCategory
    ? `«${matchedCategory.name}»`
    : (categoryHint ? `«${categoryHint}» (не найдена)` : '(категория не определена)');

  const answer = matchedCategory
    ? `Записать ${typeLabel.toLowerCase()}: ${amountStr}, категория ${categoryLabel}.`
    : `Записать ${typeLabel.toLowerCase()}: ${amountStr}, ${categoryLabel}. Подтвердите или выберите категорию вручную.`;

  const payload: Record<string, unknown> = {
    amount,
    tx_type,
    category_hint: categoryHint ?? null,
    description: description ?? null,
  };

  if (matchedCategory) {
    payload.category_id = matchedCategory.id;
    payload.category_name = matchedCategory.name;
  }

  if (currency) {
    payload.currency = currency;
  }

  return {
    answer,
    facts: [
      `${typeLabel}: ${amountStr}`,
      `Категория: ${matchedCategory?.name ?? categoryHint ?? 'не указана'}`,
    ],
    actions: [
      {
        type: 'create_transaction',
        label: `Записать ${typeLabel.toLowerCase()}`,
        payload,
      },
    ],
    followUps: ['Сколько потратил за месяц?', 'Остаток бюджета'],
  };
}

export function buildEditTransactionResponse(
  query: string,
  transactions: TxRow[],
  categories: CategoryRow[],
  llmEntities?: LLMClassificationResult['entities'],
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const txRef = llmEntities?.tx_ref ?? null;
  const newAmount = typeof llmEntities?.amount === 'number' && llmEntities.amount > 0
    ? llmEntities.amount
    : null;
  const newCategoryHint = typeof llmEntities?.category === 'string' && llmEntities.category
    ? llmEntities.category
    : null;
  const newDescription = typeof llmEntities?.description === 'string' && llmEntities.description
    ? llmEntities.description
    : null;

  const recentExpenses = transactions
    .filter((tx) => tx.type === 'expense' && !tx.transfer_group_id)
    .sort((a, b) => b.date.localeCompare(a.date));

  let targetTx: TxRow | null = null;

  if (txRef) {
    const refLower = normalizeForMatch(txRef);
    if (/последн|предыдущ/u.test(refLower)) {
      targetTx = recentExpenses[0] ?? null;
    } else if (/вчера/u.test(refLower)) {
      const yesterday = addDays(toDateOnly(new Date()), -1);
      targetTx = recentExpenses.find((tx) => tx.date.slice(0, 10) === yesterday) ?? null;
    } else {
      targetTx = transactions.find((tx) => {
        const catName = normalizeForMatch(tx.category?.name ?? '');
        return catName.includes(refLower) || refLower.includes(catName);
      }) ?? null;
    }
  } else {
    targetTx = recentExpenses[0] ?? null;
  }

  if (!targetTx) {
    return {
      answer: 'Не нашёл транзакцию для редактирования. Уточните, какую запись изменить.',
      facts: [],
      actions: [{ type: 'open_transactions', label: 'Открыть транзакции' }],
      followUps: ['Измени последнюю трату', 'Покажи крупные расходы'],
    };
  }

  const catName = targetTx.category?.name ?? 'Без категории';
  const currentAmount = safeNumber(targetTx.amount);

  const matchedCategory = newCategoryHint
    ? fuzzyMatchCategory(newCategoryHint, categories, targetTx.type)
    : null;

  const changes: string[] = [];
  const payload: Record<string, unknown> = {
    transaction_id: targetTx.id,
  };

  if (newAmount) {
    changes.push(`Сумма: ${formatMoney(currentAmount)} → ${formatMoney(newAmount)}`);
    payload.amount = newAmount;
  }
  if (matchedCategory) {
    changes.push(`Категория: ${catName} → ${matchedCategory.name}`);
    payload.category_id = matchedCategory.id;
    payload.category_name = matchedCategory.name;
  } else if (newCategoryHint) {
    changes.push(`Категория: ${catName} → «${newCategoryHint}» (не найдена)`);
  }
  if (newDescription) {
    changes.push(`Описание: «${newDescription}»`);
    payload.description = newDescription;
  }

  if (changes.length === 0) {
    return {
      answer: `Что вы хотите изменить в транзакции «${catName}» на ${formatMoney(currentAmount)} (${targetTx.date.slice(0, 10)})?`,
      facts: [`Текущая: ${catName}, ${formatMoney(currentAmount)}, ${targetTx.date.slice(0, 10)}`],
      actions: [{ type: 'open_transactions', label: 'Открыть транзакции' }],
      followUps: ['Поменяй сумму на 1000', `Поменяй категорию`, 'Удали эту трату'],
    };
  }

  return {
    answer: `Изменить транзакцию «${catName}» (${formatMoney(currentAmount)}, ${targetTx.date.slice(0, 10)}):`,
    facts: changes,
    actions: [
      {
        type: 'edit_transaction',
        label: 'Изменить транзакцию',
        payload,
      },
    ],
    followUps: ['Удали эту трату', 'Сколько потратил за месяц?'],
  };
}

export function buildDeleteTransactionResponse(
  query: string,
  transactions: TxRow[],
  llmEntities?: LLMClassificationResult['entities'],
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const txRef = llmEntities?.tx_ref ?? null;

  const recentTxs = [...transactions].sort((a, b) => b.date.localeCompare(a.date));

  let targetTx: TxRow | null = null;

  if (txRef) {
    const refLower = normalizeForMatch(txRef);
    if (/последн|предыдущ/u.test(refLower)) {
      targetTx = recentTxs[0] ?? null;
    } else if (/вчера/u.test(refLower)) {
      const yesterday = addDays(toDateOnly(new Date()), -1);
      targetTx = recentTxs.find((tx) => tx.date.slice(0, 10) === yesterday) ?? null;
    } else {
      targetTx = recentTxs.find((tx) => {
        const catName = normalizeForMatch(tx.category?.name ?? '');
        return catName.includes(refLower) || refLower.includes(catName);
      }) ?? null;
    }
  } else {
    targetTx = recentTxs[0] ?? null;
  }

  if (!targetTx) {
    return {
      answer: 'Не нашёл транзакцию для удаления. Уточните, какую запись удалить.',
      facts: [],
      actions: [{ type: 'open_transactions', label: 'Открыть транзакции' }],
      followUps: ['Удали последнюю трату', 'Покажи крупные расходы'],
    };
  }

  const catName = targetTx.category?.name ?? 'Без категории';
  const amount = safeNumber(targetTx.amount);
  const typeLabel = targetTx.type === 'income' ? 'доход' : 'расход';

  return {
    answer: `Удалить ${typeLabel}: ${formatMoney(amount)}, категория «${catName}» (${targetTx.date.slice(0, 10)})?`,
    facts: [
      `${targetTx.type === 'income' ? 'Доход' : 'Расход'}: ${formatMoney(amount)}`,
      `Категория: ${catName}`,
      `Дата: ${targetTx.date.slice(0, 10)}`,
    ],
    actions: [
      {
        type: 'delete_transaction',
        label: `Удалить ${typeLabel}`,
        payload: {
          transaction_id: targetTx.id,
          amount,
          category_name: catName,
        },
      },
    ],
    followUps: ['Сколько потратил за месяц?', 'Последние транзакции'],
  };
}

export async function buildEditBudgetResponse(
  query: string,
  anonClient: SupabaseClient,
  llmEntities?: LLMClassificationResult['entities'],
  userId?: string,
): Promise<{ answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] }> {
  const categoryHint = typeof llmEntities?.category === 'string' && llmEntities.category
    ? llmEntities.category
    : null;
  const newAmount = typeof llmEntities?.amount === 'number' && llmEntities.amount > 0
    ? llmEntities.amount
    : null;

  let resolvedAmount = newAmount;
  if (!resolvedAmount) {
    const amountMatch = query.match(/(\d[\d\s.,]*\d|\d+)\s*(к|тыс|руб)?/u);
    if (amountMatch) {
      let num = Number(amountMatch[1].replace(/[\s,]/g, '').replace(',', '.'));
      if (amountMatch[2] && /к|тыс/u.test(amountMatch[2])) num *= 1000;
      if (num > 0) resolvedAmount = num;
    }
  }

  let bq = anonClient
    .from('budgets')
    .select('id,amount,category_ids,period_type,is_active')
    .eq('is_active', true);
  if (userId) bq = bq.eq('user_id', userId);
  const { data: budgetsData } = await bq.limit(300);

  const budgets = ((budgetsData ?? []) as BudgetRow[]).filter((b) => b.is_active);

  if (budgets.length === 0) {
    return {
      answer: 'Активных бюджетов нет. Создайте бюджет, чтобы его можно было редактировать.',
      facts: [],
      actions: [{ type: 'open_budget_tab', label: 'Создать бюджет' }],
      followUps: ['Создай бюджет на еду', 'Сводка расходов'],
    };
  }

  let targetBudget: BudgetRow | null = null;
  let budgetCategoryName: string | null = null;

  if (categoryHint) {
    const { data: cats } = await anonClient.from('categories').select('id,name,type').limit(500);
    const categories = (cats ?? []) as CategoryRow[];

    const hintLower = normalizeForMatch(categoryHint);
    const matchedCat = categories.find((c) => normalizeForMatch(c.name).includes(hintLower));

    if (matchedCat) {
      targetBudget = budgets.find((b) => b.category_ids.includes(matchedCat.id)) ?? null;
      budgetCategoryName = matchedCat.name;
    }
  }

  if (!targetBudget) {
    targetBudget = budgets[0];
    if (targetBudget.category_ids.length > 0) {
      const { data: cats } = await anonClient
        .from('categories')
        .select('id,name')
        .in('id', targetBudget.category_ids.slice(0, 3))
        .limit(3);
      budgetCategoryName = (cats ?? []).map((c: { name: string }) => c.name).join(', ') || null;
    }
  }

  const currentAmount = safeNumber(targetBudget.amount);
  const label = budgetCategoryName ?? 'Бюджет';

  if (!resolvedAmount) {
    return {
      answer: `Какой новый лимит установить для бюджета «${label}» (текущий: ${formatMoney(currentAmount)})?`,
      facts: [`Текущий лимит: ${formatMoney(currentAmount)}`, `Тип: ${targetBudget.period_type === 'weekly' ? 'еженедельный' : 'ежемесячный'}`],
      actions: [{ type: 'open_budget_tab', label: 'Открыть бюджеты' }],
      followUps: [`Установи ${formatMoney(currentAmount * 1.2)}`, `Установи ${formatMoney(currentAmount * 0.8)}`],
    };
  }

  const direction = resolvedAmount > currentAmount ? 'Увеличить' : 'Уменьшить';

  return {
    answer: `${direction} лимит бюджета «${label}» с ${formatMoney(currentAmount)} до ${formatMoney(resolvedAmount)}?`,
    facts: [
      `Бюджет: ${label}`,
      `Текущий лимит: ${formatMoney(currentAmount)}`,
      `Новый лимит: ${formatMoney(resolvedAmount)}`,
      `Изменение: ${resolvedAmount > currentAmount ? '+' : ''}${formatMoney(resolvedAmount - currentAmount)}`,
    ],
    actions: [
      {
        type: 'edit_budget',
        label: `${direction} до ${formatMoney(resolvedAmount)}`,
        payload: {
          budget_id: targetBudget.id,
          new_amount: resolvedAmount,
          old_amount: currentAmount,
          category_name: budgetCategoryName,
        },
      },
    ],
    followUps: ['Остаток бюджета', 'Риски по бюджетам'],
  };
}

export function buildSeasonalForecastResponse(
  transactions: TxRow[],
  today: string,
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const todayDate = parseDateOnly(today);
  const currentMonth = todayDate.getUTCMonth();
  const currentYear = todayDate.getUTCFullYear();
  const dayOfMonth = todayDate.getUTCDate();

  const sixMonthsAgo = addDays(today, -180);
  const expenses = transactions.filter(
    (tx) => tx.type === 'expense' && !tx.transfer_group_id && tx.date.slice(0, 10) >= sixMonthsAgo && tx.date.slice(0, 10) <= today,
  );

  if (expenses.length < 10) {
    return {
      answer: 'Недостаточно данных для сезонного прогноза (нужно минимум 10 расходов за 6 месяцев).',
      facts: [],
      actions: [{ type: 'open_add_expense', label: 'Добавить расход' }],
      followUps: ['Сводка расходов', 'Прогноз'],
    };
  }

  const monthStart = `${currentYear}-${String(currentMonth + 1).padStart(2, '0')}-01`;
  const thisMonthExpenses = expenses.filter((tx) => tx.date.slice(0, 10) >= monthStart);
  const thisMonthTotal = thisMonthExpenses.reduce((s, tx) => s + safeNumber(tx.amount), 0);
  const currentPaceDaily = dayOfMonth > 0 ? thisMonthTotal / dayOfMonth : 0;

  const sameMonthLastYear = `${currentYear - 1}-${String(currentMonth + 1).padStart(2, '0')}`;
  const sameMonthLastYearTxs = transactions.filter(
    (tx) => tx.type === 'expense' && !tx.transfer_group_id && tx.date.slice(0, 7) === sameMonthLastYear,
  );
  const sameMonthLastYearTotal = sameMonthLastYearTxs.reduce((s, tx) => s + safeNumber(tx.amount), 0);

  const threeMonthsAgo = addDays(today, -90);
  const last3MonthExpenses = expenses.filter((tx) => tx.date.slice(0, 10) >= threeMonthsAgo);
  const last3MonthTotal = last3MonthExpenses.reduce((s, tx) => s + safeNumber(tx.amount), 0);
  const rolling3MonthAvg = last3MonthTotal / 3;

  const daysInMonth = new Date(currentYear, currentMonth + 1, 0).getUTCDate();
  const projectedFromPace = currentPaceDaily * daysInMonth;

  let totalWeight = 0;
  let weightedSum = 0;

  if (currentPaceDaily > 0) {
    weightedSum += projectedFromPace * 0.4;
    totalWeight += 0.4;
  }

  if (sameMonthLastYearTotal > 0) {
    weightedSum += sameMonthLastYearTotal * 0.3;
    totalWeight += 0.3;
  }

  if (rolling3MonthAvg > 0) {
    weightedSum += rolling3MonthAvg * 0.3;
    totalWeight += 0.3;
  }

  const forecast = totalWeight > 0 ? weightedSum / totalWeight : projectedFromPace;

  const dailyAmounts = new Map<string, number>();
  for (const tx of expenses) {
    const d = tx.date.slice(0, 10);
    dailyAmounts.set(d, (dailyAmounts.get(d) ?? 0) + safeNumber(tx.amount));
  }
  const dailyValues = [...dailyAmounts.values()];
  const dailyMean = dailyValues.reduce((s, v) => s + v, 0) / (dailyValues.length || 1);
  const dailyStdDev = Math.sqrt(
    dailyValues.reduce((s, v) => s + (v - dailyMean) ** 2, 0) / (dailyValues.length || 1),
  );
  const remainingDays = Math.max(0, daysInMonth - dayOfMonth);
  const confidenceMargin = dailyStdDev * Math.sqrt(remainingDays) * 1.96;

  let seasonalFact = '';
  if (sameMonthLastYearTotal > 0 && rolling3MonthAvg > 0) {
    const seasonalDelta = ((sameMonthLastYearTotal - rolling3MonthAvg) / rolling3MonthAvg) * 100;
    const monthNames = ['январе', 'феврале', 'марте', 'апреле', 'мае', 'июне', 'июле', 'августе', 'сентябре', 'октябре', 'ноябре', 'декабре'];
    if (Math.abs(seasonalDelta) > 10) {
      const direction = seasonalDelta > 0 ? 'выше' : 'ниже';
      seasonalFact = `Обычно в ${monthNames[currentMonth]} расходы ${direction} на ${Math.abs(Math.round(seasonalDelta))}%`;
    }
  }

  const facts: string[] = [
    `Текущий темп: ${formatMoney(currentPaceDaily)} / день`,
    `Прогноз на месяц: ${formatMoney(forecast)}`,
    `Диапазон: ${formatMoney(Math.max(0, forecast - confidenceMargin))} – ${formatMoney(forecast + confidenceMargin)}`,
  ];

  if (sameMonthLastYearTotal > 0) {
    facts.push(`Тот же месяц год назад: ${formatMoney(sameMonthLastYearTotal)}`);
  }
  if (seasonalFact) {
    facts.push(seasonalFact);
  }

  return {
    answer: `Сезонный прогноз расходов: ~${formatMoney(forecast)} (±${formatMoney(confidenceMargin)}). Осталось ${remainingDays} дней.`,
    facts,
    actions: [
      { type: 'open_budget_tab', label: 'Проверить бюджеты' },
      { type: 'open_transactions', label: 'Открыть транзакции' },
    ],
    followUps: ['Остаток бюджета', 'Топ категорий', 'Сводка расходов'],
  };
}

export function detectRecurringPatterns(transactions: TxRow[], today: string): RecurringPattern[] {
  const expenses = transactions
    .filter((tx) => tx.type === 'expense' && !tx.transfer_group_id)
    .sort((a, b) => a.date.localeCompare(b.date));

  const groups = new Map<string, { description: string; amounts: number[]; dates: string[] }>();

  for (const tx of expenses) {
    const key = tx.merchant_normalized
      ?? (tx.merchant_name ? normalizeForMatch(tx.merchant_name) : null)
      ?? (tx.category?.name ? normalizeForMatch(tx.category.name) : null)
      ?? '';
    if (!key || key.length < 2) continue;

    const label = tx.merchant_name?.trim() ?? tx.category?.name?.trim() ?? key;
    const entry = groups.get(key) ?? { description: label, amounts: [], dates: [] };
    entry.amounts.push(safeNumber(tx.amount));
    entry.dates.push(tx.date.slice(0, 10));
    if (entry.description === key && label !== key) entry.description = label;
    groups.set(key, entry);
  }

  const patterns: RecurringPattern[] = [];

  for (const [, group] of groups) {
    if (group.dates.length < 3) continue;

    const uniqueDates = [...new Set(group.dates)].sort();
    if (uniqueDates.length < 3) continue;

    const intervals: number[] = [];
    for (let i = 1; i < uniqueDates.length; i++) {
      const diff = Math.abs(
        (parseDateOnly(uniqueDates[i]).getTime() - parseDateOnly(uniqueDates[i - 1]).getTime()) / (24 * 60 * 60 * 1000),
      );
      if (diff > 0) intervals.push(diff);
    }
    if (intervals.length < 2) continue;

    const sortedIntervals = [...intervals].sort((a, b) => a - b);
    const medianInterval = sortedIntervals[Math.floor(sortedIntervals.length / 2)];

    const intervalMean = sortedIntervals.reduce((s, v) => s + v, 0) / sortedIntervals.length;
    const intervalStdDev = Math.sqrt(
      sortedIntervals.reduce((s, v) => s + (v - intervalMean) ** 2, 0) / sortedIntervals.length,
    );

    let frequency: 'monthly' | 'weekly' | 'unknown' = 'unknown';
    if (medianInterval >= 25 && medianInterval <= 35 && intervalStdDev <= 5) {
      frequency = 'monthly';
    } else if (medianInterval >= 5 && medianInterval <= 9 && intervalStdDev <= 2) {
      frequency = 'weekly';
    } else {
      continue;
    }

    const sortedAmounts = [...group.amounts].sort((a, b) => a - b);
    const medianAmount = sortedAmounts[Math.floor(sortedAmounts.length / 2)];
    const amountStable = group.amounts.every((a) => Math.abs(a - medianAmount) / medianAmount <= 0.1);

    const pointScore = Math.min(1, group.dates.length / 10) * 0.4;
    const intervalScore = (1 - Math.min(1, intervalStdDev / medianInterval)) * 0.4;
    const amountScore = amountStable ? 0.2 : 0.05;
    const confidence = Math.round((pointScore + intervalScore + amountScore) * 100) / 100;

    if (confidence < 0.3) continue;

    const lastDate = uniqueDates[uniqueDates.length - 1];
    const nextExpectedDate = addDays(lastDate, Math.round(medianInterval));

    patterns.push({
      description: group.description,
      frequency,
      medianAmount,
      medianIntervalDays: Math.round(medianInterval),
      nextExpectedDate,
      confidence,
      count: uniqueDates.length,
    });
  }

  patterns.sort((a, b) => b.confidence - a.confidence);
  return patterns.slice(0, 10);
}

export function buildRecurringPatternsResponse(
  transactions: TxRow[],
  today: string,
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const patterns = detectRecurringPatterns(transactions, today);

  if (patterns.length === 0) {
    return {
      answer: 'Не обнаружил регулярных платежей. Нужно минимум 3 похожих транзакции с одинаковым интервалом.',
      facts: [],
      actions: [{ type: 'open_transactions', label: 'Открыть транзакции' }],
      followUps: ['Сводка расходов', 'Топ категорий'],
    };
  }

  const top5 = patterns.slice(0, 5);
  const totalMonthly = top5.reduce((sum, p) => {
    if (p.frequency === 'monthly') return sum + p.medianAmount;
    if (p.frequency === 'weekly') return sum + p.medianAmount * 4.33;
    return sum;
  }, 0);

  const freqLabel = (f: string) => f === 'monthly' ? 'ежемесячно' : f === 'weekly' ? 'еженедельно' : '';

  const facts = top5.map((p, idx) =>
    `${idx + 1}. ${p.description}: ${formatMoney(p.medianAmount)} ${freqLabel(p.frequency)}, след. ${p.nextExpectedDate}`,
  );

  facts.push(`Итого регулярных в месяц: ~${formatMoney(totalMonthly)}`);

  return {
    answer: `Найдено ${patterns.length} регулярных платежей. Ежемесячная сумма: ~${formatMoney(totalMonthly)}.`,
    facts,
    actions: [{ type: 'open_transactions', label: 'Посмотреть транзакции' }],
    followUps: ['Сводка расходов', 'Топ категорий', 'Прогноз'],
  };
}

export async function buildSavingsAdviceResponse(
  anonClient: SupabaseClient,
  userId?: string,
): Promise<{ answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] }> {
  let gq = anonClient
    .from('savings_goals')
    .select('id,name,target_amount,current_amount,deadline,status,monthly_target')
    .eq('status', 'active');
  if (userId) gq = gq.eq('user_id', userId);
  const { data: goalsData } = await gq.limit(20);

  const goals = (goalsData ?? []) as SavingsGoalRow[];

  if (goals.length === 0) {
    return {
      answer: 'У вас пока нет активных целей накопления. Создайте цель, чтобы начать копить!',
      facts: [],
      actions: [{ type: 'open_savings', label: 'Открыть накопления' }],
      followUps: ['Сводка расходов', 'Прогноз'],
    };
  }

  const sixtyDaysAgo = new Date();
  sixtyDaysAgo.setDate(sixtyDaysAgo.getDate() - 60);
  const goalIds = goals.map((g) => g.id);

  const { data: contribData } = await anonClient
    .from('savings_contributions')
    .select('goal_id,amount,created_at')
    .in('goal_id', goalIds)
    .gte('created_at', sixtyDaysAgo.toISOString())
    .limit(500);

  const contributions = (contribData ?? []) as SavingsContributionRow[];

  const facts: string[] = [];
  const followUps: string[] = [];

  for (const goal of goals.slice(0, 4)) {
    const progress = goal.target_amount > 0
      ? Math.round((goal.current_amount / goal.target_amount) * 100)
      : 0;
    const remaining = Math.max(0, goal.target_amount - goal.current_amount);

    const goalContribs = contributions.filter((c) => c.goal_id === goal.id);
    const totalContribs = goalContribs.reduce((s, c) => s + safeNumber(c.amount), 0);
    const avgMonthly = totalContribs > 0 ? totalContribs / 2 : 0;

    let projectedCompletion = '';
    if (avgMonthly > 0 && remaining > 0) {
      const monthsLeft = Math.ceil(remaining / avgMonthly);
      projectedCompletion = `, завершение ~через ${monthsLeft} мес.`;
    } else if (goal.deadline) {
      projectedCompletion = `, дедлайн: ${goal.deadline.slice(0, 10)}`;
    }

    facts.push(`${goal.name}: ${formatMoney(goal.current_amount)} из ${formatMoney(goal.target_amount)} (${progress}%${projectedCompletion})`);
    followUps.push(`Внести на цель ${goal.name}`);
  }

  const totalProgress = goals.reduce((s, g) => s + g.current_amount, 0);
  const totalTarget = goals.reduce((s, g) => s + g.target_amount, 0);
  const overallPercent = totalTarget > 0 ? Math.round((totalProgress / totalTarget) * 100) : 0;

  return {
    answer: `У вас ${goals.length} активных целей. Общий прогресс: ${overallPercent}% (${formatMoney(totalProgress)} из ${formatMoney(totalTarget)}).`,
    facts,
    actions: [{ type: 'open_savings', label: 'Открыть накопления' }],
    followUps: followUps.slice(0, 3),
  };
}

export function buildSavingsContributeResponse(
  query: string,
  goals: SavingsGoalRow[],
  llmEntities?: LLMClassificationResult['entities'],
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  const amountMatch = normalizeForMatch(query).match(/(\d[\d\s]*[\d](?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)/);
  let amount: number | null = null;
  if (amountMatch) {
    const raw = amountMatch[1].replace(/\s/g, '').replace(',', '.');
    const parsed = parseFloat(raw);
    if (Number.isFinite(parsed) && parsed > 0) amount = parsed;
  }
  if (typeof llmEntities?.amount === 'number' && llmEntities.amount > 0) {
    amount = llmEntities.amount;
  }

  if (!amount) {
    return {
      answer: 'Укажите сумму для внесения. Например: "Внеси 5000 на цель Отпуск".',
      facts: [],
      actions: [{ type: 'open_savings', label: 'Открыть накопления' }],
      followUps: ['Как дела с целями?', 'Сводка расходов'],
    };
  }

  const goalHint = llmEntities?.description ?? null;
  let matchedGoal: SavingsGoalRow | null = null;

  if (goalHint) {
    const hintLower = normalizeForMatch(goalHint);
    matchedGoal = goals.find((g) => normalizeForMatch(g.name).includes(hintLower)) ?? null;
    if (!matchedGoal) {
      matchedGoal = goals.find((g) => hintLower.includes(normalizeForMatch(g.name))) ?? null;
    }
  }

  if (!matchedGoal && goals.length === 1) {
    matchedGoal = goals[0];
  }

  if (!matchedGoal) {
    const goalNames = goals.map((g) => g.name).join(', ');
    return {
      answer: `Не удалось определить цель. Доступные цели: ${goalNames}. Уточните: "Внеси ${formatAmountNeutral(amount)} на цель <имя>".`,
      facts: [],
      actions: [{ type: 'open_savings', label: 'Открыть накопления' }],
      followUps: goals.slice(0, 2).map((g) => `Внеси ${formatAmountNeutral(amount!)} на цель ${g.name}`),
    };
  }

  const currentProgress = matchedGoal.target_amount > 0
    ? Math.round((matchedGoal.current_amount / matchedGoal.target_amount) * 100)
    : 0;
  const afterProgress = matchedGoal.target_amount > 0
    ? Math.round(((matchedGoal.current_amount + amount) / matchedGoal.target_amount) * 100)
    : 0;

  return {
    answer: `Внести ${formatMoney(amount)} на цель «${matchedGoal.name}»? Прогресс: ${currentProgress}% → ${afterProgress}%.`,
    facts: [
      `Цель: ${matchedGoal.name}`,
      `Текущий: ${formatMoney(matchedGoal.current_amount)} из ${formatMoney(matchedGoal.target_amount)}`,
      `После взноса: ${formatMoney(matchedGoal.current_amount + amount)} (${afterProgress}%)`,
    ],
    actions: [
      {
        type: 'savings_contribute',
        label: `Внести ${formatAmountNeutral(amount)}`,
        payload: {
          goal_id: matchedGoal.id,
          goal_name: matchedGoal.name,
          amount,
        },
      },
    ],
    followUps: ['Как дела с целями?', 'Сводка расходов'],
  };
}

// ── Smart Budget Create ──

export function buildSmartBudgetCreateResponse(
  transactions: TxRow[],
  currentWindow: PeriodWindow,
  entities?: LLMClassificationResult['entities'],
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  // Last 60 days of expense transactions (non-transfer)
  const sixtyDaysAgo = addDays(currentWindow.end, -60);
  const recentTxs = transactions.filter(
    (tx) => tx.type === 'expense' && !tx.transfer_group_id && tx.date.slice(0, 10) >= sixtyDaysAgo && tx.date.slice(0, 10) <= currentWindow.end,
  );

  if (recentTxs.length === 0) {
    return {
      answer: 'Недостаточно данных для создания бюджетов. Добавьте транзакции за последние 2 месяца.',
      facts: ['Для анализа нужны расходы минимум за 30 дней.'],
      actions: [{ type: 'open_add_expense', label: 'Добавить расход' }],
      followUps: ['Сводка расходов', 'Помощь'],
    };
  }

  // Group by category
  const categorySpend = new Map<string, { total: number; categoryId: string }>();
  for (const tx of recentTxs) {
    const name = tx.category?.name?.trim() || 'Без категории';
    const existing = categorySpend.get(name) ?? { total: 0, categoryId: tx.category_id };
    existing.total += safeNumber(tx.amount);
    categorySpend.set(name, existing);
  }

  // Calculate days in range for monthly average
  const actualDays = Math.max(1, diffDaysInclusive(sixtyDaysAgo, currentWindow.end));
  const monthMultiplier = 30 / actualDays;

  // Sort by spending, take top 7
  let sorted = [...categorySpend.entries()]
    .map(([name, { total, categoryId }]) => ({
      name,
      categoryId,
      monthlyAvg: total * monthMultiplier,
    }))
    .sort((a, b) => b.monthlyAvg - a.monthlyAvg)
    .slice(0, 7);

  // Follow-up filtering: if user specified a specific category, filter to it
  const categoryHint = entities?.category;
  let isFiltered = false;
  if (categoryHint && typeof categoryHint === 'string') {
    const hintNorm = normalizeForMatch(categoryHint);
    // Direct match
    let filtered = sorted.filter((c) => {
      const catNorm = normalizeForMatch(c.name);
      return catNorm.includes(hintNorm) || hintNorm.includes(catNorm);
    });
    // Synonym fallback
    if (filtered.length === 0) {
      for (const [canonical, synonyms] of Object.entries(CATEGORY_SYNONYMS)) {
        const allTerms = [canonical, ...synonyms];
        if (allTerms.some((s) => normalizeForMatch(s).includes(hintNorm) || hintNorm.includes(normalizeForMatch(s)))) {
          filtered = sorted.filter((c) => {
            const catNorm = normalizeForMatch(c.name);
            return allTerms.some((s) => catNorm.includes(normalizeForMatch(s)) || normalizeForMatch(s).includes(catNorm));
          });
          if (filtered.length > 0) break;
        }
      }
    }
    if (filtered.length > 0) {
      sorted = filtered;
      isFiltered = true;
    }
  }

  if (sorted.length === 0) {
    return {
      answer: 'Не нашлось категорий с расходами для создания бюджетов.',
      facts: [],
      actions: [{ type: 'open_add_expense', label: 'Добавить расход' }],
      followUps: ['Сводка расходов'],
    };
  }

  // Suggest budget = average + 10% buffer, rounded nicely
  const budgetPlan = sorted.map((cat) => {
    const raw = cat.monthlyAvg * 1.1;
    // Round to nearest 100 if > 1000, nearest 50 if > 500, nearest 10 otherwise
    let suggested: number;
    if (raw >= 1000) {
      suggested = Math.ceil(raw / 100) * 100;
    } else if (raw >= 500) {
      suggested = Math.ceil(raw / 50) * 50;
    } else {
      suggested = Math.max(100, Math.ceil(raw / 10) * 10);
    }
    return { ...cat, suggested };
  });

  // If follow-up specifies a custom amount for a single filtered budget, use it
  if (isFiltered && budgetPlan.length === 1 && typeof entities?.amount === 'number' && entities.amount > 0) {
    budgetPlan[0].suggested = entities.amount;
  }

  const totalSuggested = budgetPlan.reduce((sum, b) => sum + b.suggested, 0);

  const facts = budgetPlan.map(
    (b) => `${b.name}: ~${formatMoney(Math.round(b.monthlyAvg))}/мес → бюджет ${formatMoney(b.suggested)}`,
  );
  if (budgetPlan.length > 1) {
    facts.push(`Итого бюджетов: ${formatMoney(totalSuggested)}/мес`);
  }

  // Build action payload with budget plan
  const budgetItems = budgetPlan.map((b) => ({
    category_id: b.categoryId,
    category_name: b.name,
    amount: b.suggested,
  }));

  const answer = isFiltered && budgetPlan.length === 1
    ? `Предлагаю создать бюджет для «${budgetPlan[0].name}» на ${formatMoney(budgetPlan[0].suggested)}/мес:`
    : `На основе ваших расходов за 60 дней предлагаю создать ${budgetPlan.length} бюджетов с запасом +10%:`;

  return {
    answer,
    facts,
    actions: [
      {
        type: 'smart_budget_create',
        label: budgetPlan.length === 1 ? 'Создать бюджет' : `Создать ${budgetPlan.length} бюджетов`,
        payload: {
          budgets: budgetItems,
        },
      },
    ],
    followUps: ['Остаток бюджета', 'Сравни с прошлым месяцем', 'Топ категорий'],
  };
}

// ── Spending Optimization ──

export function buildSpendingOptimizationResponse(
  transactions: TxRow[],
  currentWindow: PeriodWindow,
): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[]; recommendedActions?: RecommendedAction[] } {
  // Last 90 days of expense transactions
  const ninetyDaysAgo = addDays(currentWindow.end, -90);
  const recentTxs = transactions.filter(
    (tx) => tx.type === 'expense' && !tx.transfer_group_id && tx.date.slice(0, 10) >= ninetyDaysAgo && tx.date.slice(0, 10) <= currentWindow.end,
  );

  if (recentTxs.length === 0) {
    return {
      answer: 'Недостаточно данных для анализа оптимизации. Добавьте транзакции за последние месяцы.',
      facts: ['Для анализа нужны расходы минимум за 30 дней.'],
      actions: [{ type: 'open_add_expense', label: 'Добавить расход' }],
      followUps: ['Сводка расходов', 'Помощь'],
    };
  }

  // Split into 3 months
  const month1End = currentWindow.end;
  const month1Start = addDays(month1End, -29);
  const month2End = addDays(month1Start, -1);
  const month2Start = addDays(month2End, -29);
  const month3End = addDays(month2Start, -1);
  const month3Start = addDays(month3End, -29);

  const months = [
    { start: month3Start, end: month3End },
    { start: month2Start, end: month2End },
    { start: month1Start, end: month1End },
  ];

  // Monthly spending per category
  const monthlyByCategory: Array<Map<string, number>> = months.map((m) => {
    const map = new Map<string, number>();
    for (const tx of recentTxs) {
      const d = tx.date.slice(0, 10);
      if (d >= m.start && d <= m.end) {
        const name = tx.category?.name?.trim() || 'Без категории';
        map.set(name, (map.get(name) ?? 0) + safeNumber(tx.amount));
      }
    }
    return map;
  });

  const facts: string[] = [];
  const followUps: string[] = [];
  const recommendedActions: RecommendedAction[] = [];
  let totalPotentialSavings = 0;

  // 1. Growing categories: month-over-month >15%
  const allCatNames = new Set<string>();
  for (const m of monthlyByCategory) {
    for (const k of m.keys()) allCatNames.add(k);
  }

  const growingCategories: Array<{ name: string; growthPercent: number; latestAmount: number }> = [];
  for (const name of allCatNames) {
    const m2 = monthlyByCategory[1].get(name) ?? 0;
    const m3 = monthlyByCategory[2].get(name) ?? 0; // latest month
    if (m2 > 0 && m3 > m2) {
      const growth = Math.round(((m3 - m2) / m2) * 100);
      if (growth > 15) {
        growingCategories.push({ name, growthPercent: growth, latestAmount: m3 });
        totalPotentialSavings += Math.round((m3 - m2) * 0.5); // estimate 50% of growth as saveable
      }
    }
  }

  growingCategories.sort((a, b) => b.growthPercent - a.growthPercent);
  for (const cat of growingCategories.slice(0, 3)) {
    facts.push(`📈 «${cat.name}» выросла на ${cat.growthPercent}% (${formatMoney(cat.latestAmount)}/мес)`);
  }

  // 2. High-frequency small transactions (potential subscriptions)
  const merchantCounts = new Map<string, { count: number; total: number }>();
  for (const tx of recentTxs) {
    const merchant = tx.merchant_normalized ?? tx.merchant_name ?? tx.category?.name?.trim();
    if (!merchant) continue;
    const existing = merchantCounts.get(merchant) ?? { count: 0, total: 0 };
    existing.count++;
    existing.total += safeNumber(tx.amount);
    merchantCounts.set(merchant, existing);
  }

  const potentialSubscriptions = [...merchantCounts.entries()]
    .filter(([_, v]) => v.count >= 3)
    .sort((a, b) => b[1].count - a[1].count)
    .slice(0, 3);

  for (const [name, { count, total }] of potentialSubscriptions) {
    const avg = Math.round(total / count);
    facts.push(`🔄 «${name}»: ${count} операций, ~${formatMoney(avg)} каждая`);
    totalPotentialSavings += Math.round(avg * 0.3); // estimate 30% as saveable per recurring
  }

  // 3. Top discretionary categories by total spend
  const ESSENTIAL_KEYWORDS = ['аренда', 'квартплата', 'коммуналь', 'ипотек', 'кредит', 'связь', 'интернет', 'транспорт'];
  const latestMonthSpend = monthlyByCategory[2]; // most recent month
  const discretionary = [...latestMonthSpend.entries()]
    .filter(([name, _]) => !ESSENTIAL_KEYWORDS.some((kw) => name.toLowerCase().includes(kw)))
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3);

  if (discretionary.length > 0 && facts.length < 8) {
    for (const [name, amount] of discretionary) {
      if (!facts.some((f) => f.includes(`«${name}»`))) {
        facts.push(`💡 «${name}»: ${formatMoney(amount)}/мес — можно сократить?`);
      }
    }
  }

  // Total potential savings fact
  if (totalPotentialSavings > 0) {
    facts.push(`💰 Потенциальная экономия: ~${formatMoney(totalPotentialSavings)}/мес`);
  }

  // Build answer
  const insights: string[] = [];
  if (growingCategories.length > 0) {
    insights.push(`${growingCategories.length} категори${growingCategories.length === 1 ? 'я растёт' : 'и растут'}`);
  }
  if (potentialSubscriptions.length > 0) {
    insights.push(`${potentialSubscriptions.length} повторяющ${potentialSubscriptions.length === 1 ? 'ийся' : 'ихся'} платеж${potentialSubscriptions.length === 1 ? '' : 'а'}`);
  }

  let answer: string;
  if (insights.length > 0) {
    answer = `Анализ расходов за 90 дней: ${insights.join(', ')}.${totalPotentialSavings > 0 ? ` Можно сэкономить ~${formatMoney(totalPotentialSavings)}/мес.` : ''}`;
  } else {
    answer = 'Расходы стабильны за последние 3 месяца. Явных точек оптимизации не обнаружено.';
  }

  // Follow-ups
  followUps.push('Создать бюджеты для контроля расходов?');
  if (growingCategories.length > 0) {
    followUps.push(`Подробнее о категории «${growingCategories[0].name}»?`);
  }
  followUps.push('Сравни с прошлым месяцем');

  // Recommended actions for growing categories
  for (const cat of growingCategories.slice(0, 3)) {
    recommendedActions.push({
      id: `optim_budget_${cat.name.toLowerCase().replace(/\s+/g, '_')}`,
      label: `Создать бюджет для «${cat.name}»`,
      action_type: 'create_budget_suggestion',
      payload: { category: cat.name },
    });
  }

  return {
    answer,
    facts: facts.slice(0, 10),
    actions: [{ type: 'open_transactions', label: 'Разобрать расходы' }],
    followUps: followUps.slice(0, 3),
    ...(recommendedActions.length > 0 ? { recommendedActions } : {}),
  };
}

export function helpResponse(): { answer: string; facts: string[]; actions: AssistantAction[]; followUps: string[] } {
  return {
    answer:
      'Я могу помочь с расходами, бюджетами, прогнозами и аналитикой. Вот что я умею:',
    facts: [
      '"Сколько потратил за месяц" — сводка',
      '"Топ категорий" — куда уходят деньги',
      '"Прогноз на следующий месяц" — сезонный прогноз',
      '"Найди подписки" — регулярные платежи',
      '"Как дела с целями?" — прогресс накоплений',
      '"Внеси 5000 на цель Отпуск" — пополнить цель',
      '"Запиши 500 на обед" — добавить транзакцию',
      '"Удали последнюю транзакцию" — удалить',
      '"Увеличь бюджет на еду до 30к" — изменить бюджет',
    ],
    actions: [
      { type: 'open_transactions', label: 'Открыть транзакции' },
      { type: 'open_budget_tab', label: 'Открыть бюджеты' },
    ],
    followUps: ['Траты за неделю', 'Топ категорий', 'Прогноз'],
  };
}
