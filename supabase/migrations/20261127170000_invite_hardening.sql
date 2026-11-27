-- Review 2026-11-27, S8: invites could live forever and outlive their author.
--   * p_expires_hours had no upper bound (an editor could mint a 100-year
--     invite via the API), and accept never checked that the creator still
--     had the right to invite — a removed ex-partner rejoined with their own
--     code;
--   * the 16-character short code was stored in plain text (token_prefix),
--     so anyone who could read the invites table could join;
--   * accept did not lock the row (two people could redeem one invite);
--   * budget owners could neither see nor revoke invites their editors made.
-- Response shapes of accept_* are unchanged (clients parse them); a code
-- whose author lost the right answers like an unknown one.

alter table public.account_invites add column if not exists token_prefix_hash text;
alter table public.budget_invites  add column if not exists token_prefix_hash text;
update public.account_invites set token_prefix_hash = encode(extensions.digest(token_prefix, 'sha256'), 'hex'), token_prefix = null where token_prefix is not null;
update public.budget_invites  set token_prefix_hash = encode(extensions.digest(token_prefix, 'sha256'), 'hex'), token_prefix = null where token_prefix is not null;
create index if not exists account_invites_prefix_hash_idx on public.account_invites (token_prefix_hash) where status = 'pending';
create index if not exists budget_invites_prefix_hash_idx  on public.budget_invites  (token_prefix_hash) where status = 'pending';

-- Lifetime: 1 hour .. 7 days (default 72 h as before).
create or replace function public.invite_expiry(p_hours integer)
returns timestamptz
language sql
stable
set search_path = public
as $$ select now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 72), 168))) $$;

create or replace function public.create_account_invite(p_account_id uuid, p_role text default 'viewer', p_expires_hours integer default 72)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_token text;
begin
    if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
    if not exists (
        select 1 from public.account_members
         where account_id = p_account_id and user_id = auth.uid() and role in ('owner', 'editor')
    ) then
        raise exception 'Access denied: you are not an owner or editor of this account';
    end if;
    if p_role not in ('editor', 'viewer') then
        raise exception 'Invalid role: must be editor or viewer';
    end if;
    v_token := encode(gen_random_bytes(32), 'hex');
    insert into public.account_invites (account_id, token_hash, token_prefix, token_prefix_hash, role, created_by, expires_at)
    values (p_account_id,
            encode(digest(v_token, 'sha256'), 'hex'),
            null,
            encode(digest(substr(v_token, 1, 16), 'sha256'), 'hex'),
            p_role, auth.uid(), public.invite_expiry(p_expires_hours));
    return v_token;
end;
$$;

create or replace function public.create_budget_invite(p_budget_id uuid, p_role text default 'viewer', p_expires_hours integer default 72)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_token text;
begin
    if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
    if not public.is_budget_editor_or_owner(p_budget_id) then
        raise exception 'Access denied: you are not an owner or editor of this budget';
    end if;
    if p_role not in ('editor', 'viewer') then
        raise exception 'Invalid role: must be editor or viewer';
    end if;
    v_token := encode(gen_random_bytes(32), 'hex');
    insert into public.budget_invites (budget_id, token_hash, token_prefix, token_prefix_hash, role, created_by, expires_at)
    values (p_budget_id,
            encode(digest(v_token, 'sha256'), 'hex'),
            null,
            encode(digest(substr(v_token, 1, 16), 'sha256'), 'hex'),
            p_role, auth.uid(), public.invite_expiry(p_expires_hours));
    return v_token;
end;
$$;

create or replace function public.accept_account_invite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_clean  text;
    v_invite record;
begin
    if auth.uid() is null then
        return jsonb_build_object('success', false, 'error', 'not_authenticated');
    end if;
    v_clean := lower(replace(coalesce(p_token, ''), ' ', ''));

    if length(v_clean) = 16 then
        select * into v_invite from public.account_invites
         where token_prefix_hash = encode(digest(v_clean, 'sha256'), 'hex') and status = 'pending'
         limit 1 for update;
    else
        select * into v_invite from public.account_invites
         where token_hash = encode(digest(v_clean, 'sha256'), 'hex') and status = 'pending'
         limit 1 for update;
    end if;

    if v_invite is null then
        -- Not an account invite — maybe a budget one (shared link path).
        return public.accept_budget_invite(p_token);
    end if;

    if v_invite.expires_at < now() then
        update public.account_invites set status = 'revoked' where id = v_invite.id;
        return jsonb_build_object('success', false, 'error', 'invite_expired');
    end if;
    -- The author must still be allowed to invite.
    if not exists (
        select 1 from public.account_members
         where account_id = v_invite.account_id and user_id = v_invite.created_by and role in ('owner', 'editor')
    ) then
        update public.account_invites set status = 'revoked' where id = v_invite.id;
        return jsonb_build_object('success', false, 'error', 'invite_not_found');
    end if;
    if exists (
        select 1 from public.account_members
         where account_id = v_invite.account_id and user_id = auth.uid()
    ) then
        return jsonb_build_object('success', false, 'error', 'already_member');
    end if;

    insert into public.account_members (account_id, user_id, role, invited_by)
    values (v_invite.account_id, auth.uid(), v_invite.role, v_invite.created_by);

    update public.account_invites
       set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
     where id = v_invite.id;

    return jsonb_build_object('success', true, 'account_id', v_invite.account_id, 'role', v_invite.role);
