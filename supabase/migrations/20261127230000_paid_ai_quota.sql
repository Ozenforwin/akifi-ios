-- Review 2026-11-27, S12: transcription (Whisper), bank-statement parsing and
-- receipt analysis call paid OpenAI APIs with no per-user limit; the bot even
-- transcribed voice messages of people who have no account. paid_ai_take
-- atomically checks a rolling 24 h window per (user, kind) and records a
-- tick before the paid call. Service role only.
create table if not exists public.paid_ai_ticks (
    user_id uuid        not null references auth.users(id) on delete cascade,
    kind    text        not null check (kind ~ '^[a-z_]{1,32}$'),
    at      timestamptz not null default now()
);
create index if not exists paid_ai_ticks_user_kind_at_idx on public.paid_ai_ticks (user_id, kind, at desc);
alter table public.paid_ai_ticks enable row level security;
revoke all on public.paid_ai_ticks from anon, authenticated;

create or replace function public.paid_ai_take(p_user_id uuid, p_kind text, p_limit integer)
returns boolean
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
    perform pg_advisory_xact_lock(hashtextextended('paid_ai:' || p_user_id::text || ':' || p_kind, 0));
    delete from paid_ai_ticks where user_id = p_user_id and kind = p_kind and at < now() - interval '2 days';
    select count(*) into v_used from paid_ai_ticks
     where user_id = p_user_id and kind = p_kind and at > now() - interval '24 hours';
    if v_used >= greatest(p_limit, 1) then
        return false;
    end if;
    insert into paid_ai_ticks(user_id, kind) values (p_user_id, p_kind);
    return true;
end;
$$;
revoke execute on function public.paid_ai_take(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.paid_ai_take(uuid, text, integer) to service_role;
