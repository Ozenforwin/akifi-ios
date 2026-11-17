import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { createRequestContext, requestContext, requestToday, runWithRequestContext } from "./request-context.ts";
import { formatMoney, getWindow } from "./utils.ts";
import { parseIntentAndPeriod } from "./intent-parser.ts";
import { localDate } from "../_shared/timezone.ts";

const plain = (s: string) => s.replace(/[  ]/g, " ");
const tick = () => new Promise((r) => setTimeout(r, 5));

// M9: formatMoney was hard-wired to RUB.
Deno.test("formatMoney uses the request's display currency", async () => {
  const usd = { ...createRequestContext(), displayCurrency: "USD", lang: "en" };
  const got = await runWithRequestContext(usd, async () => {
    await tick();
    return formatMoney(1234.5);
  });
  assertEquals(got, "$1,234.50");
});

Deno.test("concurrent requests do not see each other's context", async () => {
  const a = runWithRequestContext({ ...createRequestContext(), displayCurrency: "USD", lang: "en" }, async () => {
    await tick();
    return formatMoney(10);
  });
  const b = runWithRequestContext({ ...createRequestContext(), displayCurrency: "RUB", lang: "ru" }, async () => {
    await tick();
    return formatMoney(10);
  });
  assertEquals(await a, "$10.00");
  assertEquals(plain(await b), "10 ₽");
});

Deno.test("context filled after start is visible to later awaits (index.ts pattern)", async () => {
  const today = await runWithRequestContext(createRequestContext(), async () => {
    const ctx = requestContext();
    await tick();
    ctx.today = "2026-12-01";
    await tick();
    return requestToday();
  });
  assertEquals(today, "2026-12-01");
});

// D6: 06:00 on 1 Dec in UTC+7 is 30 Nov 23:00 UTC.
Deno.test("«this month» / «today» / «вчера» follow the user's local day", async () => {
  const now = new Date("2026-11-30T23:00:00Z");
  const today = localDate(now, "Asia/Bangkok");
  assertEquals(today, "2026-12-01");
  assertEquals(getWindow("month", today), { start: "2026-12-01", end: "2026-12-01" });
  assertEquals(getWindow("today", today), { start: "2026-12-01", end: "2026-12-01" });
  // 1 Dec 2026 is a Tuesday → the week starts Monday 30 Nov.
  assertEquals(getWindow("week", today), { start: "2026-11-30", end: "2026-12-01" });
  const parsed = await runWithRequestContext({ ...createRequestContext(), today }, async () => {
    await tick();
    return parseIntentAndPeriod("сколько я потратил вчера");
  });
  assertEquals(parsed.explicitDate, "2026-11-30");
});
