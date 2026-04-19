import type { AssistantIntent, AssistantPeriod } from '../_shared/assistant-schema.ts';
import type { OpenAIUsage } from '../_shared/openai.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.95.3';

// deno-lint-ignore no-explicit-any
export type SupabaseClient = ReturnType<typeof createClient<any>>;

export interface AssistantQueryContext {
  accounts?: Array<{ id: string; name: string; balance: number; currency: string }>;
  categories?: Array<{ id: string; name: string; type: string }>;
  messages?: Array<{ role: string; content: string }>;
}

export interface AssistantQueryRequest {
  query?: string;
  source?: 'mini_app' | 'telegram_bot' | 'system';
  conversation_id?: string;
  context?: AssistantQueryContext;
}

export interface TxRow {
  id: string;
  amount: number;
  date: string;
  type: 'income' | 'expense';
  category_id: string;
  account_id: string | null;
  merchant_name?: string | null;
  merchant_normalized?: string | null;
  transfer_group_id?: string | null;
  category?: { name?: string | null } | null;
}

export interface BudgetRow {
  id: string;
  amount: number;
  category_ids: string[];
  account_ids: string[] | null;
  period_type: 'monthly' | 'weekly' | 'custom';
  custom_start_date: string | null;
  custom_end_date: string | null;
  is_active: boolean;
}

export interface CategoryRow {
  id: string;
  name: string;
  type?: string;
}

export interface AccountRow {
  id: string;
  name: string;
  balance?: number;
  currency?: string;
  is_shared?: boolean;
  owner_user_id?: string;
  member_role?: 'owner' | 'editor' | 'viewer';
}

export interface PeriodWindow {
  start: string;
  end: string;
}

export interface ParsedIntent {
  intent: AssistantIntent;
  period: AssistantPeriod;
  entity?: string;
  customDays?: number;
}

export interface ConversationMessage {
  role: 'user' | 'assistant';
  content: string;
  intent?: string;
  period?: string;
}

export interface LLMClassificationResult {
  intent: AssistantIntent;
  period: AssistantPeriod;
  confidence: number;
  customDays?: number;
  entities?: {
    category?: string | null;
    account?: string | null;
    merchant?: string | null;
    amount?: number | null;
    tx_type?: string | null;
    description?: string | null;
    tx_ref?: string | null;
  };
  usage?: OpenAIUsage | null;
}

export interface ClassificationResult {
  intent: AssistantIntent;
  period: AssistantPeriod;
  entity?: string;
  customDays?: number;
  source: 'llm' | 'regex' | 'llm+regex_fallback';
  confidence: number;
  llmLatencyMs?: number;
  regexIntent?: AssistantIntent;
  regexPeriod?: AssistantPeriod;
  classifyUsage?: OpenAIUsage | null;
  llmEntities?: LLMClassificationResult['entities'];
}

export interface SavingsGoalRow {
  id: string;
  name: string;
  target_amount: number;
  current_amount: number;
  deadline: string | null;
  status: string;
  monthly_target: number | null;
}

export interface SavingsContributionRow {
  goal_id: string;
  amount: number;
  created_at: string;
}

export interface RecurringPattern {
  description: string;
  frequency: 'monthly' | 'weekly' | 'unknown';
  medianAmount: number;
  medianIntervalDays: number;
  nextExpectedDate: string;
  confidence: number;
  count: number;
}

export interface AnomaliesResult {
  answer: string;
  facts: string[];
  actions: import('../_shared/assistant-schema.ts').AssistantAction[];
  followUps: string[];
  evidence: import('../_shared/assistant-schema.ts').AnomalyEvidence[];
  confidence: number;
  recommendedActions: import('../_shared/assistant-schema.ts').RecommendedAction[];
  explainability: string;
}

// User AI settings types
export type AiTone = 'balanced' | 'strict' | 'friendly';

export interface UserAiSettings {
  tone: AiTone;
  locale: string;
  timezone: string;
}

export interface CreateTxEntities {
  amount: number | null;
  tx_type: 'income' | 'expense';
  category_hint: string | null;
  description: string | null;
  currency: string | null;
}
