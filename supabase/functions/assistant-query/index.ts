// deno-lint-ignore-file
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.95.3';
import {
  sanitizeAssistantResponse,
  type AssistantAction,
  type AnomalyEvidence,
  type RecommendedAction,
} from '../_shared/assistant-schema.ts';

import type {
  AssistantQueryRequest,
  TxRow,
  CategoryRow,
  AccountRow,
  SavingsGoalRow,
  ConversationMessage,
  SupabaseClient,
} from './types.ts';

import {
  normalizeText,
  normalizeForMatch,
  isMissingColumnError,
  toDateOnly,
  addDays,
  getWindow,
  getPreviousWindow,
  periodLabel,
} from './utils.ts';

import {
  enrichTransactions,
  accountsMap,
  fxRatesMap,
  type TxMathRow,
} from '../_shared/transaction-math.ts';
import { timingSafeEqual } from '../_shared/auth.ts';
import { fetchAll, fetchAllIn } from '../_shared/paging.ts';
import { getRubRates, toUsdPivot } from '../_shared/fx.ts';
import { localDate, resolveTimeZone } from '../_shared/timezone.ts';
import { createRequestContext, requestContext, runWithRequestContext } from './request-context.ts';
import { graceEligibleSub, type Jwk, verifyJwtSignature } from './jwt.ts';

/**
 * FX rates baked into the edge function as a last-resort fallback.
 * iOS is expected to send fresh rates in `context_json.fx_rates`; this
 * table exists so Telegram-bot / cron callers and failing-to-parse
 * contexts don't silently regress to 1:1 conversion (the VND-as-RUB
 * bug). USD-pivoted: values are units of `code` per 1 USD. Update
 * when substantially stale — the keys mirror `CurrencyCode` in iOS.
 */
const DEFAULT_FX_RATES: Record<string, number> = {
  USD: 1.0,
  RUB: 92.5,
  EUR: 0.92,
  GBP: 0.79,
  CNY: 7.24,
  JPY: 154.5,
  VND: 25_400,
  THB: 36.5,
  IDR: 16_300,
};

import { parseIntentAndPeriod, classifyIntent } from './intent-parser.ts';

import {
  buildSpendSummaryResponse,
  buildTopCategoriesResponse,
  buildTopExpensesResponse,
  buildTrendCompareResponse,
  buildBudgetRiskResponse,
  buildByCategoryResponse,
  buildByAccountResponse,
  buildBudgetRemainingResponse,
  buildAverageCheckResponse,
  buildForecastResponse,
  buildAnomaliesResponse,
  buildCreateTransactionResponse,
  buildEditTransactionResponse,
  buildDeleteTransactionResponse,
  buildEditBudgetResponse,
  buildSeasonalForecastResponse,
  buildSavingsAdviceResponse,
  buildSavingsContributeResponse,
  buildRecurringPatternsResponse,
  buildSmartBudgetCreateResponse,
  buildSpendingOptimizationResponse,
  helpResponse,
} from './response-builders.ts';

import {
  buildFinancialAdviceResponse,
  buildImpulseCheckResponse,
  buildDebtStrategyResponse,
  buildSavingsPlanResponse,
  buildBudgetOptimizationResponse,
  buildFinancialStageResponse,
  buildInvestmentBasicsResponse,
  buildFinancialSafetyResponse,
  buildHabitCheckResponse,
  buildBookRecommendationsResponse,
} from './coaching-builders.ts';

import { nlgRephrase, loadUserSettings } from './nlg.ts';
import { buildDataContext } from './data-context-builder.ts';
import { analyzeWithLLM } from './analysis-llm.ts';
import { runToolAgent } from './tool-agent.ts';
import { getOrRefreshSummary } from './conversation-summary.ts';

// ── Environment variables ──

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const SUPABASE_JWT_SECRET = Deno.env.get('JWT_SECRET') ?? Deno.env.get('SUPABASE_JWT_SECRET') ?? '';
const AI_DAILY_LIMIT = Math.max(10, Number(Deno.env.get('AI_DAILY_LIMIT') ?? '40'));
const OPENAI_MODEL = Deno.env.get('OPENAI_MODEL') ?? 'gpt-4o-mini';

// ── CORS ──

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// ── i18n: detect user language ──
//
// Priority:
//   1. `response_language` sent by the iOS client (user's explicit UI choice).
//   2. `locale` BCP-47 prefix from the client (e.g. "ru_RU" → "ru").
//   3. Heuristic character detection on the query text.
//   4. English fallback.

type Lang = 'ru' | 'en' | 'es';

function normalizeLang(value: unknown): Lang | null {
  if (typeof value !== 'string' || !value) return null;
  const prefix = value.toLowerCase().split(/[-_]/)[0];
  if (prefix === 'ru' || prefix === 'en' || prefix === 'es') return prefix;
  return null;
}

function detectLang(text: string, ctx?: { response_language?: unknown; locale?: unknown }): Lang {
  const fromCtxExplicit = normalizeLang(ctx?.response_language);
  if (fromCtxExplicit) return fromCtxExplicit;
  const fromLocale = normalizeLang(ctx?.locale);
  if (fromLocale) return fromLocale;
  if (/[а-яёА-ЯЁ]/.test(text)) return 'ru';
  if (/[áéíóúñ¿¡üÁÉÍÓÚÑÜ]/.test(text)) return 'es';
  return 'en';
}

const i18n: Record<string, Record<Lang, string>> = {
  rateLimitAnswer: {
    ru: 'Слишком много запросов. Подождите минуту и попробуйте снова.',
    en: 'Too many requests. Please wait a minute and try again.',
    es: 'Demasiadas solicitudes. Espera un minuto e inténtalo de nuevo.',
  },
  rateLimitFact: {
    ru: 'Лимит: {n} запросов в минуту.',
    en: 'Limit: {n} requests per minute.',
    es: 'Límite: {n} solicitudes por minuto.',
  },
  dailyLimitAnswer: {
    ru: 'На сегодня достигнут лимит AI-запросов ({n}). Попробуйте снова завтра.',
    en: 'Daily AI request limit reached ({n}). Please try again tomorrow.',
    es: 'Se alcanzó el límite diario de solicitudes AI ({n}). Inténtalo mañana.',
  },
  dailyLimitFact: {
    ru: 'Лимит защищает стабильность и стоимость сервиса.',
    en: 'The limit protects service stability and cost.',
    es: 'El límite protege la estabilidad y el costo del servicio.',
  },
  clarifyAnswer: {
    ru: 'Я не совсем понял ваш запрос. Попробуйте один из вариантов:',
    en: "I didn't quite understand your request. Try one of these:",
    es: 'No entendí bien tu solicitud. Prueba una de estas opciones:',
  },
  llmFallbackAnswer: {
    ru: 'Не удалось обработать запрос. Попробуйте ещё раз через несколько секунд.',
    en: "I'm having trouble processing your request right now. Please try again in a moment.",
    es: 'Tengo problemas para procesar tu solicitud. Inténtalo de nuevo en un momento.',
  },
  errorFallbackAnswer: {
    ru: 'Не удалось обработать запрос. Попробуйте еще раз через несколько секунд.',
    en: 'Failed to process the request. Please try again in a few seconds.',
    es: 'No se pudo procesar la solicitud. Inténtalo de nuevo en unos segundos.',
  },
  errorFallbackFact: {
    ru: 'Если ошибка повторяется, переформулируйте запрос короче.',
    en: 'If the error persists, try rephrasing your question.',
    es: 'Si el error persiste, intenta reformular tu pregunta.',
  },
  openTransactions: {
    ru: 'Открыть транзакции',
    en: 'Open transactions',
    es: 'Abrir transacciones',
  },
};

