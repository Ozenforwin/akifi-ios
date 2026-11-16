import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  addMonthsClamped,
  chargeDateAt,
  isOnSchedule,
  nearestChargeDate,
  nextChargeAfter,
  planCatchUp,
  previousChargeBefore,
  scheduleAnchor,
} from "./schedule.ts";

// ═══════════════════════════════════════════════════════════════════════
// Cross-platform test vectors — ported 1:1 from
// AkifiIOSTests/SubscriptionScheduleTests.swift (dates stream). The Swift
// engine and this file must produce exactly the same strings.
// ═══════════════════════════════════════════════════════════════════════

const range = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => from + i);
const sequence = (anchor: string, period: string, from: number, to: number) =>
  range(from, to).map((k) => chargeDateAt(anchor, period, k));
const next = (last: string, anchor: string, period: string) => nextChargeAfter(anchor, period, last);

// ── Sequences (anchor + k periods) ──

Deno.test("vector: monthly from 31 Jan clamps every month to its length", () => {
  assertEquals(sequence("2026-01-31", "monthly", 0, 12), [
    "2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31", "2026-06-30",
    "2026-07-31", "2026-08-31", "2026-09-30", "2026-10-31", "2026-11-30", "2026-12-31",
    "2027-01-31",
  ]);
});

Deno.test("vector: monthly from 31 Jan, leap-year February", () => {
  assertEquals(sequence("2024-01-31", "monthly", 0, 3), ["2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30"]);
});

Deno.test("vector: monthly from 30 and 29 Jan", () => {
  assertEquals(sequence("2026-01-30", "monthly", 0, 3), ["2026-01-30", "2026-02-28", "2026-03-30", "2026-04-30"]);
  assertEquals(sequence("2026-01-29", "monthly", 0, 2), ["2026-01-29", "2026-02-28", "2026-03-29"]);
});

Deno.test("vector: monthly, ordinary day", () => {
  assertEquals(sequence("2026-11-17", "monthly", 0, 2), ["2026-11-17", "2026-12-17", "2027-01-17"]);
});

Deno.test("vector: monthly, negative index walks back from the anchor", () => {
  assertEquals(sequence("2026-03-31", "monthly", -3, 0), ["2025-12-31", "2026-01-31", "2026-02-28", "2026-03-31"]);
});

Deno.test("vector: quarterly from 30 Nov", () => {
  assertEquals(sequence("2025-11-30", "quarterly", 0, 4), ["2025-11-30", "2026-02-28", "2026-05-30", "2026-08-30", "2026-11-30"]);
});

Deno.test("vector: quarterly from 31 Aug", () => {
  assertEquals(sequence("2025-08-31", "quarterly", 0, 4), ["2025-08-31", "2025-11-30", "2026-02-28", "2026-05-31", "2026-08-31"]);
});

Deno.test("vector: yearly from 29 Feb comes back in leap years", () => {
  assertEquals(sequence("2024-02-29", "yearly", 0, 4), ["2024-02-29", "2025-02-28", "2026-02-28", "2027-02-28", "2028-02-29"]);
});

Deno.test("vector: yearly century rule (2100 not leap, 2000 leap)", () => {
  assertEquals(sequence("2096-02-29", "yearly", 0, 1), ["2096-02-29", "2097-02-28"]);
  assertEquals(sequence("2096-02-29", "yearly", 4, 4), ["2100-02-28"]);
  assertEquals(sequence("1996-02-29", "yearly", 4, 4), ["2000-02-29"]);
});

Deno.test("vector: weekly crosses month and year", () => {
  assertEquals(sequence("2026-12-22", "weekly", 0, 3), ["2026-12-22", "2026-12-29", "2027-01-05", "2027-01-12"]);
});

Deno.test("vector: custom is thirty days", () => {
  assertEquals(sequence("2026-01-31", "custom", 0, 2), ["2026-01-31", "2026-03-02", "2026-04-01"]);
});

// ── next_payment_date ──

Deno.test("vector: next is strictly after the last charged date", () => {
  assertEquals(next("2026-01-31", "2026-01-31", "monthly"), "2026-02-28");
  assertEquals(next("2026-02-28", "2026-01-31", "monthly"), "2026-03-31");
  assertEquals(next("2026-03-30", "2026-01-31", "monthly"), "2026-03-31");
  assertEquals(next("2026-03-31", "2026-01-31", "monthly"), "2026-04-30");
});

Deno.test("vector: next before the anchor is the anchor", () => {
  assertEquals(next("2025-12-01", "2026-01-31", "monthly"), "2026-01-31");
  assertEquals(next("2026-01-30", "2026-01-31", "monthly"), "2026-01-31");
});

Deno.test("vector: next, other periods", () => {
  assertEquals(next("2026-02-28", "2025-11-30", "quarterly"), "2026-05-30");
  assertEquals(next("2027-02-28", "2024-02-29", "yearly"), "2028-02-29");
  assertEquals(next("2026-11-20", "2026-11-17", "weekly"), "2026-11-24");
  assertEquals(next("2026-11-24", "2026-11-17", "weekly"), "2026-12-01");
  assertEquals(next("2026-03-01", "2026-01-31", "custom"), "2026-03-02");
});

