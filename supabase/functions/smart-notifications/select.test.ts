import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { selectCandidates } from "./select.ts";

const c = (type: string, key: string) => ({ type, key });

Deno.test("already-sent alerts no longer block new ones (prod 2026-11-17..27)", () => {
  // Two budgets alerted on 11-17 come first in get_budget_metrics order;
  // «Питание» and «Досуг» crossed later and must still go out.
  const candidates = [
    c("budget_warning", "budget_warning:sport:2026-11-02:100"),
    c("budget_warning", "budget_warning:bike:2026-11-04:80"),
    c("budget_warning", "budget_warning:food:2026-11-02:100"),
    c("budget_warning", "budget_warning:leisure:2026-11-02:100"),
  ];
  const sent = new Set(["budget_warning:sport:2026-11-02:100", "budget_warning:bike:2026-11-04:80"]);
  assertEquals(selectCandidates(candidates, sent, 2).map((x) => x.key), [
    "budget_warning:food:2026-11-02:100",
    "budget_warning:leisure:2026-11-02:100",
  ]);
});

Deno.test("a large expense is not starved by stale budget alerts", () => {
  const candidates = [
    c("budget_warning", "b1"),
    c("budget_warning", "b2"),
    c("large_expense", "le:tx1"),
  ];
  assertEquals(selectCandidates(candidates, new Set(["b1", "b2"]), 2).map((x) => x.key), ["le:tx1"]);
});

Deno.test("priority order, stable within a type", () => {
  const candidates = [
    c("savings_milestone", "s1"),
    c("large_expense", "le1"),
    c("budget_warning", "b1"),
    c("budget_warning", "b2"),
  ];
  assertEquals(selectCandidates(candidates, new Set(), 3).map((x) => x.key), ["b1", "b2", "le1"]);
});

Deno.test("cap honours what is left of the daily limit", () => {
  const candidates = [c("budget_warning", "b1"), c("budget_warning", "b2")];
  assertEquals(selectCandidates(candidates, new Set(), 1).length, 1);
  assertEquals(selectCandidates(candidates, new Set(), 0).length, 0);
  assertEquals(selectCandidates(candidates, new Set(), -3).length, 0);
  assertEquals(selectCandidates(candidates, new Set(), Number.NaN).length, 0);
});

Deno.test("duplicate keys in one batch go out once", () => {
  const candidates = [c("budget_warning", "b1"), c("budget_warning", "b1"), c("weekly_pace", "p1")];
  assertEquals(selectCandidates(candidates, new Set(), 5).map((x) => x.key), ["b1", "p1"]);
});