const followUpsByLang: Record<Lang, string[]> = {
  ru: ['Сколько я потратил за месяц?', 'Покажи топ категорий', 'Сравни с прошлым месяцем'],
  en: ['How much did I spend this month?', 'Show my top categories', 'Compare with last month'],
  es: ['¿Cuánto gasté este mes?', 'Muestra mis categorías principales', 'Compara con el mes pasado'],
};

const clarifyFollowUpsByLang: Record<Lang, string[]> = {
  ru: ['Сколько я потратил за месяц?', 'Дай финансовый совет', 'Помоги с бюджетом'],
  en: ['How much did I spend this month?', 'Give me financial advice', 'Help me with my budget'],
  es: ['¿Cuánto gasté este mes?', 'Dame un consejo financiero', 'Ayúdame con mi presupuesto'],
};

function t(key: string, lang: Lang, vars?: Record<string, string | number>): string {
  let str = i18n[key]?.[lang] ?? i18n[key]?.['en'] ?? key;
  if (vars) {
    for (const [k, v] of Object.entries(vars)) {
      str = str.replace(`{${k}}`, String(v));
    }
  }
  return str;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// ── Auth helper ──
//
// Normal path: GoTrue validates the bearer (`auth.getUser()`) and every
// query runs as that user, under RLS.
//
// Grace path (S10) — for an iOS token that expired moments ago. It used to
// accept ANY token GoTrue rejected (sign-out, revoked session) if its HS256
// signature verified, and then queried with an unscoped service-role
// client. Now a token is accepted only when ALL of these hold:
//   1. its signature verifies (ES256 via the project JWKS — the key the
//      project signs user tokens with — or HS256 when JWT_SECRET is set);
//   2. it is EXPIRED, by at most 2 h (a token GoTrue rejects while still
//      valid was revoked or forged — never graced); role = authenticated;
//   3. the user still exists and is not banned;
//   4. its session is still alive: RPC `auth_session_is_active(session_id)`
//      (SECURITY DEFINER, service_role only). Until that RPC exists the
//      grace path stays closed — fail closed, the client refreshes + retries.
// Grace-path requests then use the service client, but every query in this
// function and its builders is explicitly scoped by the verified user id
// (user_id / account_members / budget_members filters; audited 2026-11-17).

const JWKS_TTL_MS = 10 * 60 * 1000;
let jwksCache: { keys: Jwk[]; at: number } | null = null;

async function loadJwks(): Promise<Jwk[]> {
  if (jwksCache && Date.now() - jwksCache.at < JWKS_TTL_MS) return jwksCache.keys;
  let keys: Jwk[] = [];
  const raw = Deno.env.get('SUPABASE_JWKS');
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      keys = Array.isArray(parsed) ? parsed : (Array.isArray(parsed?.keys) ? parsed.keys : []);
    } catch {
      console.warn('[auth] SUPABASE_JWKS is not valid JSON');
    }
  }
  if (keys.length === 0 && SUPABASE_URL) {
    try {
      const res = await fetch(`${SUPABASE_URL}/auth/v1/.well-known/jwks.json`, { signal: AbortSignal.timeout(5000) });
      if (res.ok) keys = ((await res.json())?.keys ?? []) as Jwk[];
    } catch {
      console.warn('[auth] JWKS fetch failed');
    }
  }
  jwksCache = { keys, at: Date.now() };
  return keys;
}

async function verifyGraceToken(token: string, serviceClient: SupabaseClient): Promise<string | null> {
  const claims = await verifyJwtSignature(token, { jwks: loadJwks, hmacSecret: SUPABASE_JWT_SECRET || undefined });
  if (!claims) return null;
  const sub = graceEligibleSub(claims, Math.floor(Date.now() / 1000));
  if (!sub) return null;

  const { data: userData, error: userError } = await serviceClient.auth.admin.getUserById(sub);
  const user = userData?.user as { banned_until?: string | null; deleted_at?: string | null } | undefined;
  if (userError || !user) return null;
  if (user.deleted_at) return null;
  if (user.banned_until && Date.parse(user.banned_until) > Date.now()) return null;

  // bounded-fetch: RPC returns one boolean
  const { data: alive, error: sessionError } = await serviceClient.rpc('auth_session_is_active', {
    p_session_id: claims.session_id,
  });
  if (sessionError) {
    console.warn('[auth] grace path unavailable: session check failed');
    return null;
  }
  return alive === true ? sub : null;
}

interface ResolveResult {
  userId: string;
  /** true when the token was accepted via grace period (expired but valid signature) */
  viaGracePeriod: boolean;
}

async function resolveUserId(authHeader: string, serviceClient: SupabaseClient): Promise<ResolveResult | null> {
  // Stage 1: standard GoTrue validation (valid, unrevoked tokens).
  const anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: authHeader } },
  });

  const { data, error } = await anonClient.auth.getUser();
  if (!error && data.user?.id) return { userId: data.user.id, viaGracePeriod: false };

  // Stage 2: strictly an expired-but-genuine token (see above).
  const token = authHeader.replace(/^bearer\s+/i, '').trim();
  const graceUserId = await verifyGraceToken(token, serviceClient);
  if (graceUserId) {
    console.info('[auth] accepted an expired token within the grace period');
    return { userId: graceUserId, viaGracePeriod: true };
  }
  return null;
}

/** ISO code check for client-supplied currencies. */
function isCurrencyCode(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z]{3}$/.test(value.trim());
}

// ── Response cache (in-memory, TTL 5 min, max 200 entries) ──

const CACHE_TTL_MS = 5 * 60 * 1000;
const CACHE_MAX_SIZE = 200;
const responseCache = new Map<string, { payload: unknown; ts: number }>();

/** ISO date → «DD.MM.YYYY» for user-facing period labels. */
function fmtRuDate(iso: string): string {
  return iso.split('-').reverse().join('.');
}

function cacheKey(userId: string, intent: string, period: string, entity?: string): string {
  return `${userId}:${intent}:${period}:${entity ?? ''}`;
}

function getCached(key: string): unknown | null {
  const entry = responseCache.get(key);
  if (!entry) return null;
  if (Date.now() - entry.ts > CACHE_TTL_MS) {
    responseCache.delete(key);
    return null;
  }
  return entry.payload;
}

function setCache(key: string, payload: unknown): void {
  if (responseCache.size >= CACHE_MAX_SIZE) {
    const firstKey = responseCache.keys().next().value;
    if (firstKey !== undefined) responseCache.delete(firstKey);
  }
  responseCache.set(key, { payload, ts: Date.now() });
}

