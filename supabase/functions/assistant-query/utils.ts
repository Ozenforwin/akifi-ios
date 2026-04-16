import type { AssistantPeriod } from '../_shared/assistant-schema.ts';
import type { PeriodWindow } from './types.ts';

// Re-export shared utilities so other modules can import from './utils.ts'
export {
  normalizeText,
  normalizeForMatch,
  isMissingColumnError,
  toDateOnly,
  parseDateOnly,
  addDays,
} from '../_shared/utils.ts';
import { parseDateOnly, toDateOnly, addDays } from '../_shared/utils.ts';
import { formatMoney as _formatMoney } from '../_shared/utils.ts';

const DEFAULT_CURRENCY = (Deno.env.get('BOT_DEFAULT_CURRENCY') ?? 'RUB').toUpperCase();

export function diffDaysInclusive(start: string, end: string): number {
  const ms = parseDateOnly(end).getTime() - parseDateOnly(start).getTime();
  return Math.floor(ms / (24 * 60 * 60 * 1000)) + 1;
}

export function getWindow(period: AssistantPeriod, today: string, customDays?: number): PeriodWindow {
  if (period === 'custom_days' && customDays && customDays > 0) {
    return {
      start: addDays(today, -(customDays - 1)),
      end: today,
    };
  }

  if (period === 'today') {
    return { start: today, end: today };
  }

  if (period === 'week') {
    const date = parseDateOnly(today);
    const day = date.getUTCDay();
    const offset = day === 0 ? 6 : day - 1;
    return {
      start: addDays(today, -offset),
      end: today,
    };
  }

  if (period === 'month') {
    const date = parseDateOnly(today);
    date.setUTCDate(1);
    return {
      start: toDateOnly(date),
      end: today,
    };
  }

  return {
    start: addDays(today, -89),
    end: today,
  };
}

export function getPreviousWindow(current: PeriodWindow): PeriodWindow {
  const length = diffDaysInclusive(current.start, current.end);
  const prevEnd = addDays(current.start, -1);
  const prevStart = addDays(prevEnd, -(length - 1));
  return { start: prevStart, end: prevEnd };
}

export function inWindow(date: string, window: PeriodWindow): boolean {
  const dateOnly = date.slice(0, 10);
  return dateOnly >= window.start && dateOnly <= window.end;
}

export function safeNumber(value: unknown): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

export function formatMoney(value: number): string {
  return _formatMoney(value, DEFAULT_CURRENCY);
}

export function periodLabel(period: AssistantPeriod | string, customDays?: number): string {
  if (period === 'today') return 'сегодня';
  if (period === 'week') return 'за неделю';
  if (period === 'month') return 'за месяц';
  if (period === 'custom_days') {
    if (!customDays) return 'за указанный период';
    if (customDays === 1) return 'за 1 день';
    if (customDays % 30 === 0 && customDays >= 30) {
      const months = customDays / 30;
      if (months === 1) return 'за 1 месяц';
      if (months >= 2 && months <= 4) return `за ${months} месяца`;
      return `за ${months} месяцев`;
    }
    if (customDays % 7 === 0 && customDays >= 7) {
      const weeks = customDays / 7;
      if (weeks === 1) return 'за 1 неделю';
      if (weeks >= 2 && weeks <= 4) return `за ${weeks} недели`;
      return `за ${weeks} недель`;
    }
    if (customDays >= 2 && customDays <= 4) return `за ${customDays} дня`;
    return `за ${customDays} дней`;
  }
  return 'за последние 90 дней';
}

// Format amount without currency (currency-neutral, just number with spaces as thousands separator)
export function formatAmountNeutral(value: number): string {
  return new Intl.NumberFormat('ru-RU', {
    maximumFractionDigits: 2,
    minimumFractionDigits: 0,
  }).format(value);
}

export function budgetWindowForToday(budget: { period_type: string; custom_start_date: string | null; custom_end_date: string | null }, today: string): PeriodWindow | null {
  if (budget.period_type === 'weekly') {
    return getWindow('week', today);
  }

  if (budget.period_type === 'custom') {
    if (!budget.custom_start_date || !budget.custom_end_date) return null;
    if (today < budget.custom_start_date || today > budget.custom_end_date) return null;
    return { start: budget.custom_start_date, end: budget.custom_end_date };
  }

  return getWindow('month', today);
}
