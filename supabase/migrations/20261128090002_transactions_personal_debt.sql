-- Personal spending from a shared account (1.6.0).
--
-- transactions.personal_debt_user_id (nullable, -> auth.users, ON DELETE
-- SET NULL) marks a row on a SHARED account as one member's personal money:
--   * on an EXPENSE (type = expense, transfer_group_id IS NULL — a direct
--     expense or the main expense of an auto-transfer): this member
--     personally owes for it;
--       - paid via «Оплачено с» (auto_transfer_group_id set): not split by
--         weights, 100 % goes to that member's fair share
--         (get_account_settlement v2, 20261128090003); paid from the
--         member's own card it nets to zero, from a partner's card the
--         member owes the partner the full amount;
--       - paid from the shared account's own money (no auto_transfer_group_id):
--         the member owes it TO THE ACCOUNT (settlement v2 personal_debts);
--   * on the INCOME leg of a manual transfer into the shared account
--     (type = income, transfer_group_id set, auto_transfer_group_id NULL):
--     this transfer repays that member's personal debt to the account.
--
-- Enforced by trigger trg_transactions_personal_debt (not only RLS):
-- Data rules — every role, SQLSTATE 23514:
--   personal_debt_invalid_row   the row is neither shape above
--   personal_debt_not_shared    the account has fewer than two parties
--                               (owner + members) or is a debt account
--   personal_debt_not_member    the value is not a party of the account
-- Permission rules — client sessions (authenticated / anon), SQLSTATE 42501:
--   expense:   the author may mark their own row for themselves
--              (value = author = caller); an owner/editor of the account may
--              mark any member or clear any mark;
--   repayment: only for oneself (value = author = caller), set or clear.
-- A statement that does not touch the column but moves/reshapes a marked
-- row so the mark no longer fits (another account, expense -> income, made
-- part of a transfer, ...) drops the mark instead of failing: clients that
-- do not know the column (the Telegram Mini App, iOS <= 1.5.x) can never be
-- blocked by it.
-- Prod has no rows with the column set (it is new), so nothing changes for
-- existing data.

alter table public.transactions
    add column if not exists personal_debt_user_id uuid
        references auth.users(id) on delete set null;

comment on column public.transactions.personal_debt_user_id is
    'Shared accounts only. Expense: this member owes for it personally. Income leg of a manual transfer: repays this member''s personal debt to the account. Migration 20261128090002.';

-- FK index (ON DELETE SET NULL of a user) and per-member lookups.
create index if not exists idx_transactions_personal_debt_user
    on public.transactions (personal_debt_user_id, account_id)
    where personal_debt_user_id is not null;