// ── Guardrails ──

const MAX_QUERY_LENGTH = 500;
const MIN_QUERY_LENGTH = 2;

function validateQuery(query: string, ctx?: { response_language?: unknown; locale?: unknown }): string | null {
  const l = detectLang(query, ctx);
  if (query.length < MIN_QUERY_LENGTH) {
    return ({ ru: 'Слишком короткий запрос. Опишите вопрос подробнее.', en: 'Query is too short. Please describe your question in more detail.', es: 'La consulta es demasiado corta. Describe tu pregunta con más detalle.' })[l];
  }

  if (query.length > MAX_QUERY_LENGTH) {
    return ({ ru: `Запрос слишком длинный (${query.length} символов, максимум ${MAX_QUERY_LENGTH}). Сформулируйте короче.`, en: `Query is too long (${query.length} characters, max ${MAX_QUERY_LENGTH}). Please shorten it.`, es: `La consulta es demasiado larga (${query.length} caracteres, máximo ${MAX_QUERY_LENGTH}). Acórtala.` })[l];
  }

  const lettersOnly = query.replace(/[^a-zA-Zа-яёА-ЯЁ]/g, '');
  if (lettersOnly.length < 2) {
    return ({ ru: 'Не удалось понять запрос. Попробуйте сформулировать вопрос словами, например: "Сколько потратил за неделю?"', en: "Couldn't understand the query. Try phrasing your question in words, e.g.: \"How much did I spend this week?\"", es: 'No se pudo entender la consulta. Intenta formular tu pregunta con palabras, por ejemplo: "¿Cuánto gasté esta semana?"' })[l];
  }

  if (/(.)\1{9,}/u.test(query)) {
    return ({ ru: 'Запрос содержит повторяющиеся символы. Пожалуйста, задайте конкретный вопрос.', en: 'Query contains repeated characters. Please ask a specific question.', es: 'La consulta contiene caracteres repetidos. Por favor, haz una pregunta específica.' })[l];
  }

  return null;
}

// ── Per-minute rate limiter (in-memory sliding window) ──

const PER_MINUTE_LIMIT = Math.max(3, Number(Deno.env.get('AI_PER_MINUTE_LIMIT') ?? '10'));
const rateBuckets = new Map<string, number[]>();

function isRateLimited(userId: string): boolean {
  const now = Date.now();
  const windowMs = 60_000;
  const timestamps = rateBuckets.get(userId) ?? [];

  const recent = timestamps.filter((ts) => now - ts < windowMs);

  if (recent.length >= PER_MINUTE_LIMIT) {
    rateBuckets.set(userId, recent);
    return true;
  }

  recent.push(now);
  rateBuckets.set(userId, recent);
  return false;
}

// ── Conversation history loader ──

async function loadConversationHistory(
  serviceClient: SupabaseClient,
  conversationId: string | null,
  userId: string,
): Promise<ConversationMessage[]> {
  if (!conversationId) return [];

  try {
    const { data, error } = await serviceClient
      .from('ai_messages')
      .select('role,content,intent,period')
      .eq('conversation_id', conversationId)
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(12); // bounded-fetch: the last 12 turns are the live window by design

    if (error || !data) return [];

    return (data as Array<{ role: string; content: string; intent?: string; period?: string }>)
      .reverse()
      .filter((m) => m.role === 'user' || m.role === 'assistant')
      .map((m) => ({
        role: m.role as 'user' | 'assistant',
        content: m.content,
        ...(m.intent ? { intent: m.intent } : {}),
        ...(m.period ? { period: m.period } : {}),
      }));
  } catch {
    return [];
  }
}

// ── Main handler ──

