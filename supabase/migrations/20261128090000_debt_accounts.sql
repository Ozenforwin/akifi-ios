-- «Долги» (1.6.0): money lent to / borrowed from people.
--
-- Modelled exactly like deposits (20260419160000_account_type.sql,
-- 20260419160100_deposits.sql): every debt lives on its own account with
-- accounts.account_type = 'debt' plus a 1:1 side row in public.debts. The
-- money moves as ordinary manual transfers (two legs, one transfer_group_id,
-- one author) between a real account and the debt account:
--   «Дал в долг»   card -> debt     «Мне вернули»  debt -> card
--   «Взял в долг»  debt -> card     «Я вернул»     card -> debt
-- Debt account balance > 0: they owe me; < 0: I owe them.
-- Server analytics (get_budget_metrics, budget member expenses,
-- smart-notifications, send-weekly-digest, assistant-query spending) skip
-- rows with transfer_group_id, so moving money in or out of a debt is never
-- income or spending. See .claude/design/debts-contract.md.
--
-- Rules (enforced by triggers for every role unless noted):
--   * a debt account is personal: account_members may only hold its owner,
--     no invites, and an existing shared account cannot become a debt;
--   * a debt account cannot be the primary account, cannot be linked to a
--     budget (budgets.account_ids) or a subscription (subscriptions.account_id);
--   * debts.account_id must be a debt account owned by debts.user_id;
--   * client sessions cannot change account_type to or from 'debt', nor
--     debts.user_id / debts.account_id (consistent with
--     20261117120000_account_budget_owner_guards.sql). The owner of a debt
--     account is immutable for every role (debts.user_id must follow it).
-- Errors: SQLSTATE 23514 for data rules, 42501 for permission rules; the
-- message starts with a stable tag (debt_account_not_shareable, ...) the
-- clients can match on.

-- ── 1. accounts.account_type: + 'debt' ────────────────────────────────────
-- The original CHECK was declared inline (auto-named); drop whatever CHECK
-- mentions account_type and add a named one.
do $$
declare
    r record;
begin
    for r in
        select c.conname
          from pg_constraint c
         where c.conrelid = 'public.accounts'::regclass
           and c.contype = 'c'
           and pg_get_constraintdef(c.oid) ilike '%account_type%'
    loop
        raise notice 'dropping accounts constraint %', r.conname;
        execute format('alter table public.accounts drop constraint %I', r.conname);
    end loop;
end $$;

alter table public.accounts
    add constraint accounts_account_type_check
    check (account_type in ('checking', 'savings', 'cash', 'deposit', 'investment', 'debt'));


-- ── 2. public.debts (1:1 with the debt account) ───────────────────────────
create table if not exists public.debts (
    account_id           uuid primary key references public.accounts(id) on delete cascade,
    user_id              uuid not null default auth.uid() references auth.users(id) on delete cascade,
    counterparty_name    text not null,
    counterparty_contact text,
    due_date             date,
    remind               boolean not null default false,
    note                 text,
    closed_at            timestamptz,
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now(),
    constraint debts_counterparty_name_check
        check (char_length(btrim(counterparty_name)) between 1 and 120),
    constraint debts_counterparty_contact_check
        check (counterparty_contact is null or char_length(counterparty_contact) <= 200),
    constraint debts_note_check
        check (note is null or char_length(note) <= 2000),
    constraint debts_remind_needs_due_date
        check (not remind or due_date is not null)
);

create index if not exists idx_debts_user on public.debts(user_id);
-- Open debts with a reminder, by due date (client list + a future reminder job).
create index if not exists idx_debts_open_due on public.debts(user_id, due_date)
    where closed_at is null;

comment on table public.debts is
    'Debt details, 1:1 with an accounts row of account_type = ''debt'' (migration 20261128090000). Owner only.';

alter table public.debts enable row level security;

drop policy if exists debts_own_select on public.debts;
drop policy if exists debts_own_insert on public.debts;
drop policy if exists debts_own_update on public.debts;
drop policy if exists debts_own_delete on public.debts;

create policy debts_own_select on public.debts for select using (user_id = auth.uid());
create policy debts_own_insert on public.debts for insert with check (user_id = auth.uid());
create policy debts_own_update on public.debts for update
    using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy debts_own_delete on public.debts for delete using (user_id = auth.uid());

revoke all on public.debts from anon;
grant select, insert, update, delete on public.debts to authenticated;
grant all on public.debts to service_role;

create or replace function public.set_debts_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

drop trigger if exists trg_debts_updated_at on public.debts;
create trigger trg_debts_updated_at
    before update on public.debts
    for each row execute function public.set_debts_updated_at();

