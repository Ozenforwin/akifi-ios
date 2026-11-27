-- Review 2026-11-27, S9: the assistant's daily quota was counted from
-- "local midnight" in the time zone the client sends, so a caller could pick
-- a zone that passed midnight minutes ago and get ~40 requests per hour; the
-- request row was written only after the LLM work, so parallel requests all
-- passed the check; 'limited' answers counted too.
-- ai_quota_take(user, limit) atomically checks a rolling 24 h window and
-- records a tick before any LLM call (per-user advisory lock). Service role
-- only; the edge function calls it.

create table if not exists public.ai_quota_ticks (
    user_id uuid        not null references auth.users(id) on delete cascade,
    at      timestamptz not null default now()
);
create index if not exists ai_quota_ticks_user_at_idx on public.ai_quota_ticks (user_id, at desc);
alter table public.ai_quota_ticks enable row level security;
revoke all on public.ai_quota_ticks from anon, authenticated;

create or replace function public.ai_quota_take(p_user_id uuid, p_limit integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_used int;
begin
    if coalesce(auth.role(), '') in ('authenticated', 'anon') then
        raise exception 'service role only' using errcode = '42501';
    end if;
    perform pg_advisory_xact_lock(hashtextextended('ai_quota:' || p_user_id::text, 0));
    delete from ai_quota_ticks where user_id = p_user_id and at < now() - interval '2 days';
    select count(*) into v_used from ai_quota_ticks where user_id = p_user_id and at > now() - interval '24 hours';
    if v_used >= greatest(p_limit, 1) then
        return jsonb_build_object('allowed', false, 'used', v_used);
    end if;
    insert into ai_quota_ticks(user_id) values (p_user_id);
    return jsonb_build_object('allowed', true, 'used', v_used + 1);
end;
$$;
revoke execute on function public.ai_quota_take(uuid, integer) from public, anon, authenticated;
grant execute on function public.ai_quota_take(uuid, integer) to service_role;
