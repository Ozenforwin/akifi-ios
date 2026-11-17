-- ADR-001 leftovers on the server (2026-11-17 review).
--
-- 1) get_budget_suggestion (both overloads) averaged the LEGACY `amount`
--    column. On foreign-entry rows `amount` is the typed foreign number
--    (500 000 VND on a RUB account), so one trip inflated the suggestion by
--    orders of magnitude. They now sum `amount_native` (the account-currency
--    amount, ADR-001). The single-category overload also counted transfer
--    legs: an auto-transfer out-leg carries no category, but a manual
--    categorised transfer would; both overloads now exclude
--    `transfer_group_id IS NOT NULL` like the array overload already did.
--    Known limit (unchanged): accounts in different currencies are summed
--    without FX; the caller passes account_ids of the budget.
--
-- 2) transactions_fill_amount_native: the UPDATE branch re-synced
--    amount_native := amount only when `amount` changed. A legacy writer that
--    moves a row to another account or relabels its currency (without sending
--    amount_native) left amount_native stale. Now, for rows WITHOUT foreign
--    fields, amount_native is recomputed from `amount` when amount,
--    account_id or the currency label (case-insensitive) changes — but only if
--    the writer did not set amount_native itself (NEW = OLD). Writers that
--    send amount_native (iOS, the ADR-001 TMA, the RPCs) are authoritative and
--    untouched, and foreign-entry rows are never auto-synced.
--    On prod every no-foreign row has amount = amount_native except 288
--    auto-transfer legs whose amount_native carries sub-kopeck precision
--    (|diff| < 0.005), so the recompute can at most round those.

create or replace function public.get_budget_suggestion(
    p_category_ids uuid[],
    p_account_ids uuid[] default null::uuid[],
    p_months integer default 3
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_avg numeric;
begin
    select coalesce(avg(monthly_total), 0) into v_avg
    from (
        select date_trunc('month', t.date::date) as m,
               sum(coalesce(t.amount_native, t.amount)) as monthly_total
        from public.transactions t
        where t.user_id = auth.uid()
          and t.category_id = any(p_category_ids)
          and t.type = 'expense'
          and t.transfer_group_id is null
          and t.date::date >= (current_date - (p_months || ' months')::interval)::date
          and (p_account_ids is null or t.account_id = any(p_account_ids))
        group by m
    ) sub;

    return round(v_avg, 2);
end;
$$;

create or replace function public.get_budget_suggestion(
    p_category_id uuid,
    p_account_ids uuid[] default null::uuid[],
    p_months integer default 3
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_avg numeric;
begin
    select coalesce(avg(monthly_total), 0) into v_avg
    from (
        select date_trunc('month', t.date::date) as m,
               sum(coalesce(t.amount_native, t.amount)) as monthly_total
        from public.transactions t
        where t.user_id = auth.uid()
          and t.category_id = p_category_id
          and t.type = 'expense'
          and t.transfer_group_id is null
          and t.date::date >= (current_date - (p_months || ' months')::interval)::date
          and (p_account_ids is null or t.account_id = any(p_account_ids))
        group by m
    ) sub;

    return round(v_avg, 2);
end;
$$;

create or replace function public.transactions_fill_amount_native()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if tg_op = 'INSERT' then
        if new.amount_native is null then
            new.amount_native := new.amount;
        end if;
        return new;
    end if;

    -- UPDATE
    if new.amount_native is null then
        new.amount_native := new.amount;
    elsif new.foreign_amount is null
          and new.amount_native is not distinct from old.amount_native   -- writer did not set it
          and (   new.amount is distinct from old.amount
               or new.account_id is distinct from old.account_id
               or upper(new.currency) is distinct from upper(old.currency)) then
        -- Legacy writer changed what amount_native depends on: for a
        -- no-foreign row `amount` IS the account-currency amount.
        new.amount_native := new.amount;
    end if;
    return new;
end;
$$;

comment on function public.transactions_fill_amount_native() is
    'ADR-001 compat: fill amount_native on INSERT; on UPDATE of a no-foreign row re-sync it from amount when amount/account_id/currency changed and the writer did not set amount_native (migration 20261117120500).';
