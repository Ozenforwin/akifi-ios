import { createOpenAIJsonCompletion } from '../_shared/openai.ts';
import { createAnthropicJsonCompletion } from '../_shared/anthropic.ts';
import { formatMoney } from '../_shared/utils.ts';
import type { AssistantAction } from '../_shared/assistant-schema.ts';
import { retrieveKnowledgeSections } from './knowledge-retrieval.ts';
import { detectFinancialStage, type UserFinancialProfile } from './profile-detector.ts';
import type { TxRow, ConversationMessage, SupabaseClient } from './types.ts';

const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY') ?? '';
const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';
const OPENAI_MODEL = Deno.env.get('OPENAI_MODEL') ?? 'gpt-4o-mini';
const COACHING_MODEL = ANTHROPIC_API_KEY ? 'claude-haiku-4-5-20251001' : OPENAI_MODEL;
const COACHING_VERSION = 'v4'; // bump to force cold start verification
console.log(`coaching-builders loaded: ${COACHING_VERSION}`);

// ── Coaching persona (layer 1, ~200 tokens constant) ──

const COACHING_PERSONA = `Ты — финансовый коуч в приложении Akifi.

ПРАВИЛА:
1. Используй ТОЛЬКО данные из раздела "Данные пользователя"
2. Можешь и ДОЛЖЕН: складывать, вычитать, считать проценты, средние, сравнивать периоды
3. Если в данных "Долги: нет" — НЕ упоминай долги и кредиты
4. Если данных нет — НЕ придумывай
5. Отвечай на том же языке, на котором задан вопрос
6. Используй **жирный** для ключевых цифр
7. ОБЯЗАТЕЛЬНО: когда называешь сумму расходов или доходов, всегда указывай, за какой период эта сумма (возьми "Период анализа" из данных пользователя — например, "за 3 месяца", "в среднем в месяц"). Пользователь должен понимать, к какому промежутку времени относятся цифры.

Стиль ответа:
- Простой язык, максимум 2-3 абзаца
- Поддерживающий тон
- Не рекомендуй конкретные акции/фонды/платформы
- В конце упомяни что ты не замена финансовому консультанту`;

interface CoachingResponse {
  answer: string;
  facts: string[];
  actions: AssistantAction[];
  followUps: string[];
}

// ── Helper: build user context string (layer 3) ──

function buildUserContext(profile: UserFinancialProfile, transactions: TxRow[]): string {
  // Top spending categories from recent transactions
  const expenseTx = transactions.filter((t) => t.type === 'expense' && !t.transfer_group_id);
  const catSpend = new Map<string, number>();
  for (const t of expenseTx) {
    const name = t.category?.name ?? 'Другое';
    catSpend.set(name, (catSpend.get(name) ?? 0) + Math.abs(t.amount));
  }
  const totalSpend = [...catSpend.values()].reduce((a, b) => a + b, 0);
  const topCategories = [...catSpend.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([name, amount]) => `${name}: ${totalSpend > 0 ? Math.round((amount / totalSpend) * 100) : 0}%`);

  const stageLabels: Record<string, string> = {
    beginner: 'Начинающий',
    has_debt: 'Погашение долгов',
    building_emergency: 'Создание подушки безопасности',
    saving: 'Активное накопление',
    investing: 'Инвестирование',
    fire: 'Путь к финансовой независимости',
  };

  // Period totals — give LLM ready-made sums so it doesn't try to calculate
  const incomeTx = transactions.filter((t) => t.type === 'income' && !t.transfer_group_id);
  const totalIncome = incomeTx.reduce((s, t) => s + Math.abs(t.amount), 0);
  const monthsWithData = new Set(transactions.map((t) => t.date.slice(0, 7))).size;

  // Build human-readable context (NOT JSON) to prevent LLM from doing math
  const lines = [
    `Период анализа: ${monthsWithData} мес.`,
    `Общий доход за период: ${formatMoney(totalIncome)}`,
    `Общие расходы за период: ${formatMoney(totalSpend)}`,
    `Финансовый этап: ${stageLabels[profile.stage] ?? profile.stage}`,
    `Средний ежемесячный доход: ${formatMoney(profile.monthly_income)}`,
    `Средние ежемесячные расходы: ${formatMoney(profile.monthly_expense)}`,
    `Норма сбережений: ${Math.round(profile.savings_rate * 100)}% от дохода`,
    `Долги: ${profile.has_debts ? 'да' : 'нет'}`,
    `Подушка безопасности: ${profile.has_emergency_fund ? 'есть' : 'нет'}`,
    `Инвестиции: ${profile.has_investments ? 'есть' : 'нет'}`,
    `Топ категории расходов: ${topCategories.join(', ')}`,
  ];
  return lines.join('\n');
}

