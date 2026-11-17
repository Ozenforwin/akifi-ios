// Shared-secret authentication for cron / DB-trigger callers.
//
// Every function that pg_cron or a database trigger calls authenticates the
// caller with one shared secret, `CRON_SECRET` (function env) == vault
// secret `cron_secret` (database side). Callers send it twice:
//
//   x-cron-secret: <CRON_SECRET>
//   Authorization: Bearer <CRON_SECRET>
//
// Either header matching is enough. Those functions are deployed with
// `verify_jwt = false` (supabase/config.toml) because the secret is not a
// JWT — so THIS check is the only gate. There is deliberately no "any
// non-empty bearer is fine" fallback: with gateway verification off that
// would let anyone holding the public anon key trigger pushes/charges.
//
// Secrets are compared in constant time (global rule): both sides are
// hashed with SHA-256 first, so neither the length nor the contents of
// the presented value influence how long the comparison takes.

const encoder = new TextEncoder();

async function sha256(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}

/**
 * Constant-time string equality. Length-independent: compares SHA-256
 * digests (always 32 bytes) with an XOR accumulator, never short-circuits.
 */
export async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  const [da, db] = await Promise.all([sha256(a), sha256(b)]);
  let diff = 0;
  for (let i = 0; i < da.length; i++) diff |= da[i] ^ db[i];
  return diff === 0;
}

/** The bearer token from `Authorization`, or "" when absent. */
export function bearerToken(req: Request): string {
  return (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
}

/**
 * True when the request carries the shared cron secret in `x-cron-secret`
 * or as the bearer token. Refuses everything when the secret is not
 * configured (fail closed). `secret` is injectable for tests.
 */
export async function isCronAuthorized(
  req: Request,
  secret: string = Deno.env.get("CRON_SECRET") ?? "",
): Promise<boolean> {
  if (!secret) {
    console.error("CRON_SECRET is not configured; refusing every request");
    return false;
  }
  const presented = [
    (req.headers.get("x-cron-secret") ?? "").trim(),
    bearerToken(req),
  ];
  let authorized = false;
  // Evaluate both candidates regardless of the first result — no early
  // exit that would reveal which header matched.
  for (const candidate of presented) {
    if (!candidate) continue;
    if (await timingSafeEqual(candidate, secret)) authorized = true;
  }
  return authorized;
}
