import { isIntent, isPeriod, type AssistantIntent, type AssistantPeriod } from '../_shared/assistant-schema.ts';
import { createOpenAIJsonCompletion, type OpenAIUsage } from '../_shared/openai.ts';
import { normalizeForMatch } from './utils.ts';
import type {
  ParsedIntent,
  ConversationMessage,
  LLMClassificationResult,
  ClassificationResult,
} from './types.ts';

const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY') ?? '';
const OPENAI_MODEL = Deno.env.get('OPENAI_MODEL') ?? 'gpt-4o-mini';
const AI_LLM_CLASSIFY_OFF = (Deno.env.get('AI_LLM_CLASSIFY') ?? 'on') === 'off';
const AI_CLASSIFY_TIMEOUT_MS = Math.max(1000, Number(Deno.env.get('AI_CLASSIFY_TIMEOUT_MS') ?? '2500'));
const AI_CLASSIFY_CONFIDENCE_THRESHOLD = Math.max(0, Math.min(1, Number(Deno.env.get('AI_CLASSIFY_CONFIDENCE_THRESHOLD') ?? '0.5')));

export const CLASSIFY_SYSTEM_PROMPT = `You are a financial assistant intent classifier for a Russian-language expense tracker app.
Given a user query (and optional conversation history), classify it into exactly one intent and one period.

Intents:
- spend_summary: total spending/income overview, "сколько потратил", "расходы", "сводка", "куда деваются деньги", "почему так много ушло"
- top_categories: top spending categories, "топ категорий", "куда уходят деньги", "на что трачу больше всего"
- top_expenses: largest individual transactions, "крупные траты", "самые дорогие"
- budget_risk: budget health/risk assessment, "бюджет", "лимит", "риск"
- trend_compare: comparison with previous period, "сравни", "динамика", "рост/упал"
- by_category: spending for a specific category, "на еду", "сколько на транспорт"
- by_account: spending for a specific account/card, "на карте", "по счёту"
- budget_remaining: remaining budget amount, "остаток бюджета", "сколько осталось"
- average_check: average transaction size, "средний чек"
- forecast: spending forecast, "прогноз", "хватит ли"
- anomalies: unusual spending patterns, "аномалии", "необычные траты"
- create_transaction: user wants to record/add a new transaction, "запиши", "добавь расход", "потратил 500 на обед", "доход зарплата 50000"
- edit_transaction: user wants to modify an existing transaction, "измени последнюю трату", "поменяй сумму", "исправь категорию на кафе". Extract: amount (new), category_hint (new), description (new), tx_ref ("последняя", "вчера", specific description)
- delete_transaction: user wants to delete/cancel a transaction, "удали последнюю транзакцию", "отмени трату", "убери расход за вчера". Extract: tx_ref ("последняя", description, date)
- edit_budget: user EXPLICITLY wants to modify/change a budget limit, "увеличь бюджет на еду до 30к", "измени лимит бюджета", "поменяй бюджет", "установи бюджет 20000". NOTE: "сколько рекомендуешь тратить" is NOT edit_budget — it's financial_advice. Extract: category (budget target), amount (new limit)
- seasonal_forecast: seasonal spending prediction, "прогноз на следующий месяц", "сезонный прогноз", "обычно в декабре", "сколько обычно трачу в январе"
- savings_advice: savings goals progress/advice, "как дела с целями", "накопления", "когда накоплю", "сбережения", "прогресс по целям"
- savings_contribute: contribute to a savings goal, "внеси 5000 на цель X", "пополни копилку на 10000". Extract: amount, description (goal name)
- recurring_patterns: find recurring/subscription payments, "найди подписки", "регулярные платежи", "повторяющиеся траты", "автоплатежи"
- financial_advice: personal financial advice, recommendations, "совет", "подскажи", "что посоветуешь", "помоги с финансами", "сколько рекомендуешь тратить", "сколько стоит тратить на", "какой лимит поставить". IMPORTANT: when user asks "сколько рекомендуешь/советуешь тратить на X" or "how much should I spend on X" — this is financial_advice, NOT edit_budget. The user asks for a recommendation, not a budget change.
- impulse_check: evaluate a purchase decision, "хочу купить", "стоит ли покупать", "нужно ли"
- debt_strategy: debt repayment strategy, "как погасить долг", "стратегия погашения", "снежный ком"
- savings_plan: savings/emergency fund plan, "план накоплений", "как накопить", "подушка безопасности"
- budget_optimization: optimize budget with 50/30/20, "оптимизировать бюджет", "50/30/20", "распределить доход"
- financial_stage: assess financial stage, "мой уровень", "где я сейчас", "оценка финансов", "мой этап"
- investment_basics: investment education, "инвестиции", "куда вложить", "как начать инвестировать"
- financial_safety: fraud protection, "мошенники", "безопасность", "обман", "как защитить"
- habit_check: financial habits assessment, "привычки", "чеклист финансов", "как дела с финансами"
- smart_budget_create: auto-create budgets based on spending history, "создай бюджеты автоматически", "умный бюджет", "бюджет на основе расходов", "спланируй бюджет"
- spending_optimization: find ways to reduce spending, "как сэкономить", "оптимизируй расходы", "где сократить траты", "куда уходят деньги", "советы по экономии"
- help: unrecognized or general help request

Periods:
- today: today only
- week: current week
- month: current month (default)
- all: all time / last 90 days
- custom_days: custom period in days. Use when user specifies a specific number of days/weeks/months (e.g., "за 15 дней", "за 2 недели", "last 3 months"). Set "days" field to the number of days (e.g., 2 weeks = 14 days, 3 months = 90 days).

Respond with JSON only:
{"intent":"...","period":"...","days":null,"confidence":0.0-1.0,"entities":{"category":null,"account":null,"merchant":null,"amount":null,"tx_type":null,"description":null,"tx_ref":null}}

IMPORTANT: "days" field is ONLY used when period is "custom_days". Set it to the number of days. For weeks multiply by 7, for months multiply by 30.

IMPORTANT rules for entities:
- Set entities.category/account/merchant when the user mentions a specific one.
- entities.tx_ref: for edit/delete intents, extract how user refers to the transaction ("последняя", "за вчера", description text).
- entities.amount: for edit_transaction/edit_budget, this is the NEW value. For create_transaction, this is the transaction amount.
- entities.description: for edit_transaction, this is the new description.

Multi-turn context resolution (CRITICAL):
- When the user says "а за прошлый месяц?" after asking about a category, keep the same category and change the period.
- When the user says "а на другом счёте?" keep the same intent and change the account.
- Resolve pronouns like "там", "тут", "это", "его" using the conversation history.
- If user asks a follow-up like "а больше?" or "подробнее" — keep the same intent/entity, just expand.
- If the user says just a period like "за неделю" or "сегодня" — reuse the previous intent and entities.
- If the previous assistant response was smart_budget_create and the user asks to create specific budgets (e.g., "создай только бюджет по путешествиям 20000", "бюджет на еду 15000"), classify as smart_budget_create with entities.category = category name and entities.amount = custom amount.`;

