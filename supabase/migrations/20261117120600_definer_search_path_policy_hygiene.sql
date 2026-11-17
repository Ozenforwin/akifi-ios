-- Review item #12 (2026-11-17): SECURITY DEFINER hygiene and duplicate
-- permissive policies that cancelled the strict ones.
--
-- 1) SECURITY DEFINER functions without a pinned search_path resolve
--    unqualified names through the caller's search_path. Their bodies are
--    already schema-qualified except fn_update_savings_goal_amount, which is
--    rewritten with qualified names. Behaviour is otherwise unchanged.
-- 2) category_rules: permissive policies are OR-ed, so the loose
--    "Users can insert own rules" / "Users can update own rules" (user_id
--    only; the UPDATE one without WITH CHECK) made the strict
--    "… own category rules" policies (account access + category type match)
--    meaningless. No client writes category_rules (checked both repos); the
--    one prod row satisfies the strict check. Duplicate SELECT / DELETE
--    policies are equivalent and left alone.
-- 3) ai_messages: "ai_messages_insert_own" (user_id only) cancelled
--    "Users can insert messages into accessible conversations"
--    (has_conversation_write), and "ai_messages_update_own" had no WITH CHECK,
--    so a message could be moved into any conversation id. Messages are written
--    by assistant-query with the service role (bypasses RLS); the app only
--    reads them.

alter function public.get_shared_user_ids() set search_path = public;
alter function public.get_user_account_ids() set search_path = public;
alter function public.handle_new_user() set search_path = public;
alter function public.revoke_account_invite(uuid) set search_path = public;
alter function public.schedule_notifications_inactivity_job(text, text) set search_path = public;
alter function public.schedule_weekly_digest_job(text, text) set search_path = public;
-- schedule_check_subscriptions_job already has search_path = public.

create or replace function public.fn_update_savings_goal_amount()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_goal_id    uuid;
    v_new_amount numeric;
    v_target     numeric;
begin
    if tg_op = 'DELETE' then
        v_goal_id := old.goal_id;
    else
        v_goal_id := new.goal_id;
    end if;

    select coalesce(sum(c.amount), 0) into v_new_amount
      from public.savings_contributions c
     where c.goal_id = v_goal_id;

    select g.target_amount into v_target
      from public.savings_goals g
     where g.id = v_goal_id;

    update public.savings_goals
       set current_amount = v_new_amount,
           status = case
               when v_new_amount >= v_target and status = 'active' then 'completed'
               when v_new_amount < v_target and status = 'completed' then 'active'
               else status
           end,
           completed_at = case
               when v_new_amount >= v_target and status = 'active' then now()
               when v_new_amount < v_target and status = 'completed' then null
               else completed_at
           end
     where id = v_goal_id;

    return coalesce(new, old);
end;
$$;

drop policy if exists "Users can insert own rules" on public.category_rules;
drop policy if exists "Users can update own rules" on public.category_rules;

drop policy if exists "ai_messages_insert_own" on public.ai_messages;
drop policy if exists "ai_messages_update_own" on public.ai_messages;
create policy "ai_messages_update_own" on public.ai_messages
    for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id and public.has_conversation_write(conversation_id));