// ── Helper: call LLM with 3-layer prompt ──

async function coachingLLMCall(
  systemExtra: string,
  knowledgeText: string,
  userContext: string,
  userQuery: string,
  history: ConversationMessage[] = [],
): Promise<string | null> {
  if (!OPENAI_API_KEY && !ANTHROPIC_API_KEY) return null;

  const systemPrompt = `${COACHING_PERSONA}\n\n${systemExtra}\n\nБаза знаний:\n${knowledgeText || '(нет релевантных секций)'}\n\nДанные пользователя:\n${userContext}\n\nВерни JSON: {"answer": "твой ответ"}`;

  const historyText = history.length > 0
    ? `Предыдущий диалог:\n${history.slice(-4).map(m =>
        `${m.role === 'user' ? 'Пользователь' : 'Ассистент'}: ${m.content.slice(0, 200)}`
      ).join('\n')}\n\n`
    : '';
  const finalUserPrompt = historyText + userQuery;

  try {
    const { parsed } = ANTHROPIC_API_KEY
      ? await createAnthropicJsonCompletion({
          apiKey: ANTHROPIC_API_KEY,
          model: COACHING_MODEL,
          systemPrompt,
          userPrompt: finalUserPrompt,
          timeoutMs: 8000,
          temperature: 0.3,
          maxTokens: 2048,
        })
      : await createOpenAIJsonCompletion({
          apiKey: OPENAI_API_KEY,
          model: OPENAI_MODEL,
          systemPrompt,
          userPrompt: finalUserPrompt,
          timeoutMs: 5000,
          temperature: 0.3,
        });

    const answer = parsed?.answer;
    return typeof answer === 'string' && answer.trim().length > 10 ? answer.trim() : null;
  } catch (err) {
    console.error('coachingLLMCall error:', err);
    return null;
  }
}

// ── Lazy profile + knowledge loader ──

async function loadCoachingContext(
  serviceClient: SupabaseClient,
  userId: string,
  transactions: TxRow[],
  intent: string,
): Promise<{ profile: UserFinancialProfile; knowledge: string; userContext: string }> {
  const [profile, knowledge] = await Promise.all([
    detectFinancialStage(serviceClient, userId, transactions),
    retrieveKnowledgeSections(serviceClient, intent),
  ]);

  // Re-fetch knowledge with stage filter if different from default
  let finalKnowledge = knowledge;
  if (profile.stage !== 'beginner') {
    finalKnowledge = await retrieveKnowledgeSections(serviceClient, intent, profile.stage);
    if (!finalKnowledge) finalKnowledge = knowledge;
  }

  const userContext = buildUserContext(profile, transactions);
  return { profile, knowledge: finalKnowledge, userContext };
}

// ============================================================================
// Builder: financial_advice
// ============================================================================

export async function buildFinancialAdviceResponse(
  serviceClient: SupabaseClient,
  userId: string,
  transactions: TxRow[],
  query: string,
  history: ConversationMessage[] = [],
): Promise<CoachingResponse> {
  const { profile, knowledge, userContext } = await loadCoachingContext(
    serviceClient, userId, transactions, 'financial_advice',
  );

  const llmAnswer = await coachingLLMCall(
    'Дай персональный финансовый совет на основе этапа пользователя и его данных. Будь конкретен — используй цифры.',
    knowledge,
    userContext,
    query,
    history,
  );

  const stageLabels: Record<string, string> = {
    beginner: 'Начинающий',
    has_debt: 'Погашение долгов',
    building_emergency: 'Создание подушки безопасности',
    saving: 'Активное накопление',
    investing: 'Инвестирование',
    fire: 'Путь к финансовой независимости',
  };

  return {
    answer: llmAnswer ?? `На основе ваших данных, ваш текущий этап: ${stageLabels[profile.stage] ?? profile.stage}. Доход: ${formatMoney(profile.monthly_income)}/мес, расходы: ${formatMoney(profile.monthly_expense)}/мес, норма сбережений: ${Math.round(profile.savings_rate * 100)}%. Задайте конкретный вопрос для персонального совета.`,
    facts: [
      `Этап: ${stageLabels[profile.stage] ?? profile.stage}`,
      `Savings rate: ${Math.round(profile.savings_rate * 100)}%`,
      profile.has_debts ? 'Обнаружены кредитные платежи' : 'Кредитных платежей не обнаружено',
    ],
    actions: [
      { type: 'open_transactions', label: 'Открыть транзакции' },
      { type: 'open_savings', label: 'Мои цели' },
    ],
    followUps: [
      'Оцени мои финансы',
      'Как оптимизировать бюджет?',
      'Помоги составить план накоплений',
    ],
  };
}

