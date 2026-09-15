import { parseDateOnly, toDateOnly } from "./utils.ts";

export type BillingPeriod = "weekly" | "monthly" | "quarterly" | "yearly" | string;

const DAY_MS = 24 * 60 * 60 * 1000;

/** One billing period after `date`, UTC-safe. Unknown periods count as monthly. */
export function addPeriod(date: Date, period: BillingPeriod): Date {
  const copy = new Date(date.getTime());
  if (period === "weekly") {
    copy.setUTCDate(copy.getUTCDate() + 7);
    return copy;
  }
  if (period === "quarterly") {
    copy.setUTCMonth(copy.getUTCMonth() + 3);
    return copy;
  }
  if (period === "yearly") {
    copy.setUTCFullYear(copy.getUTCFullYear() + 1);
    return copy;
  }
  copy.setUTCMonth(copy.getUTCMonth() + 1);
  return copy;
}

export interface ScheduleCatchUp {
  /** Period dates ≤ today that must be charged, oldest first. May include today. */
  due: string[];
  /** Period dates that were too old to charge and are skipped (rolled past). */
  skipped: string[];
  /** The first period date strictly after today — the new `next_payment_date`. */
  next: string;
}

/**
 * Splits an overdue (or due-today) schedule into what to charge and what
 * to skip.
 *
 * The daily cron is not guaranteed to run: on 2026-09-01 a redeploy left
 * the function behind gateway JWT verification and it silently did nothing
 * for two weeks; on 2026-09-10/11 the database itself was down. The old
 * logic charged only when `next_payment_date === today` and otherwise
 * rolled the date forward — so every missed run was a missed charge,
 * forever, with no trace. Now every period date the cron slept through is
 * charged on its own date, idempotently (charge_events dedupe per date).
 *
 * `catchUpDays` bounds the recovery window: a row that has been overdue
 * for longer than that is stale data (a subscription nobody maintains),
 * not an outage, and is rolled forward exactly as before.
 *
 * All dates are `yyyy-MM-dd` strings; `today` too.
 */
export function planCatchUp(
  nextPaymentDate: string,
  period: BillingPeriod,
  today: string,
  catchUpDays: number,
): ScheduleCatchUp {
  const todayDate = parseDateOnly(today);
  const oldestChargeable = new Date(todayDate.getTime() - catchUpDays * DAY_MS);
  const due: string[] = [];
  const skipped: string[] = [];
  let cursor = parseDateOnly(nextPaymentDate);
  // 1200 iterations covers 23 years of weekly periods — a guard against a
  // malformed date, not a business limit.
  for (let i = 0; i < 1200 && cursor <= todayDate; i += 1) {
    (cursor >= oldestChargeable ? due : skipped).push(toDateOnly(cursor));
    cursor = addPeriod(cursor, period);
  }
  return { due, skipped, next: toDateOnly(cursor) };
}
