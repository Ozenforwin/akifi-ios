/**
 * tool-agent.ts — provider-agnostic tool-calling loop for the assistant.
 *
 * Flow per ADR-002:
 *   1. Send the user's question + tool schemas to the LLM.
 *   2. If the LLM returns text → done.
 *   3. If the LLM returns tool calls → execute them locally, feed
 *      results back, repeat (capped at MAX_ITERATIONS).
 *   4. On any provider error, return null so the caller can fall back to
 *      the deterministic LLM analyser.
 */

import { TOOLS, findTool, type ToolContext } from './tools/registry.ts';
import type { ConversationMessage, AiTone } from './types.ts';

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY') ?? '';
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY') ?? '';
const ANTHROPIC_MODEL = Deno.env.get('TOOL_AGENT_ANTHROPIC_MODEL') ?? 'claude-sonnet-4-6';
const OPENAI_MODEL = Deno.env.get('TOOL_AGENT_OPENAI_MODEL') ?? 'gpt-4o';

const MAX_ITERATIONS = 5;
const REQUEST_TIMEOUT_MS = 25_000; // tool loops can be 2-3x slower than single-shot

export interface ToolAgentResult {
  answer: string;
  toolCallsMade: Array<{ name: string; args: unknown; result: unknown }>;
  iterations: number;
  provider: 'anthropic' | 'openai';
}

const SYSTEM_PROMPT = (lang: string, tone: AiTone, baseCcy: string, today: string) => `\
You are Akifi's financial-analyst assistant. You can call deterministic
TypeScript tools to fetch and compute over the user's real transactions.

LANGUAGE: ${lang === 'ru' ? 'Russian' : lang === 'es' ? 'Spanish' : 'English'} — answer in this language.
TONE: ${toneInstruction(tone)}
TODAY: ${today}
USER BASE CURRENCY: ${baseCcy}

HARD RULES — violating these is worse than refusing:
1. NEVER state a numeric amount, percentage, or count that isn't directly
   from a tool result. If you need a number, call a tool. Doing arithmetic
   in your head is a hard violation — use the \`calculator\` tool.
2. Always reference the time period a number covers
   (e.g. "за апрель", "за последние 3 месяца"). The user must know the window.
3. If the user asks about money mechanics in a specific country (taxes,
   pension instruments, banks), give general principles and remind them
   to verify in their own jurisdiction. Do not invent country-specific
   schemes. Akifi's audience is global.
4. If a tool returns an empty result or an error, say so plainly and
   suggest a refined query — do not fabricate data.
5. Use bold for the key numbers in your final answer.
6. Keep the final answer under 200 words unless the user explicitly
   asked for more detail.

PLANNING:
- Restate the user's question in your head, decide which tools you need,
  call them, then synthesise.
- Prefer one big query_transactions + one aggregate over many small calls.
- For "сколько накоплю если..." use compound_interest, not your head.
- For arbitrary arithmetic ((a-b)/c, %): use calculator.
- For period comparisons: use compare_periods, not two separate aggregates
  + manual subtraction.

When you have enough information, write the final answer as plain text
(no JSON, no extra tool calls).`;

function toneInstruction(tone: AiTone): string {
  switch (tone) {
    case 'strict':   return 'direct and matter-of-fact, like a CFO friend';
    case 'friendly': return 'warm and encouraging, occasional emoji ok';
    case 'balanced': default: return 'professional but approachable, no fluff';
  }
}

// ════════════════════════════════════════════════════════════════════
// Public entry point
// ════════════════════════════════════════════════════════════════════

export async function runToolAgent(
  query: string,
  history: ConversationMessage[],
  ctx: ToolContext,
  options: { lang: string; tone: AiTone },
): Promise<ToolAgentResult | null> {
  if (ANTHROPIC_API_KEY) {
    const result = await runAnthropicAgent(query, history, ctx, options);
    if (result) return result;
  }
  if (OPENAI_API_KEY) {
    return await runOpenAIAgent(query, history, ctx, options);
  }
  return null;
}

// ════════════════════════════════════════════════════════════════════
// Anthropic implementation
// ════════════════════════════════════════════════════════════════════

interface AnthroBlock {
  type: 'text' | 'tool_use';
  text?: string;
  id?: string;
  name?: string;
  input?: Record<string, unknown>;
}

interface AnthroMessage {
  role: 'user' | 'assistant';
  content: string | AnthroBlock[] | Array<{ type: string; [k: string]: unknown }>;
}

