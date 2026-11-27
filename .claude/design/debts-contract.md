# Akifi 1.6 — «Долги» and personal spending: server contract

Source of truth for the clients (iOS 1.6.0, the Telegram Mini App) for:

- **A. Долги** — money lent to / borrowed from people.
- **B. Личные траты из общего счёта** — one member's personal spending on a shared account.

The server implements this in four migrations, applied in this order:

| File | What |
|---|---|
| `supabase/migrations/20261128090000_debt_accounts.sql` | `account_type = 'debt'`, table `debts`, guards, `create_debt()` |
| `supabase/migrations/20261128090001_debts_summary_rpc.sql` | `debts_summary()` |
| `supabase/migrations/20261128090002_transactions_personal_debt.sql` | `transactions.personal_debt_user_id`, its guard trigger, 15-arg `create_expense_with_auto_transfer` |
| `supabase/migrations/20261128090003_account_settlement_v2.sql` | `get_account_settlement` v2 |

Assertions: `supabase/tests/20261128090000_*.assert.sql`, `…090002_*`, `…090003_*`.

Amounts are in **minor units ×100 of the account's currency** in every RPC
(the same "kopecks" as `get_account_settlement` v1 and `Int64` amounts in Swift).
Table columns keep their existing units: `transactions.amount_native` is
numeric in main units of the **account's** currency (ADR-001),
`accounts.initial_balance` is a bigint in whole units.

---

## A. Долги

### A1. Data model

A debt is an **account** with `accounts.account_type = 'debt'` (the CHECK now
allows `checking | savings | cash | deposit | investment | debt`) plus one row
in `public.debts` (1:1, like `deposits`).

`public.debts`

| Column | Type | Notes |
|---|---|---|
| `account_id` | uuid PK | → `accounts(id)` ON DELETE CASCADE. Must be a `debt` account. |
| `user_id` | uuid not null | default `auth.uid()`. Must equal `accounts.user_id`. Immutable for clients. |
| `counterparty_name` | text not null | 1–120 chars after trim (the server trims). |
| `counterparty_contact` | text null | ≤ 200 chars (phone / Telegram / anything). |
| `due_date` | date null | "вернуть до". |
| `remind` | boolean not null default false | `true` requires `due_date` (CHECK). |
| `note` | text null | ≤ 2000 chars. |
| `closed_at` | timestamptz null | null = open. |
| `created_at`, `updated_at` | timestamptz | `updated_at` maintained by a trigger. |

RLS: owner only (`user_id = auth.uid()`) for select / insert / update / delete.
Nobody else can see a debt, its account or its movements.

**Balance** of a debt account = `initial_balance·100 + Σ income − Σ expense`
(each row `round(amount_native·100)`, summed). This is the ordinary account balance.

- `balance > 0`: they owe me («мне должны»).
- `balance < 0`: I owe them («я должен»).
- `balance = 0`: settled.

### A2. Server rules

| Rule | Who | Error |
|---|---|---|
| A debt account has no members except its owner: no `account_members` row for anyone else, including via `accept_account_invite`. | every role | 23514 `debt_account_not_shareable` |
| No invites for a debt account (`create_account_invite` fails). | every role | 23514 `debt_account_not_shareable` |
| A shared account can never become a debt account. | every role | 23514 `debt_account_not_shareable` |
| A debt account cannot be the primary account (`set_my_primary_account`, `account_members.is_primary`). | every role | 23514 `debt_account_not_primary` |
| `budgets.account_ids` cannot contain a debt account. | every role | 23514 `debt_account_not_linkable` |
| `subscriptions.account_id` cannot be a debt account. | every role | 23514 `debt_account_not_linkable` |
| `account_type` cannot change to or from `'debt'`. | clients | 42501 `debt_account_type_fixed` |
| The owner (`accounts.user_id`) of a debt account cannot change. | every role | 42501 `debt_owner_immutable` |
| `debts.user_id` / `debts.account_id` cannot change. | clients | 42501 `debt_owner_immutable` |
| A `debts` row only on a `debt` account of the same user. | every role | 23514 `debt_account_required` / `debt_owner_mismatch` |
| A reminder needs a due date. | every role | 23514 (CHECK `debts_remind_needs_due_date`) |