// The JS bug the contract replaces: setUTCMonth on 31 Jan gave 3 March.
Deno.test("vector: next never skips February", () => {
  assertEquals(next("2026-01-31", "2026-01-31", "monthly"), "2026-02-28");
});

// ── nearest / on-schedule / previous ──

Deno.test("vector: nearestChargeDate", () => {
  assertEquals(nearestChargeDate("2026-01-31", "monthly", "2026-03-03"), "2026-02-28");
  assertEquals(nearestChargeDate("2026-01-31", "monthly", "2026-03-16"), "2026-03-31");
  assertEquals(nearestChargeDate("2026-01-31", "monthly", "2025-12-29"), "2025-12-31");
  assertEquals(nearestChargeDate("2026-11-17", "weekly", "2026-11-19"), "2026-11-17");
});

Deno.test("vector: isOnSchedule", () => {
  assertEquals(isOnSchedule("2026-01-31", "monthly", "2026-02-28"), true);
  assertEquals(isOnSchedule("2026-01-31", "monthly", "2025-11-30"), true);
  assertEquals(isOnSchedule("2026-01-31", "monthly", "2026-03-28"), false);
});

Deno.test("vector: previousChargeDate", () => {
  assertEquals(previousChargeBefore("2026-01-31", "monthly", "2026-03-31"), "2026-02-28");
  assertEquals(previousChargeBefore("2026-01-31", "monthly", "2026-03-15"), "2026-02-28");
  assertEquals(previousChargeBefore("2026-11-17", "weekly", "2026-11-24"), "2026-11-17");
});

// ── Stored subscriptions ──

Deno.test("vector: anchor is start_date when next lies on its schedule (or is missing)", () => {
  assertEquals(scheduleAnchor("2026-01-31", "2026-04-30", "monthly"), "2026-01-31");
  assertEquals(scheduleAnchor("2026-01-31", null, "monthly"), "2026-01-31");
});

// Prod has rows whose start_date is "added on the 1st" while billing
// happens on the 21st; their schedule follows next_payment_date.
Deno.test("vector: legacy off-schedule start_date falls back to next_payment_date", () => {
  assertEquals(scheduleAnchor("2026-01-01", "2026-01-21", "monthly"), "2026-01-21");
});

// ═══════════════════════════════════════════════════════════════════════
// Server-side catch-up planning (check-subscriptions)
// ═══════════════════════════════════════════════════════════════════════

const plan = (startDate: string | null, nextPaymentDate: string, period: string, today: string, catchUpDays = 45) =>
  planCatchUp({ startDate, nextPaymentDate, period, today, catchUpDays });

Deno.test("addMonthsClamped crosses years both ways", () => {
  assertEquals(addMonthsClamped("2026-11-30", 3), "2027-02-28");
  assertEquals(addMonthsClamped("2026-03-31", -1), "2026-02-28");
});

Deno.test("unknown period behaves as monthly", () => {
  assertEquals(chargeDateAt("2026-01-31", "biweekly", 1), "2026-02-28");
});

Deno.test("future date: nothing due, next unchanged", () => {
  const p = plan("2026-08-18", "2026-09-18", "monthly", "2026-09-15");
  assertEquals([p.due, p.skipped, p.next, p.upcoming], [[], [], "2026-09-18", "2026-09-18"]);
});

Deno.test("due today: charged today, next one period later, reminder refers to today (D9)", () => {
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
  assertEquals([feb.source, feb.due, feb.next], ["start_date", ["2026-02-28"], "2026-03-31"]);
  const mar = plan("2026-01-31", feb.next, "monthly", "2026-03-31");
  assertEquals([mar.due, mar.next], [["2026-03-31"], "2026-04-30"]);
});

// Real prod shape: start 2026-03-24 ("added on"), billing on the 17th.
// Anchoring on start_date would charge 24 Oct again — a duplicate.
Deno.test("legacy row follows next_payment_date and keeps its billing day", () => {
  const p = plan("2026-03-24", "2026-11-17", "monthly", "2026-11-17");
  assertEquals([p.source, p.anchor, p.due, p.next], ["next_payment_date", "2026-11-17", ["2026-11-17"], "2026-12-17"]);
});

Deno.test("next is never earlier than the stored next_payment_date", () => {
  for (const [start, stored, period, today] of [
    ["2026-01-31", "2026-04-30", "monthly", "2026-04-01"],
    ["2026-03-24", "2026-11-17", "monthly", "2026-11-01"],
    ["2026-01-01", "2026-01-21", "weekly", "2026-01-10"],
  ]) {
    const p = plan(start, stored, period, today);
    assertEquals(p.next >= stored, true, `${start} ${stored} → ${p.next}`);
    assertEquals(p.due, []);
  }
});

Deno.test("quarterly and yearly catch-up use the anchor", () => {
  assertEquals(plan("2026-03-01", "2026-06-01", "quarterly", "2026-09-15").next, "2026-12-01");
  const y = plan("2024-02-29", "2026-02-28", "yearly", "2026-02-28");
  assertEquals([y.due, y.next], [["2026-02-28"], "2027-02-28"]);
  // ...and the leap-year 29th comes back.
  assertEquals(plan("2024-02-29", "2027-02-28", "yearly", "2027-02-28").next, "2028-02-29");
});
