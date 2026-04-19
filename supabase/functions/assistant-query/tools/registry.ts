/**
 * Tool registry for the tool-calling agent.
 * Each entry has a JSON-schema definition (for the LLM) and a typed
 * runner that takes the parsed args + a runtime context.
 *
 * The schemas use JSON Schema dialect understood by both OpenAI's
 * `tools` API and Anthropic's `tool_use` API — keep types simple
 * (string/number/boolean/array/object) so neither provider chokes.
 */

import type { TxRow, CategoryRow, AccountRow } from '../types.ts';
import {
  queryTransactions,
  aggregate,
  comparePeriods,
  type TxQueryFilters,
  type AggMetric,
  type AggGroupBy,
} from './transactions.ts';
import {
  compoundInterest,
  loanPayment,
  emergencyFundStatus,
  savingsRunway,
  calculator,
} from './finmath.ts';

export interface ToolContext {
  transactions: TxRow[];
  accounts: AccountRow[];
  categories: CategoryRow[];
  /// 'YYYY-MM-DD' — agent uses it to resolve relative dates.
  today: string;
  /// User's display currency, for FX-aware tools (future).
  baseCurrency: string;
}

export interface ToolDefinition {
  name: string;
  description: string;
  /// JSON Schema (subset). `parameters` per OpenAI; we transform for Anthropic in tool-agent.ts.
  parameters: Record<string, unknown>;
  run: (args: Record<string, unknown>, ctx: ToolContext) => unknown;
}

