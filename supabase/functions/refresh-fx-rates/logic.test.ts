import { assert, assertEquals, assertFalse, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildRows, isCronAuthorized, MIN_CODES, timingSafeEqualStr } from "./logic.ts";

function payload(extra: Record<string, unknown> = {}, rates: Record<string, unknown> = {}) {
  const base: Record<string, unknown> = { USD: 1, RUB: 82.5, VND: 25715.7, EUR: 0.9 };
  // pad to MIN_CODES with plausible codes
  for (let i = 0; base && Object.keys(base).length < MIN_CODES + 2; i++) {
    base[`Q${String.fromCharCode(65 + (i % 26))}${String.fromCharCode(65 + Math.floor(i / 26))}`] = 1 + i;
  }
  return { result: "success", base_code: "USD", time_last_update_unix: 1_794_700_000, rates: { ...base, ...rates }, ...extra };
}

Deno.test("timingSafeEqualStr: equal, unequal, empty secret", async () => {
  assert(await timingSafeEqualStr("s3cret", "s3cret"));
  assertFalse(await timingSafeEqualStr("s3cret", "s3creT"));
  assertFalse(await timingSafeEqualStr("short", "a-much-longer-secret"));
  assertFalse(await timingSafeEqualStr("", ""), "an empty secret must never authorize");
});

Deno.test("isCronAuthorized: header or bearer, nothing else", async () => {
  const secret = "cron-xyz";
  const mk = (h: Record<string, string>) => new Request("https://x/functions/v1/refresh-fx-rates", { method: "POST", headers: h });
  assert(await isCronAuthorized(mk({ "x-cron-secret": secret }), secret));
  assert(await isCronAuthorized(mk({ authorization: `Bearer ${secret}` }), secret));
  assertFalse(await isCronAuthorized(mk({ authorization: "Bearer some-anon-jwt" }), secret), "any bearer is not enough");
  assertFalse(await isCronAuthorized(mk({}), secret));
  assertFalse(await isCronAuthorized(mk({ "x-cron-secret": "" }), ""), "unset CRON_SECRET locks the function");
});

Deno.test("buildRows: happy path keeps USD pivot and stamps upstream time", () => {
  const now = new Date("2026-11-17T12:00:00Z");
  const { rows, skipped } = buildRows(payload(), { RUB: 80 }, now);
  assertEquals(skipped, []);
  const rub = rows.find((r) => r.code === "RUB");
  assertEquals(rub?.per_usd, 82.5);
  assertEquals(rows.find((r) => r.code === "USD")?.per_usd, 1);
  assertEquals(rub?.updated_at, new Date(1_794_700_000 * 1000).toISOString());
});

Deno.test("buildRows: future upstream stamp is clamped to now", () => {
  const now = new Date("2026-01-01T00:00:00Z");
  const { rows } = buildRows(payload({ time_last_update_unix: 4_000_000_000 }), {}, now);
  assertEquals(rows[0].updated_at, now.toISOString());
});

Deno.test("buildRows: drops bad values and implausible jumps, keeps the rest", () => {
  const { rows, skipped } = buildRows(
    payload({}, { RUB: 8256.88, XXX: -1, YYY: "12", zz: 3 }),
    { RUB: 82.5 },
    new Date(),
  );
  assertFalse(rows.some((r) => r.code === "RUB"), "100x jump must not reach the table");
  assertEquals(skipped.find((s) => s.code === "RUB")?.reason, "jump");
  assertEquals(skipped.find((s) => s.code === "XXX")?.reason, "bad_value");
  assertEquals(skipped.find((s) => s.code === "YYY")?.reason, "bad_value");
  assertEquals(skipped.find((s) => s.code === "zz")?.reason, "bad_code");
});

Deno.test("buildRows: refuses unusable payloads as a whole", () => {
  assertThrows(() => buildRows(null, {}, new Date()));
  assertThrows(() => buildRows({ result: "error" }, {}, new Date()));
  assertThrows(() => buildRows(payload({ base_code: "EUR" }), {}, new Date()));
  assertThrows(() => buildRows(payload({}, { USD: 0.9 }), {}, new Date()), Error, "USD");
  assertThrows(() => buildRows({ result: "success", rates: { USD: 1, RUB: 82 } }, {}, new Date()), Error, "usable");
});