Every error message starts with its tag. Match on the tag, not on the full text.

There is no restriction on which rows a debt account holds: the client writes
only the transfers described below. A plain expense or income on a debt
account is accepted (for example a write-off), and it counts as real spending
or income everywhere.

### A3. RPC `create_debt` — create a debt (no money moves)

`POST /rest/v1/rpc/create_debt`. Send all 10 keys; nulls must be sent as JSON `null`.
(The comments below are annotations, not part of the body.)

```jsonc
{
  "p_account_id": "6f1c2d9e-…",          // client-generated UUID (idempotency)
  "p_name": "Маша",                      // account name; null/blank -> counterparty name
  "p_currency": "RUB",                   // any case; stored lower-case like the account form
  "p_icon": null,                        // SF Symbol; null -> "person.crop.circle"
  "p_color": null,                       // hex; null -> "#F59E0B"
  "p_counterparty_name": "Маша",         // required
  "p_counterparty_contact": "+7 900 000-00-00",
  "p_due_date": "2026-12-31",            // or null
  "p_remind": true,                      // true needs p_due_date
  "p_note": "на ремонт"
}
```

The response is the account id as a JSON string. The call inserts
`accounts(account_type = 'debt', initial_balance = 0)` and the `debts` row in
one transaction. If you retry with the same `p_account_id`, it fails with
**23505**. Treat 23505 as "already created", the same as for
`create_expense_with_auto_transfer`.

Other errors are 22023 (bad currency, empty counterparty), 23514 (`p_remind`
without `p_due_date`, or a name or note that is too long) and 42501 (not signed in).

The older two-step path (insert into `accounts` with `account_type = 'debt'`,
then insert into `debts`) also works. If the second insert never happens, the
debt still shows in `debts_summary` with `has_details = false`, and the client
should offer to fill in the details.

### A4. RPC `debts_summary` — the «Долги» screen

`POST /rest/v1/rpc/debts_summary` with body `{}`. It returns **one jsonb value**
(ADR-003-safe; mark the call `// bounded-fetch: single jsonb`).

```json
{
  "version": 1,
  "today": "2026-11-28",
  "debts": [
    {
      "account_id": "6f1c2d9e-…",
      "name": "Маша",
      "icon": "person.crop.circle",
      "color": "#F59E0B",
      "currency": "RUB",
      "balance": 30000,
      "direction": "owed_to_me",
      "counterparty_name": "Маша",
      "counterparty_contact": "+7 900 000-00-00",
      "due_date": "2026-12-31",
      "remind": true,
      "note": "на ремонт",
      "closed_at": null,
      "is_closed": false,
      "is_overdue": false,
      "has_details": true,
      "tx_count": 2,
      "last_movement_at": "2026-11-28T09:12:00+00:00",
      "created_at": "2026-11-28T09:10:00.123+00:00"
    },
    {
      "account_id": "0b7e…",
      "name": "Петя",
      "icon": "person.fill",
      "color": "#10B981",
      "currency": "RUB",
      "balance": -69945,
      "direction": "i_owe",
      "counterparty_name": "Петя",
      "counterparty_contact": null,
      "due_date": null,
      "remind": false,
      "note": null,
      "closed_at": null,
      "is_closed": false,
      "is_overdue": false,
      "has_details": true,
      "tx_count": 2,
      "last_movement_at": "2026-11-28T09:20:00+00:00",
      "created_at": "2026-11-28T09:15:00+00:00"
    }
  ],
  "totals": [
    { "currency": "RUB", "owed_to_me": 30000, "i_owe": 69945, "open_count": 2 }
  ]
}
```

- `direction` is `owed_to_me` (balance > 0), `i_owe` (< 0) or `settled` (= 0).
- `today` is the caller's local date (`profiles.timezone`, UTC when unknown).
  `is_overdue` means open, `balance ≠ 0` and `due_date < today`.
- Order of `debts`: open first, then by `due_date` (nulls last), `created_at`, `account_id`.
- `totals` covers open debts only, with one entry per currency and **no FX**.
  Convert on the client with the usual rates if you need one number.
- For a debt account without a `debts` row: `has_details = false`,
  `counterparty_name` = the account name, and the other detail fields are null.
- Decode `version` and ignore unknown keys (future versions only add keys).

