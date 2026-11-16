// Market quotes for fetch-price (on demand) and refresh-portfolio-prices
// (daily cron), one implementation so both write the same numbers into
// `price_cache` (S8).
//
// Contract: a returned price is ALWAYS in the asset's currency. Twelve Data
// quotes in the listing currency (AAPL → USD); the old code cached that
// number under the asset's currency, so AAPL in a rouble asset cost ~230 ₽.
// Now the quote currency is read from `/quote` and converted with LIVE FX;
// if it cannot be converted the request is refused, never cached 1:1.
//
// Secrets: the Twelve Data key travels in the `Authorization: apikey …`
// header (supported by the API), never in the URL, so it cannot end up in
// proxy/access logs or in an error message that quotes the URL. Upstream
// error text is never returned to the caller — only a stable error code.

import { tryConvertCurrency } from "./currency.ts";
import { describeError } from "./notify.ts";
import { type FxRates, getRubRates } from "./fx.ts";

export type PriceSource = "twelvedata" | "coingecko";

export type PriceErrorCode =
  | "provider_not_configured"
  | "provider_unavailable"
  | "unknown_ticker"
  | "currency_unsupported"
  | "fx_unavailable";

export type PriceResult =
  | { ok: true; price: number; source: PriceSource; quoteCurrency: string }
  | { ok: false; status: number; code: PriceErrorCode };

export interface PriceDeps {
  fetchImpl?: typeof fetch;
  twelveDataApiKey?: string;
  rates?: () => Promise<FxRates>;
}

export const COIN_GECKO_IDS: Record<string, string> = {
  BTC: "bitcoin", ETH: "ethereum", USDT: "tether", USDC: "usd-coin",
  BNB: "binancecoin", SOL: "solana", XRP: "ripple", ADA: "cardano",
  DOGE: "dogecoin", TON: "the-open-network", TRX: "tron", DOT: "polkadot",
  MATIC: "matic-network", AVAX: "avalanche-2", LINK: "chainlink",
  LTC: "litecoin", BCH: "bitcoin-cash", ATOM: "cosmos", XLM: "stellar",
  ETC: "ethereum-classic",
};

export function coinGeckoId(ticker: string): string {
  const upper = ticker.trim().toUpperCase();
  return COIN_GECKO_IDS[upper] ?? ticker.trim().toLowerCase();
}

/** Sub-unit listing currencies (London pence, Tel Aviv agorot, Johannesburg cents). */
function normalizeQuoteCurrency(raw: string): { currency: string; factor: number } {
  if (raw === "GBp" || raw === "GBX") return { currency: "GBP", factor: 0.01 };
  if (raw === "ILA" || raw === "ILa") return { currency: "ILS", factor: 0.01 };
  if (raw === "ZAc" || raw === "ZAC") return { currency: "ZAR", factor: 0.01 };
  return { currency: raw.toUpperCase(), factor: 1 };
}

const fail = (status: number, code: PriceErrorCode): PriceResult => ({ ok: false, status, code });

async function convertQuote(
  price: number,
  from: string,
  to: string,
  source: PriceSource,
  rates: () => Promise<FxRates>,
): Promise<PriceResult> {
  if (from === to) return { ok: true, price, source, quoteCurrency: from };
  const fx = await rates();
  // A cached price lives 30 minutes / a day; never bake a stale fallback
  // rate into it.
  if (!fx.live) return fail(503, "fx_unavailable");
  const converted = tryConvertCurrency(price, from, to, fx.rates);
  if (converted === null || !Number.isFinite(converted) || converted < 0) {
    return fail(422, "currency_unsupported");
  }
  return { ok: true, price: converted, source, quoteCurrency: from };
}

