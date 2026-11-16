import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildDigest, type DigestTx } from "./digest.ts";

// RUB pivot: 80 ₽ per $.
const rates = { RUB: 1, USD: 0.0125 };
const plain = (s: string) => s.replace(/[  ]/g, " ");

const tx = (over: Partial<DigestTx>): DigestTx => ({
  id: crypto.randomUUID(),
  user_id: "u",
  type: "expense",
  amount: null,
  amount_native: 0,
  category_id: "c1",
  date: "2026-11-10T12:00:00+00:00",
  account: { currency: "RUB" },
  ...over,
});

// M4: $50 + 5 000 ₽ printed as «5 050 ₽».
Deno.test("digest converts every amount into the display currency before summing", () => {
  const digest = plain(buildDigest([
    tx({ amount_native: 50, account: { currency: "usd" } }),
    tx({ amount_native: 5000 }),
  ], new Map(), "ru", "RUB", rates)!);
  assertEquals(digest.includes("Расходы: -9 000 ₽"), true, digest);
  assertEquals(digest.includes("5 050"), false, digest);
});

Deno.test("digest in a USD display currency shows dollars", () => {
  const digest = plain(buildDigest([
    tx({ amount_native: 8000 }),
    tx({ type: "income", amount_native: 100, account: { currency: "USD" } }),
  ], new Map(), "en", "USD", rates)!);
  assertEquals(digest.includes("Expense: -$100.00"), true, digest);
  assertEquals(digest.includes("Income: +$100.00"), true, digest);
  assertEquals(digest.includes("₽"), false, digest);
});

Deno.test("digest daily average is over exactly 7 days", () => {
  const digest = plain(buildDigest([tx({ amount_native: 7000 })], new Map(), "ru", "RUB", rates)!);
  assertEquals(digest.includes("Среднедневной расход: 1 000 ₽/день"), true, digest);
});

Deno.test("digest skips (and reports) amounts without an exchange rate instead of adding them 1:1", () => {
  const digest = plain(buildDigest([
    tx({ amount_native: 1000 }),
    tx({ amount_native: 1_000_000, account: { currency: "XYZ" } }),
  ], new Map(), "ru", "RUB", rates)!);
  assertEquals(digest.includes("Расходы: -1 000 ₽"), true, digest);
  assertEquals(digest.includes("Не учтено операций без курса валюты: 1"), true, digest);
});

Deno.test("digest escapes category names for HTML", () => {
  const digest = buildDigest(
    [tx({ amount_native: 100 })],
    new Map([["c1", { id: "c1", name: "Кафе <3", icon: "☕" }]]),
    "ru",
    "RUB",
    rates,
  )!;
  assertEquals(digest.includes("Кафе &lt;3"), true, digest);
});

Deno.test("no transactions, no digest", () => {
  assertEquals(buildDigest([], new Map(), "ru", "RUB", rates), null);
});
