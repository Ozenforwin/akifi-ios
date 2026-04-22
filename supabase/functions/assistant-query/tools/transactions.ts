/**
 * Transaction-querying tools for the tool-calling agent.
 * Pure functions over an already-loaded transaction array — no DB access.
 */

import type { TxRow, CategoryRow, AccountRow } from '../types.ts';

export interface TxQueryFilters {
  /// Account ids — narrows rows to specific accounts. Empty = all accessible.
  accountIds?: string[];
  /// Account NAMES — case-insensitive substring match. Resolved via the
  /// `accounts` lookup passed to the runtime.
  accountNames?: string[];
  /// Category names (case-insensitive substring). Multiple values OR-match.
  categoryNames?: string[];
  /// Merchant fragment (case-insensitive substring).
  merchant?: string;
  /// 'income' | 'expense' | 'transfer' | undefined for any.
  type?: 'income' | 'expense' | 'transfer';
  /// 'YYYY-MM-DD' inclusive. Undefined = no lower bound.
  dateFrom?: string;
  /// 'YYYY-MM-DD' inclusive.
  dateTo?: string;
  /// Restrict to certain ISO weekdays (1 = Mon … 7 = Sun).
  weekdays?: number[];
  /// Numeric bounds on the absolute amount in the transaction's own currency.
  amountMin?: number;
  amountMax?: number;
  /// Drop transfer-pair rows (default true — usually you want spending only).
  excludeTransfers?: boolean;
  /// Cap on returned rows (default 500).
  limit?: number;
}

export interface QueryResult {
  rows: TxRow[];
  total: number;
  truncated: boolean;
}

/// The single read tool. Filters happen client-side over `transactions`.
export function queryTransactions(
  transactions: TxRow[],
  lookups: { accounts: AccountRow[]; categories: CategoryRow[] },
  filters: TxQueryFilters = {},
): QueryResult {
  const limit = Math.max(1, Math.min(2000, filters.limit ?? 500));
  const excludeTransfers = filters.excludeTransfers ?? true;

  // Resolve account name → id set.
  const accountIdSet = new Set<string>(filters.accountIds ?? []);
  if (filters.accountNames?.length) {
    const needles = filters.accountNames.map((n) => n.toLowerCase());
    for (const acc of lookups.accounts) {
      const name = acc.name.toLowerCase();
      if (needles.some((n) => name.includes(n))) accountIdSet.add(acc.id);
    }
  }

  // Resolve category names → ids (substring match across both account members).
  const categoryIdSet = new Set<string>();
  if (filters.categoryNames?.length) {
    const needles = filters.categoryNames.map((n) => n.toLowerCase());
    for (const cat of lookups.categories) {
      const name = (cat.name ?? '').toLowerCase();
      if (needles.some((n) => name.includes(n))) categoryIdSet.add(cat.id);
    }
  }

  const merchant = filters.merchant?.toLowerCase() ?? null;
  const wantedType = filters.type ?? null;
  const dateFrom = filters.dateFrom ?? null;
  const dateTo = filters.dateTo ?? null;
  const weekdaySet = filters.weekdays?.length ? new Set(filters.weekdays) : null;
  const amountMin = filters.amountMin ?? null;
  const amountMax = filters.amountMax ?? null;

  const out: TxRow[] = [];
  for (const tx of transactions) {
    if (excludeTransfers && tx.transfer_group_id) continue;
    if (wantedType && tx.type !== wantedType) continue;
    if (accountIdSet.size > 0 && (!tx.account_id || !accountIdSet.has(tx.account_id))) continue;
    if (categoryIdSet.size > 0 && !categoryIdSet.has(tx.category_id)) continue;
    if (merchant) {
      const m = (tx.merchant_name ?? tx.merchant_normalized ?? '').toLowerCase();
      if (!m.includes(merchant)) continue;
    }
    const dateOnly = tx.date.slice(0, 10);
    if (dateFrom && dateOnly < dateFrom) continue;
    if (dateTo && dateOnly > dateTo) continue;
    if (weekdaySet) {
      const wd = isoWeekday(dateOnly);
      if (!weekdaySet.has(wd)) continue;
    }
    const amt = Math.abs(Number(tx.amount_in_base ?? tx.amount_native ?? tx.amount) || 0);
    if (amountMin !== null && amt < amountMin) continue;
    if (amountMax !== null && amt > amountMax) continue;
    out.push(tx);
    if (out.length >= limit) break;
  }

  return {
    rows: out,
    total: countMatching(transactions, lookups, filters),
    truncated: out.length >= limit,
  };
}

// Cheap re-run without limit so the caller knows whether it saw everything.
function countMatching(
  transactions: TxRow[],
  lookups: { accounts: AccountRow[]; categories: CategoryRow[] },
  filters: TxQueryFilters,
): number {
  if (!filters.limit) return -1; // skip when caller didn't cap
  let n = 0;
  for (const tx of transactions) {
    if ((filters.excludeTransfers ?? true) && tx.transfer_group_id) continue;
    if (filters.type && tx.type !== filters.type) continue;
    n++;
  }
  return n;
}

// ── Aggregation ──────────────────────────────────────────────────────

export type AggMetric = 'sum' | 'avg' | 'median' | 'count' | 'min' | 'max' | 'p90';
export type AggGroupBy = 'category' | 'merchant' | 'account' | 'weekday' | 'month' | 'none';

export interface AggregateRow {
  group: string;
  value: number;
  count: number;
}