Offline fallback: compute the same balance from `dataStore.transactions`
(`initialBalance + Σ income − Σ expense` of `amountNative` on the debt account).
All rows of a debt account belong to its owner, so the local set is complete.

### A5. The four actions (ordinary manual transfers)

Every action is **two inserts** into `transactions` with:

- the same client-generated `transfer_group_id`;
- the same `user_id` (the owner) and the same `date`;
- `auto_transfer_group_id = null`, `category_id = null`, `personal_debt_user_id = null`;
- on each leg, `amount = amount_native` in **that leg's account currency** and
  `currency` = that account's currency (upper-case). This is the deposit
  pattern: for a cross-currency debt, convert one side with real quotes before
  writing anything (`DepositsViewModel.convertLeg`).
- `description` is localized (for example «Долг: Маша»), and `merchant_name` is the counterparty name.

| Action | Expense leg on | Income leg on | Debt balance |
|---|---|---|---|
| «Дал в долг» | real account | debt account | + amount |
| «Мне вернули» | debt account | real account | − amount (towards 0) |
| «Взял в долг» | debt account | real account | − amount |
| «Я вернул» | real account | debt account | + amount (towards 0) |

- **New debt:** call `create_debt`, then write the first transfer («Дал в долг» or «Взял в долг»).
  If the transfer fails, the debt stays at 0 («settled»). Show it and offer a retry.
- **Repayment:** the default amount is `|balance|`. The user may enter less (partial) or more.
  More flips the sign: confirm with the user first.
- **Lend or borrow more** on an existing debt: the same rows as the first action.
- The "real account" is any non-debt account the user can write.
  It cannot be the debt account itself or another debt account.
- Both legs are offline-queueable like any manual transfer
  (`transfer_group_id` set, `auto_transfer_group_id` null).

Server analytics already skip every row with `transfer_group_id`. A debt
movement is never income or spending in budgets, notifications, the weekly
digest or AI spending answers. The card's balance changes as the money really
moved.

### A6. Editing, closing, deleting, reminders

- **Details:** PATCH `debts?account_id=eq.<id>` with `counterparty_name`,
  `counterparty_contact`, `due_date`, `remind`, `note`.
- **Name, icon, colour:** PATCH `accounts`. Do not send `account_type`.
- **Close:** `closed_at = now()`. **Reopen:** `closed_at = null`.
  When the balance reaches 0 after a repayment, suggest «Закрыть долг».
  Closing with a non-zero balance is allowed: the debt leaves the totals, and
  the residual stays visible in its history.
- **Write-off** («Простить», optional in 1.6.0): a plain expense (they owed me)
  or income (I owed them) on the debt account for the residual, then close.
  It counts as real spending or income by design.
- **Delete:** delete the account. This cascades the `debts` row and the
  debt-account legs. The legs on the real accounts stay, so card balances are
  unchanged. Warn the user and prefer «Закрыть».
- **Reminders:** handled on the client. For `remind && !is_closed && balance ≠ 0`,
  schedule a local notification on `due_date`, and reschedule after every
  change. There is no server reminder job yet; index `idx_debts_open_due` is
  ready for one.

### A7. Where debt accounts must NOT appear (client checklist)

A debt balance is **not spendable money**. Exclude `account_type == .debt` from:

1. The Home account carousel and the "всего на счетах" / available balance.
   Show a separate «Долги» card instead: `мне должны` / `я должен` from `debts_summary.totals`.
2. Every account picker except the debt flows: expense and income target,
   «Оплачено с», the generic transfer form, the default payment source
   (`user_account_defaults`), budgets, subscriptions, deposits
   (`return_to_account_id`), savings goals and challenges, the primary account.
3. Sharing UI: there is no «Поделиться» on a debt account.
4. "Runway" or "how long will money last" estimates.
5. AI context: do not send debt accounts in `context.accounts` of `assistant-query`
   (see C3). If you want the AI to know about debts, send them separately.
6. **Net worth (default, product may override):** keep debts out of
   `accounts_total`. Add positive balances to `assets_total` («Мне должны»)
   and `|negative|` balances to `liabilities_total` («Я должен»). Net worth
   stays economically right while "money on accounts" stays spendable.
   Manual `liabilities` rows with `category = 'personal_debt'` are separate
   entities; don't double-count them, and a later migration of them into Debts is optional.

