import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseRequest, rateFromUpstream } from "./logic.ts";

const today = "2026-11-27";

Deno.test("valid request is normalised", () => {
  assertEquals(parseRequest({ from: "usd", to: " rub ", date: "2026-10-01" }, today), {
    from: "USD", to: "RUB", date: "2026-10-01",
  });
});

Deno.test("rejects bad codes, dates and the future", () => {
  for (const b of [
    { from: "US", to: "RUB", date: "2026-10-01" },
    { from: "USD", to: "RUBX", date: "2026-10-01" },
    { from: "USD", to: "RUB", date: "2026-13-01" },
    { from: "USD", to: "RUB", date: "2026-02-30" },
    { from: "USD", to: "RUB", date: "01.10.2026" },
    { from: "USD", to: "RUB", date: "1990-01-01" },
    { from: "USD", to: "RUB", date: "2026-11-29" },
    null,
  ]) {
    assertEquals(typeof parseRequest(b, today), "string", JSON.stringify(b));
  }
});

Deno.test("a local 'tomorrow' (UTC+ zones) is accepted", () => {
  assertEquals(typeof parseRequest({ from: "USD", to: "RUB", date: "2026-11-28" }, today), "object");
});

Deno.test("upstream parsing", () => {
  assertEquals(rateFromUpstream({ success: true, rates: { RUB: 92.5 } }, "RUB"), 92.5);
  assertEquals(rateFromUpstream({ success: false, rates: { RUB: 92.5 } }, "RUB"), null);
  assertEquals(rateFromUpstream({ success: true, rates: {} }, "RUB"), null);
  assertEquals(rateFromUpstream({ success: true, rates: { RUB: 0 } }, "RUB"), null);
  assertEquals(rateFromUpstream("nope", "RUB"), null);
});
