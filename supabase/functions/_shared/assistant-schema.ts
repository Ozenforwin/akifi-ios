export type AssistantIntent =
  | 'spend_summary'
  | 'top_categories'
  | 'top_expenses'
  | 'budget_risk'
  | 'trend_compare'
  | 'by_category'
  | 'by_account'
  | 'budget_remaining'
  | 'average_check'
  | 'forecast'
  | 'anomalies'
  | 'create_transaction'
  | 'edit_transaction'
  | 'delete_transaction'
  | 'edit_budget'
  | 'seasonal_forecast'
  | 'savings_advice'
  | 'savings_contribute'
  | 'recurring_patterns'
  | 'financial_advice'
  | 'impulse_check'
  | 'debt_strategy'
  | 'savings_plan'
  | 'budget_optimization'
  | 'financial_stage'
  | 'investment_basics'
  | 'financial_safety'
  | 'habit_check'
  | 'smart_budget_create'
  | 'spending_optimization'
  | 'book_recommendations'
  | 'help';

export type AssistantPeriod = 'today' | 'week' | 'month' | 'all' | 'custom_days';

export type AssistantActionType =
  | 'open_transactions'
  | 'open_budget_tab'
  | 'open_add_expense'
  | 'open_add_income'
  | 'open_savings'
  | 'create_budget_suggestion'
  | 'create_transaction'
  | 'edit_transaction'
  | 'delete_transaction'
  | 'edit_budget'
  | 'savings_contribute'
  | 'smart_budget_create';

export interface AssistantAction {
  type: AssistantActionType;
  label: string;
  payload?: Record<string, unknown>;
}

export type AnomalyEvidenceType =
  | 'category_spike'
  | 'merchant_spike'
  | 'single_large_tx'
  | 'frequency_spike';

export interface AnomalyEvidence {
  type: AnomalyEvidenceType;
  label: string;
  current_value: number;
  baseline_value: number;
  delta_percent: number;
  tx_refs: string[];
  heatmap?: { day: number; count: number }[];
}

export type RecommendedActionType =
  | 'open_transactions'
  | 'open_budget_tab'
  | 'open_add_expense'
  | 'open_add_income'
  | 'create_budget_suggestion';

export interface RecommendedAction {
  id: string;
  label: string;
  action_type: RecommendedActionType;
  payload?: {
    tx_ids?: string[];
    category?: string;
    merchant?: string;
    min_amount?: number;
  };
}

export interface AssistantResponsePayload {
  answer: string;
  facts: string[];
  actions: AssistantAction[];
  followUps: string[];
  intent: AssistantIntent;
  period: AssistantPeriod;
  evidence?: AnomalyEvidence[];
  confidence?: number;
  recommendedActions?: RecommendedAction[];
  explainability?: string;
}

export function sanitizeAssistantResponse(input: Partial<AssistantResponsePayload>): AssistantResponsePayload {
  const facts = Array.isArray(input.facts)
    ? input.facts.filter((item): item is string => typeof item === 'string' && item.trim().length > 0).slice(0, 10)
    : [];

  const actions = Array.isArray(input.actions)
    ? input.actions
      .map((item) => sanitizeAction(item))
      .filter((item): item is AssistantAction => item !== null)
      .slice(0, 4)
    : [];

  const followUps = Array.isArray(input.followUps)
    ? input.followUps.filter((item): item is string => typeof item === 'string' && item.trim().length > 0).slice(0, 3)
    : [];

  const evidence = Array.isArray(input.evidence)
    ? input.evidence
      .filter((e): e is AnomalyEvidence =>
        !!e && typeof e === 'object' && typeof e.type === 'string' && typeof e.label === 'string')
      .slice(0, 5)
    : undefined;

  const confidence = typeof input.confidence === 'number' && input.confidence >= 0 && input.confidence <= 1
    ? input.confidence
    : undefined;

  const recommendedActions = Array.isArray(input.recommendedActions)
    ? input.recommendedActions
      .map((item) => sanitizeRecommendedAction(item))
      .filter((item): item is RecommendedAction => item !== null)
      .slice(0, 5)
    : undefined;

  const explainability = typeof input.explainability === 'string' && input.explainability.trim()
    ? input.explainability.trim()
    : undefined;

  return {
    answer: typeof input.answer === 'string' && input.answer.trim()
      ? input.answer.trim()
      : 'Пока не смог сформировать ответ. Попробуйте переформулировать запрос.',
    facts,
    actions,
    followUps,
    intent: isIntent(input.intent) ? input.intent : 'help',
    period: isPeriod(input.period) ? input.period : 'month',
    ...(evidence && evidence.length > 0 ? { evidence } : {}),
    ...(confidence !== undefined ? { confidence } : {}),
    ...(recommendedActions && recommendedActions.length > 0 ? { recommendedActions } : {}),
    ...(explainability ? { explainability } : {}),
  };
}

