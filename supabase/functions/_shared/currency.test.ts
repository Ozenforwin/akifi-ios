import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { convertCurrency } from "../_shared/currency.ts";

// Rates are units per 1 RUB, as normalized in `fetchRates` (2026-09-01).
const rates = { RUB: 1, USD: 0.011573, EUR: 0.009971, THB: 0.383795, VND: 301.02 };

const near = (got: number, want: number, tolerance = 0.01) =>
  assertEquals(
    Math.abs(got - want) <= Math.max(1, Math.abs(want) * tolerance),
    true,
    `got ${got}, expected ~${want}`,
  );

// The production incident: a $10/mo subscription on a USD account was
// converted to roubles (864) and written as if it were dollars, which the
// app then rendered as 22 475 255 ₫.
Deno.test("same currency is never converted", () => {
  assertEquals(convertCurrency(10, "USD", "USD", rates), 10);
  assertEquals(convertCurrency(1295, "USD", "USD", rates), 1295);
});

Deno.test("USD subscription charged onto a VND account", () => {
  near(convertCurrency(10, "USD", "VND", rates), 260_100);
});

Deno.test("USD subscription charged onto a THB account", () => {
  near(convertCurrency(1295, "USD", "THB", rates), 42_945);
});

Deno.test("USD subscription charged onto a RUB account", () => {
  near(convertCurrency(10, "USD", "RUB", rates), 864);
});

// EUR used to be dropped by the rate whitelist, so a €10 subscription hit
// the 1:1 fallback and was charged as 10 ₽.
Deno.test("EUR subscription is converted, not passed through", () => {
  const converted = convertCurrency(10, "EUR", "RUB", rates);
  assertEquals(converted > 900, true, `€10 should be ~1000 ₽, got ${converted}`);
});

Deno.test("unknown currency falls back to 1:1 instead of NaN", () => {
  assertEquals(convertCurrency(10, "XYZ", "RUB", rates), 10);
  assertEquals(convertCurrency(10, "USD", "XYZ", rates), 10);
});

Deno.test("missing currency is treated as base RUB", () => {
  assertEquals(convertCurrency(500, null, "RUB", rates), 500);
});

Deno.test("lowercase codes resolve like uppercase", () => {
  assertEquals(
    convertCurrency(10, "usd", "rub", rates),
    convertCurrency(10, "USD", "RUB", rates),
  );
});