-- debts row consistency: on a debt account, owned by the same user.
create or replace function public.guard_debt_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_owner uuid;
    v_type  text;
begin
    if tg_op = 'UPDATE' and coalesce(auth.role(), '') in ('authenticated', 'anon') then
        if new.account_id is distinct from old.account_id then
            raise exception 'debt_owner_immutable: debts.account_id cannot change'
                using errcode = '42501';
        end if;
        if new.user_id is distinct from old.user_id then
            raise exception 'debt_owner_immutable: debts.user_id cannot change'
                using errcode = '42501';
        end if;
    end if;

    select a.user_id, a.account_type into v_owner, v_type
      from public.accounts a where a.id = new.account_id;
    if v_type is distinct from 'debt' then
        raise exception 'debt_account_required: account % is not a debt account', new.account_id
            using errcode = '23514',
                  hint = 'Create the account with account_type = ''debt'' first (or call create_debt).';
    end if;
    if v_owner is distinct from new.user_id then
        raise exception 'debt_owner_mismatch: debts.user_id must be the owner of the debt account'
            using errcode = '23514';
    end if;

    new.counterparty_name := btrim(new.counterparty_name);
    return new;
end;
$$;

revoke all on function public.guard_debt_row() from public, anon, authenticated;

drop trigger if exists trg_debts_guard on public.debts;
create trigger trg_debts_guard
    before insert or update on public.debts
    for each row execute function public.guard_debt_row();


-- ── 3. accounts: 'debt' is fixed at creation; owner of a debt is fixed ────
create or replace function public.guard_account_type_debt()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if old.account_type = 'debt' and new.user_id is distinct from old.user_id then
        raise exception 'debt_owner_immutable: the owner of a debt account cannot change'
            using errcode = '42501';
    end if;

    if new.account_type is not distinct from old.account_type then
        return new;
    end if;
    if old.account_type is distinct from 'debt' and new.account_type is distinct from 'debt' then
        return new;
    end if;

    if coalesce(auth.role(), '') in ('authenticated', 'anon') then
        raise exception 'debt_account_type_fixed: an account cannot become or stop being a debt account'
            using errcode = '42501',
                  hint = 'Create a new debt (create_debt) instead of converting an account.';
    end if;
    -- Service role / database owner (data repair): only consistent changes.
    if new.account_type = 'debt' and exists (
        select 1 from public.account_members m
         where m.account_id = new.id and m.user_id is distinct from new.user_id
    ) then
        raise exception 'debt_account_not_shareable: account % has other members', new.id
            using errcode = '23514';
    end if;
    if old.account_type = 'debt' and exists (select 1 from public.debts d where d.account_id = old.id) then
        raise exception 'debt_account_type_fixed: delete the debts row of account % first', old.id
            using errcode = '23514';
    end if;
    return new;
end;
$$;

revoke all on function public.guard_account_type_debt() from public, anon, authenticated;

drop trigger if exists trg_accounts_debt_type_guard on public.accounts;
create trigger trg_accounts_debt_type_guard
    before update of account_type, user_id on public.accounts
    for each row execute function public.guard_account_type_debt();


-- ── 4. Debt accounts are never shared, never primary ──────────────────────
-- account_members: the owner row (written by on_account_created) is the only
-- one allowed. Covers accept_account_invite and any direct insert.
create or replace function public.guard_debt_account_members()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_owner uuid;
    v_type  text;
begin
    select a.user_id, a.account_type into v_owner, v_type
      from public.accounts a where a.id = new.account_id;
    if v_type = 'debt' then
        if new.user_id is distinct from v_owner then
            raise exception 'debt_account_not_shareable: debt accounts are personal'
                using errcode = '23514';
        end if;
        if coalesce(new.is_primary, false) then
            raise exception 'debt_account_not_primary: a debt account cannot be the primary account'
                using errcode = '23514';
        end if;
    end if;
    return new;
end;
$$;

revoke all on function public.guard_debt_account_members() from public, anon, authenticated;

drop trigger if exists trg_account_members_debt_guard on public.account_members;
create trigger trg_account_members_debt_guard
    before insert or update of account_id, user_id, is_primary on public.account_members
    for each row execute function public.guard_debt_account_members();

-- account_invites: refuse at creation (create_account_invite), so nobody
-- receives a code that can never be accepted.
create or replace function public.guard_debt_account_invites()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if exists (select 1 from public.accounts a
                where a.id = new.account_id and a.account_type = 'debt') then
        raise exception 'debt_account_not_shareable: debt accounts are personal'
            using errcode = '23514';
    end if;
    return new;
