---
type: adr
status: accepted
date: 2026-09-10
tags: [supabase, postgrest, pagination, data-integrity, ios]
---

# ADR-003 — Complete-set reads: no client constant may decide correctness

## Context

PostgREST caps every response at the project's `max-rows` (1000 on Supabase
by default) and returns the truncated page **without an error**. The iOS
client read `transactions` with a bare `.select().execute()`, ordered
newest-first, so once a user's RLS-visible set crossed 1000 rows the
**oldest** rows were dropped — and account balance is
`initial_balance + Σ` over the whole history.

2026-09-10, shared account «Семейный»: one member saw 1011 rows by RLS
(own rows ∪ every shared account's rows), the other 972. The first lost 11
rows including two 38 880 ₽ income legs and saw **−38 997 ₽** where
**+36 539 ₽** was correct. A 250 ₽ coffee was the row that pushed the
balance over the cliff.

The first fix paged with `while page.count == 1000` — which merely moved
the hard-coded assumption one level down: lower `max-rows` to 500 and the
loop stops after the first short page, silently, exactly like before.
Fixing that would again require an App Store release.

## Decision

1. **All list reads go through `SupabasePaging.all(...)`** (`Services/SupabasePaging.swift`).
   Termination is driven by the server: advance by rows received, stop only
   when the server's `count=exact` is satisfied or a page comes back empty.
   `requestSize` is a round-trip hint, not a contract. Any `max-rows` value
   yields a complete set without a rebuild.
2. **Total order is enforced.** The primary key is appended as the final
   `order` term of every paginated query. Production data has 89 groups of
   rows tied on `(date, created_at)`; offset paging over a non-unique sort
   is unsound.
3. **Self-check + self-heal.** Assembled count is compared with the
   server's count; on mismatch (concurrent insert/delete) the read is
   retried once. A persistent mismatch is logged and sent to analytics as
   `fetch_integrity_mismatch`.
4. **CI guard.** `Scripts/lint-unbounded-fetch.py --strict` fails the build
   on any raw `.select()…execute()` list read. Bounded reads (`.single()`,
   `.limit(`, `.range(`, writes) pass; anything else needs
   `// bounded-fetch: <reason>` in the comment block above the statement.

## Consequences

- Row count of any table can grow without bound; no entity has a cliff.
- One extra round-trip per list per 1000 rows; negligible.
- RPCs that return row sets need a unique column to be page-safe —
  migration `20260910120000` adds `tx_id` to `get_budget_member_expenses`.
- Longer term, balances should be computed server-side (a view or RPC)
  so the client never needs the full history at all; that is the only way
  a data-layer fix ships without an App Store release.

Related: [[ADR-001-multi-currency]] (same guard-script pattern).
