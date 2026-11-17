-- budgets.currency NOT NULL (finding B4) + quarterly/yearly periods.
--
-- 1) Why: a NULL currency was resolved on each phone — the linked account's
--    currency if THIS phone can see that account, else this user's base
--    currency. A partner who can't see the linked account read the same
--    `amount` in their own base currency: "$500" for one member, "500 ₽" for
--    the other.
--
--    Backfill = exactly what the OWNER's phone resolves today
--    (BudgetMath.budgetCurrency): linked account currency (first id) →
--    owner's profile default_currency → RUB. Verified on prod 2026-11-17:
--    every NULL row resolves to RUB either way.
--
--    New rows: the iOS app always sends `currency`. The Telegram Mini App
--    never sends it and always stores the amount in RUB (its toBase() is a
--    RUB pivot), so a missing value on INSERT falls back to the owner's
--    profile currency and then RUB (all profiles are RUB today). On UPDATE a
--    missing/blank value keeps the old one, so a client that sends
--    `currency: null` can't wipe it. Codes are stored uppercase.
--
-- 2) The iOS form offers quarterly and yearly budgets, but the check
--    constraint only allowed monthly/weekly/custom — saving one failed with
--    a constraint violation. get_budget_metrics (20261117130003) supports
--    both, so the constraint is widened. (The Mini App renders unknown
--    period types as monthly.)

-- validate_budget_account_access() raises "Not authenticated" for any write
-- without a JWT (a migration has none). The backfill doesn't touch
-- account_ids, so skip that check for these two statements only.
alter table public.budgets disable trigger trg_validate_budget_accounts;

update public.budgets b
   set currency = coalesce(
           (select upper(a.currency) from public.accounts a where a.id = b.account_ids[1]),
           (select upper(p.default_currency) from public.profiles p where p.id = b.user_id),
           'RUB')
 where b.currency is null or btrim(b.currency) = '';

update public.budgets set currency = upper(currency) where currency <> upper(currency);

alter table public.budgets enable trigger trg_validate_budget_accounts;

create or replace function public.budget_fill_currency()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    new.currency := upper(nullif(btrim(coalesce(new.currency, '')), ''));
    if new.currency is null and tg_op = 'UPDATE' then
        new.currency := old.currency;
    end if;
    if new.currency is null then
        new.currency := coalesce(
            (select upper(p.default_currency) from public.profiles p where p.id = new.user_id),
            'RUB');
    end if;
    return new;
end;
$$;

revoke all on function public.budget_fill_currency() from public, anon, authenticated;

drop trigger if exists trg_budget_fill_currency on public.budgets;
create trigger trg_budget_fill_currency
    before insert or update on public.budgets
    for each row execute function public.budget_fill_currency();

alter table public.budgets alter column currency set default 'RUB';
alter table public.budgets alter column currency set not null;

alter table public.budgets drop constraint if exists budgets_currency_format;
alter table public.budgets add constraint budgets_currency_format
    check (currency ~ '^[A-Z]{3}$');

alter table public.budgets drop constraint if exists budgets_period_type_check;
alter table public.budgets add constraint budgets_period_type_check
    check (period_type = any (array['monthly', 'weekly', 'quarterly', 'yearly', 'custom']));