Analytics need no client change: debt movements are transfers, and every
spending or income view already skips transfers.

### A8. Swift decoding

- `AccountType` gets `case debt`.
- Make `Account.accountType` decoding **tolerant**: an unknown value maps to a
  non-spendable fallback or the row is skipped. It must not throw. See C1
  for why this matters.
- `Debt` model mirrors `public.debts`. `DebtsSummary` mirrors A4.

---

## B. Personal spending from a shared account

### B1. Column

`transactions.personal_debt_user_id uuid null → auth.users(id) ON DELETE SET NULL`.
It is visible to every member who can see the row, so it can drive badges.

It has a meaning on exactly two row shapes, on a **shared** account (two or
more parties: the owner plus members, and never a debt account):

| Row | Meaning |
|---|---|
| Expense, `transfer_group_id IS NULL` (direct expense, or the main expense of a «Оплачено с» triplet) | This member personally owes for it. |
| Income leg of a **manual** transfer into the shared account (`transfer_group_id` set, `auto_transfer_group_id IS NULL`) | This transfer repays that member's personal debt to the account («Погасить»). |

### B2. Who may set it (trigger `trg_transactions_personal_debt`, not only RLS)

| Situation | Allowed |
|---|---|
| Expense: author marks their own row for themselves (value = author = caller) | yes |
| Expense: owner/editor of the account marks any member, changes or clears any mark | yes |
| Expense: anyone else | 42501 `personal_debt_forbidden` |
| Repayment leg: only for oneself (value = author = caller), set or clear | otherwise 42501 `personal_debt_repayment_self_only` / `personal_debt_forbidden` |
| Value is not a party (owner/member) of the account | 23514 `personal_debt_not_member` (every role) |
| Account has fewer than two parties, or is a debt account | 23514 `personal_debt_not_shared` (every role) |
| Any other row shape (plain income, auto-transfer leg, …) | 23514 `personal_debt_invalid_row` (every role) |

If a statement does **not** touch the column but moves or reshapes a marked
row (another account, expense → income, made part of a transfer), the mark is
**dropped silently** instead of failing. Clients that don't know the column
(the Mini App, iOS ≤ 1.5.x) can never be blocked by it.

Viewers cannot write rows at all (existing RLS), so in practice every writer
is an owner or editor.

### B3. Writing it

- **Direct expense** from the shared account's own money: add
  `"personal_debt_user_id": "<member>"` to the normal insert body. This is
  offline-queueable.
- **«Оплачено с» + personal:** call `create_expense_with_auto_transfer` with
  **15 keys**: the 14 of today plus `p_personal_debt_user_id`. Send them all,
  with nulls explicit, as `CreateExpenseWithAutoTransferParams` already does.
  The 15-key body routes to the new overload; the 14-key body keeps routing to
  the old one. The mark is set on the main expense in the same transaction, and
  `null` behaves exactly like the 14-arg call.
- **Edit:** PATCH `transactions?id=eq.<id>` with `{"personal_debt_user_id": <uuid|null>}`.
  `update_expense_with_auto_transfer` does not touch the column, so the mark survives amount and category edits.
- **UI:** the expense form on a shared account gets «Личная трата», on by
  choice. The member defaults to the current user. Owners and editors can pick
  any party; otherwise only "me".

### B4. RPC `get_account_settlement` v2

`POST /rest/v1/rpc/get_account_settlement` `{"p_account_id": "<uuid>"}` returns one jsonb.

```json
{
  "version": 2,
  "account_id": "fecd…",
  "currency": "rub",
  "total_expenses": 17000,
  "tx_count": 3,
  "balances": [
    { "user_id": "aaaa…", "contributed": 14000, "fair_share": 5000,  "personal_share": 0 },
    { "user_id": "bbbb…", "contributed": 3000,  "fair_share": 12000, "personal_share": 7000 }
  ],
  "payers": { "<main expense id>": "<payer user id>" },
  "personal_debts": [
    { "user_id": "aaaa…", "owed": 0,    "expenses": 0,    "repaid": 0,    "is_member": true },
    { "user_id": "bbbb…", "owed": 1500, "expenses": 2500, "repaid": 1000, "is_member": true }
  ]
}
```

