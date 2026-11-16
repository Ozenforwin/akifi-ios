import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { bearerToken, isCronAuthorized, timingSafeEqual } from "./auth.ts";

const SECRET = "s3cr3t-value-for-tests";

function req(headers: Record<string, string>): Request {
  return new Request("https://example.test/fn", { method: "POST", headers });
}

Deno.test("timingSafeEqual: equal strings", async () => {
  assertEquals(await timingSafeEqual("abc", "abc"), true);
  assertEquals(await timingSafeEqual("", ""), true);
});

Deno.test("timingSafeEqual: different strings, including length mismatch and prefixes", async () => {
  assertEquals(await timingSafeEqual("abc", "abd"), false);
  assertEquals(await timingSafeEqual("abc", "abcd"), false);
  assertEquals(await timingSafeEqual(SECRET, SECRET.slice(0, -1)), false);
  assertEquals(await timingSafeEqual("", SECRET), false);
});

Deno.test("timingSafeEqual: unicode is compared byte-exactly", async () => {
  assertEquals(await timingSafeEqual("ключ", "ключ"), true);
  assertEquals(await timingSafeEqual("ключ", "ключи"), false);
});

Deno.test("bearerToken strips the scheme case-insensitively", () => {
  assertEquals(bearerToken(req({ Authorization: "Bearer abc" })), "abc");
  assertEquals(bearerToken(req({ Authorization: "bearer   abc  " })), "abc");
  assertEquals(bearerToken(req({})), "");
});

Deno.test("isCronAuthorized: x-cron-secret header", async () => {
  assertEquals(await isCronAuthorized(req({ "x-cron-secret": SECRET }), SECRET), true);
});

Deno.test("isCronAuthorized: bearer secret", async () => {
  assertEquals(await isCronAuthorized(req({ Authorization: `Bearer ${SECRET}` }), SECRET), true);
});

Deno.test("isCronAuthorized: either header may carry it (anon key in Authorization)", async () => {
  const r = req({ Authorization: "Bearer some-anon-jwt", "x-cron-secret": SECRET });
  assertEquals(await isCronAuthorized(r, SECRET), true);
});

// S4: the old code accepted ANY non-empty bearer.
Deno.test("isCronAuthorized: an arbitrary bearer is rejected", async () => {
  assertEquals(await isCronAuthorized(req({ Authorization: "Bearer anything" }), SECRET), false);
  assertEquals(await isCronAuthorized(req({ Authorization: "Bearer eyJhbGciOi.anon.key" }), SECRET), false);
});

Deno.test("isCronAuthorized: no credentials", async () => {
  assertEquals(await isCronAuthorized(req({}), SECRET), false);
});

Deno.test("isCronAuthorized: wrong secret in both headers", async () => {
  const r = req({ Authorization: "Bearer nope", "x-cron-secret": "nope" });
  assertEquals(await isCronAuthorized(r, SECRET), false);
});

Deno.test("isCronAuthorized: fails closed when the secret is not configured", async () => {
  assertEquals(await isCronAuthorized(req({ "x-cron-secret": "" }), ""), false);
  assertEquals(await isCronAuthorized(req({ Authorization: "Bearer x" }), ""), false);
});