export async function fetchTwelveDataQuote(
  ticker: string,
  assetCurrency: string,
  deps: PriceDeps = {},
): Promise<PriceResult> {
  const fetchImpl = deps.fetchImpl ?? fetch;
  const apiKey = deps.twelveDataApiKey ?? Deno.env.get("TWELVE_DATA_API_KEY") ?? "";
  if (!apiKey) return fail(503, "provider_not_configured");
  const symbol = encodeURIComponent(ticker.trim().toUpperCase());
  let resp: Response;
  try {
    resp = await fetchImpl(`https://api.twelvedata.com/quote?symbol=${symbol}`, {
      method: "GET",
      headers: { Authorization: `apikey ${apiKey}` },
      signal: AbortSignal.timeout(10_000),
    });
  } catch (err) {
    console.warn(`[prices] twelvedata ${ticker}: ${describeError(err)}`);
    return fail(503, "provider_unavailable");
  }
  if (!resp.ok) {
    console.warn(`[prices] twelvedata ${ticker}: HTTP ${resp.status}`);
    return fail(503, "provider_unavailable");
  }
  const body = await resp.json().catch(() => null) as Record<string, unknown> | null;
  if (!body) return fail(503, "provider_unavailable");
  if (body.status === "error") {
    const code = typeof body.code === "number" ? body.code : 0;
    console.warn(`[prices] twelvedata ${ticker}: provider error ${code}`);
    // 400/404: unknown symbol. 401/403/429 are OUR problem (key, quota).
    return code === 400 || code === 404 ? fail(404, "unknown_ticker") : fail(503, "provider_unavailable");
  }
  const price = Number(body.close ?? body.price);
  if (!Number.isFinite(price) || price < 0) return fail(503, "provider_unavailable");
  const rawCurrency = typeof body.currency === "string" && body.currency ? body.currency : "USD";
  const { currency, factor } = normalizeQuoteCurrency(rawCurrency);
  return await convertQuote(price * factor, currency, assetCurrency.toUpperCase(), "twelvedata", deps.rates ?? getRubRates);
}

export async function fetchCoinGeckoQuote(
  ticker: string,
  assetCurrency: string,
  deps: PriceDeps = {},
): Promise<PriceResult> {
  const fetchImpl = deps.fetchImpl ?? fetch;
  const id = coinGeckoId(ticker);
  const vs = assetCurrency.trim().toLowerCase();
  // Ask for USD too: CoinGecko lacks some fiat codes; then convert USD.
  const vsList = vs === "usd" ? "usd" : `${vs},usd`;
  let resp: Response;
  try {
    resp = await fetchImpl(
      `https://api.coingecko.com/api/v3/simple/price?ids=${encodeURIComponent(id)}&vs_currencies=${encodeURIComponent(vsList)}`,
      { method: "GET", signal: AbortSignal.timeout(10_000) },
    );
  } catch (err) {
    console.warn(`[prices] coingecko ${ticker}: ${describeError(err)}`);
    return fail(503, "provider_unavailable");
  }
  if (!resp.ok) {
    console.warn(`[prices] coingecko ${ticker}: HTTP ${resp.status}`);
    return fail(503, "provider_unavailable");
  }
  const body = await resp.json().catch(() => null) as Record<string, Record<string, number>> | null;
  const inner = body?.[id];
  if (!inner) return fail(404, "unknown_ticker");
  const direct = inner[vs];
  if (typeof direct === "number" && Number.isFinite(direct) && direct >= 0) {
    return { ok: true, price: direct, source: "coingecko", quoteCurrency: vs.toUpperCase() };
  }
  const usd = inner.usd;
  if (typeof usd === "number" && Number.isFinite(usd) && usd >= 0) {
    return await convertQuote(usd, "USD", vs.toUpperCase(), "coingecko", deps.rates ?? getRubRates);
  }
  return fail(422, "currency_unsupported");
}

export const MANUAL_ONLY_KINDS = new Set(["metal", "other"]);

/** Routes by holding kind. `assetCurrency` is the currency the price must be in. */
export async function fetchPriceInCurrency(
  ticker: string,
  kind: string,
  assetCurrency: string,
  deps: PriceDeps = {},
): Promise<PriceResult> {
  return kind === "crypto"
    ? await fetchCoinGeckoQuote(ticker, assetCurrency, deps)
    : await fetchTwelveDataQuote(ticker, assetCurrency, deps);
}
