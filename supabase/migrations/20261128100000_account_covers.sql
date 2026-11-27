-- Account covers (1.6.0): a photo as the background of an account card.
--
-- Vladimir: «кастомизация визуала счетов: фото ставить, выбирать область с
-- фотки и сохранять». Decided: the OWNER of an account (accounts.user_id)
-- sets the cover; every member of a shared account sees the same cover;
-- only the owner can change or remove it. Debt accounts have no cover.
--
-- Storage: private bucket `account-covers`, one object per cover, named
--   <account_id>/<uuid>.jpg            (both lower-case UUIDs)
-- The client crops and re-encodes the photo (≈1200 px wide JPEG, no EXIF /
-- location) and downloads it through the authenticated Storage API — no
-- public or signed URLs. Object names are immutable: a new cover is a new
-- uuid; the client deletes the old object after the row points at the new
-- one, so a member never sees a path that is not there yet.
--
-- Rules (client sessions = PostgREST / Storage `authenticated` / `anon`):
--   * accounts.cover_path: null or exactly '<this account id>/<uuid>.jpg'
--     (CHECK, every role) and null on a debt account (CHECK, every role);
--   * only the owner may change accounts.cover_path (trigger, 42501
--     account_cover_owner_only — editors may still rename the account);
--   * a client may point the row only at an object that exists in the
--     bucket (trigger, 23503 account_cover_missing);
--   * storage.objects in `account-covers`: SELECT for the owner and every
--     member of the account; INSERT / UPDATE / DELETE only for the owner;
--     INSERT never for a debt account; names must have the exact shape.
-- The service role and the database owner are not restricted by the
-- trigger (data repair, prepare_account_deletion handing a shared account
-- to the remaining member — the heir then owns the cover, because the
-- policies read accounts.user_id, not storage.objects.owner).
-- Same style as 20261117120000_account_budget_owner_guards.sql.
-- Depends on 20261128090000_debt_accounts.sql only for the meaning of
-- account_type = 'debt' (the CHECK below works without it).
--
-- Not done here (cannot be done in SQL — Storage forbids direct deletes):
-- removing objects when an account row is deleted. The iOS client removes
-- the cover before deleting the account; delete-account must remove the
-- objects of the accounts the leaving user still owns after
-- prepare_account_deletion (see the 1.6.0 report).

-- ── 1. accounts.cover_path ─────────────────────────────────────────────────
alter table public.accounts add column if not exists cover_path text;

comment on column public.accounts.cover_path is
    'Account cover: object name in the private storage bucket account-covers, <account_id>/<uuid>.jpg. Set only by the account owner (migration 20261128100000).';

alter table public.accounts drop constraint if exists accounts_cover_path_check;
alter table public.accounts
    add constraint accounts_cover_path_check
    check (
        cover_path is null
        or (
            char_length(cover_path) = 77
            and cover_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
            and split_part(cover_path, '/', 1) = id::text
        )
    );

alter table public.accounts drop constraint if exists accounts_cover_not_on_debt;
alter table public.accounts
    add constraint accounts_cover_not_on_debt
    check (cover_path is null or account_type is distinct from 'debt');


-- ── 2. Only the owner changes the cover; only to an uploaded object ───────
create or replace function public.guard_account_cover()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_owner uuid;
begin
    if coalesce(auth.role(), '') not in ('authenticated', 'anon') then
        return new;
    end if;

    if tg_op = 'INSERT' then
        if new.cover_path is null then
            return new;
        end if;
        v_owner := new.user_id;
    else
        if new.cover_path is not distinct from old.cover_path then
            return new;
        end if;
        v_owner := old.user_id;
    end if;

    if v_owner is distinct from auth.uid() then
        raise exception 'account_cover_owner_only: only the owner of the account can change its cover'
            using errcode = '42501';
    end if;

    -- SECURITY DEFINER: storage.objects is read regardless of the caller's RLS.
    if new.cover_path is not null and not exists (
        select 1 from storage.objects o
         where o.bucket_id = 'account-covers' and o.name = new.cover_path
    ) then
        raise exception 'account_cover_missing: upload the cover before pointing the account at it'
            using errcode = '23503',
                  hint = 'Upload <account_id>/<uuid>.jpg to the account-covers bucket first.';
    end if;

    return new;
end;
$$;

revoke all on function public.guard_account_cover() from public, anon, authenticated;

drop trigger if exists guard_account_cover on public.accounts;
create trigger guard_account_cover
    before insert or update of cover_path on public.accounts
    for each row execute function public.guard_account_cover();

comment on function public.guard_account_cover() is
    'Account covers: clients change accounts.cover_path only as the account owner and only to an object that exists in account-covers (migration 20261128100000).';


-- ── 3. Private bucket ─────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('account-covers', 'account-covers', false, 2 * 1024 * 1024, array['image/jpeg'])
on conflict (id) do update
    set public = excluded.public,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;


-- ── 4. Who may read / write an object ─────────────────────────────────────
-- The account id is the first path segment. plpgsql (not inlinable SQL):
-- the uuid cast happens only after the shape check, so a malformed name is
-- a plain "no", never a cast error inside a Storage request.
create or replace function public.account_cover_can_read(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_account uuid;
begin
    if p_name is null
       or p_name !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/' then
        return false;
    end if;
    v_account := split_part(p_name, '/', 1)::uuid;
    return exists (select 1 from public.accounts a
                    where a.id = v_account and a.user_id = auth.uid())
        or exists (select 1 from public.account_members m
                    where m.account_id = v_account and m.user_id = auth.uid());
end;
$$;

create or replace function public.account_cover_can_write(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_account uuid;
begin
    if p_name is null
       or p_name !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$' then
        return false;
    end if;
    v_account := split_part(p_name, '/', 1)::uuid;
    return exists (select 1 from public.accounts a
                    where a.id = v_account
                      and a.user_id = auth.uid()
                      and a.account_type is distinct from 'debt');
end;
$$;

revoke all on function public.account_cover_can_read(text) from public, anon;
revoke all on function public.account_cover_can_write(text) from public, anon;
grant execute on function public.account_cover_can_read(text) to authenticated, service_role;
grant execute on function public.account_cover_can_write(text) to authenticated, service_role;

comment on function public.account_cover_can_read(text) is
    'account-covers: the caller owns or is a member of the account named by the first path segment (migration 20261128100000).';
comment on function public.account_cover_can_write(text) is
    'account-covers: the caller owns the (non-debt) account and the name is <account_id>/<uuid>.jpg (migration 20261128100000).';

drop policy if exists "Account members can read account covers" on storage.objects;
create policy "Account members can read account covers" on storage.objects
    for select
    to authenticated
    using (bucket_id = 'account-covers' and public.account_cover_can_read(name));

drop policy if exists "Account owner can upload account covers" on storage.objects;
create policy "Account owner can upload account covers" on storage.objects
    for insert
    to authenticated
    with check (bucket_id = 'account-covers' and public.account_cover_can_write(name));

drop policy if exists "Account owner can update account covers" on storage.objects;
create policy "Account owner can update account covers" on storage.objects
    for update
    to authenticated
    using (bucket_id = 'account-covers' and public.account_cover_can_write(name))
    with check (bucket_id = 'account-covers' and public.account_cover_can_write(name));

drop policy if exists "Account owner can delete account covers" on storage.objects;
create policy "Account owner can delete account covers" on storage.objects
    for delete
    to authenticated
    using (bucket_id = 'account-covers' and public.account_cover_can_write(name));