async function runAnthropicAgent(
  query: string,
  history: ConversationMessage[],
  ctx: ToolContext,
  options: { lang: string; tone: AiTone },
): Promise<ToolAgentResult | null> {
  const tools = TOOLS.map((t) => ({
    name: t.name,
    description: t.description,
    input_schema: t.parameters,
  }));

  const messages: AnthroMessage[] = [
    ...history.slice(-4).map((m) => ({
      role: m.role as 'user' | 'assistant',
      content: m.content,
    })),
    { role: 'user', content: query },
  ];

  const callsMade: ToolAgentResult['toolCallsMade'] = [];

  for (let iteration = 0; iteration < MAX_ITERATIONS; iteration++) {
    const response = await fetchAnthropic({
      model: ANTHROPIC_MODEL,
      system: SYSTEM_PROMPT(options.lang, options.tone, ctx.baseCurrency, ctx.today),
      messages,
      tools,
      maxTokens: 1500,
    });
    if (!response) return null;

    const assistantBlocks = (response.content as AnthroBlock[]) ?? [];
    messages.push({ role: 'assistant', content: assistantBlocks });

    const toolUses = assistantBlocks.filter((b) => b.type === 'tool_use');
    if (toolUses.length === 0) {
      // Final answer.
      const text = assistantBlocks
        .filter((b) => b.type === 'text')
        .map((b) => b.text ?? '')
        .join('\n')
        .trim();
      if (!text) return null;
      return { answer: text, toolCallsMade: callsMade, iterations: iteration + 1, provider: 'anthropic' };
    }

    // Execute every tool call locally.
    const toolResults: Array<{ type: 'tool_result'; tool_use_id: string; content: string }> = [];
    for (const block of toolUses) {
      const tool = findTool(block.name ?? '');
      let resultText: string;
      let resultValue: unknown;
      if (!tool) {
        resultValue = { error: `unknown tool ${block.name}` };
        resultText = JSON.stringify(resultValue);
      } else {
        try {
          resultValue = tool.run(block.input ?? {}, ctx);
          resultText = JSON.stringify(resultValue, null, 2).slice(0, 8000);
        } catch (err) {
          resultValue = { error: err instanceof Error ? err.message : String(err) };
          resultText = JSON.stringify(resultValue);
        }
      }
      callsMade.push({ name: block.name ?? '?', args: block.input, result: resultValue });
      toolResults.push({
        type: 'tool_result',
        tool_use_id: block.id ?? '',
        content: resultText,
      });
    }

    messages.push({ role: 'user', content: toolResults });
  }

  console.warn('tool-agent: hit max iterations without final answer');
  return null;
}

async function fetchAnthropic(req: {
  model: string;
  system: string;
  messages: AnthroMessage[];
  tools: Array<{ name: string; description: string; input_schema: Record<string, unknown> }>;
  maxTokens: number;
}): Promise<{ content: AnthroBlock[]; stop_reason?: string } | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: req.model,
        max_tokens: req.maxTokens,
        temperature: 0.2,
        system: req.system,
        tools: req.tools,
        messages: req.messages,
      }),
      signal: controller.signal,
    });
    if (!res.ok) {
      console.error('anthropic tool-agent http', res.status, await res.text().catch(() => ''));
      return null;
    }
    return await res.json();
  } catch (err) {
    console.error('anthropic tool-agent error:', err);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// ════════════════════════════════════════════════════════════════════
// OpenAI implementation (fallback)
// ════════════════════════════════════════════════════════════════════

async function runOpenAIAgent(
  query: string,
  history: ConversationMessage[],
  ctx: ToolContext,
  options: { lang: string; tone: AiTone },
): Promise<ToolAgentResult | null> {
  const tools = TOOLS.map((t) => ({
    type: 'function' as const,
    function: {
      name: t.name,
      description: t.description,
      parameters: t.parameters,
    },
  }));

  type OAMsg =
    | { role: 'system' | 'user' | 'assistant'; content: string | null; tool_calls?: Array<{ id: string; type: 'function'; function: { name: string; arguments: string } }> }
    | { role: 'tool'; content: string; tool_call_id: string };

  const messages: OAMsg[] = [
    { role: 'system', content: SYSTEM_PROMPT(options.lang, options.tone, ctx.baseCurrency, ctx.today) },
    ...history.slice(-4).map((m) => ({ role: m.role as 'user' | 'assistant', content: m.content })),
    { role: 'user', content: query },
  ];

  const callsMade: ToolAgentResult['toolCallsMade'] = [];

  for (let iteration = 0; iteration < MAX_ITERATIONS; iteration++) {
    const response = await fetchOpenAI({ messages, tools });
    if (!response) return null;

    const choice = response.choices?.[0]?.message;
    if (!choice) return null;

    if (choice.tool_calls?.length) {
      messages.push({
        role: 'assistant',
        content: choice.content ?? null,
        tool_calls: choice.tool_calls,
      });

      for (const call of choice.tool_calls) {
        const tool = findTool(call.function.name);
        let resultValue: unknown;
        let resultText: string;
        let parsedArgs: Record<string, unknown> = {};
        try {
          parsedArgs = JSON.parse(call.function.arguments || '{}');
        } catch {
          parsedArgs = {};
        }
        if (!tool) {
          resultValue = { error: `unknown tool ${call.function.name}` };
          resultText = JSON.stringify(resultValue);
        } else {
          try {
            resultValue = tool.run(parsedArgs, ctx);
            resultText = JSON.stringify(resultValue, null, 2).slice(0, 8000);
          } catch (err) {
            resultValue = { error: err instanceof Error ? err.message : String(err) };
            resultText = JSON.stringify(resultValue);
          }
        }
        callsMade.push({ name: call.function.name, args: parsedArgs, result: resultValue });
        messages.push({ role: 'tool', tool_call_id: call.id, content: resultText });
      }
      continue;
    }

    const text = (choice.content ?? '').trim();
    if (!text) return null;
    return { answer: text, toolCallsMade: callsMade, iterations: iteration + 1, provider: 'openai' };
  }

  console.warn('tool-agent (openai): hit max iterations');
  return null;
}

interface OpenAIChatResponse {
  choices?: Array<{
    message: {
      role: string;
      content: string | null;
      tool_calls?: Array<{ id: string; type: 'function'; function: { name: string; arguments: string } }>;
    };
  }>;
}

async function fetchOpenAI(req: {
  messages: unknown[];
  tools: unknown[];
}): Promise<OpenAIChatResponse | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const res = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        temperature: 0.2,
        tools: req.tools,
        tool_choice: 'auto',
        messages: req.messages,
      }),
      signal: controller.signal,
    });
    if (!res.ok) {
      console.error('openai tool-agent http', res.status, await res.text().catch(() => ''));
      return null;
    }
    return await res.json();
  } catch (err) {
    console.error('openai tool-agent error:', err);
    return null;
  } finally {
    clearTimeout(timer);
  }
}