end;
$$;

create or replace function public.accept_budget_invite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_clean  text;
    v_invite budget_invites%rowtype;
begin
    if auth.uid() is null then
        return jsonb_build_object('success', 'false', 'error', 'not_authenticated');
    end if;
    v_clean := lower(replace(coalesce(p_token, ''), ' ', ''));

    if length(v_clean) = 16 then
        select * into v_invite from public.budget_invites
         where token_prefix_hash = encode(digest(v_clean, 'sha256'), 'hex') and status = 'pending'
         limit 1 for update;
    else
        select * into v_invite from public.budget_invites
         where token_hash = encode(digest(v_clean, 'sha256'), 'hex') and status = 'pending'
         limit 1 for update;
    end if;

    if v_invite.id is null then
        return jsonb_build_object('success', 'false', 'error', 'invite_not_found');
    end if;
    if v_invite.expires_at < now() then
        update public.budget_invites set status = 'revoked' where id = v_invite.id;
        return jsonb_build_object('success', 'false', 'error', 'invite_expired');
    end if;
    if not exists (
        select 1 from public.budget_members
         where budget_id = v_invite.budget_id and user_id = v_invite.created_by and role in ('owner', 'editor')
    ) and not exists (
        select 1 from public.budgets where id = v_invite.budget_id and user_id = v_invite.created_by
    ) then
        update public.budget_invites set status = 'revoked' where id = v_invite.id;
        return jsonb_build_object('success', 'false', 'error', 'invite_not_found');
    end if;
    if exists (
        select 1 from public.budget_members
         where budget_id = v_invite.budget_id and user_id = auth.uid()
    ) then
        return jsonb_build_object('success', 'false', 'error', 'already_member');
    end if;

    insert into public.budget_members (budget_id, user_id, role, invited_by)
    values (v_invite.budget_id, auth.uid(), v_invite.role, v_invite.created_by);

    update public.budget_invites
       set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
     where id = v_invite.id;

    return jsonb_build_object('success', 'true', 'budget_id', v_invite.budget_id::text, 'role', v_invite.role);
end;
$$;

-- Removing a member (or demoting them to viewer) kills their pending invites.
create or replace function public.revoke_invites_of_departed_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if tg_table_name = 'account_members' then
        if tg_op = 'DELETE' or (tg_op = 'UPDATE' and new.role = 'viewer' and old.role <> 'viewer') then
            update public.account_invites set status = 'revoked'
             where account_id = old.account_id and created_by = old.user_id and status = 'pending';
        end if;
    else
        if tg_op = 'DELETE' or (tg_op = 'UPDATE' and new.role = 'viewer' and old.role <> 'viewer') then
            update public.budget_invites set status = 'revoked'
             where budget_id = old.budget_id and created_by = old.user_id and status = 'pending';
        end if;
    end if;
    return null;
end;
$$;
revoke execute on function public.revoke_invites_of_departed_member() from public, anon, authenticated;

drop trigger if exists trg_account_members_revoke_invites on public.account_members;
create trigger trg_account_members_revoke_invites
    after delete or update of role on public.account_members
    for each row execute function public.revoke_invites_of_departed_member();

drop trigger if exists trg_budget_members_revoke_invites on public.budget_members;
create trigger trg_budget_members_revoke_invites
    after delete or update of role on public.budget_members
    for each row execute function public.revoke_invites_of_departed_member();

-- Budget owners/editors see and revoke every invite of their budget.
drop policy if exists "Budget editors see budget invites" on public.budget_invites;
create policy "Budget editors see budget invites"
    on public.budget_invites for select
    using (public.is_budget_editor_or_owner(budget_id));

create or replace function public.revoke_budget_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (
        select 1 from public.budget_invites bi
         where bi.id = p_invite_id and public.is_budget_editor_or_owner(bi.budget_id)
    ) then
        raise exception 'Access denied' using errcode = '42501';
    end if;
    update public.budget_invites set status = 'revoked' where id = p_invite_id and status = 'pending';
end;
$$;
revoke execute on function public.revoke_budget_invite(uuid) from public, anon;
grant execute on function public.revoke_budget_invite(uuid) to authenticated;

revoke execute on function public.invite_expiry(integer) from public, anon, authenticated;
