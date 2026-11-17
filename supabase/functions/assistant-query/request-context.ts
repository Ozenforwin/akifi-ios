// Per-request settings that ~100 formatting and date call sites need:
// the user's display currency, language and LOCAL "today".
//
// Threading them through every builder signature would touch most of the
// assistant; a module-level variable would leak between concurrent
// requests served by the same isolate. AsyncLocalStorage scopes them to
// one request: `index.ts` runs each request inside `runWithRequestContext`
// and fills the values in once they are known (after auth).

import { AsyncLocalStorage } from "node:async_hooks";

export interface RequestContext {
  /** ISO code amounts are expressed in after FX normalization (`amount_in_base`). */
  displayCurrency: string;
  /** ru / en / es — separators only, never the currency. */
  lang: string;
  /** The user's local calendar date (`yyyy-MM-dd`). */
  today: string;
  /** IANA zone `today` was computed in. */
  timeZone: string;
}

const storage = new AsyncLocalStorage<RequestContext>();

const FALLBACK_CURRENCY = (Deno.env.get("BOT_DEFAULT_CURRENCY") ?? "RUB").toUpperCase();

export function createRequestContext(): RequestContext {
  return {
    displayCurrency: FALLBACK_CURRENCY,
    lang: "ru",
    today: new Date().toISOString().slice(0, 10),
    timeZone: "UTC",
  };
}

export function runWithRequestContext<T>(ctx: RequestContext, fn: () => T): T {
  return storage.run(ctx, fn);
}

/** The mutable context of the current request (a fresh default outside one). */
export function requestContext(): RequestContext {
  return storage.getStore() ?? createRequestContext();
}

export function requestToday(): string {
  return requestContext().today;
}

export function requestCurrency(): string {
  return requestContext().displayCurrency;
}

export function requestLang(): string {
  return requestContext().lang;
}
