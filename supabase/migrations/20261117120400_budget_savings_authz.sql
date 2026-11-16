-- Review item #8 (2026-11-17): SECURITY DEFINER budget RPCs and
-- savings_contributions trusted any budget / goal id.
--
-- * record_budget_alert (called by the Telegram Mini App as the signed-in
--   user, useBudgetInsights.ts) inserted an alert event for ANY budget id —
--   and since budget_alert_events is unique per (budget, period, threshold),
--   a stranger could pre-empt (suppress) another user's alert. Now: caller
--   must be a member of the budget (is_budget_member).
-- * upsert_budget_rollover: same check (it is already revoked from clients in
--   20261117100000; defence in depth — it could not work without auth.uid()
--   anyway, user_id is NOT NULL DEFAULT auth.uid()).
-- * savings_contributions: the ALL policy only checked `user_id = auth.uid()`,
--   so a user could insert a contribution pointing at someone else's goal and
--   fn_update_savings_goal_amount (SECURITY DEFINER trigger) would rewrite that
--   goal's current_amount / status. Now the goal must belong to the caller
--   (INSERT and UPDATE; no such cross-user rows exist on prod — table is empty).

create or replace function public.record_budget_alert(p_budget_id uuid, p_period_start date, p_threshold integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    if auth.uid() is null or not public.is_budget_member(p_budget_id) then
        raise exception 'Access denied: not a member of this budget' using errcode = '42501';
    end if;

    insert into public.budget_alert_events (budget_id, user_id, period_start, threshold)
    values (p_budget_id, auth.uid(), p_period_start, p_threshold)
    on conflict (budget_id, period_start, threshold) do nothing;

    return found;
end;
$$;

create or replace function public.upsert_budget_rollover(
    p_budget_id uuid,
    p_period_start date,
    p_period_end date,
    p_carry_in numeric default 0,
    p_carry_out numeric default 0
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
begin
    if auth.uid() is null or not public.is_budget_member(p_budget_id) then
        raise exception 'Access denied: not a member of this budget' using errcode = '42501';
    end if;

    insert into public.budget_rollovers (budget_id, user_id, period_start, period_end, carry_in, carry_out, computed_at)
    values (p_budget_id, auth.uid(), p_period_start, p_period_end, p_carry_in, p_carry_out, now())
    on conflict (budget_id, period_start, period_end)
    do update set
        carry_in    = excluded.carry_in,
        carry_out   = excluded.carry_out,
        computed_at = now()
    returning id into v_id;

    return v_id;
end;
$$;

drop policy if exists "Users manage own savings contributions" on public.savings_contributions;
create policy "Users manage own savings contributions" on public.savings_contributions
    for all
    using (auth.uid() = user_id)
    with check (
        auth.uid() = user_id
        and exists (
            select 1 from public.savings_goals g
             where g.id = savings_contributions.goal_id
               and g.user_id = auth.uid()
        )
    );