// Classify cache (TTL 10 min, max 300)
const CLASSIFY_CACHE_TTL_MS = 10 * 60 * 1000;
const CLASSIFY_CACHE_MAX_SIZE = 300;
const classifyCache = new Map<string, { result: ClassificationResult; ts: number }>();

function classifyCacheKey(userId: string, query: string): string {
  return `${userId}:${normalizeForMatch(query)}`;
}

function getClassifyCached(key: string): ClassificationResult | null {
  const entry = classifyCache.get(key);
  if (!entry) return null;
  if (Date.now() - entry.ts > CLASSIFY_CACHE_TTL_MS) {
    classifyCache.delete(key);
    return null;
  }
  return entry.result;
}

function setClassifyCache(key: string, result: ClassificationResult): void {
  if (classifyCache.size >= CLASSIFY_CACHE_MAX_SIZE) {
    const firstKey = classifyCache.keys().next().value;
    if (firstKey !== undefined) classifyCache.delete(firstKey);
  }
  classifyCache.set(key, { result, ts: Date.now() });
}

export function parseIntentAndPeriod(query: string): ParsedIntent {
  const normalized = normalizeForMatch(query);

  let period: AssistantPeriod = 'month';
  let customDays: number | undefined;

  // ── Custom relative periods: "за N дней/недель/месяцев" ──
  const customPeriodPatterns: Array<{ regex: RegExp; multiplier: number; group: number }> = [
    // "за последние 15 дней", "за последних 15 дней"
    { regex: /за\s+последн(?:ие|их|ей)\s+(\d+)\s*дн/u, multiplier: 1, group: 1 },
    // "за 15 дней", "15 дней"
    { regex: /(?:за\s+)?(\d+)\s*дн/u, multiplier: 1, group: 1 },
    // "за последние 2 недели", "за 2 недели"
    { regex: /(?:за\s+)?(?:последн(?:ие|их|ей)\s+)?(\d+)\s*недел/u, multiplier: 7, group: 1 },
    // "за последние 3 месяца", "за 3 месяца"
    { regex: /(?:за\s+)?(?:последн(?:ие|их|ей)\s+)?(\d+)\s*месяц/u, multiplier: 30, group: 1 },
    // "за последний год", "за 2 года"
    { regex: /(?:за\s+)?(?:последн(?:ие|их|ей|ий)\s+)?(\d+)\s*(?:год|лет)/u, multiplier: 365, group: 1 },
    // English: "last 15 days", "past 15 days"
    { regex: /(?:last|past)\s+(\d+)\s*days?/iu, multiplier: 1, group: 1 },
    // English: "last 2 weeks"
    { regex: /(?:last|past)\s+(\d+)\s*weeks?/iu, multiplier: 7, group: 1 },
    // English: "last 3 months"
    { regex: /(?:last|past)\s+(\d+)\s*months?/iu, multiplier: 30, group: 1 },
  ];

  let customPeriodMatched = false;
  for (const { regex, multiplier, group } of customPeriodPatterns) {
    const match = normalized.match(regex);
    if (match?.[group]) {
      const n = parseInt(match[group], 10);
      if (n > 0 && n <= 3650) {
        customDays = n * multiplier;
        period = 'custom_days';
        customPeriodMatched = true;
        break;
      }
    }
  }

  // Standard period detection (only if custom period was NOT matched)
  if (!customPeriodMatched) {
    if (/(^|\s)(сегодня|today)/u.test(normalized)) {
      period = 'today';
    } else if (/(^|\s)(недел|week)/u.test(normalized)) {
      period = 'week';
    } else if (/(^|\s)(месяц|month)/u.test(normalized)) {
      period = 'month';
    } else if (/(все время|all time)/u.test(normalized)) {
      period = 'all';
    }
  }

  // Helper to include customDays in all return values
  const result = (intent: AssistantIntent, entity?: string): ParsedIntent => ({
    intent,
    period,
    ...(entity ? { entity } : {}),
    ...(customDays ? { customDays } : {}),
  });

  // ── Coaching intents (before analytical intents) ──

  // Financial safety (deterministic, no LLM needed)
  if (/(мошенник|мошенничеств|обман|безопасност|защит\S* деньг|защит\S* данн|скам|пирамид|фрод|fraud|развод)/u.test(normalized)) {
    return result('financial_safety');
  }

  // Impulse check
  if (/(хочу купить|стоит ли (покуп|брать)|нужно ли (покуп|брать)|стоит ли мне|импульс\S* покупк|покупать ли)/u.test(normalized)) {
    return result('impulse_check');
  }

  // Debt strategy
  if (/(стратеги\S* погашен|как погасить|снежн\S* ком|метод лавин|как закрыть (кредит|долг)|погаш\S* долг|погаш\S* кредит|план погашен)/u.test(normalized)) {
    return result('debt_strategy');
  }

  // Smart budget create (before budget_optimization and general budget)
  if (/(создай|предложи|сделай)\S*\s.*(бюджет|план)\S*\s.*(на основ|по|из|анализ|автоматич|умн)/u.test(normalized) ||
      /(авто|умн|смарт)\S*\s*(бюджет)/u.test(normalized) ||
      /(бюджет)\S*\s*(на основ|по расход|по трат|автоматич)/u.test(normalized) ||
      /(спланируй|распланируй)\S*\s*(бюджет|расход|финанс)/u.test(normalized)) {
    return result('smart_budget_create');
  }

  // Spending optimization (before budget_optimization)
  if (/(оптимиз|сократ|уменьш|снизи|сэконом)\S*\s*(расход|трат|бюджет)/u.test(normalized) ||
      /(где|как|на чём)\S*\s*(сэконом|сократ|меньше трат)/u.test(normalized) ||
      /(куда уход|на что уход)\S*\s*(деньг|средств)/u.test(normalized) ||
      /(анализ|провер)\S*\s*(расход|трат)\S*\s*(оптимиз|эффективн)/u.test(normalized) ||
      /(советы|рекомендации)\S*\s*(экономи|сбережени|расход)/u.test(normalized)) {
    return result('spending_optimization');
  }

  // Budget optimization (specific patterns before general budget)
  if (/(оптимизир\S* бюджет|50.30.20|правило 50|как распределить доход|распредели доход|оптимиза\S* расход)/u.test(normalized)) {
    return result('budget_optimization');
  }

  // Financial stage
  if (/(мой уровень|мой этап|где я сейчас|оценк\S* финанс|оцени мои финанс|финансов\S* этап|финансов\S* уровень|на каком я этап)/u.test(normalized)) {
    return result('financial_stage');
  }

  // Investment basics
  if (/(инвестиц|куда вложить|как начать инвестир|начать инвестир|основы инвестир|во что вложить)/u.test(normalized)) {
    return result('investment_basics');
  }

  // Savings plan (specific patterns before general savings)
  if (/(план накоплен|как накопить|подушк\S* безопасност|экстренн\S* фонд|план сбережен|как откладыв|сколько откладыв|заплати себе)/u.test(normalized)) {
    return result('savings_plan');
  }

  // Habit check
  if (/(привычк|чеклист финанс|как дела с финанс|финансов\S* привычк|мои привычк|оцени привычк|финансов\S* здоров)/u.test(normalized)) {
    return result('habit_check');
  }

  // Financial advice (broad — should be after specific coaching intents)
  if (/(совет|подскажи|что посоветуешь|помоги с финанс|финансов\S* совет|посоветуй|дай совет|как мне|что делать|как лучше|как можно|подскажи как|расскажи|объясни|помоги|как сэконом|как копить|как сократ|как уменьш|как увелич|сколько нужно|сколько откладыв|как вести бюджет|как начать|как научить|что думаешь|оцени|проанализируй|рекомендуешь|рекомендуете|посоветуешь|стоит ли тратить|сколько.*тратить)/u.test(normalized)) {
    return result('financial_advice');
  }

  // Delete transaction
  if (/(удали|отмени|убери|удалить|отменить)\s.*(транзакц|трат|расход|операц|доход|запис)/u.test(normalized) ||
      /(удали|отмени|убери|удалить|отменить)\s+(последн|предыдущ)/u.test(normalized)) {
    return result('delete_transaction');
  }

  // Edit transaction
  if (/(измени|поменяй|исправь|обнови|изменить|поменять|исправить)\s.*(транзакц|трат|расход|сумм|категори|описани|операц)/u.test(normalized) ||
      /(измени|поменяй|исправь|обнови)\s+(последн|предыдущ)/u.test(normalized)) {
    return result('edit_transaction');
  }

  // Edit budget
  if (/(увеличь|уменьши|измени|поменяй|поставь|установи|обнови|изменить|увеличить|уменьшить)\s.*(бюджет|лимит)/u.test(normalized) ||
      /(бюджет|лимит)\S*\s+(на|до)\s+\d/u.test(normalized)) {
    return result('edit_budget');
  }

  // Create transaction
  if (
    /(запиши|добавь|записал|потратил|потратила|получил|получила|трачу)\s.*\d/u.test(normalized) ||
    /(запиши|добавь|записал|потратил|потратила|получил|получила|трачу)\s+\d/u.test(normalized) ||
    /\d[\s\S]*(запиши|добавь|записал)/u.test(normalized) ||
    /(доход|зарплат|получил|получила|заработ)\S*\s+\d/u.test(normalized) ||
    /^\d[\d\s.,]*\s+(на|за)\s+\S/u.test(normalized)
  ) {
    if (!/(сколько|когда|почему|зачем|какой|какие|какая|где|покажи|статист)/u.test(normalized)) {
      return result('create_transaction');
    }
  }

  // Seasonal forecast
  if (/(сезон|следующ\S* месяц|прогноз на|обычно в|в декабр|в январ|в феврал|в март|в апрел|в мае|в июн|в июл|в август|в сентябр|в октябр|в ноябр)/u.test(normalized)) {
    return result('seasonal_forecast');
  }

  // Savings advice
  if (/(цел\S* накоплен|накоплен|копи\S+|сбережен|копилк|накопи|когда накопл|как дела с цел)/u.test(normalized)) {
    if (/(внеси|добавь|пополни|внести)\s.*\d.*(?:цел|копилк)/u.test(normalized) ||
        /(внеси|добавь|пополни|внести)\s+\d/u.test(normalized)) {
      return result('savings_contribute');
    }
    return result('savings_advice');
  }

  // Savings contribute standalone
  if (/(внеси|добавь|пополни|внести)\s.*\d.*(?:цел|копилк|накоплен)/u.test(normalized)) {
    return result('savings_contribute');
  }

  // Recurring patterns
  if (/(подписк|регулярн|повторяющ|автоплатеж|ежемесячн\S* плат|найди подписк)/u.test(normalized)) {
    return result('recurring_patterns');
  }

  // Forecast
  if (/(хватит|прогноз|forecast|уложу)/u.test(normalized)) {
    return result('forecast');
  }

  // Anomalies
  if (/(аномал|необычн|странн|подозрит|outlier|unusual)/u.test(normalized)) {
    return result('anomalies');
  }

  // Average check
  if (/(средн\S* (чек|трат|расход|сумм)|average)/u.test(normalized)) {
    return result('average_check');
  }

  // Budget remaining
  if (/(остал\S* (по |)бюдж|остаток\S* бюдж|осталось\S* бюдж)/u.test(normalized)) {
    return result('budget_remaining');
  }

  // Budget risk
  if (/(бюдж|лимит|риск)/u.test(normalized)) {
    return result('budget_risk');
  }

  // By account
  const accountMatch = normalized.match(
    /(?:на счет[уе]?|по счет[уе]?|со? счет[ауе]?|на карт[еу]?|с карт[ыиеу]?)\s+(.+?)(?:\s+за|\s+сегодня|\s+недел|\s+месяц|$)/u,
  );
  if (accountMatch?.[1]) {
    return result('by_account', accountMatch[1].trim());
  }
  const accountFallback = normalized.match(
    /(?:расход|трат|доход|баланс)\S*\s+(?:на |по |с |со )?(.{2,20}?)(?:\s+за|\s+сегодня|\s+недел|\s+месяц|$)/u,
  );
  if (
    accountFallback?.[1] &&
    !/(катег|топ|круп|дорог|больш|сравн|средн|прогноз|бюдж)/u.test(accountFallback[1])
  ) {
    const candidate = accountFallback[1].trim();
    const STOP_WORDS = new Set([
      'за', 'на', 'по', 'от', 'из', 'до', 'об', 'ко', 'во',
      'я', 'мы', 'вы', 'он', 'она', 'мне', 'все', 'всё', 'это',
      'что', 'как', 'где', 'мой', 'мои', 'наш',
      'ещё', 'еще', 'уже', 'тут', 'там', 'так', 'вот', 'нет', 'да',
    ]);
    if (candidate.length >= 2 && candidate.length <= 30 && !STOP_WORDS.has(candidate)) {
      return result('by_account', candidate);
    }
  }

  // By category
  const categoryMatch = normalized.match(
    /(?:на |по катег\S*\s+)([а-яё]{2,25})(?:\s+за|\s+сегодня|\s+недел|\s+месяц|$)/u,
  );
  if (
    categoryMatch?.[1] &&
    !/(счет|карт|бюдж|недел|месяц|сегодня)/u.test(categoryMatch[1])
  ) {
    return result('by_category', categoryMatch[1].trim());
  }

  if (/(круп|дорог|больш\S* трат|biggest|largest|top\s*\d?\s*(трат|расход|expense))/u.test(normalized)) {
    return result('top_expenses');
  }

  if (/(^|\s)(топ|катег|category)/u.test(normalized)) {
    return result('top_categories');
  }

  if (/(сравн|динам|прошл|рост|упал|больше|меньше|trend)/u.test(normalized)) {
    return result('trend_compare');
  }

  if (/(сколько|потрат|расход|доход|баланс|сводк|итог|summary|spent|spend|how much)/u.test(normalized)) {
    return result('spend_summary');
  }

  return result('help');
}

