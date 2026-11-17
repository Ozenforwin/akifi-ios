// Pure helpers for refresh-fx-rates — no I/O, unit-tested in logic.test.ts.

/// Constant-time string equality. Both sides are hashed first so the loop
/// length (and therefore the timing) does not depend on where — or whether —
/// the inputs differ, nor on their lengths. An empty expected secret never
/// matches: a missing CRON_SECRET must lock the function, not open it.
///
/// NOTE: local copy until the edge stream's `_shared/auth.ts`
/// (`isCronAuthorized`) is merged; switch to it then.
export async function timingSafeEqualStr(actual: string, expected: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(actual)),
    crypto.subtle.digest("SHA-256", enc.encode(expected)),
  ]);
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0 && expected.length > 0;
}

/// Cron callers present the secret either as `x-cron-secret` or as
/// `Authorization: Bearer <secret>`. Both candidates are always compared so
/// the response time doesn't reveal which header was tried.
export async function isCronAuthorized(req: Request, secret: string): Promise<boolean> {
  if (!secret) return false;
  const header = (req.headers.get("x-cron-secret") ?? "").trim();
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const [h, b] = await Promise.all([
    timingSafeEqualStr(header, secret),
    timingSafeEqualStr(bearer, secret),
  ]);
  return h || b;
}

export interface FxRow {
  code: string;
  per_usd: number;
  updated_at: string;
}

export interface BuildResult {
  rows: FxRow[];
  /// Codes refused by the sanity checks, with the reason (logged/returned).
  skipped: { code: string; reason: string }[];
}

/// Smallest number of valid codes we accept from one upstream response.
/// open.er-api.com returns ~166; a much shorter list means a broken payload.
export const MIN_CODES = 30;

/// A single refresh may move a rate by at most this factor either way.
/// Real moves are a few percent a day; a 2× jump is a unit/decimal bug
/// upstream and would silently rescale every converted budget.
export const MAX_STEP = 2;

/// Validates an open.er-api.com `latest/USD` payload and turns it into
/// `fx_rates` rows. Throws on a payload that is unusable as a whole; drops
/// (and reports) individual codes that fail a sanity check.
export function buildRows(
  payload: unknown,
  existing: Record<string, number>,
  now: Date,
): BuildResult {
  if (!payload || typeof payload !== "object") throw new Error("payload is not an object");
  const p = payload as { result?: unknown; base_code?: unknown; rates?: unknown; time_last_update_unix?: unknown };
  if (p.result !== "success") throw new Error("upstream result is not success");
  if (p.base_code !== undefined && p.base_code !== "USD") throw new Error("base is not USD");
  if (!p.rates || typeof p.rates !== "object") throw new Error("no rates");

  const rates = p.rates as Record<string, unknown>;
  if (rates.USD !== 1) throw new Error("USD rate is not 1 — not a USD pivot");

  const stamp = typeof p.time_last_update_unix === "number" && Number.isFinite(p.time_last_update_unix)
    ? new Date(p.time_last_update_unix * 1000)
    : now;
  // Never stamp a row in the future (clock skew) — updated_at is read as age.
  const updatedAt = (stamp.getTime() > now.getTime() ? now : stamp).toISOString();

  const rows: FxRow[] = [];
  const skipped: BuildResult["skipped"] = [];
  for (const [rawCode, rawValue] of Object.entries(rates)) {
    const code = rawCode.toUpperCase();
    if (!/^[A-Z]{3}$/.test(code)) {
      skipped.push({ code: rawCode, reason: "bad_code" });
      continue;
    }
    if (typeof rawValue !== "number" || !Number.isFinite(rawValue) || rawValue <= 0) {
      skipped.push({ code, reason: "bad_value" });
      continue;
    }
    const prev = existing[code];
    if (prev !== undefined && prev > 0) {
      const ratio = rawValue / prev;
      if (ratio > MAX_STEP || ratio < 1 / MAX_STEP) {
        skipped.push({ code, reason: "jump" });
        continue;
      }
    }
    rows.push({ code, per_usd: rawValue, updated_at: updatedAt });
  }
  if (rows.length < MIN_CODES) {
    throw new Error(`only ${rows.length} usable rates`);
  }
  return { rows, skipped };
}
