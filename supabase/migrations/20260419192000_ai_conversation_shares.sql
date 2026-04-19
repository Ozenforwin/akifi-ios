-- Phase 2 plan #20: share AI conversations between users.
-- A conversation owner can grant other Akifi users read or read+write
-- access. RLS makes shared conversations and their messages visible to
-- the recipient without exposing private chats.

CREATE TABLE IF NOT EXISTS public.ai_conversation_shares (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES public.ai_conversations(id) ON DELETE CASCADE,
  shared_by_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  shared_with_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  permission TEXT NOT NULL CHECK (permission IN ('read', 'write')) DEFAULT 'read',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (conversation_id, shared_with_user_id)
);

CREATE INDEX IF NOT EXISTS idx_ai_conversation_shares_conv
  ON public.ai_conversation_shares(conversation_id);
CREATE INDEX IF NOT EXISTS idx_ai_conversation_shares_with
  ON public.ai_conversation_shares(shared_with_user_id);

ALTER TABLE public.ai_conversation_shares ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Members of a share can view it" ON public.ai_conversation_shares;
CREATE POLICY "Members of a share can view it"
  ON public.ai_conversation_shares
  FOR SELECT
  USING (auth.uid() = shared_by_user_id OR auth.uid() = shared_with_user_id);

DROP POLICY IF EXISTS "Owner can create shares" ON public.ai_conversation_shares;
CREATE POLICY "Owner can create shares"
  ON public.ai_conversation_shares
  FOR INSERT
  WITH CHECK (
    auth.uid() = shared_by_user_id
    AND EXISTS (
      SELECT 1 FROM public.ai_conversations c
      WHERE c.id = conversation_id AND c.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Sharer or recipient can revoke" ON public.ai_conversation_shares;
CREATE POLICY "Sharer or recipient can revoke"
  ON public.ai_conversation_shares
  FOR DELETE
  USING (auth.uid() = shared_by_user_id OR auth.uid() = shared_with_user_id);

CREATE OR REPLACE FUNCTION public.has_conversation_access(p_conv_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.ai_conversations c
    WHERE c.id = p_conv_id AND c.user_id = auth.uid()
  ) OR EXISTS (
    SELECT 1 FROM public.ai_conversation_shares s
    WHERE s.conversation_id = p_conv_id AND s.shared_with_user_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION public.has_conversation_write(p_conv_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.ai_conversations c
    WHERE c.id = p_conv_id AND c.user_id = auth.uid()
  ) OR EXISTS (
    SELECT 1 FROM public.ai_conversation_shares s
    WHERE s.conversation_id = p_conv_id
      AND s.shared_with_user_id = auth.uid()
      AND s.permission = 'write'
  );
$$;

DROP POLICY IF EXISTS "Users can view messages in their conversations" ON public.ai_messages;
DROP POLICY IF EXISTS "Users can view messages in shared conversations" ON public.ai_messages;
CREATE POLICY "Users can view messages in shared conversations"
  ON public.ai_messages
  FOR SELECT
  USING (
    auth.uid() = user_id
    OR public.has_conversation_access(conversation_id)
  );

DROP POLICY IF EXISTS "Users can insert their own ai_messages" ON public.ai_messages;
DROP POLICY IF EXISTS "Users can insert messages into accessible conversations" ON public.ai_messages;
CREATE POLICY "Users can insert messages into accessible conversations"
  ON public.ai_messages
  FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND public.has_conversation_write(conversation_id)
  );

DROP POLICY IF EXISTS "Users can view their own ai_conversations" ON public.ai_conversations;
DROP POLICY IF EXISTS "Users can view accessible ai_conversations" ON public.ai_conversations;
CREATE POLICY "Users can view accessible ai_conversations"
  ON public.ai_conversations
  FOR SELECT
  USING (
    auth.uid() = user_id
    OR public.has_conversation_access(id)
  );