export async function classifyWithLLM(
  rawQuery: string,
  history: ConversationMessage[],
): Promise<LLMClassificationResult | null> {
  if (!OPENAI_API_KEY) return null;

  let userPrompt: string;
  if (history.length > 0) {
    const recentHistory = history.slice(-6).map((m) => {
      const obj: Record<string, string> = { r: m.role === 'user' ? 'u' : 'a', c: m.content };
      if (m.intent) obj.i = m.intent;
      if (m.period) obj.p = m.period;
      return obj;
    });
    userPrompt = JSON.stringify({ history: recentHistory, q: rawQuery });
  } else {
    userPrompt = JSON.stringify({ q: rawQuery });
  }

  const { parsed, usage } = await createOpenAIJsonCompletion({
    apiKey: OPENAI_API_KEY,
    model: OPENAI_MODEL,
    systemPrompt: CLASSIFY_SYSTEM_PROMPT,
    userPrompt,
    timeoutMs: AI_CLASSIFY_TIMEOUT_MS,
    temperature: 0,
  });

  if (!parsed) return null;

  const intent = parsed.intent;
  const period = parsed.period;
  const confidence = typeof parsed.confidence === 'number' ? parsed.confidence : 0;

  if (!isIntent(intent) || !isPeriod(period)) return null;

  // Extract custom days from LLM response
  const customDays = period === 'custom_days' && typeof parsed.days === 'number' && parsed.days > 0
    ? Math.min(parsed.days, 3650)
    : undefined;

  const entities = parsed.entities && typeof parsed.entities === 'object'
    ? parsed.entities as {
        category?: string | null;
        account?: string | null;
        merchant?: string | null;
        amount?: number | null;
        tx_type?: string | null;
        description?: string | null;
        tx_ref?: string | null;
      }
    : undefined;

  return { intent, period, confidence, customDays, entities, usage };
}

