// Subscription charge schedule — anchor-based (D2).
//
// CONTRACT (identical to the iOS SubscriptionDateEngine; both sides must
// produce the same dates):
//
//   charge k  = anchor + k periods,  anchor = subscriptions.start_date
//   monthly / quarterly / yearly: add 1 / 3 / 12 calendar months TO THE
//     ANCHOR (never to the previous charge date) and clamp the day to the
//     month length: 31 Jan → 28/29 Feb → 31 Mar → 30 Apr; yearly 29 Feb →
//     28 Feb in non-leap years, 29 Feb again in leap years.
//   weekly: anchor + 7k days.   custom: anchor + 30k days.
//   unknown period strings behave as monthly (historical behaviour).
//   next_payment_date = the first charge date strictly after the last
//     charged date.
//
// The previous implementation stepped from the last date with
// `setUTCMonth(+1)`, which overflows: 31 Jan → 3 Mar, so February was
// never charged, and every later charge drifted to the 3rd.
//
// All dates are `yyyy-MM-dd` strings (calendar dates, no time zone).

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

export function daysInMonth(year: number, month0: number): number {
  return new Date(Date.UTC(year, month0 + 1, 0)).getUTCDate();
}

/** Days from `from` to `to` (negative when `to` is earlier). */
export function daysBetween(from: string, to: string): number {
  return Math.round((toUtcMs(to) - toUtcMs(from)) / DAY_MS);
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

/** The k-th charge date (k ≥ 0) of the schedule anchored at `anchor`. */
export function chargeDateAt(anchor: string, period: BillingPeriod, k: number): string {
  const step = monthStep(period);
  if (step === null) return addDaysTo(anchor, k * dayStep(period));
  return addMonthsClamped(anchor, k * step);
}

/** Largest k with chargeDateAt(k) ≤ `date`, or -1 when `date` < anchor. */
export function indexOnOrBefore(anchor: string, period: BillingPeriod, date: string): number {
  if (date.slice(0, 10) < anchor.slice(0, 10)) return -1;
  const step = monthStep(period);
  if (step === null) return Math.floor(daysBetween(anchor, date) / dayStep(period));
  const a = ymd(anchor);
  const t = ymd(date);
  let k = Math.floor(((t.y - a.y) * 12 + (t.m - a.m)) / step);
  while (k > 0 && chargeDateAt(anchor, period, k) > date.slice(0, 10)) k -= 1;
  return k;
}

/** The first charge date strictly after `date` (the anchor itself when `date` precedes it). */
export function nextChargeAfter(anchor: string, period: BillingPeriod, date: string): string {
  return chargeDateAt(anchor, period, indexOnOrBefore(anchor, period, date) + 1);
}

export function isOnSchedule(anchor: string, period: BillingPeriod, date: string): boolean {
  const k = indexOnOrBefore(anchor, period, date);
  return k >= 0 && chargeDateAt(anchor, period, k) === date.slice(0, 10);
}

export interface ResolvedSchedule {
  /** Anchor the schedule is computed from. */
  anchor: string;
  /** The next uncharged schedule date (may be earlier than the stored date for drifted rows). */
  pending: string;
  /** How `pending` was derived — for logs. */
  source: "start_date" | "overflow_drift" | "next_payment_date";
}

/**
 * Reconciles the stored `next_payment_date` with the anchor schedule.
 *
 * - On the start_date schedule → anchor = start_date (the normal case).
 * - Off by 1–3 days after a clamped month end for a 29th–31st anchor →
 *   the old `setUTCMonth` overflow drift (31 Jan → 3 Mar). The pending
 *   charge is the clamped date of the same period (28 Feb), anchor stays.
 * - Anything else → the app/user rescheduled without moving start_date;
 *   their date wins and becomes the anchor, so no charge is moved earlier
 *   (an earlier anchor date could re-charge a period that was paid).
 *   NOTE: such rows lose month-end clamping across February until their
 *   start_date is rebased — see the edge-stream report.
 */
export function resolveSchedule(
  startDate: string | null | undefined,
  nextPaymentDate: string,
  period: BillingPeriod,
): ResolvedSchedule {
  const next = nextPaymentDate.slice(0, 10);
  const start = startDate ? startDate.slice(0, 10) : null;
  if (!start || next < start) return { anchor: next, pending: next, source: "next_payment_date" };
  if (isOnSchedule(start, period, next)) return { anchor: start, pending: next, source: "start_date" };
  if (monthStep(period) !== null && ymd(start).d >= 29 && ymd(next).d <= 3) {
    const k = indexOnOrBefore(start, period, next);
    const clamped = chargeDateAt(start, period, k);
    const drift = daysBetween(clamped, next);
    if (k >= 1 && drift >= 1 && drift <= 3) {
      return { anchor: start, pending: clamped, source: "overflow_drift" };
    }
  }
  return { anchor: next, pending: next, source: "next_payment_date" };
}

export interface ScheduleCatchUp {
  anchor: string;
  source: ResolvedSchedule["source"];
  /** Charge dates ≤ today to charge now, oldest first. May include today. */
  due: string[];
  /** Charge dates too old to charge (beyond the catch-up window), rolled past. */
  skipped: string[];
  /** The first charge date strictly after today — the new `next_payment_date`. */
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
 */
export function planCatchUp(input: {
  startDate: string | null | undefined;
  nextPaymentDate: string;
  period: BillingPeriod;
  today: string;
  catchUpDays: number;
}): ScheduleCatchUp {
  const { period, today, catchUpDays } = input;
  const resolved = resolveSchedule(input.startDate, input.nextPaymentDate, period);
  const oldestChargeable = addDaysTo(today, -catchUpDays);
  const due: string[] = [];
  const skipped: string[] = [];
  let k = Math.max(0, indexOnOrBefore(resolved.anchor, period, resolved.pending));
  let cursor = chargeDateAt(resolved.anchor, period, k);
  // 1200 iterations ≈ 23 years of weekly charges — a guard against a
  // malformed date, not a business limit.
  for (let i = 0; i < 1200 && cursor <= today; i += 1) {
    (cursor >= oldestChargeable ? due : skipped).push(cursor);
    k += 1;
    cursor = chargeDateAt(resolved.anchor, period, k);
  }
  return {
    anchor: resolved.anchor,
    source: resolved.source,
    due,
    skipped,
    next: cursor,
    upcoming: due.includes(today) ? today : cursor,
  };
}
