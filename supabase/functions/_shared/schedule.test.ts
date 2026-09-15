import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { addPeriod, planCatchUp } from "./schedule.ts";
import { parseDateOnly, toDateOnly } from "./utils.ts";

Deno.test("future date: nothing due, next unchanged", () => {
  const plan = planCatchUp("2026-09-18", "monthly", "2026-09-15", 45);
  assertEquals(plan, { due: [], skipped: [], next: "2026-09-18" });
});

Deno.test("due today: charged today, next is one period later", () => {
  const plan = planCatchUp("2026-09-15", "monthly", "2026-09-15", 45);
  assertEquals(plan, { due: ["2026-09-15"], skipped: [], next: "2026-10-15" });
});

// The Claude Code row on 2026-09-15: next_payment_date 2026-09-06, cron
// dead since 09-02. Old code: roll to 10-06, charge nothing. New code:
// charge 09-06, next 10-06.
Deno.test("one missed monthly charge is recovered on its own date", () => {
  const plan = planCatchUp("2026-09-06", "monthly", "2026-09-15", 45);
  assertEquals(plan, { due: ["2026-09-06"], skipped: [], next: "2026-10-06" });
});

Deno.test("several missed weekly charges are all recovered, oldest first", () => {
  const plan = planCatchUp("2026-08-25", "weekly", "2026-09-15", 45);
  assertEquals(plan.due, ["2026-08-25", "2026-09-01", "2026-09-08", "2026-09-15"]);
  assertEquals(plan.skipped, []);
  assertEquals(plan.next, "2026-09-22");
});

Deno.test("beyond the catch-up window: skipped (rolled), recent ones still charged", () => {
  // Overdue since March; window 45 days back from 09-15 = 08-01.
  const plan = planCatchUp("2026-03-06", "monthly", "2026-09-15", 45);
  assertEquals(plan.skipped, ["2026-03-06", "2026-04-06", "2026-05-06", "2026-06-06", "2026-07-06"]);
  assertEquals(plan.due, ["2026-08-06", "2026-09-06"]);
  assertEquals(plan.next, "2026-10-06");
});

Deno.test("window boundary is inclusive", () => {
  const plan = planCatchUp("2026-08-01", "monthly", "2026-09-15", 45);
  assertEquals(plan.due, ["2026-08-01", "2026-09-01"]);
  assertEquals(plan.skipped, []);
});

Deno.test("quarterly and yearly periods advance correctly", () => {
  assertEquals(toDateOnly(addPeriod(parseDateOnly("2026-01-31"), "quarterly")), "2026-05-01");
  assertEquals(toDateOnly(addPeriod(parseDateOnly("2024-02-29"), "yearly")), "2025-03-01");
  assertEquals(planCatchUp("2026-06-01", "quarterly", "2026-09-15", 45).next, "2026-12-01");
});

Deno.test("unknown period behaves as monthly", () => {
  assertEquals(planCatchUp("2026-09-01", "biweekly", "2026-09-15", 45).next, "2026-10-01");
});