export function aggregate(
  rows: TxRow[],
  lookups: { accounts: AccountRow[]; categories: CategoryRow[] },
  args: { groupBy?: AggGroupBy; metric: AggMetric },
): AggregateRow[] {
  const groupBy = args.groupBy ?? 'none';
  const buckets = new Map<string, number[]>();

  for (const tx of rows) {
    const key = groupKey(tx, lookups, groupBy);
    const arr = buckets.get(key) ?? [];
    arr.push(Math.abs(Number(tx.amount_in_base ?? tx.amount_native ?? tx.amount) || 0));
    buckets.set(key, arr);
  }

  const out: AggregateRow[] = [];
  for (const [group, arr] of buckets.entries()) {
    out.push({ group, value: applyMetric(arr, args.metric), count: arr.length });
  }
  out.sort((a, b) => b.value - a.value);
  return out;
}

function groupKey(
  tx: TxRow,
  lookups: { accounts: AccountRow[]; categories: CategoryRow[] },
  by: AggGroupBy,
): string {
  switch (by) {
    case 'category': {
      const cat = tx.category?.name ?? lookups.categories.find((c) => c.id === tx.category_id)?.name;
      return cat?.trim() || 'Other';
    }
    case 'merchant':
      return (tx.merchant_name ?? tx.merchant_normalized ?? 'Unknown').trim();
    case 'account': {
      const acc = lookups.accounts.find((a) => a.id === tx.account_id);
      return acc?.name ?? 'Unknown';
    }
    case 'weekday':
      return String(isoWeekday(tx.date.slice(0, 10)));
    case 'month':
      return tx.date.slice(0, 7);
    case 'none':
    default:
      return 'all';
  }
}

function applyMetric(values: number[], metric: AggMetric): number {
  if (values.length === 0) return 0;
  switch (metric) {
    case 'sum':   return round2(values.reduce((a, b) => a + b, 0));
    case 'avg':   return round2(values.reduce((a, b) => a + b, 0) / values.length);
    case 'count': return values.length;
    case 'min':   return round2(Math.min(...values));
    case 'max':   return round2(Math.max(...values));
    case 'median': {
      const sorted = [...values].sort((a, b) => a - b);
      const mid = Math.floor(sorted.length / 2);
      return round2(sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]);
    }
    case 'p90': {
      const sorted = [...values].sort((a, b) => a - b);
      const idx = Math.min(sorted.length - 1, Math.floor(sorted.length * 0.9));
      return round2(sorted[idx]);
    }
  }
}

// ── Period comparison ────────────────────────────────────────────────

export interface PeriodCompareResult {
  periodA: { start: string; end: string; total: number; count: number };
  periodB: { start: string; end: string; total: number; count: number };
  delta: { absolute: number; percent: number };
  byGroup?: Array<{ group: string; a: number; b: number; delta: number; deltaPercent: number }>;
}

export function comparePeriods(
  transactions: TxRow[],
  lookups: { accounts: AccountRow[]; categories: CategoryRow[] },
  args: {
    periodA: { from: string; to: string };
    periodB: { from: string; to: string };
    type?: 'income' | 'expense';
    groupBy?: Exclude<AggGroupBy, 'none'>;
  },
): PeriodCompareResult {
  const wantedType = args.type ?? 'expense';
  const slice = (from: string, to: string) =>
    transactions.filter((tx) =>
      !tx.transfer_group_id
      && tx.type === wantedType
      && tx.date.slice(0, 10) >= from
      && tx.date.slice(0, 10) <= to,
    );

  const a = slice(args.periodA.from, args.periodA.to);
  const b = slice(args.periodB.from, args.periodB.to);
  const totalA = round2(a.reduce((s, tx) => s + Math.abs(Number(tx.amount_in_base ?? tx.amount_native ?? tx.amount) || 0), 0));
  const totalB = round2(b.reduce((s, tx) => s + Math.abs(Number(tx.amount_in_base ?? tx.amount_native ?? tx.amount) || 0), 0));
  const delta = round2(totalB - totalA);
  const pct = totalA === 0 ? (totalB === 0 ? 0 : 100) : round2(((totalB - totalA) / totalA) * 100);

  const result: PeriodCompareResult = {
    periodA: { start: args.periodA.from, end: args.periodA.to, total: totalA, count: a.length },
    periodB: { start: args.periodB.from, end: args.periodB.to, total: totalB, count: b.length },
    delta: { absolute: delta, percent: pct },
  };

  if (args.groupBy) {
    const aGroups = new Map(aggregate(a, lookups, { groupBy: args.groupBy, metric: 'sum' }).map((r) => [r.group, r.value]));
    const bGroups = new Map(aggregate(b, lookups, { groupBy: args.groupBy, metric: 'sum' }).map((r) => [r.group, r.value]));
    const allKeys = new Set([...aGroups.keys(), ...bGroups.keys()]);
    result.byGroup = [...allKeys].map((g) => {
      const av = aGroups.get(g) ?? 0;
      const bv = bGroups.get(g) ?? 0;
      const d = round2(bv - av);
      const dp = av === 0 ? (bv === 0 ? 0 : 100) : round2(((bv - av) / av) * 100);
      return { group: g, a: av, b: bv, delta: d, deltaPercent: dp };
    }).sort((x, y) => Math.abs(y.delta) - Math.abs(x.delta));
  }

  return result;
}

// ── Helpers ──────────────────────────────────────────────────────────

function isoWeekday(yyyymmdd: string): number {
  // 'YYYY-MM-DD' → 1..7 (Mon..Sun) in UTC to avoid TZ surprises.
  const d = new Date(`${yyyymmdd}T00:00:00Z`);
  const js = d.getUTCDay(); // 0 = Sun, 6 = Sat
  return js === 0 ? 7 : js;
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}