// ============================================================================
// Builder: impulse_check
// ============================================================================

export async function buildImpulseCheckResponse(
  serviceClient: SupabaseClient,
  userId: string,
  transactions: TxRow[],
  query: string,
  history: ConversationMessage[] = [],
): Promise<CoachingResponse> {
  const { knowledge, userContext } = await loadCoachingContext(
    serviceClient, userId, transactions, 'impulse_check',
  );

  // Extract amount from query
  const amountMatch = query.match(/(\d[\d\s.,]*)\s*(?:₽|руб|р\b|тыс|к\b)/i) ?? query.match(/(\d[\d\s.,]*)/);
  const rawAmount = amountMatch?.[1]?.replace(/\s/g, '').replace(',', '.') ?? '';
  let amount = parseFloat(rawAmount) || 0;

  // Handle "тыс" / "к"
  if (/тыс|к\b/i.test(query) && amount < 1000) {
    amount *= 1000;
  }

  // Determine cooling period
  let coolingHours = 24;
  if (amount > 30000) coolingHours = 72;
  else if (amount > 5000) coolingHours = 48;

  // Create reminder
  if (amount > 0) {
    try {
      const triggerAt = new Date(Date.now() + coolingHours * 60 * 60 * 1000).toISOString();
      await serviceClient
        .from('coaching_reminders')
        .insert({
          user_id: userId,
          reminder_type: 'impulse_cooling',
          trigger_at: triggerAt,
          payload: { amount, query, cooling_hours: coolingHours },
          status: 'pending',
        });
    } catch (err) {
      console.error('Failed to create impulse reminder:', err);
    }
  }

  const llmAnswer = await coachingLLMCall(
    `Пользователь хочет совершить покупку${amount > 0 ? ` на сумму ${formatMoney(amount)}` : ''}. Примени правило охлаждения покупок. Период ожидания: ${coolingHours} часов. Помоги оценить: это потребность или желание?`,
    knowledge,
    userContext,
    query,
    history,
  );

  const defaultAnswer = amount > 0
    ? `Покупка на ${formatMoney(amount)} — это ${amount > 30000 ? 'крупная' : amount > 5000 ? 'значительная' : 'небольшая'} сумма. Рекомендую подождать ${coolingHours} часов перед решением. По статистике, 70% импульсивных покупок отпадают после паузы. Я напомню вам через ${coolingHours}ч.`
    : 'Перед незапланированной покупкой стоит подождать 24-72 часа (в зависимости от суммы). Задайте себе вопрос: «Это потребность или желание?» Укажите сумму, и я помогу оценить.';

  return {
    answer: llmAnswer ?? defaultAnswer,
    facts: [
      amount > 0 ? `Сумма покупки: ${formatMoney(amount)}` : 'Сумма не указана',
      `Период охлаждения: ${coolingHours}ч`,
      amount > 0 ? `Напоминание создано на ${coolingHours}ч` : 'Укажите сумму для создания напоминания',
    ],
    actions: [
      { type: 'open_transactions', label: 'Посмотреть траты' },
    ],
    followUps: [
      'Дай финансовый совет',
      'Покажи мои крупные траты',
      `Напомни через ${coolingHours}ч`,
    ],
  };
}

// ============================================================================
// Builder: debt_strategy
// ============================================================================