That example: E1 100 ₽ shared, paid by A; E2 30 ₽ B-personal, paid by B; E3
40 ₽ B-personal, paid by A; E4 25 ₽ B-personal from the account's own money;
B repaid 10 ₽. Result: B owes A 90 ₽ (50 + 40), and B owes the account 15 ₽.

The v1 fields keep their meaning:

- `total_expenses` and `tx_count` count the main auto-transfer expenses.
- `contributed` is the net auto-transfer money a member put in, plus settlements and marks.
- `payers` is unchanged.
- `delta = contributed − fair_share` (> 0: owed to them, < 0: they owe).

On accounts without marks, every v1 field is byte-identical to v1. The
assertion file checks this on every shared account on prod.

What v2 changes:

- **100 % attribution.** A main auto-transfer expense marked for member M is
  not split by weights: `fair_share(M) += amount`, and nobody else gets a share.
  `personal_share` is that part of `fair_share`. If M paid it from their own
  card, it nets to zero; if partner P paid it, M owes P the full amount.
  Shared expenses split exactly as in v1. `Σ fair_share = total_expenses`.
- **Per-transaction marks** (`transaction_member_settlements`) on such an
  expense: M's share is the full amount, and a mark for anyone else is a no-op.
- **`personal_debts`** is what members owe **the account** for personal
  spending paid from its own money:
  - `expenses` = Σ marked direct expenses;
  - `repaid` = Σ marked repayment legs;
  - `owed = max(expenses − repaid, 0)`. Display `owed`; the raw numbers are for
    the "траты / вернул" caption.
  - There is one entry per current member (zeros included), then former
    members with non-zero numbers (`is_member = false`).
  - These rows are **not** part of `balances`: direct expenses and manual
    transfers stay out of the who-owes-whom math, as in v1.
- A mark for someone who has left the account is ignored by the 100 % rule,
  and that expense is split like a shared one.
- `balances` is still `[]` when there are no auto-transfer expenses.
  `personal_debts` is present in that case too.

### B5. «Погасить» (repay my personal debt to the account)

Show it only on the **current user's own** `personal_debts` entry when `owed > 0`.
It is a manual transfer:

- expense leg on one of the user's own non-debt accounts (not the shared account);
- **income leg on the shared account with `personal_debt_user_id = me`**;
- the same `transfer_group_id` and author, amounts per ADR-001 (each leg in its
  account's currency);
- the default amount is `owed`. More than `owed` is allowed and clamps to 0 (confirm first).

Afterwards, refetch the settlement. Other members only see the number; they
cannot record a repayment for someone else.

### B6. Settlement screen and the local fallback

- `balances` and suggestions work as today. Optionally caption the member row
  with «из них личные: personal_share».
- Add a «Личные траты» section from `personal_debts`, filtered to entries with
  `expenses > 0 || repaid > 0`.
- Update `SettlementCalculator` (the offline fallback and cross-check) to the
  v2 rules: 100 % attribution for marked main expenses whose member is still a
  member, the full-amount share for marks, and `personal_debts`. This needs
  `Transaction.personalDebtUserId`. Without it, `settlement_integrity_mismatch`
  fires on every account that uses marks.
- Decode `personal_debts` and `personal_share` as optional, so an old server
  (v1) decodes as "none".

---

## C. Compatibility

### C1. iOS ≤ 1.5.x

> **Risk:** `AccountType` is a strict `String` enum and `Account.init(from:)`
> uses `try decodeIfPresent(AccountType.self, …)`. A row with
> `account_type = 'debt'` **throws**, and the whole `accounts` fetch (and the
> offline cache) fails on that device.

Debt accounts are personal, so partners are never affected. Only the same user
on a second device still running ≤ 1.5.x is hit, and only after creating a
debt on 1.6.0. Options: a minimum-version gate, or accept it. In any case,
1.6.0 must decode unknown types tolerantly (A8), so this never repeats.

Old clients ignore `personal_debt_user_id`, cannot set it, and cannot be
blocked by it (B2). Settlement v2 is backward-compatible: they decode
`version`, `total_expenses`, `balances` and `payers`, and display the server
numbers, which now include the 100 % rule. Their local cross-check does not
know marks, so they may log `settlement_integrity_mismatch` on accounts that
use marks. That is expected.

### C2. Telegram Mini App (separate repo, reads `accounts` with `select('*')`)

- It receives `account_type = 'debt'` rows. Its `Account.account_type` is a
  free `string`, so nothing crashes. It shows debt accounts as ordinary
  accounts and **includes their balance in its totals**.
  **To do in the Mini App:** filter `account_type === 'debt'` out of account
  lists, totals and pickers.
- It cannot create debt accounts: it never sends `account_type`, so the
  default is `checking`.
- If it tries to share, make primary, or link to a budget or subscription, it
  gets a 23514 error (`debt_account_*`) and shows its generic error.
- Its transfers to and from a debt account are ordinary transfers and are fine.
- `personal_debt_user_id` comes back in `select('*')`, and the Mini App
  ignores it. Its edits (move account, transfer → plain income) drop the mark
  instead of failing.
- It does not call `get_account_settlement`.

### C3. Edge functions and server analytics (checked against the code)

| Component | Debt movements (transfers) | Debt balance |
|---|---|---|
| `get_budget_metrics` / `budget_metrics_one` | skipped (`transfer_group_id is null`) | not used; debt accounts cannot be linked to a budget |
| `get_budget_member_expenses` | skipped | not used |
| `get_account_settlement` | only auto-transfer legs count; debt accounts can't be shared | not used |
| `smart-notifications` (transaction_insert, large expense, budget alerts) | skipped (`if (tx.transfer_group_id)`) | not used |
| `send-weekly-digest` | skipped (`.is("transfer_group_id", null)`) | not used |
| `check-subscriptions` | — | subscriptions can't point at a debt account |
| `assistant-query` spending answers | skipped (`!tx.transfer_group_id`) | **used**: `getAccounts()` loads every accessible account, and `accountsTotalBase` («Итого по всем счетам») sums their balances. Without client context it computes the debt balance from transactions. |

**Follow-up (edge, not in these migrations):** in `assistant-query`, select
`account_type` in `getAccounts()`. Exclude `debt` from the accounts list and
`accountsTotalBase`, and keep it out of account resolution for AI actions
(never "add expense to Маша"). Optionally add a separate «Долги» context
section. Until then, the iOS client must not send debt accounts in
`context.accounts`. Accounts the client doesn't send fall back to
`initial_balance` (0 for debts): they are harmless in the total, but still
listed.

Not changed in this release: `get_budget_metrics.by_member` still attributes
an expense to its author, not to `personal_debt_user_id`.

---

## D. Dry run and apply (main session)

Read-only pre-checks on prod:

```sql
select conname, pg_get_constraintdef(oid) from pg_constraint
 where conrelid = 'public.accounts'::regclass and contype = 'c';
select tgrelid::regclass, tgname from pg_trigger
 where not tgisinternal and tgrelid in ('public.accounts'::regclass, 'public.account_members'::regclass,
       'public.account_invites'::regclass, 'public.transactions'::regclass,
       'public.budgets'::regclass, 'public.subscriptions'::regclass) order by 1, 2;
select account_type, count(*) from public.accounts group by 1;
```

Dry run: everything in one `BEGIN … ROLLBACK`, in this order.

```
db_dryrun.py <(echo "select set_config('akifi.dry_run','on',true);") \
  supabase/migrations/20261128090000_debt_accounts.sql \
  supabase/migrations/20261128090001_debts_summary_rpc.sql \
  supabase/migrations/20261128090002_transactions_personal_debt.sql \
  supabase/migrations/20261128090003_account_settlement_v2.sql \
  supabase/tests/20261128090000_debt_accounts.assert.sql \
  supabase/tests/20261128090002_transactions_personal_debt.assert.sql \
  supabase/tests/20261128090003_account_settlement_v2.assert.sql
```

Expected output:

- three rows `… all assertions passed`;
- `NOTICE: settlement v1/v2 parity checked on N shared accounts`, with N ≥ 1 on prod;
- possibly `NOTICE: dropping accounts constraint <name>`.

The test files refuse to run without `akifi.dry_run = on`. Apply with
`db query -f` per file, in the same order, never `db push`. The migrations are
idempotent (re-running is safe).
