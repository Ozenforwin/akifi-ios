export interface OpenAIJsonRequest {
  apiKey: string;
  model: string;
  systemPrompt: string;
  userPrompt: string;
  baseUrl?: string;
  timeoutMs?: number;
  temperature?: number;
}

export interface OpenAIUsage {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
}

export async function createOpenAIJsonCompletion(
  input: OpenAIJsonRequest,
): Promise<{ parsed: Record<string, unknown> | null; raw: string | null; usage: OpenAIUsage | null }> {
  const baseUrl = (input.baseUrl ?? 'https://api.openai.com/v1').replace(/\/$/, '');
  const timeoutMs = Math.max(1500, Number(input.timeoutMs ?? 5000));
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(`${baseUrl}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${input.apiKey}`,
      },
      body: JSON.stringify({
        model: input.model,
        temperature: input.temperature ?? 0,
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: input.systemPrompt },
          { role: 'user', content: input.userPrompt },
        ],
      }),
      signal: controller.signal,
    });

    if (!response.ok) {
      const errorText = await response.text().catch(() => '');
      console.error('openai json completion http error:', response.status, errorText);
      return { parsed: null, raw: null, usage: null };
    }

    const payload = await response.json().catch(() => null) as {
      choices?: Array<{ message?: { content?: string } }>;
      usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number };
    } | null;
    const content = payload?.choices?.[0]?.message?.content;
    if (typeof content !== 'string') {
      return { parsed: null, raw: null, usage: null };
    }

    const usage: OpenAIUsage | null = payload?.usage
      ? {
        prompt_tokens: payload.usage.prompt_tokens ?? 0,
        completion_tokens: payload.usage.completion_tokens ?? 0,
        total_tokens: payload.usage.total_tokens ?? 0,
      }
      : null;

    return { parsed: parseJsonObject(content), raw: content, usage };
  } catch (error) {
    console.error('openai json completion failed:', error);
    return { parsed: null, raw: null, usage: null };
  } finally {
    clearTimeout(timer);
  }
}

// ── Audio transcription via Whisper ──

export interface TranscribeAudioInput {
  apiKey: string;
  baseUrl?: string;
  audioBlob: Blob;
  fileName?: string;
  language?: string;
  timeoutMs?: number;
}

export async function transcribeAudio(
  input: TranscribeAudioInput,
): Promise<{ text: string } | null> {
  const baseUrl = (input.baseUrl ?? 'https://api.openai.com/v1').replace(/\/$/, '');
  const timeoutMs = Math.max(5000, Number(input.timeoutMs ?? 30000));
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const formData = new FormData();
    const safeFileName = (input.fileName ?? '').trim() || 'audio.webm';
    formData.append('file', input.audioBlob, safeFileName);
    formData.append('model', 'whisper-1');
    if (input.language) {
      formData.append('language', input.language);
    }

    const response = await fetch(`${baseUrl}/audio/transcriptions`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${input.apiKey}`,
      },
      body: formData,
      signal: controller.signal,
    });

    if (!response.ok) {
      const errorText = await response.text().catch(() => '');
      console.error('transcribeAudio http error:', response.status, errorText);
      return null;
    }

    const payload = await response.json().catch(() => null) as { text?: string } | null;
    if (!payload?.text || typeof payload.text !== 'string') {
      return null;
    }

    return { text: payload.text.trim() };
  } catch (error) {
    console.error('transcribeAudio failed:', error);
    return null;
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
    const match = trimmed.match(/\{[\s\S]*\}/);
    if (!match) return null;
    try {
      const parsed = JSON.parse(match[0]);
      return typeof parsed === 'object' && parsed !== null ? parsed as Record<string, unknown> : null;
    } catch {
      return null;
    }
  }
}