export async function buildDebtStrategyResponse(
  serviceClient: SupabaseClient,
  userId: string,
  transactions: TxRow[],
  query: string,
  history: ConversationMessage[] = [],
): Promise<CoachingResponse> {
  const { profile, knowledge, userContext } = await loadCoachingContext(
    serviceClient, userId, transactions, 'debt_strategy',
  );

  const llmAnswer = await coachingLLMCall(
    'Помоги пользователю со стратегией погашения долгов. Объясни два метода (снежный ком vs лавина) и порекомендуй подходящий на основе данных.',
    knowledge,
    userContext,
    query,
    history,
  );

  return {
    answer: llmAnswer ?? 'Есть два метода погашения долгов: **Снежный ком** — начни с самого маленького долга (быстрые победы мотивируют), **Лавина** — начни с самого дорогого по процентам (экономишь больше). Для персональной рекомендации расскажите о ваших кредитах подробнее.',
    facts: [
      profile.has_debts ? 'Обнаружены кредитные платежи в расходах' : 'Кредитных платежей не обнаружено',
      'Два метода: снежный ком и лавина',
    ],
    actions: [
      { type: 'open_transactions', label: 'Посмотреть платежи' },
    ],
    followUps: [
      'Расскажи про метод снежного кома',
      'Расскажи про метод лавины',
      'Как рефинансировать долги?',
    ],
  };
}

// ============================================================================
// Builder: savings_plan
// ============================================================================

export async function buildSavingsPlanResponse(
  serviceClient: SupabaseClient,
  userId: string,
  transactions: TxRow[],
  query: string,
  history: ConversationMessage[] = [],
): Promise<CoachingResponse> {
  const { profile, knowledge, userContext } = await loadCoachingContext(
    serviceClient, userId, transactions, 'savings_plan',
  );

  // Calculate target emergency fund (3 months of expenses)
  const emergencyTarget = profile.monthly_expense * 3;
  const monthlySavings = Math.max(0, profile.monthly_income - profile.monthly_expense);
  const monthsToEmergency = monthlySavings > 0 ? Math.ceil(emergencyTarget / monthlySavings) : 0;

  const llmAnswer = await coachingLLMCall(
    `Помоги составить план накоплений. Подушка безопасности: ${formatMoney(emergencyTarget)} (3 мес расходов). Текущие сбережения: ${formatMoney(monthlySavings)}/мес. Времени до цели: ~${monthsToEmergency} мес.`,
    knowledge,
    userContext,
    query,
    history,
  );

  return {
    answer: llmAnswer ?? `Ваш план накоплений: подушка безопасности = ${formatMoney(emergencyTarget)} (3 месяца расходов). При текущих сбережениях ${formatMoney(monthlySavings)}/мес цель будет достигнута за ~${monthsToEmergency} месяцев. Рекомендую настроить автоперевод в день зарплаты.`,
    facts: [
      `Цель подушки: ${formatMoney(emergencyTarget)}`,
      `Можете откладывать: ${formatMoney(monthlySavings)}/мес`,
      monthsToEmergency > 0 ? `До цели: ~${monthsToEmergency} мес` : 'Расходы превышают доход',
    ],
    actions: [
      {
        type: 'create_savings_goal',
        label: 'Создать цель «Подушка безопасности»',
        payload: {
          name: 'Подушка безопасности',
          icon: '🛡️',
          color: '#10b981',
          targetAmount: emergencyTarget,
        },
      },
      { type: 'open_budget_tab', label: 'Бюджеты' },
    ],
    followUps: [
      'Как оптимизировать бюджет?',
      'Правило «заплати себе первому»',
      'Как автоматизировать накопления?',
    ],
  };
}

// ============================================================================
// Builder: budget_optimization
// ============================================================================

