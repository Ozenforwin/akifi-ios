---
type: prd
status: proposed
date: 2026-04-29
tags: [portfolio, investments, fire, deferred]
---

# PRD: Phase 3 features deferred from BETA "Активы → инвест-инструмент"

## Context

Sprints 1-7 of the BETA "Активы → инвест-инструмент" arc shipped:
positions / portfolio dashboard / FIRE projection (with manual
override) / compound calculator / target allocation + rebalance hint /
auto price feed (CoinGecko + Twelve Data with daily cron) / FIRE-impact
on large transactions / CAGR per holding.

Each commit in main: `c1212ba`, `b663e86`, `75176b3`, `cec840b`,
`8d6320a`, `fb2dad1`, plus the FIRE/CAGR/cron slice landing in this
sprint.

This PRD captures the features the user explicitly named for Phase 3
that we deferred — most need a schema extension or external content
the team doesn't have today.

## Schema-blocked features (need new tables)

> [!warning] Common dependency
> All four below need a `holding_transactions` (or similarly named)
> table to record buy/sell/dividend events with date + quantity +
> price + fees. The current `investment_holdings` only stores total
> position aggregates, which is enough for ROI/CAGR but not for
> anything cash-flow-aware.

### TWR / IRR / XIRR
**Why:** TWR is the standard for comparing performance against a
benchmark (it cancels out the timing of contributions). IRR/XIRR is
the cash-flow-weighted equivalent that matches the user's actual
experience.
**Blocked by:** `holding_transactions` to enumerate cash flows.
**MVP path:** add the table + a buy/sell form on each holding;
`PortfolioCalculator.twr(transactions:)` and `xirr(transactions:)`
implementations are well-known one-pagers.

### FX-decomposed return
**Why:** Multi-currency portfolios have two return components — the
asset's move in its native currency and the FX move against base.
"S&P +12%, USD −8% ⇒ 3.5% in EUR" is a more honest view than the
combined number we show today.
**Blocked by:** need `cost_basis_base` (the base-currency value at
purchase time) — without it, we can't separate FX from asset return.
**MVP path:** extend `investment_holdings` with `cost_basis_base`
+ `cost_basis_date`; populate via a one-time edge function for
existing rows using the historical FX feed already in the app.

### Dividends
**Why:** dividend-investing is a major retail use case. Forward
income forecasting is Snowball Analytics' moat — we don't need to
compete there, but logging dividends and including them in ROI is
table stakes.
**Blocked by:** `holding_dividends` table (date, gross, withholding,
currency). Manual entry first; auto via Twelve Data's
`/dividends` endpoint is paid-tier-only.

### Tax-lots (FIFO/LIFO)
**Why:** users in jurisdictions with capital-gains tax treat each
purchase lot separately when selling. "Sell 5 of 10 VOO at $500" →
the lot identification rule decides the cost basis of the 5 sold.
**Blocked by:** the same `holding_transactions` table — every buy
becomes a lot, every sell consumes lots according to the rule.
**Caveat:** Akifi positions globally (no RU bias); we should not
hard-code US/UK/AU rules. Make the lot-identification rule a per-
holding picker (FIFO / LIFO / specific-lot) and stop there.

## Schema-blocked: shared portfolio

**Why:** Akifi already has `account_members` for shared expense
accounts. Couples and families want the same for investments — "we
own this VOO position together, dividends split 70/30."
**Blocked by:**
1. `investment_holdings.shared_account_id` FK to allow ownership
   different from `auth.uid()`.
2. RLS rewrite so members see holdings on shared portfolios.
3. UI for splitting per-holding ownership rather than just
   account-level membership.
**Effort:** L (~2 sprints).

## Content-blocked: education

**Why:** tooltips already cover the four critical metrics (4% rule,
savings rate, investable, expected return) — Sprint 5 took care of
that. The next step is mini-articles ("What's an ETF?", "Why index
investing?") which need *written content*, not code.
**Blocked by:** content authoring in ru/en/es (3 articles × 3 langs
= 9 pieces minimum). Author pass + light editorial pass.
**Effort:** content M, code S (article reader is a few hundred lines
of Markdown rendering + nav).

## External-API-blocked

### Risk / volatility (without Monte Carlo)
**Why:** "your portfolio is 80% in tech-equity → expect ±20% draw-
downs" is a useful headline.
**Blocked by:** historical price data per ticker. CoinGecko gives
365-day history free; Twelve Data gives 30 days on free tier and
charges for longer. Without 5+ years of price series, volatility
calc is noisy.
**MVP path:** start with crypto-only volatility (CoinGecko 365 days
is fine for crypto's actual horizon); add stocks/ETFs when we
upgrade Twelve Data tier.

### MOEX / KASE feed (russian / kazakhstan tickers)
**Why:** part of beta users live in RU/KZ and hold local instruments.
CoinGecko & Twelve Data don't cover MOEX or KASE.
**Blocked by:** finding a feed that does. MOEX has a free public
API (https://iss.moex.com), undocumented but stable. KASE less
clear; Tinkoff Invest's API requires brokerage account.
**MVP path:** ship MOEX support via `iss.moex.com/iss/securities/
{ticker}.json` — small new branch in `fetch-price` keyed by `kind ==
'stock'` AND `currency == 'RUB'`. KASE deferred until we have a
research thread on a working feed.

## High-effort: broker CSV import

**Why:** typing every position by hand is friction; importing from
Tinkoff/IBKR/Binance is one of the top retention drivers in
competitor reviews (Snowball, Sharesight).
**Blocked by:** every broker exports a different CSV shape; each
needs a parser + tests + sample fixtures. Realistic per-broker
effort: 1-2 days each.
**MVP path:** start with the *one* broker the most active beta
users mention — likely Tinkoff or Interactive Brokers — and ship
that as the first loader. Do NOT promise broker coverage on
marketing until we have at least 3.

## Recommended ordering for Phase 3

If the team wants to keep momentum, the ordering by effort/impact:

| # | Feature | Effort | Why this slot |
|---|---|---|---|
| 1 | `holding_transactions` table + buy/sell form | L | Unblocks 3 features |
| 2 | TWR + XIRR | M | Cheap given (1) |
| 3 | Dividends (manual) | M | Cheap given (1); user-visible |
| 4 | MOEX feed | M | Self-contained, known users |
| 5 | Volatility (crypto-only) | S | Free with CoinGecko 365d |
| 6 | FX-decomposed return | S | Cheap if we add `cost_basis_base` |
| 7 | Shared portfolio | L | Big rewrite of RLS |
| 8 | Tax-lots | L | Niche outside US |
| 9 | Education content | content+code | Content gates everything |
| 10 | Broker import | XL | Per-broker, never "done" |

## Non-goals (still)

- Trading execution (we are a tracker, not a brokerage).
- Options / futures / leveraged products (different category).
- Realtime quotes (free tiers don't permit, paid tiers don't fit
  free-app economics).
- Plaid/Yodlee bank+broker connectivity (US-only and expensive).

## Open questions

1. Do we want `holding_transactions` to *replace* the current
   aggregate fields on `investment_holdings`, or live next to them?
   Recommendation: keep aggregates as denormalized cache (server-
   recomputed on transaction insert/update), so existing code that
   reads `currentValueMinor` keeps working.
2. Manual dividends default to gross or net of withholding? Start
   with gross + an optional `withholding_minor` field; UI shows
   net by default but lets the user toggle.
3. Shared portfolio invitations — reuse the existing share-account
   QR code flow, or add a separate "share holding" mechanism?
   Probably reuse — fewer concepts for the user.
