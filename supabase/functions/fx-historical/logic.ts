// Pure helpers for fx-historical (tested in logic.test.ts).

export interface HistoricalRequest {
  from: string;
  to: string;
  date: string; // YYYY-MM-DD
}

/// Per-user cap on upstream (paid) lookups per rolling 24 h. Cache hits are
/// free and unlimited; this only bounds what one account can cost.
export const MAX_UPSTREAM_PER_USER_PER_DAY = 300;

const CODE = /^[A-Z]{3}$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;

/// Validates and normalises the body. `today` is the server's UTC date; the
/// client sends a local calendar day, so one day ahead is allowed.
export function parseRequest(body: unknown, today: string): HistoricalRequest | string {
  if (!body || typeof body !== "object") return "body must be an object";
  const b = body as Record<string, unknown>;
  const from = String(b.from ?? "").trim().toUpperCase();
  const to = String(b.to ?? "").trim().toUpperCase();
  const date = String(b.date ?? "").trim();
  if (!CODE.test(from) || !CODE.test(to)) return "from/to must be ISO 4217 codes";
  if (!DAY.test(date)) return "date must be YYYY-MM-DD";
  const t = Date.parse(`${date}T00:00:00Z`);
  if (!Number.isFinite(t) || new Date(t).toISOString().slice(0, 10) !== date) return "invalid date";
  if (date < "1999-01-04") return "date too early";
  const maxDay = new Date(Date.parse(`${today}T00:00:00Z`) + 86_400_000).toISOString().slice(0, 10);
  if (date > maxDay) return "date in the future";
  return { from, to, date };
}

/// APILayer exchangerates_data/{date}?base=FROM&symbols=TO → rate or null.
export function rateFromUpstream(json: unknown, to: string): number | null {
  if (!json || typeof json !== "object") return null;
  const j = json as { success?: unknown; rates?: Record<string, unknown> };
  if (j.success !== true || !j.rates) return null;
  const r = Number(j.rates[to]);
  return Number.isFinite(r) && r > 0 ? r : null;
}
