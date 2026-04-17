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
} from './utils.ts';

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
} from './coaching-builders.ts';

import { nlgRephrase, loadUserSettings } from './nlg.ts';
import { buildDataContext } from './data-context-builder.ts';
import { analyzeWithLLM } from './analysis-llm.ts';

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

// Grace period: accept expired JWTs that are less than 2 hours old.
// This eliminates the "session expired" error for users whose iOS app
// sends a slightly stale token (background suspension, race conditions).
const JWT_GRACE_PERIOD_SEC = 2 * 60 * 60; // 2 hours

/**
 * Decode a base64url string (no padding) to a UTF-8 string.
 */
function base64UrlDecode(str: string): string {
  // Replace URL-safe chars and add padding
  let base64 = str.replace(/-/g, '+').replace(/_/g, '/');
  const pad = base64.length % 4;
  if (pad === 2) base64 += '==';
  else if (pad === 3) base64 += '=';
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return new TextDecoder().decode(bytes);
}

/**
 * Verify HMAC-SHA256 signature and extract user ID from a Supabase JWT.
 * Returns the user ID (sub claim) if the signature is valid AND the token
 * is either not expired or expired within the grace period.
 * Returns null if the JWT is malformed, signature is invalid, or too old.
 */
async function verifyJwtManually(token: string): Promise<string | null> {
  if (!SUPABASE_JWT_SECRET) {
    console.warn('[auth] JWT_SECRET not available, cannot verify JWT manually');
    return null;
  }

  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;

    const [headerB64, payloadB64, signatureB64] = parts;

    // Verify HMAC-SHA256 signature
    const encoder = new TextEncoder();
    const keyData = encoder.encode(SUPABASE_JWT_SECRET);
    const key = await crypto.subtle.importKey(
      'raw',
      keyData,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['verify'],
    );

    const signedInput = encoder.encode(`${headerB64}.${payloadB64}`);
    // Decode base64url signature to ArrayBuffer
    let sigB64 = signatureB64.replace(/-/g, '+').replace(/_/g, '/');
    const sigPad = sigB64.length % 4;
    if (sigPad === 2) sigB64 += '==';
    else if (sigPad === 3) sigB64 += '=';
    const sigBinary = atob(sigB64);
    const sigBytes = new Uint8Array(sigBinary.length);
    for (let i = 0; i < sigBinary.length; i++) sigBytes[i] = sigBinary.charCodeAt(i);

    const isValid = await crypto.subtle.verify('HMAC', key, sigBytes, signedInput);
    if (!isValid) {
      console.warn('[auth] JWT signature verification failed');
      return null;
    }

    // Parse payload
    const payload = JSON.parse(base64UrlDecode(payloadB64));
    const sub = payload.sub;
    if (typeof sub !== 'string' || !sub) {
      console.warn('[auth] JWT has no sub claim');
      return null;
    }

    // Check expiry with grace period
    const exp = payload.exp;
    if (typeof exp === 'number') {
      const now = Math.floor(Date.now() / 1000);
      if (now > exp + JWT_GRACE_PERIOD_SEC) {
        console.warn(`[auth] JWT expired ${now - exp}s ago (grace=${JWT_GRACE_PERIOD_SEC}s), rejecting`);
        return null;
      }
      if (now > exp) {
        console.info(`[auth] JWT expired ${now - exp}s ago but within grace period, accepting user ${sub}`);
      }
    }

    return sub;
  } catch (err) {
    console.error('[auth] JWT manual verification error:', err);
    return null;
  }
}

interface ResolveResult {
  userId: string;
  /** true when the token was accepted via grace period (expired but valid signature) */
  viaGracePeriod: boolean;
}

async function resolveUserId(authHeader: string): Promise<ResolveResult | null> {
  // Stage 1: Try standard GoTrue validation (fast path for valid tokens)
  const anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: authHeader } },
  });

  const { data, error } = await anonClient.auth.getUser();
  if (!error && data.user?.id) return { userId: data.user.id, viaGracePeriod: false };

  // Stage 2: GoTrue rejected the token (likely expired JWT).
  // Manually verify signature and accept within grace period.
  console.info(`[auth] GoTrue rejected token (${error?.message ?? 'no user'}), trying manual JWT verification`);
  const token = authHeader.replace(/^bearer\s+/i, '');
  const manualUserId = await verifyJwtManually(token);
  if (manualUserId) return { userId: manualUserId, viaGracePeriod: true };
  return null;
}

function startOfTodayIso(): string {
  const now = new Date();
  return `${now.toISOString().slice(0, 10)}T00:00:00.000Z`;
}

// ── Response cache (in-memory, TTL 5 min, max 200 entries) ──

