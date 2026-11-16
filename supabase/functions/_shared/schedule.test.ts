import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  addMonthsClamped,
  chargeDateAt,
  indexOnOrBefore,
  isOnSchedule,
  nextChargeAfter,
  planCatchUp,
  resolveSchedule,
} from "./schedule.ts";

const plan = (startDate: string | null, nextPaymentDate: string, period: string, today: string, catchUpDays = 45) =>
  planCatchUp({ startDate, nextPaymentDate, period, today, catchUpDays });

// ── Contract: anchor + k periods with month-end clamping (D2) ──

Deno.test("monthly from 31 Jan clamps every month and never drifts", () => {
  const dates = [0, 1, 2, 3, 4, 5].map((k) => chargeDateAt("2026-01-31", "monthly", k));
  assertEquals(dates, ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31", "2026-06-30"]);
});

Deno.test("monthly from 31 Jan in a leap year hits 29 Feb", () => {
  assertEquals(chargeDateAt("2028-01-31", "monthly", 1), "2028-02-29");
  assertEquals(chargeDateAt("2028-01-31", "monthly", 2), "2028-03-31");
});

Deno.test("monthly from the 30th and 29th", () => {
  assertEquals([0, 1, 2].map((k) => chargeDateAt("2026-01-30", "monthly", k)), ["2026-01-30", "2026-02-28", "2026-03-30"]);
  assertEquals([0, 1, 2].map((k) => chargeDateAt("2026-01-29", "monthly", k)), ["2026-01-29", "2026-02-28", "2026-03-29"]);
});

Deno.test("quarterly from 31 Jan → 30 Apr → 31 Jul → 31 Oct", () => {
  assertEquals([0, 1, 2, 3].map((k) => chargeDateAt("2026-01-31", "quarterly", k)), [
    "2026-01-31", "2026-04-30", "2026-07-31", "2026-10-31",
  ]);
  // The old overflow bug turned this into 1 May.
  assertEquals(chargeDateAt("2026-01-31", "quarterly", 1), "2026-04-30");
});

Deno.test("yearly from 29 Feb → 28 Feb in non-leap years, 29 Feb in leap years", () => {
  assertEquals([0, 1, 2, 3, 4].map((k) => chargeDateAt("2024-02-29", "yearly", k)), [
    "2024-02-29", "2025-02-28", "2026-02-28", "2027-02-28", "2028-02-29",
  ]);
});

Deno.test("weekly = +7k days, custom = +30k days", () => {
  assertEquals(chargeDateAt("2026-12-28", "weekly", 1), "2027-01-04");
  assertEquals(chargeDateAt("2026-01-31", "custom", 1), "2026-03-02");
  assertEquals(chargeDateAt("2026-01-31", "custom", 2), "2026-04-01");
});

Deno.test("unknown period behaves as monthly", () => {
  assertEquals(chargeDateAt("2026-01-31", "biweekly", 1), "2026-02-28");
});

Deno.test("addMonthsClamped crosses years both ways", () => {
  assertEquals(addMonthsClamped("2026-11-30", 3), "2027-02-28");
  assertEquals(addMonthsClamped("2026-03-31", -1), "2026-02-28");
});

Deno.test("indexOnOrBefore / nextChargeAfter / isOnSchedule", () => {
  assertEquals(indexOnOrBefore("2026-01-31", "monthly", "2026-01-30"), -1);
  assertEquals(indexOnOrBefore("2026-01-31", "monthly", "2026-02-27"), 0);
  assertEquals(indexOnOrBefore("2026-01-31", "monthly", "2026-02-28"), 1);
  assertEquals(indexOnOrBefore("2026-01-31", "monthly", "2026-03-30"), 1);
  // "next = first anchor + k·period strictly after the last charged date"
  assertEquals(nextChargeAfter("2026-01-31", "monthly", "2026-02-28"), "2026-03-31");
  assertEquals(nextChargeAfter("2026-01-31", "monthly", "2026-01-31"), "2026-02-28");
  assertEquals(nextChargeAfter("2026-01-31", "monthly", "2025-12-01"), "2026-01-31");
  assertEquals(isOnSchedule("2026-01-31", "monthly", "2026-04-30"), true);
  assertEquals(isOnSchedule("2026-01-31", "monthly", "2026-05-01"), false);
});

// ── Reconciling stored next_payment_date with the anchor ──

Deno.test("resolveSchedule: on-schedule row keeps start_date as anchor", () => {
  assertEquals(resolveSchedule("2026-01-31", "2026-04-30", "monthly"), {
    anchor: "2026-01-31", pending: "2026-04-30", source: "start_date",
  });
});

Deno.test("resolveSchedule: old overflow drift (31 Jan → 3 Mar) snaps back to 28 Feb", () => {
  assertEquals(resolveSchedule("2026-01-31", "2026-03-03", "monthly"), {
    anchor: "2026-01-31", pending: "2026-02-28", source: "overflow_drift",
  });
  // After further drifted months the date stays on the 3rd.
  assertEquals(resolveSchedule("2026-01-31", "2026-06-03", "monthly").pending, "2026-05-31");
});

Deno.test("resolveSchedule: rescheduled row (day differs from start_date) keeps its own date", () => {
  // Real prod shape: start 2026-03-24, next 2026-11-17, last paid 2026-10-17.
  // Using start_date here would re-charge 24 Oct — a duplicate.
  assertEquals(resolveSchedule("2026-03-24", "2026-11-17", "monthly"), {
    anchor: "2026-11-17", pending: "2026-11-17", source: "next_payment_date",
  });
  assertEquals(resolveSchedule(null, "2026-11-17", "monthly").anchor, "2026-11-17");
});

// ── planCatchUp ──

Deno.test("future date: nothing due, next unchanged", () => {
  const p = plan("2026-08-18", "2026-09-18", "monthly", "2026-09-15");
  assertEquals([p.due, p.skipped, p.next, p.upcoming], [[], [], "2026-09-18", "2026-09-18"]);
});

Deno.test("due today: charged today, next is one period later, reminder refers to today", () => {
  const p = plan("2026-08-15", "2026-09-15", "monthly", "2026-09-15");
  assertEquals([p.due, p.next, p.upcoming], [["2026-09-15"], "2026-10-15", "2026-09-15"]);
});

// The Claude Code row on 2026-09-15: cron dead since 09-02.
Deno.test("one missed monthly charge is recovered on its own date", () => {
  const p = plan("2026-08-06", "2026-09-06", "monthly", "2026-09-15");
  assertEquals([p.due, p.skipped, p.next], [["2026-09-06"], [], "2026-10-06"]);
});

Deno.test("several missed weekly charges are all recovered, oldest first", () => {
  const p = plan("2026-08-25", "2026-08-25", "weekly", "2026-09-15");
  assertEquals(p.due, ["2026-08-25", "2026-09-01", "2026-09-08", "2026-09-15"]);
  assertEquals(p.skipped, []);
  assertEquals(p.next, "2026-09-22");
});

Deno.test("beyond the catch-up window: skipped (rolled), recent ones still charged", () => {
  // Overdue since March; window 45 days back from 09-15 = 08-01.
  const p = plan("2026-01-06", "2026-03-06", "monthly", "2026-09-15");
  assertEquals(p.skipped, ["2026-03-06", "2026-04-06", "2026-05-06", "2026-06-06", "2026-07-06"]);
  assertEquals(p.due, ["2026-08-06", "2026-09-06"]);
  assertEquals(p.next, "2026-10-06");
});

Deno.test("window boundary is inclusive", () => {
  const p = plan("2026-08-01", "2026-08-01", "monthly", "2026-09-15");
  assertEquals(p.due, ["2026-08-01", "2026-09-01"]);
  assertEquals(p.skipped, []);
});

// D2 itself: the server used to skip February for a 31st subscription.
Deno.test("31 Jan subscription is charged on 28 Feb, then 31 Mar", () => {
  const feb = plan("2026-01-31", "2026-02-28", "monthly", "2026-02-28");
  assertEquals([feb.due, feb.next], [["2026-02-28"], "2026-03-31"]);
  const mar = plan("2026-01-31", feb.next, "monthly", "2026-03-31");
  assertEquals([mar.due, mar.next], [["2026-03-31"], "2026-04-30"]);
});

Deno.test("a drifted row is charged for the clamped date and returns to the anchor", () => {
  // Stored 2026-03-03 by the old overflow; today 1 March.
  const p = plan("2026-01-31", "2026-03-03", "monthly", "2026-03-01");
  assertEquals(p.source, "overflow_drift");
  assertEquals([p.due, p.next], [["2026-02-28"], "2026-03-31"]);
});

Deno.test("quarterly and yearly catch-up use the anchor", () => {
  assertEquals(plan("2026-03-01", "2026-06-01", "quarterly", "2026-09-15").next, "2026-12-01");
  const y = plan("2024-02-29", "2026-02-28", "yearly", "2026-02-28");
  assertEquals([y.due, y.next], [["2026-02-28"], "2027-02-28"]);
});
