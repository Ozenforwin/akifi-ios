-- Make the DISPLAYED invite code actually redeemable.
--
-- Both share sheets (accounts and budgets) show the first 16 hex chars of
-- the invite token ("26A7 43D9 BF0D 3895"), but the accept RPCs looked up
-- sha256(full 64-char token) — so manually typing the visible code could
-- never match; only the deep link (which carries the full token) worked.
--
-- Fix: store the token's 16-char prefix alongside the hash and let the
-- accept RPCs resolve short input by prefix. Full-token input keeps
-- resolving by hash (deep links unchanged). 16 hex chars = 64 bits of
-- entropy on a 72-hour, single-use invite — ample.
--
-- Old pending invites (created before this migration) have no prefix and
-- keep working via their deep link only.

alter table public.account_invites add column if not exists token_prefix text;
alter table public.budget_invites add column if not exists token_prefix text;

create unique index if not exists account_invites_token_prefix_idx
    on public.account_invites (token_prefix) where token_prefix is not null;
create unique index if not exists budget_invites_token_prefix_idx
    on public.budget_invites (token_prefix) where token_prefix is not null;

-- ── Account invites ──────────────────────────────────────────────────────

create or replace function public.create_account_invite(
    p_account_id uuid,
    p_role text default 'viewer',
    p_expires_hours integer default 72
)
returns text
language plpgsql security definer set search_path = public, extensions
as $$
declare
    v_token text;
    v_hash text;
begin
    if not exists (
        select 1 from public.account_members
        where account_id = p_account_id
          and user_id = auth.uid()
          and role in ('owner', 'editor')
    ) then
        raise exception 'Access denied: you are not an owner or editor of this account';
    end if;
    if p_role not in ('editor', 'viewer') then
        raise exception 'Invalid role: must be editor or viewer';
    end if;
    v_token := encode(gen_random_bytes(32), 'hex');
    v_hash := encode(digest(v_token, 'sha256'), 'hex');
    insert into public.account_invites (account_id, token_hash, token_prefix, role, created_by, expires_at)
    values (p_account_id, v_hash, substr(v_token, 1, 16), p_role, auth.uid(),
            now() + (p_expires_hours || ' hours')::interval);
    return v_token;
end;
$$;

create or replace function public.accept_account_invite(p_token text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
    v_clean text;
    v_invite record;
begin
    -- Tolerate user-typed formatting: spaces and uppercase from the
    -- displayed "26A7 43D9 ..." grouping.
    v_clean := lower(replace(p_token, ' ', ''));

    if length(v_clean) = 16 then
        select * into v_invite from public.account_invites
        where token_prefix = v_clean and status = 'pending'
        limit 1;
    else
        select * into v_invite from public.account_invites
        where token_hash = encode(digest(v_clean, 'sha256'), 'hex')
          and status = 'pending'
        limit 1;
    end if;

    if v_invite is null then
        return jsonb_build_object('success', false, 'error', 'invite_not_found');
    end if;
    if v_invite.expires_at < now() then
        update public.account_invites set status = 'revoked' where id = v_invite.id;
        return jsonb_build_object('success', false, 'error', 'invite_expired');
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

    return jsonb_build_object(
        'success', true,
        'account_id', v_invite.account_id,
        'role', v_invite.role
    );
end;
$$;

-- ── Budget invites ───────────────────────────────────────────────────────

create or replace function public.create_budget_invite(
    p_budget_id uuid,
    p_role text default 'viewer',
    p_expires_hours integer default 72
)
returns text
language plpgsql security definer set search_path = public, extensions
as $$
declare
    v_token text;
begin
    if not public.is_budget_editor_or_owner(p_budget_id) then
        raise exception 'Access denied: you are not an owner or editor of this budget';
    end if;
    if p_role not in ('editor', 'viewer') then
        raise exception 'Invalid role: must be editor or viewer';
    end if;
    v_token := encode(gen_random_bytes(32), 'hex');
    insert into public.budget_invites (budget_id, token_hash, token_prefix, role, created_by, expires_at)
    values (
        p_budget_id,
        encode(digest(v_token, 'sha256'), 'hex'),
        substr(v_token, 1, 16),
        p_role,
        auth.uid(),
        now() + make_interval(hours => p_expires_hours)
    );
    return v_token;
end;
$$;

create or replace function public.accept_budget_invite(p_token text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
    v_clean text;
    v_invite budget_invites%rowtype;
begin
    v_clean := lower(replace(p_token, ' ', ''));

    if length(v_clean) = 16 then
        select * into v_invite from public.budget_invites
        where token_prefix = v_clean and status = 'pending'
        limit 1;
    else
        select * into v_invite from public.budget_invites
        where token_hash = encode(digest(v_clean, 'sha256'), 'hex')
          and status = 'pending'
        limit 1;
    end if;

    if v_invite is null then
        return jsonb_build_object('success', 'false', 'error', 'invite_not_found');
    end if;
    if v_invite.expires_at < now() then
        update public.budget_invites set status = 'revoked' where id = v_invite.id;
        return jsonb_build_object('success', 'false', 'error', 'invite_expired');
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

    return jsonb_build_object(
        'success', 'true',
        'budget_id', v_invite.budget_id::text,
        'role', v_invite.role
    );
end;
$$;