end;
$$;

revoke all on function public.guard_debt_account_invites() from public, anon, authenticated;

drop trigger if exists trg_account_invites_debt_guard on public.account_invites;
create trigger trg_account_invites_debt_guard
    before insert or update of account_id on public.account_invites
    for each row execute function public.guard_debt_account_invites();


-- ── 5. Debt accounts are not linkable to budgets / subscriptions ──────────
-- Separate triggers: validate_budget_account_access() and
-- validate_subscription_account_access() (Mini App migrations) stay as they
-- are; these only add the debt rule, for every role.
create or replace function public.guard_budget_no_debt_accounts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.account_ids is not null
       and cardinality(new.account_ids) > 0
       and exists (select 1 from public.accounts a
                    where a.id = any(new.account_ids) and a.account_type = 'debt') then
        raise exception 'debt_account_not_linkable: a budget cannot track a debt account'
            using errcode = '23514';
    end if;
    return new;
end;
$$;

revoke all on function public.guard_budget_no_debt_accounts() from public, anon, authenticated;

drop trigger if exists trg_budgets_no_debt_accounts on public.budgets;
create trigger trg_budgets_no_debt_accounts
    before insert or update of account_ids on public.budgets
    for each row execute function public.guard_budget_no_debt_accounts();

create or replace function public.guard_subscription_no_debt_account()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.account_id is not null
       and exists (select 1 from public.accounts a
                    where a.id = new.account_id and a.account_type = 'debt') then
        raise exception 'debt_account_not_linkable: a subscription cannot be charged to a debt account'
            using errcode = '23514';
    end if;
    return new;
end;
$$;

revoke all on function public.guard_subscription_no_debt_account() from public, anon, authenticated;

drop trigger if exists trg_subscriptions_no_debt_account on public.subscriptions;
create trigger trg_subscriptions_no_debt_account
    before insert or update of account_id on public.subscriptions
    for each row execute function public.guard_subscription_no_debt_account();


-- ── 6. create_debt: account + details in one transaction ──────────────────
-- SECURITY INVOKER: RLS and every trigger above apply to the caller.
-- p_account_id is client-generated so an offline retry fails with 23505
-- (unique_violation) instead of creating a second debt — treat 23505 as
-- "already created". All 10 keys are required (no defaults): one overload,
-- no PostgREST ambiguity. No money moves here; the first «Дал/Взял в долг»
-- is a manual transfer written right after (see the contract).
create or replace function public.create_debt(
    p_account_id           uuid,
    p_name                 text,
    p_currency             text,
    p_icon                 text,
    p_color                text,
    p_counterparty_name    text,
    p_counterparty_contact text,
    p_due_date             date,
    p_remind               boolean,
    p_note                 text
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_uid uuid := auth.uid();
    v_id  uuid := coalesce(p_account_id, gen_random_uuid());
    v_ccy text := lower(btrim(coalesce(p_currency, '')));
begin
    if v_uid is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;
    if v_ccy !~ '^[a-z]{3}$' then
        raise exception 'p_currency must be a 3-letter currency code' using errcode = '22023';
    end if;
    if nullif(btrim(coalesce(p_counterparty_name, '')), '') is null then
        raise exception 'p_counterparty_name is required' using errcode = '22023';
    end if;

    insert into public.accounts (id, user_id, name, icon, color, initial_balance, currency, account_type)
    values (v_id, v_uid,
            coalesce(nullif(btrim(p_name), ''), btrim(p_counterparty_name)),
            coalesce(nullif(btrim(p_icon), ''), 'person.crop.circle'),
            coalesce(nullif(btrim(p_color), ''), '#F59E0B'),
            0, v_ccy, 'debt');

    insert into public.debts (account_id, user_id, counterparty_name, counterparty_contact,
                              due_date, remind, note)
    values (v_id, v_uid, p_counterparty_name,
            nullif(btrim(coalesce(p_counterparty_contact, '')), ''),
            p_due_date, coalesce(p_remind, false),
            nullif(btrim(coalesce(p_note, '')), ''));

    return v_id;
end;
$$;

revoke all on function public.create_debt(uuid, text, text, text, text, text, text, date, boolean, text) from public, anon;
grant execute on function public.create_debt(uuid, text, text, text, text, text, text, date, boolean, text) to authenticated, service_role;

comment on function public.create_debt(uuid, text, text, text, text, text, text, date, boolean, text) is
    'Creates a debt account (account_type = debt, initial_balance 0) and its debts row atomically. Retry with the same p_account_id -> 23505. Migration 20261128090000.';
