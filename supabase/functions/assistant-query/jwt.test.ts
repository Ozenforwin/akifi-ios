import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { graceEligibleSub, type Jwk, JWT_GRACE_PERIOD_SEC, verifyJwtSignature } from "./jwt.ts";

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const enc = (obj: unknown) => b64url(new TextEncoder().encode(JSON.stringify(obj)));

async function es256Pair(kid: string) {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pub = await crypto.subtle.exportKey("jwk", pair.publicKey) as Jwk;
  return { pair, jwk: { ...pub, kid, alg: "ES256" } };
}

async function signEs256(privateKey: CryptoKey, kid: string, claims: Record<string, unknown>): Promise<string> {
  const head = enc({ alg: "ES256", typ: "JWT", kid });
  const body = enc(claims);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, new TextEncoder().encode(`${head}.${body}`)));
  return `${head}.${body}.${b64url(sig)}`;
}

async function signHs256(secret: string, claims: Record<string, unknown>): Promise<string> {
  const head = enc({ alg: "HS256", typ: "JWT" });
  const body = enc(claims);
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${head}.${body}`)));
  return `${head}.${body}.${b64url(sig)}`;
}

const NOW = 1_800_000_000;
const userClaims = (exp: number) => ({ sub: "user-1", role: "authenticated", session_id: "sess-1", exp });

Deno.test("ES256 token signed by the project key verifies", async () => {
  const { pair, jwk } = await es256Pair("k1");
  const token = await signEs256(pair.privateKey, "k1", userClaims(NOW - 60));
  const claims = await verifyJwtSignature(token, { jwks: () => Promise.resolve([jwk]) });
  assertEquals(claims?.sub, "user-1");
});

Deno.test("ES256 token signed by another key is rejected", async () => {
  const project = await es256Pair("k1");
  const attacker = await es256Pair("k1");
  const token = await signEs256(attacker.pair.privateKey, "k1", userClaims(NOW - 60));
  assertEquals(await verifyJwtSignature(token, { jwks: () => Promise.resolve([project.jwk]) }), null);
});

Deno.test("tampered payload is rejected", async () => {
  const { pair, jwk } = await es256Pair("k1");
  const token = await signEs256(pair.privateKey, "k1", userClaims(NOW - 60));
  const [h, , s] = token.split(".");
  const forged = `${h}.${enc({ ...userClaims(NOW - 60), sub: "victim" })}.${s}`;
  assertEquals(await verifyJwtSignature(forged, { jwks: () => Promise.resolve([jwk]) }), null);
});

Deno.test("alg none and garbage are rejected", async () => {
  const none = `${enc({ alg: "none" })}.${enc(userClaims(NOW - 60))}.`;
  assertEquals(await verifyJwtSignature(none, { jwks: () => Promise.resolve([]) }), null);
  assertEquals(await verifyJwtSignature("not-a-jwt", { jwks: () => Promise.resolve([]) }), null);
});

Deno.test("HS256 only with a configured secret", async () => {
  const token = await signHs256("legacy-secret", userClaims(NOW - 60));
  assertEquals((await verifyJwtSignature(token, { jwks: () => Promise.resolve([]), hmacSecret: "legacy-secret" }))?.sub, "user-1");
  assertEquals(await verifyJwtSignature(token, { jwks: () => Promise.resolve([]) }), null);
  assertEquals(await verifyJwtSignature(token, { jwks: () => Promise.resolve([]), hmacSecret: "other" }), null);
});

Deno.test("grace: expired a minute ago → accepted", () => {
  assertEquals(graceEligibleSub(userClaims(NOW - 60), NOW), "user-1");
});

// S10: GoTrue rejected a token that is still within its lifetime — it was
// revoked (sign-out) or is otherwise invalid. Never grace it.
Deno.test("grace: a NOT expired token is never accepted", () => {
  assertEquals(graceEligibleSub(userClaims(NOW + 600), NOW), null);
  assertEquals(graceEligibleSub(userClaims(NOW), NOW), null);
});

Deno.test("grace: beyond the grace window → rejected", () => {
  assertEquals(graceEligibleSub(userClaims(NOW - JWT_GRACE_PERIOD_SEC - 1), NOW), null);
  assertEquals(graceEligibleSub(userClaims(NOW - JWT_GRACE_PERIOD_SEC), NOW), "user-1");
});

Deno.test("grace: anon / service_role tokens and tokens without session are rejected", () => {
  assertEquals(graceEligibleSub({ ...userClaims(NOW - 60), role: "anon" }, NOW), null);
  assertEquals(graceEligibleSub({ ...userClaims(NOW - 60), role: "service_role" }, NOW), null);
  assertEquals(graceEligibleSub({ sub: "user-1", role: "authenticated", exp: NOW - 60 }, NOW), null);
  assertEquals(graceEligibleSub({ role: "authenticated", session_id: "s", exp: NOW - 60 }, NOW), null);
});
