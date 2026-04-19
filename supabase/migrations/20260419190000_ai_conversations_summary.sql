-- Rolling summary memory for long AI assistant chats.
-- Edge function folds older messages into `summary` every N turns so the
-- LLM keeps relevant context past the 6-message live window without
-- re-sending the entire transcript every request.
ALTER TABLE public.ai_conversations
  ADD COLUMN IF NOT EXISTS summary TEXT,
  ADD COLUMN IF NOT EXISTS summary_updated_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS summary_message_count INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.ai_conversations.summary IS
  'LLM-generated summary of messages older than the live window. Refreshed every ~10 user turns.';
COMMENT ON COLUMN public.ai_conversations.summary_message_count IS
  'How many messages were folded into the current summary. Drives the next refresh threshold.';