export const TOOLS: ToolDefinition[] = [
  {
    name: 'query_transactions',
    description: 'Search the user\'s transactions. Use this to fetch the rows you need before aggregating. Returns up to `limit` matching rows. Always exclude internal transfers unless the user explicitly asks about them.',
    parameters: {
      type: 'object',
      properties: {
        accountNames: { type: 'array', items: { type: 'string' }, description: 'Substring match on account names (case-insensitive). Use the user\'s wording, e.g. ["Семейный"]. Empty = all accessible accounts.' },
        categoryNames: { type: 'array', items: { type: 'string' }, description: 'Substring match on category names. Multiple values OR-match.' },
        merchant: { type: 'string', description: 'Substring of the merchant name.' },
        type: { type: 'string', enum: ['income', 'expense', 'transfer'], description: 'Default: any non-transfer.' },
        dateFrom: { type: 'string', description: 'YYYY-MM-DD inclusive.' },
        dateTo: { type: 'string', description: 'YYYY-MM-DD inclusive.' },
        weekdays: { type: 'array', items: { type: 'integer', minimum: 1, maximum: 7 }, description: 'ISO weekdays (1=Mon, 7=Sun). Use [6, 7] for weekends.' },
        amountMin: { type: 'number' },
        amountMax: { type: 'number' },
        excludeTransfers: { type: 'boolean', description: 'Default true.' },
        limit: { type: 'integer', minimum: 1, maximum: 2000, description: 'Default 500.' },
      },
      additionalProperties: false,
    },
    run: (args, ctx) => queryTransactions(
      ctx.transactions,
      { accounts: ctx.accounts, categories: ctx.categories },
      args as TxQueryFilters,
    ),
  },
  {
    name: 'aggregate',
    description: 'Aggregate a result set from query_transactions. Returns groups sorted by value desc. Use metric=sum for totals, metric=avg for average ticket, metric=count for frequency.',
    parameters: {
      type: 'object',
      properties: {
        rows: { type: 'array', description: 'The `rows` field returned by query_transactions.' },
        groupBy: { type: 'string', enum: ['category', 'merchant', 'account', 'weekday', 'month', 'none'] },
        metric: { type: 'string', enum: ['sum', 'avg', 'median', 'count', 'min', 'max', 'p90'] },
      },
      required: ['rows', 'metric'],
      additionalProperties: false,
    },
    run: (args, ctx) => aggregate(
      (args.rows as TxRow[]) ?? [],
      { accounts: ctx.accounts, categories: ctx.categories },
      { groupBy: args.groupBy as AggGroupBy | undefined, metric: args.metric as AggMetric },
    ),
  },
  {
    name: 'compare_periods',
    description: 'Compare totals between two date windows. Returns delta and per-group breakdown when groupBy is provided. Use this for "сравни с прошлым месяцем" / "что выросло".',
    parameters: {
      type: 'object',
      properties: {
        periodA: {
          type: 'object',
          properties: {
            from: { type: 'string' },
            to: { type: 'string' },
          },
          required: ['from', 'to'],
        },
        periodB: {
          type: 'object',
          properties: {
            from: { type: 'string' },
            to: { type: 'string' },
          },
          required: ['from', 'to'],
        },
        type: { type: 'string', enum: ['income', 'expense'] },
        groupBy: { type: 'string', enum: ['category', 'merchant', 'account', 'weekday', 'month'] },
      },
      required: ['periodA', 'periodB'],
      additionalProperties: false,
    },
    run: (args, ctx) => comparePeriods(
      ctx.transactions,
      { accounts: ctx.accounts, categories: ctx.categories },
      args as Parameters<typeof comparePeriods>[2],
    ),
  },
  {
    name: 'calculator',
    description: 'Safe arithmetic evaluator. Use this for any math the user asks — never compute in your head, the model is bad at arithmetic. Supports + - * / % and parentheses. Decimal point or comma both work.',
    parameters: {
      type: 'object',
      properties: {
        expression: { type: 'string', description: 'e.g. "(18450 - 12800) / 3" or "5650 * 1.12 ** 5" — note ** is NOT supported, use repeated multiplication or compound_interest.' },
      },
      required: ['expression'],
      additionalProperties: false,
    },
    run: (args) => ({ result: calculator(String(args.expression)) }),
  },
  {
    name: 'compound_interest',
    description: 'Future value of an investment with optional monthly contributions. Use for "сколько накоплю если откладывать X под Y%". `rate` is decimal (0.08 = 8%/year).',
    parameters: {
      type: 'object',
      properties: {
        principal: { type: 'number', description: 'Starting amount.' },
        rate: { type: 'number', description: 'Annual rate as decimal: 0.07 = 7%.' },
        years: { type: 'integer', minimum: 0 },
        monthlyContribution: { type: 'number', description: 'Optional monthly addition.' },
      },
      required: ['principal', 'rate', 'years'],
      additionalProperties: false,
    },
    run: (args) => compoundInterest(args as Parameters<typeof compoundInterest>[0]),
  },
  {
    name: 'loan_payment',
    description: 'Standard amortising-loan monthly payment. Returns monthly payment, total paid, and overpay.',
    parameters: {
      type: 'object',
      properties: {
        principal: { type: 'number' },
        rate: { type: 'number', description: 'Annual rate as decimal: 0.12 = 12%.' },
        termMonths: { type: 'integer', minimum: 1 },
      },
      required: ['principal', 'rate', 'termMonths'],
      additionalProperties: false,
    },
    run: (args) => loanPayment(args as Parameters<typeof loanPayment>[0]),
  },
  {
    name: 'emergency_fund_status',
    description: 'How many months of expenses the user\'s liquid savings cover, plus the gap to the conventional 3 / 6-month targets.',
    parameters: {
      type: 'object',
      properties: {
        monthlyExpenses: { type: 'number' },
        currentSavings: { type: 'number' },
      },
      required: ['monthlyExpenses', 'currentSavings'],
      additionalProperties: false,
    },
    run: (args) => emergencyFundStatus(args as Parameters<typeof emergencyFundStatus>[0]),
  },
  {
    name: 'savings_runway',
    description: 'How long current balance lasts at current monthly burn rate.',
    parameters: {
      type: 'object',
      properties: {
        balance: { type: 'number' },
        monthlyBurn: { type: 'number' },
      },
      required: ['balance', 'monthlyBurn'],
      additionalProperties: false,
    },
    run: (args) => savingsRunway(args as Parameters<typeof savingsRunway>[0]),
  },
];

export function findTool(name: string): ToolDefinition | undefined {
  return TOOLS.find((t) => t.name === name);
}
