// FX helpers shared by the scheduled jobs that write money rows.
//
// Lives here rather than inside a single function because getting this
// wrong is expensive: a subscription charge written in the wrong currency
// reads back multiplied by the FX rate (a $10/mo subscription once landed
// as 22 475 255 ₫ on a user's screen).

/// Units of each currency per 1 RUB (RUB-pivot). Last resort when the FX
/// provider is unreachable — it MUST cover every currency a subscription
/// can be priced in, because a missing entry means a 1:1 conversion (a
/// €10 subscription charged as 10 ₽).
export const FALLBACK_RATES: Record<string, number> = {
  RUB: 1,
  USD: 0.0116,
  EUR: 0.01,
  GBP: 0.0086,
  VND: 300,
  THB: 0.384,
  IDR: 190,
  CNY: 0.083,
  JPY: 1.79,
  KZT: 6.2,
  TRY: 0.47,
  AED: 0.0425,
  GEL: 0.031,
  RSD: 1.17,
  AMD: 4.45,
};

export function roundCurrency(value: number): number {
  return Math.round(value * 100) / 100;
}

/// Converts between any two currencies. `rates[CODE]` is units of CODE per
/// 1 RUB (RUB-pivot, matching `FALLBACK_RATES`); the formula is
/// pivot-agnostic as long as both legs share one. A missing or zero rate
/// on either side falls back to 1:1 rather than multiplying by undefined —
/// the same fail-safe contract as `NetWorthCalculator.convert` on the
/// client (ADR-001).
export function convertCurrency(
  amount: number,
  fromCurrency: string | null | undefined,
  toCurrency: string | null | undefined,
  rates: Record<string, number>,
): number {
  const from = (fromCurrency ?? "RUB").toUpperCase();
  const to = (toCurrency ?? "RUB").toUpperCase();
  if (from === to) return roundCurrency(amount);
  const fromRate = rates[from] ?? FALLBACK_RATES[from];
  const toRate = rates[to] ?? FALLBACK_RATES[to];
  if (!fromRate || fromRate <= 0 || !toRate || toRate <= 0) return roundCurrency(amount);
  return roundCurrency(amount / fromRate * toRate);
}
