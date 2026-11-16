-- profiles.timezone — the user's IANA time zone (e.g. "Asia/Bangkok").
--
-- The server needs each user's LOCAL calendar day: a budget period, "today"
-- and the 80 % / 100 % push must use the same day the phone shows. Until now
-- the edge functions computed periods in UTC, so at 06:00 in UTC+7 the push
-- still talked about yesterday (and the first hours of a month about the
-- previous month).
--
-- Written by the iOS client once per launch when it changed
-- (ProfileRepository.updateTimezoneIfNeeded). NULL = unknown → callers fall
-- back to UTC. An unknown zone name is coerced to NULL by the trigger so a
-- typo can never make `at time zone` throw inside a metrics RPC or a cron run.

alter table public.profiles add column if not exists timezone text;

comment on column public.profiles.timezone is
    'IANA time zone of the user (written by the iOS client). NULL = unknown, treat as UTC.';

create or replace function public.profiles_normalize_timezone()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if new.timezone is not null then
        new.timezone := nullif(btrim(new.timezone), '');
    end if;
    if new.timezone is not null and not exists (
        select 1 from pg_catalog.pg_timezone_names where name = new.timezone
    ) then
        new.timezone := null;
    end if;
    return new;
end;
$$;

drop trigger if exists trg_profiles_normalize_timezone on public.profiles;
create trigger trg_profiles_normalize_timezone
    before insert or update of timezone on public.profiles
    for each row execute function public.profiles_normalize_timezone();
