-- Security lockdown — holes found in the 2026-11-17 project review and
-- verified on prod the same day (read-only checks: has_function_privilege,
-- has_table_privilege, pg_policies).
--
-- Callers were checked in BOTH repos (AkifiIOS + the Telegram Mini App repo):
--   * apply_premium_purchase — only edge functions on service_role
--     (admin-panel, prodamus-webhook, telegram-webhook).
--   * schedule_*_job, rollover_subscription_dates, backfill_account_categories,
--     upsert_budget_rollover — no client callers (pg_cron / one-off admin).
--   * record_budget_alert — called by the Mini App as the signed-in user, so
--     `authenticated` keeps EXECUTE; only anon loses it.
--   * budget_members — no client writes it directly; membership comes from
--     budget_add_owner_member (trigger) and accept_budget_invite, both
--     SECURITY DEFINER, so they bypass RLS and keep working.
--   * profiles — the app reads other users' profiles only for shared-account
--     members, which "Users can view profiles of shared account members"
--     already allows.

-- 1) SECURITY DEFINER functions with no auth.uid() check were executable by
--    anon (the public key embedded in the app) and authenticated:
--    free lifetime Premium for anyone, every user's subscription dates moved,
--    prod cron jobs replaced, shared-account categories rewritten.
revoke execute on function public.apply_premium_purchase(uuid, text, integer, text) from public, anon, authenticated;
revoke execute on function public.rollover_subscription_dates(date) from public, anon, authenticated;
revoke execute on function public.schedule_check_subscriptions_job(text, text) from public, anon, authenticated;
revoke execute on function public.schedule_notifications_inactivity_job(text, text) from public, anon, authenticated;
revoke execute on function public.schedule_weekly_digest_job(text, text) from public, anon, authenticated;
revoke execute on function public.backfill_account_categories(boolean) from public, anon, authenticated;
revoke execute on function public.upsert_budget_rollover(uuid, date, date, numeric, numeric) from public, anon, authenticated;
revoke execute on function public.record_budget_alert(uuid, date, integer) from public, anon;
revoke execute on function public.get_budget_member_expenses(uuid) from public, anon;

-- 2) profiles were world-readable: anon could list every user's email,
--    full_name, telegram ids and FCM token.
drop policy if exists "Public profiles are viewable by everyone." on public.profiles;

-- 3) budget_members: an owner/editor could INSERT a row for ANY user_id and
--    then read that user's 400-day expense history through
--    get_budget_member_expenses. Clients may now only remove members (owner)
--    or leave (self); nobody can remove the owner row.
drop policy if exists "Owner or editor manage budget members" on public.budget_members;
create policy "Owner removes members, members leave" on public.budget_members
    for delete
    using (
        role <> 'owner'
        and (
            user_id = auth.uid()
            or exists (select 1 from public.budgets b
                       where b.id = budget_members.budget_id and b.user_id = auth.uid())
        )
    );
