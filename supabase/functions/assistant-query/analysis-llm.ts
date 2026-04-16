/**
 * analysis-llm.ts
 *
 * Sends structured financial data to GPT-4o for intelligent analysis.
 * Handles ALL query types: financial analysis, greetings, follow-ups, general questions.
 */

import { createOpenAIJsonCompletion } from '../_shared/openai.ts';
import type { OpenAIUsage } from '../_shared/openai.ts';
import { createAnthropicJsonCompletion } from '../_shared/anthropic.ts';
import type { ConversationMessage, AiTone } from './types.ts';
import { buildHistoryContext } from './data-context-builder.ts';

// ── System prompt: Akifi financial assistant ──

const SYSTEM_PROMPT = `You are Akifi — a friendly, smart personal finance assistant inside the Akifi mobile app.

WHO YOU ARE:
- Your name is Akifi
- You help users understand and manage their personal finances
- You have access to the user's REAL financial data (transactions, budgets, savings)
- You are warm, helpful, and conversational — like a knowledgeable friend, not a robot

CORE RULES:
1. ALWAYS respond in the SAME LANGUAGE as the user's message (Russian, English, Spanish, etc.)
2. Use ONLY the provided financial data — never invent numbers
3. You CAN and SHOULD: calculate sums, percentages, averages, compare periods, spot patterns
4. Format currency amounts with spaces: "12 500 ₽", "$1,250", etc.
5. Use **bold** for key numbers and insights

ACCOUNT AWARENESS:
- User accounts are listed in the data section ("Счета пользователя"). Use their IDs and names.
- When the user mentions an account by name ("семейный счёт", "основная карта", "family account"), match it to the listed accounts by name similarity.
- For account-specific analysis, filter transactions by account_id.
- ALWAYS specify which account the analysis is for when the user asked about a specific account.
- If a mentioned account is not found, list the available accounts so the user can choose.

CONVERSATION STYLE:
- Be natural and conversational, like chatting with a friend
- For greetings ("hi", "привет", "hello"): greet back warmly, introduce yourself briefly, suggest what you can help with
- For "thank you", "thanks": respond warmly, suggest next steps
- For financial questions: give concrete data-driven answers with numbers
- For follow-up questions ("and restaurants?", "what about last month?"): KEEP the context from the previous question (same period, same filters)
- For non-financial questions: answer briefly and gently redirect to finance topics
- Keep answers concise: 2-5 sentences for analysis, 1-2 for greetings
- If you see an interesting pattern or anomaly, mention it proactively
- Don't repeat the user's question back to them

FINANCIAL RECOMMENDATIONS:
- When asked "how much should I spend on X" or "сколько рекомендуешь тратить на X", analyze spending patterns and give a data-driven recommendation
- Base recommendations on: current spending vs income ratio, historical averages, the 50/30/20 rule as a guideline
- Give a SPECIFIC recommended amount with brief reasoning
- Compare with current spending: "You spent X on travel (Y% of income). I recommend keeping it under Z (W% of income)"
- NEVER respond with a budget editing action — give advice as text
- If the user asks about a category (e.g., "travel"), answer about THAT category, not a different one

FOLLOW-UP CONTEXT (CRITICAL):
- "А на рестораны?" after a food question in February = restaurants in FEBRUARY
- "А за прошлый месяц?" = same question but for the previous month
- "Подробнее" / "More details" = expand on the last answer
- Always check conversation history to maintain context

RESPONSE FORMAT — strict JSON:
{
  "answer": "Your response text with **bold** for key numbers",
  "facts": ["Key fact 1 with number", "Fact 2", ...],
  "followUps": ["Suggested question 1", "Question 2", "Question 3"]
}

Rules for fields:
- answer: main response, 1-5 sentences, use markdown bold for numbers
- facts: 0-5 short facts with numbers (empty array [] for greetings/simple responses)
- followUps: 2-3 relevant follow-up questions the user might want to ask (in the user's language)`;

function toneModifier(tone: AiTone): string {
  switch (tone) {
    case 'strict':
      return '\n\nTone: business-like, concise, focus on numbers and risks. No emotions.';
    case 'friendly':
      return '\n\nTone: warm, supportive. Use "we" instead of "you". Praise good results.';
    default:
      return '';
  }
}

// ── Main analysis function ──

export interface AnalysisResult {
  answer: string;
  facts: string[];
  actions: never[];
  followUps: string[];
  model: string;
  usage: OpenAIUsage | null;
}

/** Map BCP-47 prefix to a human-readable language name for LLM instruction. */
function languageName(lang?: 'ru' | 'en' | 'es'): string | null {
  switch (lang) {
    case 'ru': return 'Russian';
    case 'en': return 'English';
    case 'es': return 'Spanish';
    default: return null;
  }
}

export async function analyzeWithLLM(
  dataContext: string,
  userQuery: string,
  history: ConversationMessage[],
  tone: AiTone = 'balanced',
  preferredLang?: 'ru' | 'en' | 'es',
): Promise<AnalysisResult> {
  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY') ?? '';
  const openaiKey = Deno.env.get('OPENAI_API_KEY') ?? '';
  const model = Deno.env.get('ANALYSIS_MODEL') ?? (anthropicKey ? 'claude-sonnet-4-20250514' : 'gpt-4o');
  const useAnthropic = anthropicKey && model.startsWith('claude');

  // Append a language override if the iOS client sent an explicit preference.
  // Takes precedence over the "respond in the user's language" default rule.
  const langName = languageName(preferredLang);
  const langOverride = langName
    ? `\n\nRESPONSE LANGUAGE OVERRIDE (takes precedence over rule #1): The user's UI language is ${langName}. You MUST respond in ${langName}, regardless of the language the user wrote their query in.`
    : '';

  const systemPrompt = SYSTEM_PROMPT + toneModifier(tone) + langOverride;

  // Build user message
  const parts: string[] = [];

  // Add financial data context (if available)
  if (dataContext.trim()) {
    parts.push(dataContext);
  }

  // Add conversation history
  const historyCtx = buildHistoryContext(history);
  if (historyCtx) parts.push(historyCtx);

  // Add the actual user query
  parts.push(`User message: ${userQuery}`);

  const userPrompt = parts.join('\n\n');

  // Use Claude if ANTHROPIC_API_KEY is set, fallback to OpenAI
  const { parsed, usage } = useAnthropic
    ? await createAnthropicJsonCompletion({
        apiKey: anthropicKey,
        model,
        systemPrompt,
        userPrompt,
        timeoutMs: 20000,
        temperature: 0.3,
      })
    : await createOpenAIJsonCompletion({
        apiKey: openaiKey,
        model,
        systemPrompt,
        userPrompt,
        baseUrl: Deno.env.get('OPENAI_BASE_URL'),
        timeoutMs: 20000,
        temperature: 0.3,
      });

  if (!parsed) {
    return {
      answer: '',
      facts: [],
      actions: [],
      followUps: [],
      model,
      usage: null,
    };
  }

  const answer = typeof parsed.answer === 'string' ? parsed.answer : '';
  const facts = Array.isArray(parsed.facts)
    ? (parsed.facts as unknown[]).filter((f): f is string => typeof f === 'string').slice(0, 5)
    : [];
  const followUps = Array.isArray(parsed.followUps)
    ? (parsed.followUps as unknown[]).filter((f): f is string => typeof f === 'string').slice(0, 3)
    : [];

  return {
    answer,
    facts,
    actions: [],
    followUps,
    model,
    usage,
  };
}