export async function buildBudgetOptimizationResponse(
  serviceClient: SupabaseClient,
  userId: string,
  transactions: TxRow[],
  query: string,
  history: ConversationMessage[] = [],
): Promise<CoachingResponse> {
  const { profile, knowledge, userContext } = await loadCoachingContext(
    serviceClient, userId, transactions, 'budget_optimization',
  );

  // Calculate 50/30/20 breakdown
  const income = profile.monthly_income;
  const ideal50 = income * 0.5;
  const ideal30 = income * 0.3;
  const ideal20 = income * 0.2;

  // Categorize expenses
  const needsKeywords = ['аренда', 'жиль', 'квартир', 'коммунал', 'еда', 'продукт', 'транспорт', 'связь', 'медицин', 'здоров', 'страхов'];
  const expenseTx = transactions.filter((t) => t.type === 'expense' && !t.transfer_group_id);

  let needsTotal = 0;
  let wantsTotal = 0;

  for (const t of expenseTx) {
    const catName = (t.category?.name ?? '').toLowerCase();
    const isNeed = needsKeywords.some((kw) => catName.includes(kw));
    if (isNeed) {
      needsTotal += Math.abs(t.amount);
    } else {
      wantsTotal += Math.abs(t.amount);
    }
  }

  // Normalize to monthly
  const months = Math.max(1, new Set(expenseTx.map((t) => t.date.slice(0, 7))).size);
  needsTotal = Math.round(needsTotal / months);
  wantsTotal = Math.round(wantsTotal / months);
  const actualSavings = Math.max(0, income - needsTotal - wantsTotal);

  const llmAnswer = await coachingLLMCall(
    `Анализ бюджета по правилу 50/30/20:
Идеал: Необходимое ${formatMoney(ideal50)}, Желания ${formatMoney(ideal30)}, Сбережения ${formatMoney(ideal20)}.
Факт: Необходимое ${formatMoney(needsTotal)}, Желания ${formatMoney(wantsTotal)}, Сбережения ${formatMoney(actualSavings)}.
Помоги оптимизировать.`,
    knowledge,
    userContext,
    query,
    history,
  );

  return {
    answer: llmAnswer ?? `По правилу 50/30/20 при доходе ${formatMoney(income)}:\n• Необходимое: ${formatMoney(needsTotal)} (идеал ${formatMoney(ideal50)})\n• Желания: ${formatMoney(wantsTotal)} (идеал ${formatMoney(ideal30)})\n• Сбережения: ${formatMoney(actualSavings)} (идеал ${formatMoney(ideal20)})`,
    facts: [
      `Необходимое: ${formatMoney(needsTotal)} / ${formatMoney(ideal50)} (${income > 0 ? Math.round((needsTotal / income) * 100) : 0}%)`,
      `Желания: ${formatMoney(wantsTotal)} / ${formatMoney(ideal30)} (${income > 0 ? Math.round((wantsTotal / income) * 100) : 0}%)`,
      `Сбережения: ${formatMoney(actualSavings)} / ${formatMoney(ideal20)} (${income > 0 ? Math.round((actualSavings / income) * 100) : 0}%)`,
    ],
    actions: [
      { type: 'open_budget_tab', label: 'Настроить бюджеты' },
      { type: 'open_transactions', label: 'Посмотреть траты' },
    ],
    followUps: [
      'Топ категорий расходов',
      'Как сократить расходы?',
      'Помоги составить план накоплений',
    ],
  };
}

// ============================================================================
// Builder: financial_stage
// ============================================================================

export async function buildFinancialStageResponse(
  serviceClient: SupabaseClient,
  userId: string,
  transactions: TxRow[],
  query: string,
  history: ConversationMessage[] = [],
): Promise<CoachingResponse> {
  const { profile, knowledge, userContext } = await loadCoachingContext(
    serviceClient, userId, transactions, 'financial_stage',
  );

  console.log(`[coaching v4] financial_stage for ${userId}, stage=${profile.stage}, income=${profile.monthly_income}, expense=${profile.monthly_expense}, debts=${profile.has_debts}`);
  console.log(`[coaching v4] userContext: ${userContext}`);

  const llmAnswer = await coachingLLMCall(
    `Объясни пользователю его текущий финансовый этап. Опиши, что он уже сделал хорошо, и дай конкретные следующие шаги. Будь поддерживающим. Используй ТОЛЬКО данные из контекста.`,
    knowledge,
    userContext,
    query,
    history,
  );

  const stageLabels: Record<string, string> = {
    beginner: 'Начинающий',
    has_debt: 'Погашение долгов',
    building_emergency: 'Создание подушки безопасности',
    saving: 'Активное накопление',
    investing: 'Инвестирование',
    fire: 'Путь к FIRE',
  };

  const stageEmoji: Record<string, string> = {
    beginner: '🌱',
    has_debt: '🏗',
    building_emergency: '🛡',
    saving: '💰',
    investing: '📈',
    fire: '🔥',
  };

  return {
    answer: llmAnswer ?? `Ваш финансовый этап: ${stageEmoji[profile.stage] ?? ''} ${stageLabels[profile.stage] ?? profile.stage}. Доход: ${formatMoney(profile.monthly_income)}/мес, расходы: ${formatMoney(profile.monthly_expense)}/мес. Savings rate: ${Math.round(profile.savings_rate * 100)}%.`,
    facts: [
      `${stageEmoji[profile.stage] ?? ''} Этап: ${stageLabels[profile.stage] ?? profile.stage}`,
      `Ежемесячный доход: ${formatMoney(profile.monthly_income)}`,
      `Ежемесячные расходы: ${formatMoney(profile.monthly_expense)}`,
      `Норма сбережений: ${Math.round(profile.savings_rate * 100)}%`,
    ],
    actions: [
      { type: 'open_transactions', label: 'Мои транзакции' },
      { type: 'open_savings', label: 'Мои цели' },
    ],
    followUps: [
      'Дай финансовый совет',
      'Как перейти на следующий этап?',
      'Оптимизация бюджета',
    ],
  };
}