async function handleRequest(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return json({ error: 'Missing required environment variables' }, 500);
  }

  // ── Authentication: internal (telegram-webhook) or JWT (Mini App) ──
  const internalSecret = req.headers.get('x-internal-secret') ?? '';
  const internalUserId = req.headers.get('x-internal-user-id') ?? '';
  const INTERNAL_SECRET = Deno.env.get('ASSISTANT_INTERNAL_SECRET') ?? '';

  let userId: string;
  let anonClient: SupabaseClient;
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Constant-time secret comparison (global rule); evaluated only when both
  // sides are present.
  const internalAuthorized = !!internalSecret && !!INTERNAL_SECRET && !!internalUserId &&
    await timingSafeEqual(internalSecret, INTERNAL_SECRET);

  if (internalAuthorized) {
    userId = internalUserId;
    anonClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
  } else {
    const authHeader = req.headers.get('authorization') ?? '';
    if (!authHeader.toLowerCase().startsWith('bearer ')) {
      return json({ error: 'Unauthorized', detail: 'Missing bearer token' }, 401);
    }

    const resolveResult = await resolveUserId(authHeader, serviceClient);
    if (!resolveResult) {
      return json({ error: 'Unauthorized', detail: 'Failed to resolve user from token' }, 401);
    }
    userId = resolveResult.userId;

    if (resolveResult.viaGracePeriod) {
      // The expired JWT cannot pass PostgREST; queries below are all
      // explicitly scoped by the verified `userId` (see the auth notes).
      anonClient = serviceClient;
    } else {
      anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
        auth: { autoRefreshToken: false, persistSession: false },
        global: { headers: { Authorization: authHeader } },
      });
    }
  }

  let body: AssistantQueryRequest = {};
  try {
    body = await req.json() as AssistantQueryRequest;
  } catch {
    body = {};
  }

  // iOS sends context as "context_json" (a JSON string), parse it into body.context
  if (!body.context) {
    const rawBody = body as Record<string, unknown>;
    if (typeof rawBody.context_json === 'string') {
      try {
        body.context = JSON.parse(rawBody.context_json) as AssistantQueryRequest['context'];
      } catch { /* ignore malformed JSON */ }
    }
  }

  const rawQuery = typeof body.query === 'string' ? normalizeText(body.query) : '';
  if (!rawQuery) {
    return json({ error: 'Validation error', detail: 'query is required' }, 400);
  }
  const ctxForLang = body.context as { response_language?: unknown; locale?: unknown } | undefined;
  const lang = detectLang(rawQuery, ctxForLang);

  // Request context (D6, M9): the user's LOCAL today — transactions.date is
  // local wall-clock time, and «сегодня» at 06:00 in UTC+7 must not mean
  // yesterday — and the display currency every formatted amount is in.
  const reqCtx = requestContext();
  reqCtx.lang = lang;
  reqCtx.timeZone = await resolveTimeZone(serviceClient, userId, body.context?.timezone);
  reqCtx.today = localDate(new Date(), reqCtx.timeZone);
  if (isCurrencyCode(body.context?.display_currency)) {
    reqCtx.displayCurrency = body.context!.display_currency!.trim().toUpperCase();
  } else {
    const { data: profileRow } = await serviceClient
      .from('profiles')
      .select('default_currency')
      .eq('id', userId)
      .maybeSingle();
    if (isCurrencyCode(profileRow?.default_currency)) {
      reqCtx.displayCurrency = String(profileRow!.default_currency).trim().toUpperCase();
    }
  }

  const incomingConversationId = typeof body.conversation_id === 'string' && body.conversation_id.trim()
    ? body.conversation_id.trim()
    : null;

  // Guardrails: reject invalid prompts early
  const guardrailResult = validateQuery(rawQuery, ctxForLang);
  if (guardrailResult) {
    return json({
      ok: true,
      request_id: null,
      status: 'fallback',
      ...sanitizeAssistantResponse({
        answer: guardrailResult,
        facts: [],
        actions: [{ type: 'open_transactions', label: t('openTransactions', lang) }],
        intent: 'help',
        period: 'month',
      }),
    });
  }

  const source = body.source === 'telegram_bot' || body.source === 'system'
    ? body.source
    : 'mini_app';

  const startedAt = Date.now();
  const normalizedQuery = normalizeForMatch(rawQuery);
  const regexParsed = parseIntentAndPeriod(rawQuery);

  try {
    // Per-minute rate limit
    if (isRateLimited(userId)) {
      const rateLimitResponse = sanitizeAssistantResponse({
        answer: t('rateLimitAnswer', lang),
        facts: [t('rateLimitFact', lang, { n: PER_MINUTE_LIMIT })],
        actions: [{ type: 'open_transactions', label: t('openTransactions', lang) }],
        intent: regexParsed.intent,
        period: regexParsed.period,
      });

      return json({
        ok: true,
        request_id: null,
        status: 'limited',
        ...rateLimitResponse,
      });
    }

    // Daily quota: rolling 24 h, taken atomically before any LLM work
    // (ai_quota_take, migration 20261127190000). The client's time zone no
    // longer decides the window, and parallel requests can't all pass.
    const { data: quota, error: quotaError } = await serviceClient
      .rpc('ai_quota_take', { p_user_id: userId, p_limit: AI_DAILY_LIMIT }); // bounded-fetch: RPC returns one jsonb
    if (quotaError) {
      throw new Error(`Failed to take daily quota: ${quotaError.code ?? 'unknown'}`);
    }

    if ((quota as { allowed?: boolean } | null)?.allowed === false) {
      const limitedResponse = sanitizeAssistantResponse({
        answer: t('dailyLimitAnswer', lang, { n: AI_DAILY_LIMIT }),
        facts: [t('dailyLimitFact', lang)],
        actions: [{ type: 'open_transactions', label: t('openTransactions', lang) }],
        intent: regexParsed.intent,
        period: regexParsed.period,
      });

      const { data: limitedLog } = await serviceClient
        .from('ai_requests')
        .insert({
          user_id: userId,
          source,
          query: rawQuery,
          normalized_query: normalizedQuery,
          intent: regexParsed.intent,
          model: 'deterministic-v1',
          status: 'limited',
          latency_ms: Date.now() - startedAt,
          request_payload: { source, period: regexParsed.period },
          response_payload: limitedResponse,
        })
        .select('id')
        .maybeSingle();

      return json({
        ok: true,
        request_id: limitedLog?.id ?? null,
        status: 'limited',
        ...limitedResponse,
      });
    }

    // Check response cache
    const ck = cacheKey(userId, regexParsed.intent, regexParsed.period, regexParsed.entity);
    const cached = !incomingConversationId ? getCached(ck) : null;
    if (cached && regexParsed.intent !== 'help') {
      const cachedPayload = cached as Record<string, unknown>;
      const { data: cachedLog } = await serviceClient
        .from('ai_requests')
        .insert({
          user_id: userId,
          source,
          query: rawQuery,
          normalized_query: normalizedQuery,
          intent: regexParsed.intent,
          model: 'deterministic-v1-cached',
          status: 'success',
          latency_ms: Date.now() - startedAt,
          request_payload: { source, period: regexParsed.period, cached: true },
          response_payload: cachedPayload,
        })
        .select('id')
        .maybeSingle();

      return json({
        ok: true,
        request_id: cachedLog?.id ?? null,
        conversation_id: null,
        message_id: null,
        status: 'success',
        ...cachedPayload,
      });
    }

    // ── Multi-turn: resolve or create conversation ──
    let conversationId: string | null = incomingConversationId;

    if (conversationId) {
      const { data: existingConv } = await serviceClient
        .from('ai_conversations')
        .select('id')
        .eq('id', conversationId)
        .eq('user_id', userId)
        .maybeSingle();

      if (!existingConv) {
        conversationId = null;
      }
    }

    if (!conversationId) {
      const { data: newConv } = await serviceClient
        .from('ai_conversations')
        .insert({ user_id: userId, source })
        .select('id')
        .single();

      conversationId = newConv?.id ?? null;
    }

    // Load conversation history BEFORE saving user message.
    // `liveHistory` = the last few raw turns. The intent classifier uses
    // these only — they're enough to resolve pronouns / period follow-ups.
    const liveHistory = (conversationId && incomingConversationId)
      ? await loadConversationHistory(serviceClient, conversationId, userId)
      : [];

    // Rolling summary memory — folded older transcript so long chats keep
    // context past the live window. Refreshed lazily inside the helper.
    // Builders / NLG / tool-agent get `history` (summary + live), so they
    // remember decisions and stated goals from earlier in the chat.
    const conversationSummary: string | null = (conversationId && incomingConversationId)
      ? await getOrRefreshSummary(serviceClient, conversationId, userId)
      : null;
    const history: ConversationMessage[] = conversationSummary
      ? [
          { role: 'assistant', content: `Сводка предыдущей части диалога:\n${conversationSummary}` },
          ...liveHistory,
        ]
      : liveHistory;

    // Save user message
    if (conversationId) {
      await serviceClient
        .from('ai_messages')
        .insert({
          conversation_id: conversationId,
          user_id: userId,
          role: 'user',
          content: rawQuery,
        })
        .select('id')
        .single();
    }

    // ── Intent classification (LLM primary + regex fallback) ──
    const classification = await classifyIntent(rawQuery, liveHistory, userId);
    const { intent, period, entity, customDays } = classification;

    // Low-confidence fallback: ask clarifying question instead of generic help
    if (intent === 'help' && classification.confidence < 0.6 && classification.source !== 'regex') {
      const clarifyPayload = sanitizeAssistantResponse({
        answer: t('clarifyAnswer', lang),
        facts: [],
        actions: [],
        intent: 'help',
        period,
        followUps: clarifyFollowUpsByLang[lang],
      });

      const { data: clarifyLog } = await serviceClient
        .from('ai_requests')
        .insert({
          user_id: userId,
          source,
          query: rawQuery,
          normalized_query: normalizedQuery,
          intent: 'help',
          model: 'deterministic-v1',
          status: 'clarify',
          latency_ms: Date.now() - startedAt,
          request_payload: { source, period, classify_confidence: classification.confidence },
          response_payload: clarifyPayload,
        })
        .select('id')
        .maybeSingle();

      return json({
        ok: true,
        request_id: clarifyLog?.id ?? null,
        conversation_id: conversationId,
        message_id: null,
        status: 'success',
        ...clarifyPayload,
      });
    }

    // Load user AI settings for tone personalization
    const userSettings = await loadUserSettings(serviceClient, userId);

    const today = reqCtx.today;
    // Explicit date/range queries («вчера», «7 июля», «в 2025 году»)
    // override the period-derived window — the regex date is exact.
    const currentWindow = classification.explicitDate
      ? { start: classification.explicitDate, end: classification.explicitEndDate ?? classification.explicitDate }
      : getWindow(period, today, customDays);
    const previousWindow = getPreviousWindow(currentWindow);
    const lookbackStart = (intent === 'trend_compare' || intent === 'anomalies')
      ? previousWindow.start
      : (intent === 'seasonal_forecast' || intent === 'recurring_patterns')
        ? addDays(currentWindow.end, -365)
        : (intent === 'spending_optimization' || intent === 'smart_budget_create')
          ? addDays(currentWindow.end, -90)
          : addDays(currentWindow.end, -180);

    // Load account IDs the user has access to (own + shared accounts).
    // Also remember each account's role so we can mark shared accounts in LLM context.
    const memberRows = await fetchAll<{ account_id: string; role: 'owner' | 'editor' | 'viewer' }>(
      'account_members(own)',
      () => anonClient.from('account_members').select('id,account_id,role', { count: 'exact' }).eq('user_id', userId),
    );
    const memberRoleByAccount = new Map<string, 'owner' | 'editor' | 'viewer'>();
    for (const row of (memberRows ?? []) as Array<{ account_id: string; role: 'owner' | 'editor' | 'viewer' }>) {
      memberRoleByAccount.set(row.account_id, row.role);
    }
    const accessibleAccountIds = Array.from(memberRoleByAccount.keys());

    // Load all member user_ids of accessible accounts (used to fetch categories
    // owned by co-members of shared accounts — each user has their own categories).
    const allMemberUserIds = new Set<string>([userId]);
    if (accessibleAccountIds.length > 0) {
      const coMemberRows = await fetchAllIn<{ user_id: string }>(
        'account_members(co)',
        accessibleAccountIds,
        (ids) => anonClient.from('account_members').select('id,user_id', { count: 'exact' }).in('account_id', ids),
      );
      for (const row of (coMemberRows ?? []) as Array<{ user_id: string }>) {
        if (row.user_id) allMemberUserIds.add(row.user_id);
      }
    }

    // Display names of co-members — «сколько потратила Оля» is answerable
    // only when the per-member split in the context carries a real name.
    const memberNames: Record<string, string> = {};
    const coMemberIds = Array.from(allMemberUserIds).filter((id) => id !== userId);
    if (coMemberIds.length > 0) {
      const profileRows = await fetchAllIn<{ id: string; full_name: string | null }>(
        'profiles(co)',
        coMemberIds,
        (ids) => anonClient.from('profiles').select('id,full_name', { count: 'exact' }).in('id', ids),
      );
      for (const row of (profileRows ?? []) as Array<{ id: string; full_name: string | null }>) {
        if (row.full_name) memberNames[row.id] = row.full_name;
      }
    }

    // Fetch transactions from all accessible accounts — the COMPLETE set
    // (ADR-003). `.limit(5000)` never helped: PostgREST's max-rows (1000)
    // still truncated silently, and the shared «Семейный» account alone has
    // ~1 100 rows (M9).
    const TX_COLUMNS = 'id,amount,amount_native,currency,foreign_amount,foreign_currency,fx_rate,date,type,category_id,account_id,user_id,merchant_name,merchant_normalized,transfer_group_id,category:categories(name),description';
    const TX_COLUMNS_LEGACY = 'id,amount,amount_native,currency,foreign_amount,foreign_currency,fx_rate,date,type,category_id,account_id,user_id,transfer_group_id,category:categories(name),description';
    const loadTransactions = (columns: string): Promise<TxRow[]> => {
      const windowed = (q: any) => q
        .gte('date', lookbackStart)
        // `date` is timestamptz; a date-only upper bound casts to midnight
        // and silently drops every transaction ON the window's last day.
        .lt('date', addDays(currentWindow.end, 1))
        .order('date', { ascending: false });
      return accessibleAccountIds.length > 0
        ? fetchAllIn<TxRow>('transactions', accessibleAccountIds, (ids) =>
          windowed(anonClient.from('transactions').select(columns, { count: 'exact' }).in('account_id', ids)))
        : fetchAll<TxRow>('transactions', () =>
          windowed(anonClient.from('transactions').select(columns, { count: 'exact' }).eq('user_id', userId)));
    };

    let txData: TxRow[];
    try {
      txData = await loadTransactions(TX_COLUMNS);
    } catch (txError) {
      // Backward-compatible fallback for environments where merchant columns are not migrated yet
      if (isMissingColumnError(txError, 'merchant_name') || isMissingColumnError(txError, 'merchant_normalized')) {
        txData = await loadTransactions(TX_COLUMNS_LEGACY);
      } else {
        throw new Error(`Failed to fetch transactions: ${(txError as Error)?.message ?? 'unknown'}`);
      }
    }
    // Several account chunks are merged — restore newest-first.
    txData.sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0));

    const rawTransactions = txData;

    // Lazy-load categories and accounts only when needed
    let allCategories: CategoryRow[] | null = null;
    let allAccounts: AccountRow[] | null = null;

    // ADR-001 enrichment: the edge function sums `tx.amount_in_base`
    // everywhere an aggregation used to read `tx.amount`. We resolve
    // the value eagerly here so downstream code never has to hold the
    // FX context. When iOS omits `fx_rates` we fall back to baked-in
    // rates — better than silent 1:1 which re-introduces the VND-as-
    // RUB phantom.
    const displayCurrency = reqCtx.displayCurrency;
    // Rates: the client's (freshest, what the app shows) over live server
    // rates over the baked-in table — so Telegram/system callers without
    // `fx_rates` do not fall back to stale 2026-04 constants.
    const liveRates = await getRubRates();
    const fxRatesSource: Record<string, number> = {
      ...DEFAULT_FX_RATES,
      ...(liveRates.live ? toUsdPivot(liveRates.rates) : {}),
      ...(body.context?.fx_rates ?? {}),
    };
    const fxRates = fxRatesMap(fxRatesSource);

    async function ensureEnrichedTransactions(): Promise<TxRow[]> {
      const accounts = await getAccounts();
      const accountsIndex = accountsMap(
        accounts.map((a) => ({ id: a.id, currency: a.currency ?? null })),
      );
      // TxRow has no index signature; the enrichment only adds amount_in_base.
      return enrichTransactions(
        rawTransactions as unknown as TxMathRow[],
        accountsIndex,
        fxRates,
        displayCurrency,
      ) as unknown as TxRow[];
    }

    let transactions: TxRow[] = rawTransactions;
    try {
      transactions = await ensureEnrichedTransactions();
    } catch (enrichError) {
      // Accounts fetch failure → fall back to raw rows. Aggregation code
      // will still use `amount_native ?? amount` via the fallback chain,
      // so single-currency users remain unaffected.
      console.warn('[assistant-query] FX enrichment failed:', enrichError);
    }

    async function getCategories(): Promise<CategoryRow[]> {
      if (allCategories !== null) return allCategories;
      // Load categories owned by ALL members of accessible accounts.
      // Reason: shared accounts have transactions tagged with categories owned by
      // either user — without co-member categories, names won't resolve and the
      // LLM sees "Другое" instead of "Coffee", breaking by-category answers.
      const memberIds = Array.from(allMemberUserIds);
      allCategories = await fetchAllIn<CategoryRow>('categories', memberIds.length > 0 ? memberIds : [userId], (ids) =>
        anonClient.from('categories').select('id,name,type', { count: 'exact' }).in('user_id', ids));
      return allCategories;
    }

    async function getAccounts(): Promise<AccountRow[]> {
      if (allAccounts !== null) return allAccounts;
      // Load ALL accessible accounts (own + shared via account_members).
      // Previously this filtered by user_id only, so a member like Olya never saw
      // the "Family" account that Vladimir owns and silently got "account not found".
      type AccountDbRow = AccountRow & { initial_balance?: number; user_id?: string; account_type?: string | null };
      const ACCOUNT_COLUMNS = 'id,name,initial_balance,currency,user_id,account_type';
      const data = accessibleAccountIds.length > 0
        ? await fetchAllIn<AccountDbRow>('accounts', accessibleAccountIds, (ids) =>
          anonClient.from('accounts').select(ACCOUNT_COLUMNS, { count: 'exact' }).in('id', ids))
        : await fetchAll<AccountDbRow>('accounts', () =>
          anonClient.from('accounts').select(ACCOUNT_COLUMNS, { count: 'exact' }).eq('user_id', userId));
      // 1.6 «Долги»: a debt account's balance is what someone owes, not
      // money the user has — keep it out of balances and totals.
      allAccounts = data.filter((row) => row.account_type !== 'debt').map((row) => {
        const role = memberRoleByAccount.get(row.id);
        const ownerUserId = row.user_id;
        const isShared = ownerUserId !== undefined && ownerUserId !== userId;
        return {
          id: row.id,
          name: row.name,
          currency: row.currency,
          balance: row.initial_balance ?? row.balance,
          is_shared: isShared,
          owner_user_id: ownerUserId,
          member_role: role,
        };
      });

      // Merge balance/currency from client context if provided (iOS sends computed balances)
      if (body.context?.accounts?.length) {
        const contextMap = new Map(
          body.context.accounts.map((a: { id: string; balance?: number; currency?: string }) => [a.id, a]),
        );
        allAccounts = allAccounts.map((acc) => {
          const ctx = contextMap.get(acc.id);
          if (ctx && ctx.balance !== undefined) {
            return { ...acc, balance: ctx.balance, currency: ctx.currency ?? acc.currency };
          }
          return acc;
        });
      } else {
        // No client context — compute balance from initial_balance + ALL transactions
        // For shared accounts, we need ALL transactions on that account (not just current user's)
        const accountIds = allAccounts.map((a) => a.id);
        if (accountIds.length > 0) {
          // Balance = initial_balance + Σ over the WHOLE history, so the
          // set must be complete (ADR-003) — `.limit(50000)` was capped at
          // 1000 rows by the server.
          const allTxData = await fetchAllIn<{ id: string; account_id: string | null; amount: number | null; amount_native: number | null; type: string }>(
            'transactions.balance',
            accountIds,
            (ids) => anonClient.from('transactions').select('id,account_id,amount,amount_native,type', { count: 'exact' }).in('account_id', ids),
          );

          if (allTxData?.length) {
            const incomeByAccount = new Map<string, number>();
            const expenseByAccount = new Map<string, number>();
            for (const tx of allTxData) {
              const accId = tx.account_id;
              if (!accId) continue;
              // ADR-001: `amount_native` is the canonical balance contributor
              // in the account's own currency. Fall back to legacy `amount`
              // only if the row predates the Phase 1 backfill.
              const amt = Number(tx.amount_native ?? tx.amount) || 0;
              if (tx.type === 'income') {
                incomeByAccount.set(accId, (incomeByAccount.get(accId) ?? 0) + amt);
              } else if (tx.type === 'expense') {
                expenseByAccount.set(accId, (expenseByAccount.get(accId) ?? 0) + amt);
              }
            }
            allAccounts = allAccounts.map((acc) => ({
              ...acc,
              balance: (acc.balance ?? 0) + (incomeByAccount.get(acc.id) ?? 0) - (expenseByAccount.get(acc.id) ?? 0),
            }));
          }
        }
      }

      return allAccounts;
    }

    let computed: {
      answer: string;
      facts: string[];
      actions: AssistantAction[];
      followUps: string[];
      evidence?: AnomalyEvidence[];
      confidence?: number;
      recommendedActions?: RecommendedAction[];
      explainability?: string;
    };

    // ── Analytical intents: LLM-powered analysis with real data ──
    const ANALYTICAL_INTENTS = new Set([
      'spend_summary', 'top_categories', 'top_expenses', 'trend_compare',
      'by_category', 'by_account', 'budget_remaining', 'average_check',
      'forecast', 'anomalies', 'seasonal_forecast', 'recurring_patterns',
      'budget_risk', 'smart_budget_create', 'spending_optimization',
    ]);

    if (ANALYTICAL_INTENTS.has(intent)) {
      // Load supplementary data based on intent
      const categories = await getCategories();
      const accounts = await getAccounts();

      let budgets: import('./types.ts').BudgetRow[] = [];
      if (['budget_remaining', 'budget_risk', 'smart_budget_create'].includes(intent)) {
        const BUDGET_COLS = 'id,name,amount,currency,category_ids,account_ids,period_type,custom_start_date,custom_end_date,is_active';
        budgets = await fetchAll<import('./types.ts').BudgetRow>('budgets', () =>
          anonClient.from('budgets').select(BUDGET_COLS, { count: 'exact' }).eq('user_id', userId).eq('is_active', true));

        // Shared budgets: the app shows budgets the user joined via
        // budget_members — without them «как дела с бюджетом на питание»
        // answered «нет бюджетов» while three cards sat on the Budgets tab.
        const memberBudgetRows = await fetchAll<{ id: string; budget_id: string }>('budget_members', () =>
          anonClient.from('budget_members').select('id,budget_id', { count: 'exact' }).eq('user_id', userId));
        const memberBudgetIds = memberBudgetRows
          .map((r: { budget_id: string }) => r.budget_id)
          .filter((id: string) => !budgets.some((b) => b.id === id));
        if (memberBudgetIds.length > 0) {
          const sharedBudgetData = await fetchAllIn<import('./types.ts').BudgetRow>('budgets.shared', memberBudgetIds, (ids) =>
            anonClient.from('budgets').select(BUDGET_COLS, { count: 'exact' }).in('id', ids).eq('is_active', true));
          budgets = budgets.concat(sharedBudgetData);
        }
      }

      // Subscription tracker rows — the source of truth for «какие у меня
      // подписки»; transaction history alone misses annual/quiet ones.
      let subscriptions: import('./data-context-builder.ts').SubscriptionRow[] = [];
      if (intent === 'recurring_patterns') {
        subscriptions = await fetchAll<import('./data-context-builder.ts').SubscriptionRow>('subscriptions', () =>
          anonClient.from('subscriptions').select('id,service_name,amount,currency,billing_period,status', { count: 'exact' })
            .eq('user_id', userId).eq('status', 'active'));
      }

      let savingsGoals: Array<{ name: string; target_amount: number; current_amount: number; deadline: string | null; status: string }> = [];
      if (['savings_advice'].includes(intent)) {
        savingsGoals = await fetchAll<(typeof savingsGoals)[number]>('savings_goals', () =>
          anonClient.from('savings_goals').select('id,name,target_amount,current_amount,deadline,status', { count: 'exact' })
            .eq('user_id', userId).eq('status', 'active'));
      }

      // FX-converted net worth across accounts — computed here where the
      // rates live, so the LLM never adds USD to RUB itself.
      const accountsTotalBase = accounts.reduce((sum, a) => {
        const bal = Number(a.balance ?? 0);
        if (!Number.isFinite(bal) || bal === 0) return sum;
        const cur = (a.currency ?? displayCurrency).toUpperCase();
        if (cur === displayCurrency) return sum + bal;
        const rateAcc = fxRates.get(cur);
        const rateBase = fxRates.get(displayCurrency);
        if (!rateAcc || !rateBase || rateAcc <= 0) return sum + bal;
        // Not rounded: main units (rounding $0.40 to $0 before summing).
        return sum + bal * (rateBase / rateAcc);
      }, 0);

      // Build structured data context for LLM
      const dataContext = buildDataContext({
        intent,
        period,
        customDays,
        entity: entity ?? classification.llmEntities?.category ?? classification.llmEntities?.merchant ?? undefined,
        transactions,
        currentWindow,
        previousWindow,
        categories,
        accounts,
        budgets,
        savingsGoals,
        subscriptions,
        currentUserId: userId,
        memberNames,
        accountsTotalBase,
      });

      // Load user settings for tone
      const userSettings = await loadUserSettings(anonClient, userId);

      // Call GPT-4o for analysis
      const analysisResult = await analyzeWithLLM(
        dataContext,
        rawQuery,
        history,
        userSettings.tone,
        lang,
      );

      if (analysisResult.answer) {
        // LLM analysis succeeded
        computed = analysisResult;
      } else {
        // Fallback to deterministic builders
        if (intent === 'spend_summary') {
          computed = buildSpendSummaryResponse(transactions, currentWindow, period);
        } else if (intent === 'top_categories') {
          computed = buildTopCategoriesResponse(transactions, currentWindow, period);
        } else if (intent === 'top_expenses') {
          computed = buildTopExpensesResponse(transactions, currentWindow, period);
        } else if (intent === 'trend_compare') {
          computed = buildTrendCompareResponse(transactions, currentWindow, previousWindow);
        } else if (intent === 'budget_risk') {
          computed = await buildBudgetRiskResponse(anonClient, transactions, today, userId);
        } else if (intent === 'by_category') {
          computed = buildByCategoryResponse(transactions, currentWindow, period, entity ?? '', categories, classification.llmEntities);
        } else if (intent === 'by_account') {
          computed = buildByAccountResponse(transactions, currentWindow, period, entity ?? '', accounts, classification.llmEntities);
        } else if (intent === 'budget_remaining') {
          computed = await buildBudgetRemainingResponse(anonClient, transactions, today, userId);
        } else if (intent === 'average_check') {
          computed = buildAverageCheckResponse(transactions, currentWindow, period);
        } else if (intent === 'forecast') {
          computed = buildForecastResponse(transactions, currentWindow, period);
        } else if (intent === 'anomalies') {
          computed = buildAnomaliesResponse(transactions, currentWindow, previousWindow, period);
        } else if (intent === 'seasonal_forecast') {
          computed = buildSeasonalForecastResponse(transactions, today);
        } else if (intent === 'recurring_patterns') {
          computed = buildRecurringPatternsResponse(transactions, today);
        } else if (intent === 'smart_budget_create') {
          computed = buildSmartBudgetCreateResponse(transactions, currentWindow, classification.llmEntities);
        } else if (intent === 'spending_optimization') {
          computed = buildSpendingOptimizationResponse(transactions, currentWindow);
        } else {
          computed = buildSpendSummaryResponse(transactions, currentWindow, period);
        }
      }

      // The user must always see the exact «от и до» range behind any
      // amounts. Appended deterministically — prompts alone drift.
      // spending_optimization aggregates over its own 90-day lookback,
      // not currentWindow, so it keeps its hardcoded label instead.
      if (intent !== 'spending_optimization'
          && computed && Array.isArray(computed.facts) && computed.facts.length > 0) {
        const range = currentWindow.start === currentWindow.end
          ? fmtRuDate(currentWindow.start)
          : `${fmtRuDate(currentWindow.start)} — ${fmtRuDate(currentWindow.end)}`;
        if (!computed.facts.some((f: string) => typeof f === 'string' && f.includes(range))) {
          computed.facts = [...computed.facts, `Период: ${range}`];
        }
      }
    } else if (intent === 'create_transaction') {
      const cats = await getCategories();
      computed = buildCreateTransactionResponse(rawQuery, cats, classification.llmEntities);
    } else if (intent === 'edit_transaction') {
      const cats = await getCategories();
      computed = buildEditTransactionResponse(rawQuery, transactions, cats, classification.llmEntities);
    } else if (intent === 'delete_transaction') {
      computed = buildDeleteTransactionResponse(rawQuery, transactions, classification.llmEntities, userId);
    } else if (intent === 'edit_budget') {
      computed = await buildEditBudgetResponse(rawQuery, anonClient, classification.llmEntities, userId);
    } else if (intent === 'savings_advice') {
      computed = await buildSavingsAdviceResponse(anonClient, userId);
    } else if (intent === 'savings_contribute') {
      const goals = await fetchAll<SavingsGoalRow>('savings_goals', () =>
        anonClient.from('savings_goals').select('id,name,target_amount,current_amount,deadline,status,monthly_target', { count: 'exact' })
          .eq('user_id', userId).eq('status', 'active'));
      computed = buildSavingsContributeResponse(rawQuery, goals, classification.llmEntities);
    } else if (intent === 'financial_advice') {
      computed = await buildFinancialAdviceResponse(serviceClient, userId, transactions, rawQuery, history);
    } else if (intent === 'impulse_check') {
      computed = await buildImpulseCheckResponse(serviceClient, userId, transactions, rawQuery, history);
    } else if (intent === 'debt_strategy') {
      computed = await buildDebtStrategyResponse(serviceClient, userId, transactions, rawQuery, history);
    } else if (intent === 'savings_plan') {
      computed = await buildSavingsPlanResponse(serviceClient, userId, transactions, rawQuery, history);
    } else if (intent === 'budget_optimization') {
      computed = await buildBudgetOptimizationResponse(serviceClient, userId, transactions, rawQuery, history);
    } else if (intent === 'financial_stage') {
      computed = await buildFinancialStageResponse(serviceClient, userId, transactions, rawQuery, history);
    } else if (intent === 'investment_basics') {
      computed = await buildInvestmentBasicsResponse(serviceClient, userId, transactions, rawQuery, history);
    } else if (intent === 'financial_safety') {
      computed = await buildFinancialSafetyResponse(serviceClient);
    } else if (intent === 'habit_check') {
      computed = await buildHabitCheckResponse(serviceClient, userId, transactions, rawQuery, history);
    } else if (intent === 'book_recommendations') {
      computed = await buildBookRecommendationsResponse(serviceClient, userId, transactions, rawQuery, history);
    } else {
      // ADR-002: unmatched queries go through the tool-calling agent first.
      // The agent has deterministic tools (query_transactions / aggregate /
      // calculator / compound_interest …) so free-form computational
      // questions don't have to map to a hard-coded intent.
      const categories = await getCategories();
      const accounts = await getAccounts();
      const userSettingsForAgent = await loadUserSettings(anonClient, userId);
      const agentResult = await runToolAgent(
        rawQuery,
        history,
        {
          transactions,
          accounts,
          categories,
          today,
          // Transactions are enriched into the display currency.
          baseCurrency: displayCurrency,
        },
        { lang, tone: userSettingsForAgent.tone },
      );

      if (agentResult?.answer) {
        computed = {
          answer: agentResult.answer,
          facts: agentResult.toolCallsMade.slice(0, 3).map((c) => `${c.name}(…)`),
          actions: [{ type: 'open_transactions', label: t('openTransactions', lang) }],
          followUps: followUpsByLang[lang],
        };
      } else {
        // Tool-agent unavailable — keep the previous analyseWithLLM path as
        // a last resort. Preserves historical behaviour for greetings /
        // language-detection / etc.
        const dataContext = buildDataContext({
          intent,
          period,
          customDays,
          entity: entity ?? classification.llmEntities?.category ?? classification.llmEntities?.merchant ?? undefined,
          transactions,
          currentWindow,
          previousWindow,
          categories,
          accounts,
        });
        const llmResult = await analyzeWithLLM(dataContext, rawQuery, history, userSettingsForAgent.tone, lang);
        if (llmResult.answer) {
          computed = llmResult;
        } else {
          computed = {
            answer: t('llmFallbackAnswer', lang),
            facts: [],
            actions: [],
            followUps: followUpsByLang[lang],
          };
        }
      }
    }

    const payload = sanitizeAssistantResponse({
      ...computed,
      intent,
      period,
    });

    // Optional NLG: rephrase answer using LLM
    let model = 'deterministic-v1';
    let promptTokens: number | undefined;
    let completionTokens: number | undefined;
    let totalTokens: number | undefined;

    const ACTION_INTENTS = new Set([
      'create_transaction', 'edit_transaction', 'delete_transaction', 'edit_budget', 'savings_contribute', 'help',
      'financial_advice', 'impulse_check', 'debt_strategy', 'savings_plan', 'budget_optimization',
      'financial_stage', 'investment_basics', 'financial_safety', 'habit_check', 'smart_budget_create',
      'book_recommendations',
    ]);
    if (!ACTION_INTENTS.has(intent)) {
      // spending_optimization uses a fixed 90-day window, not the parsed `period`.
      const nlgPeriodLabel = intent === 'spending_optimization'
        ? 'за последние 90 дней'
        : `${periodLabel(period, customDays)} (${currentWindow.start === currentWindow.end
            ? fmtRuDate(currentWindow.start)
            : `${fmtRuDate(currentWindow.start)} — ${fmtRuDate(currentWindow.end)}`})`;
      const rephrased = await nlgRephrase(computed, rawQuery, userSettings.tone, nlgPeriodLabel);
      if (rephrased) {
        payload.answer = rephrased;
        model = `nlg-${OPENAI_MODEL}`;
      }
    }

    // Cache the computed result (skip action intents)
    if (!ACTION_INTENTS.has(intent)) {
      setCache(ck, payload);
    }

    // Save assistant message to conversation
    let assistantMessageId: string | null = null;
    if (conversationId) {
      const { data: assistantMsg } = await serviceClient
        .from('ai_messages')
        .insert({
          conversation_id: conversationId,
          user_id: userId,
          role: 'assistant',
          content: payload.answer,
          intent,
          period,
          actions: payload.actions,
          follow_ups: payload.followUps,
          metadata: {
            facts: payload.facts,
            ...(payload.evidence ? { evidence: payload.evidence } : {}),
            ...(payload.confidence !== undefined ? { confidence: payload.confidence } : {}),
            ...(payload.recommendedActions ? { recommendedActions: payload.recommendedActions } : {}),
            ...(payload.explainability ? { explainability: payload.explainability } : {}),
          },
        })
        .select('id')
        .single();

      assistantMessageId = assistantMsg?.id ?? null;

      if (!incomingConversationId) {
        await serviceClient
          .from('ai_conversations')
          .update({ title: rawQuery.slice(0, 100) })
          .eq('id', conversationId);
      }
    }

    const { data: logRow, error: logError } = await serviceClient
      .from('ai_requests')
      .insert({
        user_id: userId,
        source,
        query: rawQuery,
        normalized_query: normalizedQuery,
        intent,
        model,
        status: 'success',
        latency_ms: Date.now() - startedAt,
        prompt_tokens: promptTokens,
        completion_tokens: completionTokens,
        total_tokens: totalTokens,
        request_payload: {
          source,
          period,
          tone: userSettings.tone,
          nlg: model !== 'deterministic-v1',
          conversation_id: conversationId,
          classify_source: classification.source,
          classify_confidence: classification.confidence,
          classify_llm_latency_ms: classification.llmLatencyMs,
          regex_intent: classification.regexIntent,
          regex_period: classification.regexPeriod,
          classify_tokens: classification.classifyUsage ?? undefined,
        },
        response_payload: payload,
      })
      .select('id')
      .maybeSingle();

    if (logError && logError.code !== '42P01') {
      console.error('assistant-query log insert failed:', logError);
    }

    return json({
      ok: true,
      request_id: logRow?.id ?? null,
      conversation_id: conversationId,
      message_id: assistantMessageId,
      status: 'success',
      ...payload,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error('assistant-query failed:', message);

    try {
      await serviceClient
        .from('ai_requests')
        .insert({
          user_id: userId,
          source,
          query: rawQuery,
          normalized_query: normalizedQuery,
          intent: regexParsed.intent,
          model: 'deterministic-v1',
          status: 'error',
          latency_ms: Date.now() - startedAt,
          error_code: 'assistant_query_failed',
          error_message: message.slice(0, 1000),
          request_payload: { source, period: regexParsed.period },
        })
        .select('id')
        .maybeSingle();
    } catch {
      // ignore logging errors in error handler
    }

    const fallback = sanitizeAssistantResponse({
      answer: t('errorFallbackAnswer', lang),
      facts: [t('errorFallbackFact', lang)],
      actions: [{ type: 'open_transactions', label: t('openTransactions', lang) }],
      intent: regexParsed.intent,
      period: regexParsed.period,
    });

    return json({
      ok: true,
      request_id: null,
      status: 'fallback',
      ...fallback,
    });
  }
}

// Every request runs in its own context (display currency, language, the
// user's local today) — see request-context.ts.
Deno.serve((req) => runWithRequestContext(createRequestContext(), () => handleRequest(req)));
