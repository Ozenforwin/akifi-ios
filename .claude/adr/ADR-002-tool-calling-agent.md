---
type: adr
status: accepted
date: 2026-04-19
tags: [ai-assistant, architecture, tool-calling, llm]
---

# ADR-002 — Tool-calling agent for the AI assistant

## Context

The `assistant-query` edge function classifies every user query into one
of ~32 hard-coded intents (`spend_summary`, `top_categories`,
`financial_advice`, …) and routes to a builder. This works for the queries
we anticipated; everything else falls into `help` with low confidence and
the user sees **«Я не совсем понял ваш запрос»**.

Pain points the user raised:

1. Cannot answer arbitrary computational questions
   («какой % дохода уходит на кофе по выходным», «сколько накоплю если
   откладывать разницу под 12% годовых») — these don't map to any intent
   and the LLM-fallback (`analyzeWithLLM`) hallucinates numbers.
2. Cannot answer reading-list / educational queries reliably without us
   writing a new intent each time (we just had to add
   `book_recommendations`).
3. The user is currently exporting data to ChatGPT to do the math —
   exactly the experience Akifi should replace.

The two-LLM-layer pipeline (intent classifier + NLG rephrase, see
`project_ai_assistant_pipeline`) won't scale; every new question type
needs a new intent + builder + tests.

## Decision

Adopt **tool-calling** (function-calling) as the primary path for free-form
questions. The intent classifier stays as a fast deterministic shortcut
for the well-known queries (which are ~80% of traffic and 100× cheaper
to compute than an LLM call). For the rest:

1. The user query goes to a tool-calling agent (`tool-agent.ts`).
2. The agent has a toolbox of **deterministic** TypeScript functions
   (`tools/`) and the user's already-loaded transactions in scope.
3. The LLM (Anthropic Claude Sonnet preferred, OpenAI gpt-4o fallback)
   plans which tools to call, runs them in a loop (max 5 rounds), and
   composes the final answer from real numbers — never from its own
   arithmetic.
4. Final answer goes through the same `sanitizeAssistantResponse` and
   conversation persistence path as everything else.

### Toolbox (initial set)

| Tool | Purpose |
|------|---------|
| `query_transactions(filters)` | Filter by account / category / merchant / date / weekday / amount |
| `aggregate(rows, {group_by, metric})` | sum / avg / median / count / p90, optional grouping |
| `compare_periods(period_a, period_b, group_by?)` | Δ between two windows |
| `calculator(expression)` | Safe math eval (no `eval`, whitelist of operators) |
| `compound_interest({principal, rate, years, monthly})` | Schedule + total |
| `loan_payment({principal, rate, term_months})` | Monthly + overpay |
| `emergency_fund_status({monthly_expenses, current_savings})` | Months covered / gap |
| `savings_runway({balance, monthly_burn})` | How many months you survive |
| `fx_convert(amount, from, to)` | Reuses existing FX module |

All tools are **pure** — they receive data as arguments, no DB access from
inside. The agent loader fetches transactions/categories/accounts/budgets
once and passes them in.

### Why deterministic tools instead of OpenAI Code Interpreter

- ⚡ TypeScript runs in 5–50 ms inside the existing Deno edge function;
  Code Interpreter adds a second network hop.
- 💰 No extra cost — we already pay for the LLM call.
- 🔒 No arbitrary code execution — the safe-math `calculator` is a
  whitelist parser.
- 🎯 Tools already understand our domain (multi-currency `amount_native`,
  shared accounts via `account_members`, `transfer_group_id` filtering).

## Consequences

### Positive

- New question types no longer require new intents — the LLM picks the
  right tools.
- Numbers in answers are guaranteed to come from tool results; the model
  is instructed that fabricating amounts is a hard rule violation.
- Replaces «Я не совсем понял» with a real answer.
- Foundation for the broader Phase 2 plan (knowledge-base RAG tool,
  conversation summary tool, etc.).

### Negative

- Tool-calling roundtrips add ~1–3 seconds latency vs. a deterministic
  builder. Mitigated by keeping the fast intent path for the top ~32
  queries and only falling back to the agent on miss.
- One more failure mode: the LLM can call tools with bad arguments. We
  log every tool invocation and return structured errors that the LLM
  must handle in its next turn.

### Neutral

- The existing intent classifier and builders stay as-is — this change is
  additive. We can deprecate individual builders later if the agent
  proves consistently better.

## Implementation plan

1. `tools/` module with the nine functions above + Zod-style schemas the
   LLM can read. (#14)
2. `tool-agent.ts` — provider-agnostic loop that prefers Anthropic
   `tool_use` blocks and falls back to OpenAI `tool_choice`. (#15)
3. `index.ts` routes the current `else` (unmatched-intent) branch through
   the agent. Keep `analyzeWithLLM` as second-stage fallback for the
   30-second timeout case. (#16)
4. Eval set (10–20 free-form questions with expected behaviours) before
   we expand the agent's surface area.

## References

- Memory: `project_ai_assistant_pipeline` — the existing two-LLM-layer flow.
- Memory: `project_global_product_no_ru_bias` — content rules for any LLM
  prompt added in the toolbox.
- ADR-001 multi-currency — `fx_convert` tool must respect `amount_native`
  semantics.