// ============================================================================
// Builder: investment_basics
// ============================================================================

export async function buildInvestmentBasicsResponse(
  serviceClient: SupabaseClient,
  userId: string,
  transactions: TxRow[],
  query: string,
  history: ConversationMessage[] = [],
): Promise<CoachingResponse> {
  const { profile, knowledge, userContext } = await loadCoachingContext(
    serviceClient, userId, transactions, 'investment_basics',
  );

  const llmAnswer = await coachingLLMCall(
    'Дай образовательный ответ об инвестировании. Не рекомендуй конкретные акции или платформы. Обязательно добавь дисклеймер.',
    knowledge,
    userContext,
    query,
    history,
  );

  const readyToInvest = !profile.has_debts && profile.has_emergency_fund;

  return {
    answer: llmAnswer ?? (readyToInvest
      ? 'У вас нет долгов и есть подушка безопасности — вы готовы начать инвестировать. Базовые шаги: 1) Определите горизонт (5+ лет). 2) Выберите уровень риска. 3) Начните с простых инструментов (ETF, облигации). ⚠️ Я не финансовый консультант — это общеобразовательная информация.'
      : 'Перед инвестированием рекомендуется: 1) Погасить высокопроцентные долги. 2) Создать подушку безопасности (3-6 мес расходов). Инвестировать стоит только свободные деньги. ⚠️ Я не финансовый консультант — это общеобразовательная информация.'),
    facts: [
      readyToInvest ? 'Готовы к инвестированию' : 'Рекомендуется сначала создать подушку',
      'Это образовательная информация, не инвестиционный совет',
    ],
    actions: [
      { type: 'open_savings', label: 'Мои цели' },
    ],
    followUps: [
      'Что такое сложный процент?',
      'Как определить толерантность к риску?',
      'Оцени мои финансы',
    ],
  };
}

// ============================================================================
// Builder: financial_safety (deterministic, no LLM)
// ============================================================================

export async function buildFinancialSafetyResponse(
  serviceClient: SupabaseClient,
): Promise<CoachingResponse> {
  const knowledge = await retrieveKnowledgeSections(serviceClient, 'financial_safety', undefined, 3);

  return {
    answer: knowledge || 'Основные правила финансовой безопасности:\n• Никогда не сообщайте CVV, PIN, SMS-коды\n• Банк никогда не звонит с просьбой перевести деньги\n• Гарантированная доходность 30%+ = мошенничество\n• Используйте двухфакторную аутентификацию\n• Проверяйте URL сайтов банков',
    facts: [
      'Никогда не сообщайте CVV, PIN, SMS-коды',
      'Банк НЕ звонит с просьбой назвать коды',
      'Гарантированная доходность 30%+ = пирамида',
    ],
    actions: [],
    followUps: [
      'Как защитить данные?',
      'Признаки инвестиционного мошенничества',
      'Дай финансовый совет',
    ],
  };
}

// ============================================================================
// Builder: habit_check
// ============================================================================

