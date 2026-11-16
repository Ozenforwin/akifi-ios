import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { describeError, escapeHtml, pushTextFromHtml, redactSecrets } from "./notify.ts";

// Shape of a real Deno fetch failure — the URL (with the bot token in the
// path) is part of the message.
const FAKE_TOKEN = "1234567890:AAFakeTokenForTestsOnly_abcdefghijklmn";

Deno.test("redactSecrets: Telegram bot token in a URL path", () => {
  const msg = `error sending request for url (https://api.telegram.org/bot${FAKE_TOKEN}/sendMessage): connection reset`;
  const out = redactSecrets(msg);
  assertEquals(out.includes(FAKE_TOKEN), false);
  assertEquals(out.includes("/bot<redacted>/sendMessage"), true);
});

Deno.test("redactSecrets: api keys in query strings and bearer tokens", () => {
  assertEquals(
    redactSecrets("GET https://api.twelvedata.com/price?symbol=AAPL&apikey=SECRETKEY123 failed"),
    "GET https://api.twelvedata.com/price?symbol=AAPL&apikey=<redacted> failed",
  );
  assertEquals(redactSecrets("Authorization: Bearer eyJhbGciOi.abc.def"), "Authorization: Bearer <redacted>");
});

Deno.test("describeError never echoes the token", () => {
  const err = new TypeError(`error sending request for url (https://api.telegram.org/bot${FAKE_TOKEN}/sendMessage)`);
  assertEquals(describeError(err).includes(FAKE_TOKEN), false);
});

Deno.test("escapeHtml protects parse_mode=HTML from user-provided names", () => {
  assertEquals(escapeHtml("Кафе <3 & бары"), "Кафе &lt;3 &amp; бары");
});

Deno.test("pushTextFromHtml strips tags and unescapes entities", () => {
  assertEquals(pushTextFromHtml("💸 <b>Крупная трата</b>\n\n5 000 ₽ — Кафе &lt;3"), {
    title: "💸 Крупная трата",
    body: "5 000 ₽ — Кафе <3",
  });
});