const CACHE_TTL_MS = 5 * 60 * 1000;
const CACHE_MAX_SIZE = 200;
const responseCache = new Map<string, { payload: unknown; ts: number }>();

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
      .limit(12);

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

Deno.serve(async (req) => {
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

  if (internalSecret && INTERNAL_SECRET && internalSecret === INTERNAL_SECRET && internalUserId) {
    userId = internalUserId;
    anonClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
  } else {
    const authHeader = req.headers.get('authorization') ?? '';
    if (!authHeader.toLowerCase().startsWith('bearer ')) {
      return json({ error: 'Unauthorized', detail: 'Missing bearer token' }, 401);
    }

    const resolveResult = await resolveUserId(authHeader);
    if (!resolveResult) {
      return json({ error: 'Unauthorized', detail: 'Failed to resolve user from token' }, 401);
    }
    userId = resolveResult.userId;

    if (resolveResult.viaGracePeriod) {
      // Token expired but accepted via grace period — use service_role for DB queries
      // since the expired JWT won't pass PostgREST validation.
      console.info(`[auth] User ${userId} authenticated via grace period, using service client`);
      anonClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
        auth: { autoRefreshToken: false, persistSession: false },
      });
    } else {
      anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
        auth: { autoRefreshToken: false, persistSession: false },
        global: { headers: { Authorization: authHeader } },
      });
    }
  }

  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

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

    const { count: todayCount, error: countError } = await serviceClient
      .from('ai_requests')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId)
      .gte('created_at', startOfTodayIso());

    if (countError && countError.code !== '42P01') {
      throw new Error(`Failed to count daily quota: ${countError.message}`);
    }

    if ((todayCount ?? 0) >= AI_DAILY_LIMIT) {
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

    // Load conversation history BEFORE saving user message
    const history = (conversationId && incomingConversationId)
      ? await loadConversationHistory(serviceClient, conversationId, userId)
      : [];

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
    const classification = await classifyIntent(rawQuery, history, userId);
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

    const today = toDateOnly(new Date());
    const currentWindow = getWindow(period, today, customDays);
    const previousWindow = getPreviousWindow(currentWindow);
    const lookbackStart = (intent === 'trend_compare' || intent === 'anomalies')
      ? previousWindow.start
      : (intent === 'seasonal_forecast' || intent === 'recurring_patterns')
        ? addDays(currentWindow.end, -365)
        : (intent === 'spending_optimization' || intent === 'smart_budget_create')
          ? addDays(currentWindow.end, -90)
          : addDays(currentWindow.end, -180);

    // Load account IDs the user has access to (own + shared accounts)
    const { data: memberRows } = await anonClient
      .from('account_members')
      .select('account_id')
      .eq('user_id', userId);
    const accessibleAccountIds = (memberRows ?? []).map((r: { account_id: string }) => r.account_id);

    // Fetch transactions from all accessible accounts
    let txQuery = anonClient
      .from('transactions')
      .select('id,amount,date,type,category_id,account_id,merchant_name,merchant_normalized,transfer_group_id,category:categories(name),description')
      .gte('date', lookbackStart)
      .lte('date', currentWindow.end)
      .order('date', { ascending: false })
      .limit(5000);

    if (accessibleAccountIds.length > 0) {
      txQuery = txQuery.in('account_id', accessibleAccountIds);
    } else {
      txQuery = txQuery.eq('user_id', userId);
    }

    const txWithMerchant = await txQuery;

    let txData: unknown[] | null = txWithMerchant.data as unknown[] | null;
    let txError: { code?: string; message?: string } | null = txWithMerchant.error;

    // Backward-compatible fallback for environments where merchant columns are not migrated yet
    if (
      txError
      && (
        isMissingColumnError(txError, 'merchant_name')
        || isMissingColumnError(txError, 'merchant_normalized')
      )
    ) {
      let fallbackQuery = anonClient
        .from('transactions')
        .select('id,amount,date,type,category_id,account_id,transfer_group_id,category:categories(name),description')
        .gte('date', lookbackStart)
        .lte('date', currentWindow.end)
        .order('date', { ascending: false })
        .limit(5000);

      if (accessibleAccountIds.length > 0) {
        fallbackQuery = fallbackQuery.in('account_id', accessibleAccountIds);
      } else {
        fallbackQuery = fallbackQuery.eq('user_id', userId);
      }

      const txLegacy = await fallbackQuery;
      txData = txLegacy.data as unknown[] | null;
      txError = txLegacy.error;
    }

    if (txError) {
      throw new Error(`Failed to fetch transactions: ${txError.message ?? 'unknown'}`);
    }

    const transactions = (txData ?? []) as TxRow[];

    // Lazy-load categories and accounts only when needed
    let allCategories: CategoryRow[] | null = null;
    let allAccounts: AccountRow[] | null = null;

    async function getCategories(): Promise<CategoryRow[]> {
      if (allCategories !== null) return allCategories;
      const { data } = await anonClient.from('categories').select('id,name,type').eq('user_id', userId).limit(500);
      allCategories = (data ?? []) as CategoryRow[];
      return allCategories;
    }

    async function getAccounts(): Promise<AccountRow[]> {
      if (allAccounts !== null) return allAccounts;
      const { data } = await anonClient.from('accounts').select('id,name,initial_balance,currency').eq('user_id', userId).limit(100);
      allAccounts = ((data ?? []) as Array<AccountRow & { initial_balance?: number }>).map((row) => ({
        id: row.id,
        name: row.name,
        currency: row.currency,
        balance: row.initial_balance ?? row.balance,
      }));

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
          const { data: allTxData } = await anonClient
            .from('transactions')
            .select('account_id,amount,type')
            .in('account_id', accountIds)
            .limit(50000);

          if (allTxData?.length) {
            const incomeByAccount = new Map<string, number>();
            const expenseByAccount = new Map<string, number>();
            for (const tx of allTxData) {
              const accId = tx.account_id;
              if (!accId) continue;
              const amt = Number(tx.amount) || 0;
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
        const { data: budgetData } = await anonClient
          .from('budgets')
          .select('id,amount,category_ids,account_ids,period_type,custom_start_date,custom_end_date,is_active')
          .eq('user_id', userId)
          .eq('is_active', true)
          .limit(20);
        budgets = (budgetData ?? []) as import('./types.ts').BudgetRow[];
      }

      let savingsGoals: Array<{ name: string; target_amount: number; current_amount: number; deadline: string | null; status: string }> = [];
      if (['savings_advice'].includes(intent)) {
        const { data: goalsData } = await anonClient
          .from('savings_goals')
          .select('name,target_amount,current_amount,deadline,status')
          .eq('user_id', userId)
          .eq('status', 'active')
          .limit(20);
        savingsGoals = (goalsData ?? []) as typeof savingsGoals;
      }

      // Build structured data context for LLM
      const dataContext = buildDataContext({
        intent,
        period,
        customDays,
        entity: entity ?? classification.llmEntities?.category ?? classification.llmEntities?.merchant,
        transactions,
        currentWindow,
        previousWindow,
        categories,
        accounts,
        budgets,
        savingsGoals,
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
    } else if (intent === 'create_transaction') {
      const cats = await getCategories();
      computed = buildCreateTransactionResponse(rawQuery, cats, classification.llmEntities);
    } else if (intent === 'edit_transaction') {
      const cats = await getCategories();
      computed = buildEditTransactionResponse(rawQuery, transactions, cats, classification.llmEntities);
    } else if (intent === 'delete_transaction') {
      computed = buildDeleteTransactionResponse(rawQuery, transactions, classification.llmEntities);
    } else if (intent === 'edit_budget') {
      computed = await buildEditBudgetResponse(rawQuery, anonClient, classification.llmEntities, userId);
    } else if (intent === 'savings_advice') {
      computed = await buildSavingsAdviceResponse(anonClient, userId);
    } else if (intent === 'savings_contribute') {
      const { data: goalsData } = await anonClient
        .from('savings_goals')
        .select('id,name,target_amount,current_amount,deadline,status,monthly_target')
        .eq('user_id', userId)
        .eq('status', 'active')
        .limit(20);
      const goals = (goalsData ?? []) as SavingsGoalRow[];
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
    } else {
      // Route ALL unmatched queries through LLM — it handles language detection,
      // greetings, general questions, and responds in the user's language
      const categories = await getCategories();
      const accounts = await getAccounts();
      const dataContext = buildDataContext({
        intent,
        period,
        customDays,
        entity: entity ?? classification.llmEntities?.category ?? classification.llmEntities?.merchant,
        transactions,
        currentWindow,
        previousWindow,
        categories,
        accounts,
      });
      const userSettings = await loadUserSettings(anonClient, userId);
      const llmResult = await analyzeWithLLM(dataContext, rawQuery, history, userSettings.tone, lang);
      if (llmResult.answer) {
        computed = llmResult;
      } else {
        // LLM failed — provide a friendly fallback instead of a template
        computed = {
          answer: t('llmFallbackAnswer', lang),
          facts: [],
          actions: [],
          followUps: followUpsByLang[lang],
        };
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
    ]);
    if (!ACTION_INTENTS.has(intent)) {
      const rephrased = await nlgRephrase(computed, rawQuery, userSettings.tone);
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
});
