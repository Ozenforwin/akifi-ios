import { createOpenAIJsonCompletion } from '../_shared/openai.ts';
import { createAnthropicJsonCompletion } from '../_shared/anthropic.ts';
import type { AiTone, UserAiSettings, SupabaseClient } from './types.ts';

const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY') ?? '';
const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';
const OPENAI_MODEL = Deno.env.get('OPENAI_MODEL') ?? 'gpt-4o-mini';
const NLG_MODEL = ANTHROPIC_API_KEY ? 'claude-haiku-4-5-20251001' : OPENAI_MODEL;
const AI_NLG_MODE = (Deno.env.get('AI_NLG_MODE') ?? 'on') === 'on';

const DEFAULT_SETTINGS: UserAiSettings = {
  tone: 'balanced',
  locale: 'ru-RU',
  timezone: 'Europe/Moscow',
};

export async function loadUserSettings(
  serviceClient: SupabaseClient,
  userId: string,
): Promise<UserAiSettings> {
  try {
    const { data, error } = await serviceClient
      .from('ai_user_settings')
      .select('tone,locale,timezone')
      .eq('user_id', userId)
      .maybeSingle();

    if (error || !data) return DEFAULT_SETTINGS;

    return {
      tone: (['balanced', 'strict', 'friendly'] as const).includes(data.tone) ? data.tone : 'balanced',
      locale: typeof data.locale === 'string' && data.locale ? data.locale : 'ru-RU',
      timezone: typeof data.timezone === 'string' && data.timezone ? data.timezone : 'Europe/Moscow',
    };
  } catch {
    return DEFAULT_SETTINGS;
  }
}

function detectQueryLang(query: string): string {
  if (/[а-яёА-ЯЁ]/.test(query)) return 'Russian';
  if (/[áéíóúñ¿¡üÁÉÍÓÚÑÜ]/.test(query)) return 'Spanish';
  return 'English';
}

export function buildNlgSystemPrompt(tone: AiTone, userQuery: string): string {
  const lang = detectQueryLang(userQuery);
  const base = `You are a financial assistant in a mobile expense tracking app.
You are given a JSON with the user's analytical data. Rephrase the "answer" field.
CRITICAL: You MUST respond ONLY in ${lang}. The user wrote in ${lang}, so your answer MUST be in ${lang}.
Rules:
- Respond ONLY in ${lang} — this is mandatory, ignore the language of the "answer" or "facts" fields
- Do NOT change numbers or amounts — they are already precise
- Do NOT invent data — only use what is given
- Keep the answer to 1-3 sentences
- MANDATORY: if the input JSON has a non-empty "period_label" field, your answer MUST explicitly state the time period (use the value from "period_label" verbatim, or a natural-language equivalent in ${lang}). The user needs to know WHICH time range the numbers refer to. Never output amounts without stating the period.`;

  if (tone === 'strict') {
    return `${base}
- Tone: strict and business-like
- Focus on risks and concrete actions
- No emotions, no pleasantries
- If there is a problem — state it directly
Return JSON: {"answer": "your response in the user's language"}`;
  }

  if (tone === 'friendly') {
    return `${base}
- Tone: warm, supportive, friendly
- Encourage even if results aren't ideal
- You may use informal style
- Add 1 practical tip if appropriate
Return JSON: {"answer": "your response in the user's language"}`;
  }

  // balanced (default)
  return `${base}
- Tone: neutral and helpful, not too dry and not too casual
- You may add 1 practical tip if appropriate
Return JSON: {"answer": "your response in the user's language"}`;
}

export async function nlgRephrase(
  computed: { answer: string; facts: string[] },
  query: string,
  tone: AiTone,
  periodLabelText?: string,
): Promise<string | null> {
  if (!AI_NLG_MODE || (!OPENAI_API_KEY && !ANTHROPIC_API_KEY)) return null;

  try {
    const systemPrompt = buildNlgSystemPrompt(tone, query);
    const userPrompt = JSON.stringify({
      target_language: detectQueryLang(query),
      user_query: query,
      period_label: periodLabelText ?? '',
      answer: computed.answer,
      facts: computed.facts,
    });
    const temp = tone === 'strict' ? 0.15 : tone === 'friendly' ? 0.4 : 0.3;

    const { parsed } = ANTHROPIC_API_KEY
      ? await createAnthropicJsonCompletion({
          apiKey: ANTHROPIC_API_KEY,
          model: NLG_MODEL,
          systemPrompt,
          userPrompt,
          timeoutMs: 5000,
          temperature: temp,
          maxTokens: 1024,
        })
      : await createOpenAIJsonCompletion({
          apiKey: OPENAI_API_KEY,
          model: OPENAI_MODEL,
          systemPrompt,
          userPrompt,
          timeoutMs: 3000,
          temperature: temp,
        });

    const rephrased = parsed?.answer;
    if (typeof rephrased === 'string' && rephrased.trim().length > 10) {
      return rephrased.trim();
    }
    return null;
  } catch {
    return null;
  }
}
