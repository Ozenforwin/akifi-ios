-- Review 2026-11-27, S6: a user could rewrite identity columns of their own
-- profile. RLS allowed UPDATE of every column where id = auth.uid(), so:
--   * telegram_chat_id := <anyone's Telegram id> made the official bot send
--     that person the attacker's reminders ("Аккаунт заблокирован…") and,
--     with export-csv, any file;
--   * email := 'tg_<victim>@telegram.local' broke the victim's Mini App login
--     (telegram-auth looks the user up by profiles.email) and hijacked
--     "share chat by e-mail" lookups.
--
-- Column GRANTs would also block the Mini App, which upserts its own verified
-- Telegram id from the client (AuthProvider.tsx). So instead: from a client
-- (JWT role authenticated/anon) these columns may only take values the server
-- already vouches for —
--   telegram_user_id / telegram_chat_id: the current value, NULL (unlink), or
--     auth.users.raw_user_meta_data->>'telegram_id', which only telegram-auth
--     sets after verifying initData with the bot token;
--   email: the current value or auth.users.email.
-- Anything else is silently kept as it was, so a combined upsert (name +
-- avatar + Telegram ids) still saves the harmless fields.
-- service_role, migrations and triggers without JWT claims are not affected.

create or replace function public.guard_profile_identity_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_role      text := coalesce(auth.role(), '');
    v_meta_tg   text;
    v_auth_mail text;
    v_old_tg    bigint;
    v_old_chat  bigint;
    v_old_mail  text;
    v_old_link  timestamptz;
begin
    if v_role not in ('authenticated', 'anon') then
        return new;
    end if;

    select u.raw_user_meta_data->>'telegram_id', u.email
      into v_meta_tg, v_auth_mail
      from auth.users u
     where u.id = new.id;

    if tg_op = 'UPDATE' then
        v_old_tg := old.telegram_user_id;
        v_old_chat := old.telegram_chat_id;
        v_old_mail := old.email;
        v_old_link := old.telegram_linked_at;
    end if;

    if new.telegram_user_id is distinct from v_old_tg
       and new.telegram_user_id is not null
       and new.telegram_user_id::text is distinct from v_meta_tg then
        new.telegram_user_id := v_old_tg;
        new.telegram_linked_at := v_old_link;
    end if;

    if new.telegram_chat_id is distinct from v_old_chat
       and new.telegram_chat_id is not null
       and new.telegram_chat_id::text is distinct from v_meta_tg then
        new.telegram_chat_id := v_old_chat;
    end if;

    if new.email is distinct from v_old_mail
       and new.email is distinct from v_auth_mail then
        new.email := v_old_mail;
    end if;

    return new;
end;
$$;

revoke execute on function public.guard_profile_identity_columns() from public, anon, authenticated;

drop trigger if exists trg_profiles_identity_guard on public.profiles;
create trigger trg_profiles_identity_guard
    before insert or update of telegram_user_id, telegram_chat_id, email
    on public.profiles
    for each row execute function public.guard_profile_identity_columns();