-- Is p_user a party (owner or member) of p_account? No caller check: used
-- only inside the trigger below, not granted to clients.
create or replace function public.account_has_party(p_account_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select p_account_id is not null and p_user_id is not null and (
           exists (select 1 from public.account_members m
                    where m.account_id = p_account_id and m.user_id = p_user_id)
        or exists (select 1 from public.accounts a
                    where a.id = p_account_id and a.user_id = p_user_id));
$$;

revoke all on function public.account_has_party(uuid, uuid) from public, anon, authenticated;

create or replace function public.guard_transaction_personal_debt()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_client       boolean := coalesce(auth.role(), '') in ('authenticated', 'anon');
    v_uid          uuid    := auth.uid();
    v_flag_changed boolean;
    v_old_repay    boolean;
    v_new_repay    boolean;
    v_problem      text;
    v_parties      int;
    v_type         text;
begin
    if tg_op = 'INSERT' then
        if new.personal_debt_user_id is null then
            return new;
        end if;
        v_flag_changed := true;
    else
        v_flag_changed := new.personal_debt_user_id is distinct from old.personal_debt_user_id;
        if not v_flag_changed and new.personal_debt_user_id is null then
            return new;
        end if;
        if not v_flag_changed
           and new.account_id is not distinct from old.account_id
           and new.type is not distinct from old.type
           and new.transfer_group_id is not distinct from old.transfer_group_id
           and new.auto_transfer_group_id is not distinct from old.auto_transfer_group_id
           and new.user_id is not distinct from old.user_id then
            return new;
        end if;
    end if;

    -- Clearing / replacing an existing mark (client sessions).
    if tg_op = 'UPDATE' and v_flag_changed and old.personal_debt_user_id is not null and v_client then
        v_old_repay := old.type = 'income' and old.transfer_group_id is not null
                       and old.auto_transfer_group_id is null;
        if v_uid is null
           or (v_old_repay and not (old.personal_debt_user_id = v_uid and old.user_id = v_uid))
           or (not v_old_repay
               and not (old.personal_debt_user_id = v_uid and old.user_id = v_uid)
               and not public.is_account_editor_or_owner(old.account_id)) then
            raise exception 'personal_debt_forbidden: you cannot change this personal mark'
                using errcode = '42501';
        end if;
    end if;

    if new.personal_debt_user_id is null then
        return new;   -- mark cleared
    end if;

    -- Data rules for the (new) mark on the (new) row.
    v_new_repay := new.type = 'income' and new.transfer_group_id is not null
                   and new.auto_transfer_group_id is null;
    if not v_new_repay and not (new.type = 'expense' and new.transfer_group_id is null) then
        v_problem := 'personal_debt_invalid_row';
    else
        select a.account_type into v_type from public.accounts a where a.id = new.account_id;
        select count(*) into v_parties
          from (select m.user_id from public.account_members m where m.account_id = new.account_id
                union
                select a.user_id from public.accounts a where a.id = new.account_id) p;
        if new.account_id is null or v_type is null or v_type = 'debt' or v_parties < 2 then
            v_problem := 'personal_debt_not_shared';
        elsif not public.account_has_party(new.account_id, new.personal_debt_user_id) then
            v_problem := 'personal_debt_not_member';
        end if;
    end if;

    if v_problem is not null then
        if not v_flag_changed then
            -- The statement did not touch the mark; the row no longer fits it.
            new.personal_debt_user_id := null;
            return new;
        end if;
        raise exception '%: personal_debt_user_id is allowed only on an expense or a repayment transfer leg of a shared account, for one of its members', v_problem
            using errcode = '23514';
    end if;

    -- Permission to put this mark here (client sessions).
    if v_client and (v_flag_changed or new.account_id is distinct from old.account_id) then
        if v_uid is null then
            raise exception 'personal_debt_forbidden: not authenticated' using errcode = '42501';
        end if;
        if v_new_repay then
            if new.personal_debt_user_id <> v_uid or new.user_id is distinct from v_uid then
                raise exception 'personal_debt_repayment_self_only: a repayment can only be recorded for yourself'
                    using errcode = '42501';
            end if;
        elsif not (new.personal_debt_user_id = v_uid and new.user_id is not distinct from v_uid)
              and not public.is_account_editor_or_owner(new.account_id) then
            raise exception 'personal_debt_forbidden: only the author (for themselves) or an owner/editor can mark this expense'
                using errcode = '42501';
        end if;
    end if;

    return new;
end;
$$;

revoke all on function public.guard_transaction_personal_debt() from public, anon, authenticated;

drop trigger if exists trg_transactions_personal_debt on public.transactions;
create trigger trg_transactions_personal_debt
    before insert or update of personal_debt_user_id, account_id, type, transfer_group_id,
                               auto_transfer_group_id, user_id
    on public.transactions
    for each row execute function public.guard_transaction_personal_debt();


-- ── create_expense_with_auto_transfer: 15-arg overload (+ personal mark) ──
-- The 14-arg overload (20261117120200) plus p_personal_debt_user_id, all in
-- one transaction: the mark is never missing on a freshly created expense.
-- All 15 keys are required (no defaults), so PostgREST routes a 15-key body
-- here and a 14-key body to the 14-arg overload — no ambiguity. SECURITY
-- INVOKER like the others: RLS and the trigger above apply to the caller.
-- p_personal_debt_user_id = NULL behaves exactly like the 14-arg call.
create or replace function public.create_expense_with_auto_transfer(
    p_account_id uuid,
    p_category_id uuid,
    p_amount numeric,
    p_currency text,
    p_date timestamp with time zone,
    p_description text,
    p_merchant_name text,
    p_payment_source_account_id uuid,
    p_source_amount numeric,
    p_source_currency text,
    p_foreign_amount numeric,
    p_foreign_currency text,
    p_fx_rate numeric,
    p_id uuid,
    p_personal_debt_user_id uuid
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
    v_id uuid;
    v_n  integer;
begin
    v_id := public.create_expense_with_auto_transfer(
        p_account_id, p_category_id, p_amount, p_currency, p_date,
        p_description, p_merchant_name, p_payment_source_account_id,
        p_source_amount, p_source_currency,
        p_foreign_amount, p_foreign_currency, p_fx_rate,
        p_id);

    if p_personal_debt_user_id is not null then
        update public.transactions
           set personal_debt_user_id = p_personal_debt_user_id
         where id = v_id;
        get diagnostics v_n = row_count;
        if v_n <> 1 then
            raise exception 'Expense % is not editable by you', v_id using errcode = '42501';
        end if;
    end if;

    return v_id;
end;
$$;

revoke all on function public.create_expense_with_auto_transfer(
    uuid, uuid, numeric, text, timestamp with time zone, text, text, uuid,
    numeric, text, numeric, text, numeric, uuid, uuid) from public, anon;
grant execute on function public.create_expense_with_auto_transfer(
    uuid, uuid, numeric, text, timestamp with time zone, text, text, uuid,
    numeric, text, numeric, text, numeric, uuid, uuid) to authenticated, service_role;

comment on function public.create_expense_with_auto_transfer(
    uuid, uuid, numeric, text, timestamp with time zone, text, text, uuid,
    numeric, text, numeric, text, numeric, uuid, uuid) is
    '14-arg create + p_personal_debt_user_id (marks the main expense personal, same transaction). All 15 keys required. Migration 20261128090002.';
