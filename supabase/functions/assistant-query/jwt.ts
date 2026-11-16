// JWT checks for the assistant-query grace path (S10).
//
// The grace path exists for iOS requests whose access token expired a
// moment ago (background suspension). It must accept ONLY such tokens:
//
//   * the signature verifies against the project's keys — ES256 through the
//     JWKS (the project signs user tokens with an EC key) or HS256 when the
//     legacy JWT secret is configured;
//   * the token IS expired, and by no more than the grace period — a token
//     GoTrue rejects while still inside its lifetime was revoked, signed out
//     or forged, never "just stale";
//   * it is a user token (role = authenticated) bound to a session.
//
// The caller then also checks that the user still exists / is not banned
// and that the session is still alive (index.ts).

export const JWT_GRACE_PERIOD_SEC = 2 * 60 * 60;

export type Jwk = JsonWebKey & { kid?: string; alg?: string };

export interface JwtKeys {
  jwks: () => Promise<Jwk[]>;
  hmacSecret?: string;
}

export function base64UrlToBytes(str: string): Uint8Array<ArrayBuffer> {
  let base64 = str.replace(/-/g, "+").replace(/_/g, "/");
  const pad = base64.length % 4;
  if (pad === 2) base64 += "==";
  else if (pad === 3) base64 += "=";
  else if (pad === 1) throw new Error("invalid base64url");
  const binary = atob(base64);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function decodeJson(part: string): Record<string, unknown> | null {
  try {
    const value = JSON.parse(new TextDecoder().decode(base64UrlToBytes(part)));
    return value && typeof value === "object" ? value as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

/** Verifies the signature; returns the claims only when it is valid. */
export async function verifyJwtSignature(token: string, keys: JwtKeys): Promise<Record<string, unknown> | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const header = decodeJson(parts[0]);
  if (!header) return null;
  const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  let signature: Uint8Array<ArrayBuffer>;
  try {
    signature = base64UrlToBytes(parts[2]);
  } catch {
    return null;
  }
  let valid = false;
  try {
    if (header.alg === "ES256") {
      const all = await keys.jwks();
      const jwk = all.find((k) => k.kty === "EC" && k.crv === "P-256" && (!header.kid || k.kid === header.kid));
      if (!jwk) return null;
      const key = await crypto.subtle.importKey(
        "jwk",
        { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y, ext: true },
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["verify"],
      );
      valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature, signed);
    } else if (header.alg === "HS256" && keys.hmacSecret) {
      const key = await crypto.subtle.importKey(
        "raw",
        new TextEncoder().encode(keys.hmacSecret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["verify"],
      );
      // WebCrypto HMAC verify compares in constant time.
      valid = await crypto.subtle.verify("HMAC", key, signature, signed);
    } else {
      return null; // "none", RS*, unknown — never accepted
    }
  } catch {
    return null;
  }
  return valid ? decodeJson(parts[1]) : null;
}

/**
 * Pure claims check for the grace path. Returns the user id only for an
 * authenticated-user token that expired within the grace period.
 */
export function graceEligibleSub(claims: Record<string, unknown>, nowSec: number): string | null {
  const sub = claims.sub;
  const exp = claims.exp;
  if (typeof sub !== "string" || !sub) return null;
  if (claims.role !== "authenticated") return null;
  if (typeof claims.session_id !== "string" || !claims.session_id) return null;
  if (typeof exp !== "number" || !Number.isFinite(exp)) return null;
  if (nowSec <= exp) return null; // not expired, yet rejected by GoTrue → revoked / invalid
  if (nowSec > exp + JWT_GRACE_PERIOD_SEC) return null;
  return sub;
}
