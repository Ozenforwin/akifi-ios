---
type: adr
status: accepted
date: 2026-04-19
tags: [multi-currency, architecture, database, ios]
---

# ADR-001 — Multi-currency storage

## Context

Users travel and enter transactions in foreign currencies (VND, IDR, EUR, USD)
on accounts that may be in a different base currency (e.g. a RUB-denominated
"Семейный" account or a USD-denominated ByBit account).

Legacy TMA (Telegram Mini App) stored `transactions.amount` inconsistently:

- On **RUB accounts**, `amount` was kept in **rubles** regardless of the
  `currency` label. VND/USD labels on RUB-accounts were just display tags —
  the stored number was already in rubles.
- On **USD accounts**, some rows with `currency = NULL` were actually entered
  in rubles but treated as USD by downstream code. iOS then multiplies those
  by the USD→RUB rate in Net Worth, inflating the balance ~76×.

Symptom: Net Worth reports **2 631 940 ₽** for data where real balances are an
order of magnitude smaller.

## Decision

Adopt the **Firefly III / Wallet / Spendee** pattern: `amount` is the single
source of truth for account balance and is always stored **in the account's
own currency**. Original entry currency and frozen FX rate are stored
separately when they differ.

### Schema

```
transactions:
  amount_native    BIGINT   -- minor units in account.currency (new canonical field)
  amount           BIGINT   -- legacy, kept for backward compat, equals amount_native after migration
  currency         TEXT     -- legacy label (kept read-only)
  foreign_amount   BIGINT   -- minor units in user-entered currency (NULL if same as account.currency)
  foreign_currency TEXT     -- ISO code of user-entered currency (NULL if same)
  fx_rate          NUMERIC(18,8) -- frozen rate at entry time (foreign_currency → account.currency)
```

**Invariant:** `amount_native` determines the account balance. `foreign_*`
fields exist only for display and audit.

### Computations

- **Account balance** = `initial_balance + Σ(amount_native)` — all in
  `account.currency`. No FX.
- **Net Worth in display currency X** = `Σ(account_balance × FX(account.currency → X))`.
  FX happens **only** at this aggregation step.
- **Budget in currency Y** = `Σ(tx.amount_native × FX(account.currency → Y))` per
  incoming transaction.
- **Analytics currency picker** = live FX conversion on the fly.

### User flows

**Entering 500 000 VND on a RUB account (Семейный):**

1. User picks account Семейный.
2. Enters `500 000`, toggles currency picker to VND.
3. App pulls `FX(VND → RUB) ≈ 0.0038`.
4. Preview: "500 000 VND ≈ 1 900 ₽".
5. On save:
   - `amount_native = 190_000` (kopecks, account currency)
   - `foreign_amount = 50_000_000_00` (dong minor)
   - `foreign_currency = "VND"`
   - `fx_rate = 0.0038`

**Display of such a transaction:**

- Main label: `"500 000 VND"` from `foreign_amount + foreign_currency`.
- Subtitle: `"≈ 1 900 ₽"` from `amount_native`.
- If `foreign_*` is NULL → just show `amount_native` in `account.currency`.

**Edit account balance:**

- Field is **always** in `account.currency` (for ByBit the prefix is `$`).
- Optional read-only preview `≈ X ₽` on the right.
- Save writes into `account.initial_balance` without any FX.

## Migration strategy

Phased, additive, feature-flagged.

1. **Phase 0** — snapshot backup (done: `backup_20260419` schema).
2. **Phase 1** — additive DDL: `ADD COLUMN amount_native / foreign_amount /
   foreign_currency / fx_rate`. Naive backfill `amount_native = amount`. Mark
   cross-currency rows (`tx.currency != account.currency`) into `foreign_*`
   for later reconciliation. No behavioural change.
3. **Phase 2** — iOS read-path behind `multi_currency_v2` flag. When ON, read
   `amount_native`. When OFF, read `amount` (legacy behaviour).
4. **Phase 3** — iOS write-path: `EditAccountView` writes balance in account
   currency only; `TransactionFormView` adds currency picker; RPC
   `create_expense_with_auto_transfer` accepts optional `foreign_*` params.
5. **Phase 4** — reconciliation UI in Settings. User audits rows where
   `foreign_currency IS NOT NULL` and confirms / fixes / deletes.
