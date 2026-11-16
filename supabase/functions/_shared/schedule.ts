// Subscription charge schedule — anchor-based (D2).
//
// CONTRACT — identical to the iOS `SubscriptionDateEngine` (dates stream);
// the test vectors in schedule.test.ts are ported 1:1 from
// AkifiIOSTests/SubscriptionScheduleTests.swift:
//
//   charge k = anchor + k periods (k may be negative when walking history)
//   monthly / quarterly / yearly: add 1 / 3 / 12 calendar months TO THE
//     ANCHOR (never to the previous charge date) and clamp the day to the
//     month length: 31 Jan → 28/29 Feb → 31 Mar → 30 Apr; yearly 29 Feb →
//     28 Feb in non-leap years, 29 Feb again in leap years.
//   weekly: anchor + 7k days.   custom: anchor + 30k days.
//   unknown period strings behave as monthly (historical server behaviour).
//
//   anchor(sub) = start_date when next_payment_date is missing or lies ON
//     the schedule anchored at start_date; otherwise next_payment_date.
//     (11 of 16 active prod rows have a legacy start_date = "day it was
//     added", not a billing day — anchoring on it would move their day.)
//   After charging cycle C: next_payment_date = the first anchor + k·period
//     (k ≥ 0) strictly after C, never earlier than the stored value.
//
// The previous implementation stepped from the last date with
// `setUTCMonth(+1)`, which overflows: 31 Jan → 3 Mar, so February was never
// charged and every later charge drifted to the 3rd.
//
// All dates are `yyyy-MM-dd` strings (calendar days, no time zone).

export type BillingPeriod = "weekly" | "monthly" | "quarterly" | "yearly" | "custom" | string;

const DAY_MS = 24 * 60 * 60 * 1000;
export const CUSTOM_PERIOD_DAYS = 30;

interface Ymd { y: number; m: number; d: number } // m: 0-based

function ymd(date: string): Ymd {
  const [y, m, d] = date.slice(0, 10).split("-").map(Number);
  return { y, m: m - 1, d };
}

