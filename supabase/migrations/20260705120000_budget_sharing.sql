-- Budget sharing, mirroring the account-sharing machinery
-- (account_members / account_invites / create_account_invite /
-- accept_account_invite — those live in the remote DB, created via TMA).
--
-- Wire-format note: accept_budget_invite returns every jsonb value as TEXT
-- ('true'/'false', uuid::text) because the iOS client decodes the RPC
-- result as [String: String] (see AcceptInviteView). The account-sharing
-- RPC returns booleans there — a latent decode hazard we're not repeating.

-- 1) Members. The owner gets a row too (backfill + trigger below), matching
--    account_members semantics.
create table public.budget_members (
    id uuid primary key default gen_random_uuid(),
    budget_id uuid not null references public.budgets(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    role text not null default 'viewer' check (role in ('owner', 'editor', 'viewer')),
    invited_by uuid references auth.users(id),
    created_at timestamptz not null default now(),
    unique (budget_id, user_id)
);
alter table public.budget_members enable row level security;

-- 2) Invites — raw token never stored, only its sha256 (as in account_invites).
create table public.budget_invites (
    id uuid primary key default gen_random_uuid(),
    budget_id uuid not null references public.budgets(id) on delete cascade,
    token_hash text not null unique,
    role text not null default 'viewer' check (role in ('editor', 'viewer')),
    created_by uuid not null references auth.users(id),
    status text not null default 'pending' check (status in ('pending', 'accepted', 'revoked')),
    expires_at timestamptz not null,
    accepted_by uuid references auth.users(id),
    accepted_at timestamptz,
    created_at timestamptz not null default now()
);
alter table public.budget_invites enable row level security;

-- 3) Helpers. SECURITY DEFINER so budget_members policies can call them
--    without recursing into their own RLS.
create or replace function public.is_budget_member(p_budget_id uuid)
returns boolean
language sql stable security definer set search_path = public, extensions
as $$
    select exists (
        select 1 from budget_members
        where budget_id = p_budget_id and user_id = auth.uid()
    );
$$;

create or replace function public.is_budget_editor_or_owner(p_budget_id uuid)
returns boolean
language sql stable security definer set search_path = public, extensions
as $$
    select exists (
        select 1 from budget_members
        where budget_id = p_budget_id
          and user_id = auth.uid()
          and role in ('owner', 'editor')
    );
$$;

-- 4) Every budget owner is a member. Trigger for new budgets (security
--    definer — the insert must bypass member RLS), backfill for existing.
create or replace function public.budget_add_owner_member()
returns trigger
language plpgsql security definer set search_path = public, extensions
as $$
begin
    insert into budget_members (budget_id, user_id, role)
    values (new.id, new.user_id, 'owner')
    on conflict (budget_id, user_id) do nothing;
    return new;
end;
$$;

create trigger trg_budget_add_owner
    after insert on public.budgets
    for each row execute function public.budget_add_owner_member();

insert into public.budget_members (budget_id, user_id, role)
select id, user_id, 'owner' from public.budgets
on conflict (budget_id, user_id) do nothing;

-- 5) RLS. The existing permissive ALL policy "Users can manage own budgets"
--    (auth.uid() = user_id) STAYS — permissive policies OR-combine, so the
--    owner keeps full access and DELETE remains owner-only.
--    NB: the iOS "archive" action is an UPDATE (is_active = false), so
--    editors can archive a shared budget — accepted behavior.
create policy "Members can view budget members" on public.budget_members
    for select using (public.is_budget_member(budget_id));
create policy "Owner or editor manage budget members" on public.budget_members
    for all using (public.is_budget_editor_or_owner(budget_id))
    with check (public.is_budget_editor_or_owner(budget_id));

create policy "Members can view shared budgets" on public.budgets
    for select using (public.is_budget_member(id));
create policy "Editors can update shared budgets" on public.budgets
    for update using (public.is_budget_editor_or_owner(id))
    with check (public.is_budget_editor_or_owner(id));

create policy "Creator sees own budget invites" on public.budget_invites
    for select using (created_by = auth.uid());

-- 6) RPCs — mirrors of create_account_invite / accept_account_invite.
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
    insert into budget_invites (budget_id, token_hash, role, created_by, expires_at)
    values (
        p_budget_id,
        encode(digest(v_token, 'sha256'), 'hex'),
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
    v_invite budget_invites%rowtype;
begin
    select * into v_invite
    from budget_invites
    where token_hash = encode(digest(p_token, 'sha256'), 'hex')
      and status = 'pending'
    limit 1;

    if v_invite is null then
        return jsonb_build_object('success', 'false', 'error', 'invite_not_found');
    end if;

    if v_invite.expires_at < now() then
        update budget_invites set status = 'revoked' where id = v_invite.id;
        return jsonb_build_object('success', 'false', 'error', 'invite_expired');
    end if;

    if exists (
        select 1 from budget_members
        where budget_id = v_invite.budget_id and user_id = auth.uid()
    ) then
        return jsonb_build_object('success', 'false', 'error', 'already_member');
    end if;

    insert into budget_members (budget_id, user_id, role, invited_by)
    values (v_invite.budget_id, auth.uid(), v_invite.role, v_invite.created_by);

    update budget_invites
    set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
    where id = v_invite.id;

    return jsonb_build_object(
        'success', 'true',
        'budget_id', v_invite.budget_id::text,
        'role', v_invite.role
    );
end;
$$;

grant execute on function public.create_budget_invite(uuid, text, integer) to authenticated;
grant execute on function public.accept_budget_invite(text) to authenticated;
