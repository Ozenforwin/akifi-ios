import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { formatMoney } from "./utils.ts";
import { accountsMap, computeAmountInBase, fxRatesMap } from "./transaction-math.ts";

const NBSP = /[  ]/g;
const plain = (s: string) => s.replace(NBSP, " ");

Deno.test("formatMoney: roubles without kopecks (historical format)", () => {
  assertEquals(plain(formatMoney(5000)), "5 000 ₽");
  assertEquals(plain(formatMoney(848.54, "rub")), "849 ₽");
});

// M4: the currency comes from the amount, the language only from the user.
Deno.test("formatMoney: dollars stay dollars for a Russian-speaking user", () => {
  const s = plain(formatMoney(50, "USD", "ru"));
  assertEquals(s.includes("$"), true, s);
  assertEquals(s.includes("₽"), false, s);
  assertEquals(s.includes("50,00"), true, s);
});

Deno.test("formatMoney: English locale formatting", () => {
  assertEquals(formatMoney(1234.5, "USD", "en"), "$1,234.50");
});

Deno.test("formatMoney: unknown code does not throw", () => {
  assertEquals(formatMoney(10, "NOT_A_CODE"), "10 NOT_A_CODE");
});

// M9: transaction-math.ts used to Math.round main units.
Deno.test("computeAmountInBase keeps cents", () => {
  const accounts = accountsMap([{ id: "a", currency: "usd" }, { id: "b", currency: "USD" }]);
  const rates = fxRatesMap({ USD: 1, RUB: 92.5 });
  // Same currency: untouched.
  assertEquals(computeAmountInBase({ id: "t1", account_id: "b", amount_native: 15.86 }, accounts, rates, "USD"), 15.86);
  // RUB → USD: 92.5 ₽ = $1.00, 46.25 ₽ = $0.50 (was rounded to 1 / 0).
  assertEquals(
    computeAmountInBase({ id: "t2", account_id: "x", amount_native: 46.25 }, accountsMap([{ id: "x", currency: "RUB" }]), rates, "USD"),
    0.5,
  );
  assertEquals(computeAmountInBase({ id: "t3", account_id: "a", amount_native: 0.4 }, accounts, rates, "RUB"), 37);
});