function sanitizeAction(input: unknown): AssistantAction | null {
  if (!input || typeof input !== 'object') return null;
  const obj = input as Record<string, unknown>;
  if (!isActionType(obj.type)) return null;
  const label = typeof obj.label === 'string' ? obj.label.trim() : '';
  if (!label) return null;

  const payload = obj.payload && typeof obj.payload === 'object'
    ? obj.payload as Record<string, unknown>
    : undefined;

  return {
    type: obj.type,
    label,
    ...(payload ? { payload } : {}),
  };
}

const RECOMMENDED_ACTION_TYPES: Set<string> = new Set([
  'open_transactions', 'open_budget_tab', 'open_add_expense', 'open_add_income', 'create_budget_suggestion',
]);

function sanitizeRecommendedAction(input: unknown): RecommendedAction | null {
  if (!input || typeof input !== 'object') return null;
  const obj = input as Record<string, unknown>;
  if (typeof obj.id !== 'string' || !obj.id) return null;
  if (typeof obj.label !== 'string' || !obj.label.trim()) return null;
  if (typeof obj.action_type !== 'string' || !RECOMMENDED_ACTION_TYPES.has(obj.action_type)) return null;

  const payload = obj.payload && typeof obj.payload === 'object'
    ? obj.payload as RecommendedAction['payload']
    : undefined;

  return {
    id: obj.id,
    label: obj.label.trim(),
    action_type: obj.action_type as RecommendedActionType,
    ...(payload ? { payload } : {}),
  };
}

export function isIntent(value: unknown): value is AssistantIntent {
  return value === 'spend_summary'
    || value === 'top_categories'
    || value === 'top_expenses'
    || value === 'budget_risk'
    || value === 'trend_compare'
    || value === 'by_category'
    || value === 'by_account'
    || value === 'budget_remaining'
    || value === 'average_check'
    || value === 'forecast'
    || value === 'anomalies'
    || value === 'create_transaction'
    || value === 'edit_transaction'
    || value === 'delete_transaction'
    || value === 'edit_budget'
    || value === 'seasonal_forecast'
    || value === 'savings_advice'
    || value === 'savings_contribute'
    || value === 'recurring_patterns'
    || value === 'financial_advice'
    || value === 'impulse_check'
    || value === 'debt_strategy'
    || value === 'savings_plan'
    || value === 'budget_optimization'
    || value === 'financial_stage'
    || value === 'investment_basics'
    || value === 'financial_safety'
    || value === 'habit_check'
    || value === 'smart_budget_create'
    || value === 'spending_optimization'
    || value === 'book_recommendations'
    || value === 'help';
}

export function isPeriod(value: unknown): value is AssistantPeriod {
  return value === 'today' || value === 'week' || value === 'month' || value === 'all' || value === 'custom_days';
}

function isActionType(value: unknown): value is AssistantActionType {
  return value === 'open_transactions'
    || value === 'open_budget_tab'
    || value === 'open_add_expense'
    || value === 'open_add_income'
    || value === 'open_savings'
    || value === 'create_budget_suggestion'
    || value === 'create_transaction'
    || value === 'edit_transaction'
    || value === 'delete_transaction'
    || value === 'edit_budget'
    || value === 'savings_contribute'
    || value === 'smart_budget_create';
}