export async function buildHabitCheckResponse(
  serviceClient: SupabaseClient,
  userId: string,
  transactions: TxRow[],
  query: string,
  history: ConversationMessage[] = [],
): Promise<CoachingResponse> {
  const { profile, knowledge, userContext } = await loadCoachingContext(
    serviceClient, userId, transactions, 'habit_check',
  );

  // Analyze tracking consistency
  const last30Days = new Date();
  last30Days.setDate(last30Days.getDate() - 30);
  const last30Str = last30Days.toISOString().slice(0, 10);

  const recentTx = transactions.filter((t) => t.date >= last30Str);
  const uniqueDays = new Set(recentTx.map((t) => t.date)).size;
  const trackingScore = Math.min(100, Math.round((uniqueDays / 30) * 100));

  // Days since last transaction
  const lastTxDate = transactions.length > 0 ? transactions[0].date : null;
  const daysSinceLastTx = lastTxDate
    ? Math.round((Date.now() - new Date(lastTxDate).getTime()) / (1000 * 60 * 60 * 24))
    : 999;

  const llmAnswer = await coachingLLMCall(
    `Оцени финансовые привычки пользователя. Консистентность записи: ${trackingScore}% (${uniqueDays} из 30 дней). Дней с последней записи: ${daysSinceLastTx}. Дай оценку и рекомендации по улучшению привычек.`,
    knowledge,
    userContext,
    query,
    history,
  );

  return {
    answer: llmAnswer ?? `Оценка финансовых привычек:\n• Консистентность учёта: ${trackingScore}% (${uniqueDays} дней из 30)\n• ${daysSinceLastTx === 0 ? 'Сегодня записи есть' : daysSinceLastTx <= 1 ? 'Вчера были записи' : `Последняя запись ${daysSinceLastTx} дн. назад`}\n${trackingScore >= 70 ? 'Отличная привычка! Продолжайте.' : trackingScore >= 40 ? 'Неплохо, но можно лучше. Попробуйте записывать траты сразу.' : 'Нужно чаще записывать расходы. Начните с ежедневного напоминания.'}`,
    facts: [
      `Консистентность: ${trackingScore}%`,
      `Дней с записями: ${uniqueDays}/30`,
      daysSinceLastTx <= 1 ? 'Записи актуальны' : `Последняя запись: ${daysSinceLastTx} дн. назад`,
    ],
    actions: [
      { type: 'open_add_expense', label: 'Записать расход' },
      { type: 'open_transactions', label: 'Мои транзакции' },
    ],
    followUps: [
      'Дай финансовый совет',
      'Покажи траты за неделю',
      'Оцени мои финансы',
    ],
  };
}

// ============================================================================
// Builder: book_recommendations
// ============================================================================

/// Curated global classics — NO Russia-specific sources (per project policy:
/// Akifi is a global product). The LLM picks 3-5 most relevant for the user's
/// stage and query topic; if the LLM is unavailable we surface a sensible
/// default selection.
const BOOK_LIBRARY = [
  {
    title: 'The Psychology of Money',
    author: 'Morgan Housel',
    year: 2020,
    topics: ['behavior', 'mindset', 'beginner', 'general'],
    why: 'Why behaviour matters more than spreadsheets. Short essays, no jargon.',
  },
  {
    title: 'I Will Teach You To Be Rich',
    author: 'Ramit Sethi',
    year: 2009,
    topics: ['automation', 'budgeting', 'beginner', 'general'],
    why: 'A practical 6-week setup: automation, conscious spending, no guilt.',
  },
  {
    title: 'Your Money or Your Life',
    author: 'Vicki Robin & Joe Dominguez',
    year: 1992,
    topics: ['fire', 'lifestyle', 'mindset', 'beginner'],
    why: 'Foundation of the FIRE movement — money as life energy, 9-step program.',
  },
  {
    title: 'The Total Money Makeover',
    author: 'Dave Ramsey',
    year: 2003,
    topics: ['debt', 'beginner', 'budgeting'],
    why: 'Debt-snowball method and 7 baby steps — best when getting out of debt.',
  },
  {
    title: 'The Little Book of Common Sense Investing',
    author: 'John C. Bogle',
    year: 2007,
    topics: ['investing', 'index', 'saving'],
    why: 'The case for low-cost index funds, from the founder of Vanguard.',
  },
  {
    title: 'A Random Walk Down Wall Street',
    author: 'Burton Malkiel',
    year: 1973,
    topics: ['investing', 'index', 'theory'],
    why: 'Classic on efficient markets and why most active investing fails.',
  },
  {
    title: 'The Simple Path to Wealth',
    author: 'JL Collins',
    year: 2016,
    topics: ['investing', 'fire', 'index', 'saving'],
    why: 'Plain-English roadmap to FIRE through total-market index funds.',
  },
  {
    title: 'The Four Pillars of Investing',
    author: 'William Bernstein',
    year: 2002,
    topics: ['investing', 'theory', 'history'],
    why: 'Theory + history + psychology + business of investing — deeper than Bogle.',
  },
  {
    title: 'Rich Dad Poor Dad',
    author: 'Robert Kiyosaki',
    year: 1997,
    topics: ['mindset', 'beginner', 'assets'],
    why: 'Mindset shift: assets vs liabilities. Read it for the framing, not the specifics.',
  },
  {
    title: 'The Millionaire Next Door',
    author: 'Thomas J. Stanley & William D. Danko',
    year: 1996,
    topics: ['lifestyle', 'mindset', 'saving'],
    why: 'Research-based portrait of how actual millionaires live (frugally).',
  },
  {
    title: 'Thinking, Fast and Slow',
    author: 'Daniel Kahneman',
    year: 2011,
    topics: ['behavior', 'psychology', 'theory'],
    why: 'Nobel-prize behavioural economics — explains the biases that wreck money decisions.',
  },
  {
    title: 'Nudge',
    author: 'Richard Thaler & Cass Sunstein',
    year: 2008,
    topics: ['behavior', 'psychology', 'design'],
    why: 'How tiny choice-architecture tweaks improve outcomes — applies directly to budgets.',
  },
] as const;

