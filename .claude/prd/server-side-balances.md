---
type: prd
status: proposed
date: 2026-09-10
tags: [supabase, balances, data-integrity, ios, offline]
---

# Server-side account balances

## Why

Today the phone downloads the **entire** transaction history and computes
`initial_balance + Σincome − Σexpense` in `DataStore.rebuildCaches()`. Any
defect on that path — truncation ([[ADR-003-complete-set-reads]]), a
legacy-row quirk ([[ADR-001-multi-currency]]), a transfer-semantics change —
shows up as a wrong number on the home screen and **can only be fixed by an
App Store release**. The 2026-09-10 incident took a day to diagnose and
still needs a build to reach the affected phone.

Goal: the balance a user sees is produced by SQL that we can change in
five minutes with a migration, and the client's own computation becomes a
cross-check that alerts us, not the source of truth.

## Design

### 1. View `account_balances` (security_invoker)

```sql
create view public.account_balances
with (security_invoker = true) as
select
    a.id                                     as account_id,
    a.currency,
    a.initial_balance
      + coalesce(sum(case t.type
                       when 'income'  then  t.amount_native
                       when 'expense' then -t.amount_native
                       else 0 end), 0)      as balance,          -- account currency, main units
    coalesce(sum(t.amount_native) filter (where t.type = 'income'),  0) as income_total,
    coalesce(sum(t.amount_native) filter (where t.type = 'expense'), 0) as expense_total,
    count(t.id)                              as tx_count,
    max(t.created_at)                        as last_tx_at
from accounts a
left join transactions t on t.account_id = a.id
group by a.id, a.currency, a.initial_balance;
```

- `security_invoker` → the existing RLS on `accounts` / `transactions`
  applies; a shared-account member sees the sum over **all** rows on the
  account (`is_account_member`), exactly like the client does today.
- Balance stays in the **account's** currency (ADR-001). FX into the
  display currency happens at render, as it should — today it is baked into
  the cache at rebuild time and goes stale when rates refresh.
- `tx_count` / `last_tx_at` are the cross-check hooks (see 3).
- 1 805 rows, index on `transactions(account_id)` already exists → sub-ms.
  No triggers, no materialisation; add them only if a real dataset needs it.

### 2. Client

| Where | Change |
|---|---|
| `AccountRepository.fetchAll` | Also read `account_balances` (one paged `SupabasePaging.all`), attach as `Account.serverBalance: AccountBalance?` |
| `DataStore.balance(for:)` | Return `serverBalance` FX-converted at call time; fall back to the local computation when nil (offline cold start, view missing) |
| `DataStore.rebuildCaches()` | Keep computing the local balance; **compare** with the server one |
| Offline | `PersistenceManager` caches the balances with the accounts; `OfflineQueue` pending ops overlay on top exactly as they do now |
| Widgets | `SharedSnapshotWriter` writes the server balance |
| Home / Net Worth / Settlement | No change — they call `balance(for:)` |

### 3. Cross-check telemetry — the part that would have caught the incident

When both numbers exist and `|local − server| > 1` minor unit, or
`transactions.filter(account).count != tx_count`:

- `AppLogger.data.error(...)` with account id, both values, both counts
- Analytics event `balance_integrity_mismatch`
- DEBUG builds: a banner on the account card

With this in place the 2026-09-10 truncation would have fired on the first
sync after the 1000th row, weeks before anyone entered a coffee.

### 4. Rollout

1. Migration: create the view + `grant select on account_balances to authenticated`. Additive, zero risk to old clients.
2. Client: read + fallback + cross-check behind a feature flag in `feature_flags` (`server_balances`), default **on** — the flag is the kill-switch, not the launch gate.
3. Ship; watch `balance_integrity_mismatch` for a week.
4. Then decide whether `rebuildCaches()` keeps computing balances at all, or only monthly aggregates.

### Out of scope (deliberately)

- Moving analytics aggregates (`monthlyAggregates`) server-side — same
  pattern, separate PRD once balances prove the approach.
- Replacing the full transaction fetch: the transactions tab and analytics
  still need the rows; ADR-003 keeps that fetch complete.

## Estimate

~1 day: migration 1 h, client 3–4 h, tests 2 h (view SQL against fixtures
via `supabase db query`, `DataStoreTests` for fallback/overlay/mismatch),
prod verification via the self-testing rule.

## Open question for Vladimir

Balance in the account currency (proposed) vs. the legacy "base kopecks"
contract in `balanceCache`: the first is correct under ADR-001 and simpler,
the second avoids touching 23 call sites. Recommendation: account currency,
convert in `balance(for:)`.
