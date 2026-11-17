/**
 * Shared utility functions for Supabase Edge Functions.
 *
 * IMPORTANT: Keep function signatures stable -- many edge functions depend on them.
 */

// ---------------------------------------------------------------------------
// Text utilities
// ---------------------------------------------------------------------------

/** Collapse whitespace and trim. */
export function normalizeText(value: string): string {
  return value.replace(/\s+/g, ' ').trim();
}

/** Lowercase, replace yo, strip punctuation, collapse whitespace -- for fuzzy matching. */
export function normalizeForMatch(value: string): string {
  return value
    .toLowerCase()
    .replace(/\u0451/g, '\u0435') // ё -> е
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------

/** Check whether a Supabase/PostgREST error is about a missing column. */
export function isMissingColumnError(error: unknown, column: string): boolean {
  if (!error || typeof error !== 'object') return false;
  const maybe = error as { code?: string; message?: string; details?: string; hint?: string };
  const blob = [maybe.message, maybe.details, maybe.hint].filter(Boolean).join(' ').toLowerCase();
  return maybe.code === '42703' || maybe.code === 'PGRST204' || blob.includes(column.toLowerCase());
}

// ---------------------------------------------------------------------------
// Date utilities
// ---------------------------------------------------------------------------

/** Return the YYYY-MM-DD portion of a Date. */
export function toDateOnly(value: Date): string {
  return value.toISOString().slice(0, 10);
}

/** Parse a YYYY-MM-DD string into a UTC Date at midnight. */
export function parseDateOnly(value: string): Date {
  return new Date(`${value.slice(0, 10)}T00:00:00.000Z`);
}

/** Add (or subtract) days from a YYYY-MM-DD string. */
export function addDays(value: string, days: number): string {
  const date = parseDateOnly(value);
  date.setUTCDate(date.getUTCDate() + days);
  return toDateOnly(date);
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

const LOCALE_BY_LANG: Record<string, string> = { ru: 'ru-RU', en: 'en-US', es: 'es-ES' };

/**
 * Format a main-unit amount in `currency` (defaults to RUB, ru-RU locale).
 * `lang` (ru/en/es or a BCP-47 tag) only picks separators and symbol
 * placement — never the currency: «$50» must not become «50 ₽» because
 * the user reads Russian (M4).
 */
export function formatMoney(value: number, currency = 'RUB', lang?: string): string {
  const code = (currency || 'RUB').toUpperCase();
  const prefix = (lang ?? 'ru').toLowerCase().split(/[-_]/)[0];
  const locale = LOCALE_BY_LANG[prefix] ?? (lang && lang.includes('-') ? lang : 'ru-RU');
  try {
    return new Intl.NumberFormat(locale, {
      style: 'currency',
      currency: code,
      // Roubles have always been shown without kopecks; other currencies
      // keep their own minor digits (USD 2, VND/JPY 0, ...).
      ...(code === 'RUB' ? { minimumFractionDigits: 0, maximumFractionDigits: 0 } : {}),
    }).format(value);
  } catch {
    return `${Math.round(value)} ${code}`;
  }
}