function resolveEntityFromLLM(
  llmResult: LLMClassificationResult,
): string | undefined {
  if (llmResult.intent === 'by_category') {
    if (llmResult.entities?.category && typeof llmResult.entities.category === 'string') {
      return llmResult.entities.category;
    }
    if (llmResult.entities?.merchant && typeof llmResult.entities.merchant === 'string') {
      return llmResult.entities.merchant;
    }
  }
  if (llmResult.intent === 'by_account') {
    if (llmResult.entities?.account && typeof llmResult.entities.account === 'string') {
      return llmResult.entities.account;
    }
  }
  if (llmResult.entities?.category && typeof llmResult.entities.category === 'string') {
    return llmResult.entities.category;
  }
  if (llmResult.entities?.account && typeof llmResult.entities.account === 'string') {
    return llmResult.entities.account;
  }
  if (llmResult.entities?.merchant && typeof llmResult.entities.merchant === 'string') {
    return llmResult.entities.merchant;
  }
  return undefined;
}

export async function classifyIntent(
  rawQuery: string,
  history: ConversationMessage[],
  userId: string,
): Promise<ClassificationResult> {
  // 1. Always compute regex result (for fallback and logging)
  const regexResult = parseIntentAndPeriod(rawQuery);

  // 2. If LLM classify is explicitly off or no API key -> return regex
  if (AI_LLM_CLASSIFY_OFF || !OPENAI_API_KEY) {
    return {
      intent: regexResult.intent,
      period: regexResult.period,
      entity: regexResult.entity,
      ...(regexResult.customDays ? { customDays: regexResult.customDays } : {}),
      source: 'regex',
      confidence: 1,
      regexIntent: regexResult.intent,
      regexPeriod: regexResult.period,
    };
  }

  // 3. Check classify cache (skip for multi-turn)
  const isMultiTurn = history.length > 0;
  if (!isMultiTurn) {
    const cck = classifyCacheKey(userId, rawQuery);
    const cachedClassify = getClassifyCached(cck);
    if (cachedClassify) {
      return { ...cachedClassify, regexIntent: regexResult.intent, regexPeriod: regexResult.period };
    }
  }

  // 4. Call LLM with timeout
  const llmStart = Date.now();
  let llmResult: LLMClassificationResult | null = null;
  try {
    llmResult = await classifyWithLLM(rawQuery, history);
  } catch (err) {
    console.error('classifyWithLLM error:', err);
  }
  const llmLatencyMs = Date.now() - llmStart;

  // 5. If LLM OK + confidence >= threshold -> use LLM
  if (llmResult && llmResult.confidence >= AI_CLASSIFY_CONFIDENCE_THRESHOLD) {
    const entity = resolveEntityFromLLM(llmResult);
    // Resolve customDays: prefer LLM's value, fallback to regex
    const resolvedCustomDays = llmResult.customDays ?? regexResult.customDays;
    const classResult: ClassificationResult = {
      intent: llmResult.intent,
      period: llmResult.period,
      entity,
      ...(resolvedCustomDays ? { customDays: resolvedCustomDays } : {}),
      source: 'llm',
      confidence: llmResult.confidence,
      llmLatencyMs,
      regexIntent: regexResult.intent,
      regexPeriod: regexResult.period,
      classifyUsage: llmResult.usage,
      llmEntities: llmResult.entities,
    };

    if (!isMultiTurn) {
      setClassifyCache(classifyCacheKey(userId, rawQuery), classResult);
    }

    return classResult;
  }

  // 6. LLM low confidence or error -> fallback to regex
  return {
    intent: regexResult.intent,
    period: regexResult.period,
    entity: regexResult.entity,
    ...(regexResult.customDays ? { customDays: regexResult.customDays } : {}),
    source: llmResult ? 'llm+regex_fallback' : 'regex',
    confidence: llmResult?.confidence ?? 0,
    llmLatencyMs,
    regexIntent: regexResult.intent,
    regexPeriod: regexResult.period,
    classifyUsage: llmResult?.usage,
  };
}