function fmt({ y, m, d }: Ymd): string {
  return `${String(y).padStart(4, "0")}-${String(m + 1).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

function toUtcMs(date: string): number {
  const { y, m, d } = ymd(date);
  return Date.UTC(y, m, d);
}

function fromUtcMs(ms: number): string {
  const dt = new Date(ms);
  return fmt({ y: dt.getUTCFullYear(), m: dt.getUTCMonth(), d: dt.getUTCDate() });
}

function dayNumber(date: string): number {
  return Math.round(toUtcMs(date) / DAY_MS);
}

export function daysInMonth(year: number, month0: number): number {
  return new Date(Date.UTC(year, month0 + 1, 0)).getUTCDate();
}

/** Days from `from` to `to` (negative when `to` is earlier). */
export function daysBetween(from: string, to: string): number {
  return dayNumber(to) - dayNumber(from);
}

export function addDaysTo(date: string, days: number): string {
  return fromUtcMs(toUtcMs(date) + days * DAY_MS);
}

/** `date` + `months` calendar months, day clamped to the target month's length. */
export function addMonthsClamped(date: string, months: number): string {
  const { y, m, d } = ymd(date);
  const total = y * 12 + m + months;
  const ty = Math.floor(total / 12);
  const tm = total - ty * 12;
  return fmt({ y: ty, m: tm, d: Math.min(d, daysInMonth(ty, tm)) });
}

function monthStep(period: BillingPeriod): number | null {
  if (period === "weekly" || period === "custom") return null;
  if (period === "quarterly") return 3;
  if (period === "yearly") return 12;
  return 1; // monthly and unknown
}

function dayStep(period: BillingPeriod): number {
  return period === "weekly" ? 7 : CUSTOM_PERIOD_DAYS;
}

/** The k-th charge date (any sign) of the schedule anchored at `anchor`. */
export function chargeDateAt(anchor: string, period: BillingPeriod, k: number): string {
  const step = monthStep(period);
  if (step === null) return addDaysTo(anchor, k * dayStep(period));
  return addMonthsClamped(anchor, k * step);
}

/** Smallest k (any sign) whose charge date is strictly after `date` (Swift `firstIndex(after:)`). */
export function firstIndexAfter(anchor: string, period: BillingPeriod, date: string): number {
  const step = monthStep(period);
  if (step === null) {
    return Math.floor(daysBetween(anchor, date) / dayStep(period)) + 1;
  }
  const a = ymd(anchor);
  const t = ymd(date);
  let k = Math.floor(((t.y * 12 + t.m) - (a.y * 12 + a.m)) / step) - 1; // ≥ one step before `date`
  while (chargeDateAt(anchor, period, k) <= date.slice(0, 10)) k += 1;
  return k;
}

/** Largest k (any sign) with chargeDateAt(k) ≤ `date`. */
export function indexOnOrBefore(anchor: string, period: BillingPeriod, date: string): number {
  return firstIndexAfter(anchor, period, date) - 1;
}

/** First charge date (k ≥ 0) strictly after `date` — the anchor itself when `date` precedes it. */
export function nextChargeAfter(anchor: string, period: BillingPeriod, date: string): string {
  return chargeDateAt(anchor, period, Math.max(0, firstIndexAfter(anchor, period, date)));
}

/** Last charge date (any k) strictly before `date`. */
export function previousChargeBefore(anchor: string, period: BillingPeriod, date: string): string {
  return chargeDateAt(anchor, period, firstIndexAfter(anchor, period, addDaysTo(date, -1)) - 1);
}

/** The charge date (any k) closest to `date`; ties go to the earlier one. */
export function nearestChargeDate(anchor: string, period: BillingPeriod, date: string): string {
  const k = firstIndexAfter(anchor, period, date);
  const before = chargeDateAt(anchor, period, k - 1);
  const after = chargeDateAt(anchor, period, k);
  return daysBetween(before, date) <= daysBetween(date, after) ? before : after;
}

/** True when `date` is one of the schedule's charge dates (any k). */
export function isOnSchedule(anchor: string, period: BillingPeriod, date: string): boolean {
  return nearestChargeDate(anchor, period, date) === date.slice(0, 10);
}

/**
 * The schedule anchor of a stored subscription (Swift `anchor(for:)`):
 * start_date when next_payment_date is missing or lies on its schedule,
 * otherwise next_payment_date.
 */
export function scheduleAnchor(
  startDate: string | null | undefined,
  nextPaymentDate: string | null | undefined,
  period: BillingPeriod,
): string | null {
  const start = startDate ? startDate.slice(0, 10) : null;
  const next = nextPaymentDate ? nextPaymentDate.slice(0, 10) : null;
  if (!start) return next;
  if (!next) return start;
  return isOnSchedule(start, period, next) ? start : next;
}

export interface ScheduleCatchUp {
  anchor: string;
  /** Which column the anchor came from — for logs. */
  source: "start_date" | "next_payment_date";
  /** Charge dates ≤ today to charge now, oldest first. May include today. */
  due: string[];
  /** Charge dates too old to charge (beyond the catch-up window), rolled past. */
  skipped: string[];
  /** The first charge date strictly after today (never before the stored date) — the new `next_payment_date`. */
  next: string;
  /** The charge date a reminder should refer to: today when due today, else `next`. */
  upcoming: string;
}

/**
 * Splits an overdue (or due-today) schedule into what to charge and what
 * to skip.
 *
 * The daily cron is not guaranteed to run (2026-09-01: two weeks behind
 * gateway JWT verification; 2026-09-10/11: database down), so every charge
 * date the cron slept through is charged on its own date, idempotently
 * (charge events dedupe per date). Dates older than `catchUpDays` are
 * stale data, not an outage, and are rolled past.
 *
 * The stored next_payment_date is always ON the resolved anchor's schedule
 * (it either matches start_date's schedule or IS the anchor), so the walk
 * starts exactly there and nothing before it is ever (re)charged.
 */
export function planCatchUp(input: {
  startDate: string | null | undefined;
  nextPaymentDate: string;
  period: BillingPeriod;
  today: string;
  catchUpDays: number;
}): ScheduleCatchUp {
  const { period, today, catchUpDays } = input;
  const stored = input.nextPaymentDate.slice(0, 10);
  const anchor = scheduleAnchor(input.startDate, stored, period) ?? stored;
  const source: ScheduleCatchUp["source"] =
    input.startDate && anchor === input.startDate.slice(0, 10) ? "start_date" : "next_payment_date";
  const oldestChargeable = addDaysTo(today, -catchUpDays);
  const due: string[] = [];
  const skipped: string[] = [];
  let k = indexOnOrBefore(anchor, period, stored);
  let cursor = chargeDateAt(anchor, period, k);
  // 1200 iterations ≈ 23 years of weekly charges — a guard against a
  // malformed date, not a business limit.
  for (let i = 0; i < 1200 && cursor <= today; i += 1) {
    (cursor >= oldestChargeable ? due : skipped).push(cursor);
    k += 1;
    cursor = chargeDateAt(anchor, period, k);
  }
  const next = cursor < stored ? stored : cursor; // never earlier than the stored date
  return {
    anchor,
    source,
    due,
    skipped,
    next,
    upcoming: due.includes(today) ? today : next,
  };
}
