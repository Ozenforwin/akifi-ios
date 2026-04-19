/**
 * conversation-summary.ts — rolling memory for long AI chats.
 *
 * The assistant keeps the last ~6 messages live but folds anything older
 * into `ai_conversations.summary`. The summary is refreshed once the
 * total message count grows past the previous fold by `REFRESH_EVERY`
 * messages. Cheap (one Haiku call) and lazy (only runs when warranted).
 */

import { createOpenAIJsonCompletion } from '../_shared/openai.ts';
import { createAnthropicJsonCompletion } from '../_shared/anthropic.ts';
import type { SupabaseClient, ConversationMessage } from './types.ts';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY') ?? '';
const SUMMARY_MODEL_ANTHROPIC = Deno.env.get('SUMMARY_MODEL_ANTHROPIC') ?? 'claude-haiku-4-5-20251001';
const SUMMARY_MODEL_OPENAI = Deno.env.get('SUMMARY_MODEL_OPENAI') ?? 'gpt-4o-mini';

/// Re-summarise once the conversation has gained this many new messages
/// since the previous fold. Tuned so a chatty session triggers ~once a
/// minute rather than per turn.
const REFRESH_EVERY = 10;
/// Live window — messages we always send verbatim alongside the summary.
const LIVE_WINDOW = 6;

const SUMMARY_SYSTEM_PROMPT = `You compress a financial-coaching chat
into a structured running summary so future LLM calls keep context
without re-reading the transcript.

Rules:
- ≤ 250 words, plain prose, in the same language as the chat.
- Preserve durable facts: stated goals, agreed plans, debts/savings the
  user disclosed, decisions, recurring topics, advice already given.
- Drop pleasantries, repeated clarifications, exact wording.
- Refer to the user as "пользователь" / "the user" — no names unless
  the user used one.
- Output JSON: {"summary": "..."}.`;

interface SummaryRow {
  summary: string | null;
  summary_message_count: number;
  total_count: number;
}

/// Returns the existing summary if it's still fresh, otherwise refreshes
/// it from the older portion of the transcript and persists the new value.
/// Always non-blocking on errors — chats keep working without summary.
export async function getOrRefreshSummary(
  serviceClient: SupabaseClient,
  conversationId: string,
  userId: string,
): Promise<string | null> {
  try {
    const meta = await loadMeta(serviceClient, conversationId, userId);
    if (!meta) return null;

    const newSinceFold = meta.total_count - meta.summary_message_count;
    if (meta.summary && newSinceFold < REFRESH_EVERY) {
      return meta.summary;
    }

    // Anything beyond the LIVE_WINDOW is fair game to summarise.
    const toFoldCount = Math.max(0, meta.total_count - LIVE_WINDOW);
    if (toFoldCount === 0) return meta.summary;

    const transcript = await loadOlderMessages(serviceClient, conversationId, userId, toFoldCount);
    if (transcript.length === 0) return meta.summary;

    const fresh = await callSummaryLLM(meta.summary, transcript);
    if (!fresh) return meta.summary;

    await serviceClient
      .from('ai_conversations')
      .update({
        summary: fresh,
        summary_updated_at: new Date().toISOString(),
        summary_message_count: meta.total_count,
      })
      .eq('id', conversationId)
      .eq('user_id', userId);

    return fresh;
  } catch (err) {
    console.error('summary refresh failed:', err);
    return null;
  }
}

async function loadMeta(
  serviceClient: SupabaseClient,
  conversationId: string,
  userId: string,
): Promise<SummaryRow | null> {
  const { data: conv, error: convErr } = await serviceClient
    .from('ai_conversations')
    .select('summary,summary_message_count')
    .eq('id', conversationId)
    .eq('user_id', userId)
    .maybeSingle();
  if (convErr || !conv) return null;

  const { count, error: countErr } = await serviceClient
    .from('ai_messages')
    .select('id', { count: 'exact', head: true })
    .eq('conversation_id', conversationId)
    .eq('user_id', userId)
    .in('role', ['user', 'assistant']);
  if (countErr) return null;

  return {
    summary: (conv as { summary: string | null }).summary ?? null,
    summary_message_count: (conv as { summary_message_count: number }).summary_message_count ?? 0,
    total_count: count ?? 0,
  };
}

/// Load the OLDEST `n` user/assistant messages in chronological order.
async function loadOlderMessages(
  serviceClient: SupabaseClient,
  conversationId: string,
  userId: string,
  n: number,
): Promise<ConversationMessage[]> {
  const { data, error } = await serviceClient
    .from('ai_messages')
    .select('role,content,created_at')
    .eq('conversation_id', conversationId)
    .eq('user_id', userId)
    .in('role', ['user', 'assistant'])
    .order('created_at', { ascending: true })
    .limit(n);
  if (error || !data) return [];
  return (data as Array<{ role: string; content: string }>)
    .filter((m) => m.role === 'user' || m.role === 'assistant')
    .map((m) => ({ role: m.role as 'user' | 'assistant', content: m.content }));
}

async function callSummaryLLM(
  previousSummary: string | null,
  transcript: ConversationMessage[],
): Promise<string | null> {
  const transcriptText = transcript
    .map((m) => `${m.role === 'user' ? 'Пользователь' : 'Ассистент'}: ${m.content.slice(0, 1000)}`)
    .join('\n');

  const userPrompt = previousSummary
    ? `Старый summary:\n${previousSummary}\n\nНовая часть диалога:\n${transcriptText}\n\nОбнови summary с учётом новой части. Верни JSON {"summary": "..."}.`
    : `Сделай summary этой части диалога. Верни JSON {"summary": "..."}.\n\n${transcriptText}`;

  if (ANTHROPIC_API_KEY) {
    const { parsed } = await createAnthropicJsonCompletion({
      apiKey: ANTHROPIC_API_KEY,
      model: SUMMARY_MODEL_ANTHROPIC,
      systemPrompt: SUMMARY_SYSTEM_PROMPT,
      userPrompt,
      temperature: 0.1,
      maxTokens: 600,
      timeoutMs: 6000,
    });
    const v = parsed?.summary;
    if (typeof v === 'string' && v.trim().length > 10) return v.trim();
  }
  if (OPENAI_API_KEY) {
    const { parsed } = await createOpenAIJsonCompletion({
      apiKey: OPENAI_API_KEY,
      model: SUMMARY_MODEL_OPENAI,
      systemPrompt: SUMMARY_SYSTEM_PROMPT,
      userPrompt,
      temperature: 0.1,
      timeoutMs: 6000,
    });
    const v = parsed?.summary;
    if (typeof v === 'string' && v.trim().length > 10) return v.trim();
  }
  return null;
}
