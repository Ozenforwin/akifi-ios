-- Review 2026-11-27 (D2/V11): a client could insert or edit a message with
-- role = 'assistant' and any `actions` payload. With a write share of a chat,
-- a partner could plant a fake "Akifi" button in the owner's conversation;
-- the owner's tap then ran that action under the owner's identity.
-- Assistant rows are written only by edge functions (service role, which
-- bypasses RLS); neither iOS nor the Mini App inserts into ai_messages.
-- Clients may now write only their own user-role messages without actions.

drop policy if exists "Users can insert messages into accessible conversations" on public.ai_messages;
create policy "Users can insert messages into accessible conversations"
    on public.ai_messages for insert
    with check (
        auth.uid() = user_id
        and has_conversation_write(conversation_id)
        and role = 'user'
        and (actions is null or actions = '[]'::jsonb or actions = 'null'::jsonb)
    );

drop policy if exists ai_messages_update_own on public.ai_messages;
create policy ai_messages_update_own
    on public.ai_messages for update
    using (auth.uid() = user_id and role = 'user')
    with check (
        auth.uid() = user_id
        and has_conversation_write(conversation_id)
        and role = 'user'
        and (actions is null or actions = '[]'::jsonb or actions = 'null'::jsonb)
    );
