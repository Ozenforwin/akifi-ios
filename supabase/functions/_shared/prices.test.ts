import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { fetchCoinGeckoQuote, fetchTwelveDataQuote } from "./prices.ts";
import type { FxRates } from "./fx.ts";

const KEY = "td-test-key-not-real";
// RUB pivot: 1 RUB = 0.0125 USD (80 ₽/$), 0.0108 EUR.
const liveRates = (): Promise<FxRates> => Promise.resolve({ rates: { RUB: 1, USD: 0.0125, EUR: 0.0108 }, live: true });
const staleRates = (): Promise<FxRates> => Promise.resolve({ rates: { RUB: 1, USD: 0.0125 }, live: false });

function mockFetch(body: unknown, status = 200, seen: { url?: string; headers?: Headers } = {}): typeof fetch {
  return ((input: string | URL | Request, init?: RequestInit) => {
    seen.url = String(input);
    seen.headers = new Headers(init?.headers);
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  }) as typeof fetch;
}

Deno.test("twelvedata: USD quote for a RUB asset is converted, not cached 1:1 (S8)", async () => {
  const r = await fetchTwelveDataQuote("AAPL", "RUB", {
    fetchImpl: mockFetch({ symbol: "AAPL", currency: "USD", close: "230.00" }),
    twelveDataApiKey: KEY,
    rates: liveRates,
  });
  assertEquals(r.ok, true);
  if (r.ok) {
    assertEquals(Math.round(r.price), 18_400); // 230 $ × 80 ₽
    assertEquals(r.quoteCurrency, "USD");
  }
});

Deno.test("twelvedata: same currency passes through", async () => {
  const r = await fetchTwelveDataQuote("AAPL", "usd", {
    fetchImpl: mockFetch({ currency: "USD", close: "230.5" }),
    twelveDataApiKey: KEY,
    rates: liveRates,
  });
  assertEquals(r.ok && r.price, 230.5);
});

Deno.test("twelvedata: the API key goes in a header, never in the URL", async () => {
  const seen: { url?: string; headers?: Headers } = {};
  await fetchTwelveDataQuote("AAPL", "USD", {
    fetchImpl: mockFetch({ currency: "USD", close: "1" }, 200, seen),
    twelveDataApiKey: KEY,
    rates: liveRates,
  });
  assertEquals(seen.url?.includes(KEY), false);
  assertEquals(seen.headers?.get("authorization"), `apikey ${KEY}`);
});

Deno.test("twelvedata: upstream error text is not passed to the caller", async () => {
  const r = await fetchTwelveDataQuote("NOPE", "USD", {
    fetchImpl: mockFetch({ status: "error", code: 404, message: "symbol not found, see https://x?apikey=leak" }),
    twelveDataApiKey: KEY,
    rates: liveRates,
  });
  assertEquals(r, { ok: false, status: 404, code: "unknown_ticker" });
  const quota = await fetchTwelveDataQuote("AAPL", "USD", {
    fetchImpl: mockFetch({ status: "error", code: 429, message: "quota" }),
    twelveDataApiKey: KEY,
    rates: liveRates,
  });
  assertEquals(quota, { ok: false, status: 503, code: "provider_unavailable" });
});

Deno.test("twelvedata: refuses when the asset currency cannot be converted", async () => {
  const r = await fetchTwelveDataQuote("AAPL", "XYZ", {
    fetchImpl: mockFetch({ currency: "USD", close: "230" }),
    twelveDataApiKey: KEY,
    rates: liveRates,
  });
  assertEquals(r, { ok: false, status: 422, code: "currency_unsupported" });
});

Deno.test("twelvedata: refuses to convert with stale fallback rates", async () => {
  const r = await fetchTwelveDataQuote("AAPL", "RUB", {
    fetchImpl: mockFetch({ currency: "USD", close: "230" }),
    twelveDataApiKey: KEY,
    rates: staleRates,
  });
  assertEquals(r, { ok: false, status: 503, code: "fx_unavailable" });
});

Deno.test("twelvedata: London pence are converted to pounds", async () => {
  const r = await fetchTwelveDataQuote("VOD", "GBP", {
    fetchImpl: mockFetch({ currency: "GBp", close: "7250" }),
    twelveDataApiKey: KEY,
    rates: liveRates,
  });
  assertEquals(r.ok && r.price, 72.5);
});

Deno.test("twelvedata: network error is reported as a code; key never echoed", async () => {
  const throwing = (() => Promise.reject(new TypeError(`error sending request for url (https://api.twelvedata.com/quote?apikey=${KEY})`))) as typeof fetch;
  const r = await fetchTwelveDataQuote("AAPL", "USD", { fetchImpl: throwing, twelveDataApiKey: KEY, rates: liveRates });
  assertEquals(r, { ok: false, status: 503, code: "provider_unavailable" });
});

Deno.test("twelvedata: no key configured", async () => {
  const r = await fetchTwelveDataQuote("AAPL", "USD", { twelveDataApiKey: "", rates: liveRates });
  assertEquals(r, { ok: false, status: 503, code: "provider_not_configured" });
});

Deno.test("coingecko: direct quote in the asset currency", async () => {
  const r = await fetchCoinGeckoQuote("BTC", "RUB", {
    fetchImpl: mockFetch({ bitcoin: { rub: 7_000_000, usd: 90_000 } }),
    rates: liveRates,
  });
  assertEquals(r.ok && r.price, 7_000_000);
});

Deno.test("coingecko: missing fiat falls back to USD × live FX", async () => {
  const r = await fetchCoinGeckoQuote("BTC", "EUR", {
    fetchImpl: mockFetch({ bitcoin: { usd: 100_000 } }),
    rates: liveRates,
  });
  assertEquals(r.ok && Math.round(r.price), 86_400); // 100 000 / 0.0125 × 0.0108
});

Deno.test("coingecko: unknown id", async () => {
  const r = await fetchCoinGeckoQuote("ZZZ", "USD", { fetchImpl: mockFetch({}), rates: liveRates });
  assertEquals(r, { ok: false, status: 404, code: "unknown_ticker" });
});
