/**
 * transaction-math.ts
 *
 * FX-normalization helper for edge functions. Mirrors the iOS
 * `TransactionMath.amountInBase(tx, accountsById, fxRates, baseCode)`
 * so analytics/AI/digests all read the same canonical number.
 *
 * Contract (ADR-001):
 * - `amount_native` is in the minor units of the TRANSACTION'S OWN
 *   account currency (i.e. `accounts.currency`). For legacy rows it may
 *   be missing — we fall back to the legacy `amount` column, which on
 *   post-Phase-1 backfill equals `amount_native`.
 * - `fxRates` is a USD-pivoted rate map (same convention as
 *   `ExchangeRateService.fetchRates` and `NetWorthCalculator.convert`):
 *   `fxRates[code]` = units of `code` per 1 USD.
 * - `amount_in_base = amount_native * (fxRates[base] / fxRates[accountCurrency])`
 *   (both sides in minor units; the ratio of major-unit rates is
 *   dimensionally a pure number).
 *
 * Usage:
 * - Pre-enrich once per request: `const rich = enrichTransactions(txs, accountsById, fxRates, base);`
 * - Then always aggregate via `safeNumber(tx.amount_in_base)` instead of
 *   `safeNumber(tx.amount)`. The `_lint-amount-usage.sh` guard allows
 *   `amount_in_base` but fails on bare `tx.amount` outside the allowlist.
 */

export interface TxMathAccount {
  id: string;
  currency?: string | null;
}

export interface TxMathRow {
  id: string;
  account_id?: string | null;
  /** Canonical amount in the account's own currency, minor units. */
  amount_native?: number | null;
  /** Legacy fallback (pre-backfill rows). */
  amount?: number | null;
  /** Row's stored currency label — advisory, not authoritative. */
  currency?: string | null;
  [key: string]: unknown;
}

export type EnrichedTxRow<T extends TxMathRow> = T & {
  /** FX-normalized into the caller's base currency. Always populated
   *  by `enrichTransactions`, in minor units of `base`. */
  amount_in_base: number;
};

/**
 * Convert `tx.amount_native` into `base`. Returns minor units.
 * On missing data falls back to `tx.amount` (legacy) without FX —
 * which is only correct when all accounts share `base` (single-
 * currency user). For multi-currency users this is the regression-
 * protection behaviour the lint rule aims to surface.
 */
export function computeAmountInBase<T extends TxMathRow>(
  tx: T,
  accountsById: Map<string, TxMathAccount>,
  fxRates: Map<string, number>,
  base: string,
): number {
  const native = Number(tx.amount_native ?? tx.amount ?? 0);
  if (!Number.isFinite(native) || native === 0) return 0;

  const baseUpper = base.toUpperCase();
  const account = tx.account_id ? accountsById.get(tx.account_id) : undefined;
  const accountCcy = (account?.currency ?? baseUpper).toUpperCase();
  if (accountCcy === baseUpper) return native;

  const rateAccount = fxRates.get(accountCcy);
  const rateBase = fxRates.get(baseUpper);
  if (!rateAccount || !rateBase || rateAccount <= 0) {
    // Missing rate — return unconverted value; caller decides whether
    // to surface a warning. Never coerce silently to 1:1 when it would
    // mask a 78× inflation (the VND-as-RUB bug).
    return native;
  }

  return Math.round(native * (rateBase / rateAccount));
}

/**
 * Enrich a batch of transactions with `amount_in_base`. Call once per
 * request, then pass `rich` everywhere a sum/aggregate is needed.
 */
export function enrichTransactions<T extends TxMathRow>(
  txs: T[],
  accountsById: Map<string, TxMathAccount>,
  fxRates: Map<string, number>,
  base: string,
): EnrichedTxRow<T>[] {
  return txs.map((tx) => ({
    ...tx,
    amount_in_base: computeAmountInBase(tx, accountsById, fxRates, base),
  }));
}

/**
 * Build a Map from a list of accounts keyed by id. Convenience wrapper
 * so call sites don't repeat the boilerplate.
 */
export function accountsMap<T extends TxMathAccount>(accounts: T[]): Map<string, T> {
  const m = new Map<string, T>();
  for (const a of accounts) m.set(a.id, a);
  return m;
}

/**
 * Build a fxRates Map from either a plain record (`{ RUB: 92.5, ... }`)
 * or an iOS-style `CurrencyManager.rates` object.
 */
export function fxRatesMap(rates: Record<string, number> | null | undefined): Map<string, number> {
  const m = new Map<string, number>();
  if (!rates) return m;
  for (const [k, v] of Object.entries(rates)) {
    if (typeof v === 'number' && Number.isFinite(v) && v > 0) {
      m.set(k.toUpperCase(), v);
    }
  }
  return m;
}