6. **Phase 5** — far future: drop legacy columns after 3+ months of stability.

## Data protection

- **Only ADD COLUMN** throughout migration (except the final cleanup).
- **Snapshot schema** `backup_20260419` copied before any DDL.
- **Supabase PITR** retains 7-day point-in-time restore as secondary backup.
- **Feature flag** for instant rollback of behaviour without DDL churn.
- **All UPDATE idempotent** (`WHERE amount_native IS NULL`).
- **Legacy contract tests**: flag OFF must preserve legacy behaviour exactly.

## Consequences

**Positive.**
- Single source of truth for balances.
- Net Worth becomes deterministic.
- Foreign-currency entry becomes native UX.
- Legacy TMA rows can be audited and corrected.

**Negative.**
- Four new columns on the hot `transactions` table.
- Client must branch on feature flag during rollout.
- Reconciliation UI requires manual user work for ambiguous legacy rows.

**Explicitly rejected alternatives.**
- **Single-currency storage with per-user conversion at read time** — cannot
  represent the legacy TMA inconsistency, still inflates USD accounts.
- **Automatic reinterpretation of legacy rows** — unsafe; TMA conventions are
  per-account inconsistent, algorithmic guesses could destroy real data.
- **Recomputing `initial_balance`** — user historically used it as a
  plug-number; silent rewrites would break their working balances.

## Guardrails (added 2026-04-22, Phase 8)

The invariant above only holds if every aggregation reads `amount_native`
(not the legacy `amount`) and FX-normalizes across accounts in different
currencies. Because both fields are `Int64` / `number`, the compiler
cannot distinguish them — a fresh developer summing `.amount` instead of
`amountInBase(tx)` silently recreates the VND-as-RUB phantom.

Three layers of defence:

1. **Swift type system.** `Transaction.amount` is marked
   `@available(*, deprecated, message: "Use dataStore.amountInBase(tx) or
   tx.amountNative. See ADR-001.")`. Every legacy call site lights up
   as a warning in Xcode.

2. **Runtime helper.** `AkifiIOS/Services/TransactionMath.swift` exposes
   `amountInBase(tx, accountsById, fxRates, baseCode) -> Int64` and a
   `CurrencyContext` typealias used by `BudgetMath`,
   `ChallengeProgressEngine`, `PDFReportGenerator`, `InsightEngine` and
   the `DataStore.aggregate(_:signed:)` one-line wrapper. Client code
   never FX-converts manually — it routes through the helper.

3. **CI lint guard.** `Scripts/lint-amount-usage.sh` greps for
   aggregation shapes (`reduce`, `+=`, `abs(...)`) reading `.amount` on
   a transaction, and for `tx.amount` on the TS side, with an allowlist
   for the model / repository / math files where the legacy column
   legitimately still lives. Blocking in `codemagic.yaml` as of Phase 8.
   Exceptional call sites get `// allowlisted-amount: <reason>`.

**Self-test rule (CLAUDE.md).** Fixes that touch user-visible money MUST
verify against real DB state via `supabase db query --linked` before
being reported fixed. Unit-test-only validation does not see legacy
rows written by a previous client / the Telegram Mini App / a broken
write-path — that is how the 2026-04-22 screenshot bug slipped through
Phase 1-3 on fixture-only tests.

## References

- Firefly III transaction model — https://docs.firefly-iii.org/references/financial-concepts/transactions/
- Project memory: `project_multi_currency_plan.md`
- Backup schemas: `backup_20260419` (Phase 1 DDL snapshot),
  `backup_20260422` (VND-on-RUB reconciliation snapshot)
- Migration files:
  - `supabase/migrations/20260419170000_multi_currency_phase1.sql`
  - `supabase/migrations/20260422120000_fix_vnd_rub_foreign_fields.sql`
- FX source (Phase 6 historical quotes): APILayer Exchange Rates Data
  API, Pro Plan, 100k requests/month. Key in `Config/*.xcconfig` as
  `EXCHANGE_RATE_API_KEY`, surfaced through Info.plist,
  gitignored. Used only via `ExchangeRateService.fetchHistoricalRate`;
  the hot-path `fetchRates` stays on free open.er-api.com so an
  expired paid key doesn't break core balance math.
