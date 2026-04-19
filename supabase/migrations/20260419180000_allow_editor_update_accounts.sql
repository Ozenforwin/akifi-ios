-- Allow editor members (account_members.role IN ('owner','editor')) to UPDATE
-- shared accounts. Previously the policy in
-- Akifi/supabase/migrations/20260213000003_fix_rls_with_security_definer.sql:94-96
-- restricted UPDATE to the original owner (auth.uid() = user_id), which made
-- editing fail silently for shared-account members (PostgREST returned 200
-- with 0 rows changed, no client-visible error).
--
-- The helper public.is_account_editor_or_owner(uuid) already exists and is
-- used for transactions write policies (see 20260217000028_ai_assistant_foundation.sql).

drop policy if exists "Owner can update accounts" on public.accounts;
drop policy if exists "Owner or editor can update accounts" on public.accounts;

create policy "Owner or editor can update accounts"
  on public.accounts for update
  using (
    auth.uid() = user_id
    or public.is_account_editor_or_owner(id)
  );
