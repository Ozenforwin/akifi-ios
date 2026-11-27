import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildDeleteTransactionResponse } from "./response-builders.ts";
import type { TxRow } from "./types.ts";

const row = (id: string, date: string, extra: Partial<TxRow>): TxRow => ({
  id, amount: 100, amount_native: 100, date, type: "expense", category_id: "c", account_id: "a",
  ...extra,
} as TxRow);

Deno.test("M17: 'delete the last expense' picks the caller's own expense", () => {
  const txs = [
    row("partner", "2026-11-27T10:00:00", { user_id: "B" }),
    row("income", "2026-11-27T09:00:00", { user_id: "A", type: "income" }),
    row("leg", "2026-11-27T08:00:00", { user_id: "A", transfer_group_id: "g" }),
    row("mine", "2026-11-26T12:00:00", { user_id: "A" }),
  ];
  const res = buildDeleteTransactionResponse("удали последнюю трату", txs, undefined, "A");
  const payload = res.actions.find((a) => a.type === "delete_transaction")?.payload as { transaction_id?: string };
  assertEquals(payload?.transaction_id, "mine");
});

Deno.test("M17: nothing to delete when only partner rows exist", () => {
  const res = buildDeleteTransactionResponse("удали последнюю трату", [row("p", "2026-11-27", { user_id: "B" })], undefined, "A");
  assertEquals(res.actions.some((a) => a.type === "delete_transaction"), false);
});
