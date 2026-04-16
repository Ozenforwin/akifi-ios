/**
 * anthropic.ts — Claude API client for Supabase Edge Functions.
 * Drop-in companion to openai.ts with the same interface.
 */

export interface AnthropicJsonRequest {
  apiKey: string;
  model: string;
  systemPrompt: string;
  userPrompt: string;
  timeoutMs?: number;
  temperature?: number;
  maxTokens?: number;
}

export interface AnthropicUsage {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
}

export async function createAnthropicJsonCompletion(
  input: AnthropicJsonRequest,
): Promise<{ parsed: Record<string, unknown> | null; raw: string | null; usage: AnthropicUsage | null }> {
  const timeoutMs = Math.max(1500, Number(input.timeoutMs ?? 15000));
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': input.apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: input.model,
        max_tokens: input.maxTokens ?? 4096,
        temperature: input.temperature ?? 0,
        system: input.systemPrompt,
        messages: [
          { role: 'user', content: input.userPrompt },
        ],
      }),
      signal: controller.signal,
    });

    if (!response.ok) {
      const errorText = await response.text().catch(() => '');
      console.error('anthropic completion http error:', response.status, errorText);
      return { parsed: null, raw: null, usage: null };
    }

    const payload = await response.json().catch(() => null) as {
      content?: Array<{ type: string; text?: string }>;
      usage?: { input_tokens?: number; output_tokens?: number };
    } | null;

    const textBlock = payload?.content?.find((b) => b.type === 'text');
    const content = textBlock?.text;
    if (typeof content !== 'string') {
      return { parsed: null, raw: null, usage: null };
    }

    const usage: AnthropicUsage | null = payload?.usage
      ? {
        prompt_tokens: payload.usage.input_tokens ?? 0,
        completion_tokens: payload.usage.output_tokens ?? 0,
        total_tokens: (payload.usage.input_tokens ?? 0) + (payload.usage.output_tokens ?? 0),
      }
      : null;

    return { parsed: parseJsonObject(content), raw: content, usage };
  } catch (error) {
    console.error('anthropic completion failed:', error);
    return { parsed: null, raw: null, usage: null };
  } finally {
    clearTimeout(timer);
  }
}

function parseJsonObject(raw: string): Record<string, unknown> | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;

  try {
    const parsed = JSON.parse(trimmed);
    return typeof parsed === 'object' && parsed !== null ? parsed as Record<string, unknown> : null;
  } catch {
    // Claude sometimes wraps JSON in markdown code blocks
    const match = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/) ?? trimmed.match(/\{[\s\S]*\}/);
    const jsonStr = match?.[1] ?? match?.[0];
    if (!jsonStr) return null;
    try {
      const parsed = JSON.parse(jsonStr);
      return typeof parsed === 'object' && parsed !== null ? parsed as Record<string, unknown> : null;
    } catch {
      return null;
    }
  }
}
