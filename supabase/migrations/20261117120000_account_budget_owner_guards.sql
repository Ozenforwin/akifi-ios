-- S5 (2026-11-17 review): an editor of a shared account could take it over.
--
-- The UPDATE policy "Owner or editor can update accounts" has no WITH CHECK,
-- so USING doubles as the check — and `auth.uid() = user_id` is true for the
-- NEW row once an editor writes their own id into it. After that the DELETE
-- policy (`auth.uid() = user_id`) treats them as the owner and the cascade
-- removes every transaction of the account. The same editor could also
-- change `accounts.currency`, silently changing the meaning of every
-- `amount_native` on the account (ADR-001: amount_native is in the
-- account's currency, with no FX applied at read time).
-- `budgets` has the same shape: "Editors can update shared budgets" lets an
-- editor rewrite `budgets.user_id`, and "Users can manage own budgets" (ALL)
-- then lets them delete the budget.
--
-- Pattern: guard_transaction_author_immutable — a BEFORE UPDATE trigger that
-- applies to client sessions (PostgREST `authenticated` / `anon`). The
-- service role and the database owner (migrations, data repair such as
-- 20260422130000_fix_olya_account_ccy.sql) are not restricted.
--
-- Rules for client sessions:
--   accounts.user_id   immutable.
--   accounts.currency  may change only (a) by the owner (accounts.user_id)
--                      and (b) while the account has no transactions at all.
--                      Case-only changes are not a change: the iOS account
--                      form always sends `currency` lower-cased
--                      (AccountFormView → AccountRepository.update), and two
--                      prod accounts store "USD", so renaming such an account
--                      must keep working.
--   budgets.user_id    immutable.
-- Deleting a shared account stays owner-only: the DELETE policy checks
-- accounts.user_id, which an editor can no longer rewrite.

create or replace function public.guard_account_owner_currency()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if coalesce(auth.role(), '') not in ('authenticated', 'anon') then
        return new;
    end if;

    if new.user_id is distinct from old.user_id then
        raise exception 'Account owner is immutable'
            using errcode = '42501';
    end if;

    if lower(new.currency) is distinct from lower(old.currency) then
        if old.user_id is distinct from auth.uid() then
            raise exception 'Only the account owner can change the account currency'
                using errcode = '42501';
        end if;
        -- SECURITY DEFINER: counts rows of every member, not only the ones
        -- RLS shows the caller.
        if exists (select 1 from public.transactions t where t.account_id = old.id) then
            raise exception 'Account currency cannot change once the account has transactions'
                using errcode = '23514',
                      hint = 'Every amount_native on the account is stored in its currency (ADR-001). Create a new account instead.';
        end if;
    end if;

    return new;
end;
$$;

revoke all on function public.guard_account_owner_currency() from public, anon, authenticated;

drop trigger if exists guard_account_owner_currency on public.accounts;
create trigger guard_account_owner_currency
    before update on public.accounts
    for each row execute function public.guard_account_owner_currency();


create or replace function public.guard_budget_owner_immutable()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if coalesce(auth.role(), '') in ('authenticated', 'anon')
       and new.user_id is distinct from old.user_id then
        raise exception 'Budget owner is immutable'
            using errcode = '42501';
    end if;
    return new;
end;
$$;

revoke all on function public.guard_budget_owner_immutable() from public, anon, authenticated;

drop trigger if exists guard_budget_owner_immutable on public.budgets;
create trigger guard_budget_owner_immutable
    before update on public.budgets
    for each row execute function public.guard_budget_owner_immutable();

comment on function public.guard_account_owner_currency() is
    'S5: clients cannot change accounts.user_id; currency only by the owner and only while the account has no transactions (migration 20261117120000).';
comment on function public.guard_budget_owner_immutable() is
    'S5: clients cannot change budgets.user_id (migration 20261117120000).';
