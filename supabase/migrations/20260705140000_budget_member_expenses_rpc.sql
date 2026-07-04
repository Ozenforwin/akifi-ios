-- Shared-budget progress: expose OTHER members' budget-relevant spending.
--
-- Without this, a shared budget only aggregated locally visible
-- transactions (RLS), so a partner paying from their private card never
-- moved my progress bar — defeating the point of a shared budget.
--
-- The RPC returns the minimum needed for the progress math — amount, the
-- account's currency (for FX into the budget currency), and the date (for
-- period bucketing). Descriptions/merchants are deliberately NOT exposed:
-- sharing a budget must not leak the partner's transaction details.
--
-- Dedup contract: rows on accounts where the CALLER is a member are
-- excluded — those transactions are already visible client-side through
-- account-sharing RLS and are counted by the local math. What remains is
-- exactly the invisible remainder.

create or replace function public.get_budget_member_expenses(p_budget_id uuid)
returns table (
    amount_native numeric,
    currency text,
    tx_date date
)
language plpgsql stable security definer set search_path = public, extensions
as $$
declare
    v_budget budgets%rowtype;
begin
    -- Caller must be a member of the budget.
    if not exists (
        select 1 from budget_members
        where budget_id = p_budget_id and user_id = auth.uid()
    ) then
        raise exception 'Access denied: not a member of this budget';
    end if;

    select * into v_budget from budgets where id = p_budget_id;
    if v_budget is null then
        return;
    end if;

    return query
    with budget_cat_names as (
        -- Budget categories matched by NAME too — the partner's same-name
        -- category has a different id (mirrors BudgetMath.CategoryMatcher).
        select lower(trim(c.name)) as nm
        from categories c
        where c.id = any(coalesce(v_budget.category_ids, '{}'))
    )
    select
        t.amount_native,
        coalesce(a.currency, t.currency, 'RUB') as currency,
        t.date::date as tx_date
    from transactions t
    left join accounts a on a.id = t.account_id
    left join categories c on c.id = t.category_id
    where t.user_id in (
            select bm.user_id from budget_members bm
            where bm.budget_id = p_budget_id
          )
      and t.user_id <> auth.uid()
      and t.type = 'expense'
      and t.transfer_group_id is null
      -- Category filter: none set → everything counts; else id OR name match.
      and (
            v_budget.category_ids is null
            or cardinality(v_budget.category_ids) = 0
            or t.category_id = any(v_budget.category_ids)
            or lower(trim(c.name)) in (select nm from budget_cat_names)
          )
      -- Account filter of the budget itself.
      and (
            v_budget.account_ids is null
            or cardinality(v_budget.account_ids) = 0
            or t.account_id = any(v_budget.account_ids)
          )
      -- Dedup: skip rows the caller already sees via account sharing.
      and (
            t.account_id is null
            or t.account_id not in (
                select am.account_id from account_members am
                where am.user_id = auth.uid()
            )
          )
      -- Enough history for yearly budgets; the client re-buckets by the
      -- budget's actual current period.
      and t.date >= now() - interval '400 days';
end;
$$;

grant execute on function public.get_budget_member_expenses(uuid) to authenticated;