const BOOK_RECOMMENDATIONS_PERSONA = `Ты — финансовый коуч в приложении Akifi и должен порекомендовать книги по теме запроса пользователя.

ПРАВИЛА:
1. Выбери 3-5 книг ТОЛЬКО из списка "Доступные книги" ниже. Не придумывай свои.
2. Подбирай книги, релевантные теме запроса пользователя И его текущему финансовому этапу:
   - Этап has_debt → начни с Ramsey, потом Sethi
   - Этап building_emergency / beginner → Sethi, Housel, Robin
   - Этап saving / investing → Bogle, Collins, Bernstein, Malkiel
   - Этап fire → Robin, Collins
   - Запрос про поведение/психологию → Housel, Kahneman, Thaler
   - Запрос про инвестиции → Bogle, Collins, Malkiel, Bernstein
3. Формат ответа: для каждой книги — заголовок жирным, автор, год в скобках, ОДНО предложение почему она подойдёт пользователю с учётом его данных.
4. В конце 1-2 предложения о том, в каком порядке читать.
5. ВАЖНО: книги — международная классика. НЕ упоминай российских авторов, российские реалии, ЦБ РФ, ИИС, НДФЛ, российские банки. Аудитория глобальная.
6. Отвечай на том же языке, на котором задан вопрос пользователя.
7. Не более 250 слов всего.`;

export async function buildBookRecommendationsResponse(
  serviceClient: SupabaseClient,
  userId: string,
  transactions: TxRow[],
  query: string,
  history: ConversationMessage[] = [],
): Promise<CoachingResponse> {
  const { profile, userContext } = await loadCoachingContext(
    serviceClient, userId, transactions, 'book_recommendations',
  );

  const libraryText = BOOK_LIBRARY.map((b, i) =>
    `${i + 1}. "${b.title}" — ${b.author} (${b.year}). Темы: ${b.topics.join(', ')}. ${b.why}`
  ).join('\n');

  const llmAnswer = await coachingLLMCall(
    `Подбери книги для пользователя на этапе "${profile.stage}". База:\n\nДоступные книги:\n${libraryText}`,
    BOOK_RECOMMENDATIONS_PERSONA,
    userContext,
    query,
    history,
  );

  // Static fallback — pick by stage
  const stagePicks: Record<string, number[]> = {
    beginner:           [0, 1, 2],         // Housel, Sethi, Robin
    has_debt:           [3, 1, 0],         // Ramsey, Sethi, Housel
    building_emergency: [1, 0, 2],         // Sethi, Housel, Robin
    saving:             [4, 6, 0],         // Bogle, Collins, Housel
    investing:          [4, 5, 7, 6],      // Bogle, Malkiel, Bernstein, Collins
    fire:               [2, 6, 4],         // Robin, Collins, Bogle
  };
  const picks = stagePicks[profile.stage] ?? [0, 1, 4];
  const fallback = picks
    .map((i) => `**${BOOK_LIBRARY[i].title}** — ${BOOK_LIBRARY[i].author} (${BOOK_LIBRARY[i].year}). ${BOOK_LIBRARY[i].why}`)
    .join('\n\n');

  return {
    answer: llmAnswer ?? `Подборка для вашего этапа:\n\n${fallback}`,
    facts: [
      `Подборка из ${BOOK_LIBRARY.length} классических книг`,
      'Все книги — мировая классика (без региональной привязки)',
    ],
    actions: [],
    followUps: [
      'С чего начать читать?',
      'Книги про инвестиции',
      'Книги про привычки и психологию',
    ],
  };
}
