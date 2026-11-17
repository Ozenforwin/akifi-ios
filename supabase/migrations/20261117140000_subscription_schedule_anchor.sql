-- Subscription schedule in SQL follows the same contract as the iOS
-- SubscriptionDateEngine and supabase/functions/_shared/schedule.ts
-- (2026-11-17 review, D2):
--
--   k-th charge date = anchor + k periods. Monthly / quarterly / yearly add
--   1 / 3 / 12 calendar months TO THE ANCHOR — never to the previous date —
--   and the day is clamped to the month length (Postgres `date + interval
--   'N months'` already clamps: 31 Jan + 1 month = 28/29 Feb, + 2 months =
--   31 Mar). Weekly = +7k days, custom = +30k days.
--   anchor = start_date when next_payment_date is missing or lies on the
--   schedule anchored at start_date; otherwise next_payment_date (11 of 16
--   active prod rows store "the day it was added" as start_date).
--
-- Before: calculate_next_subscription_payment chained `add_subscription_period`
-- from the previous date, so a 31st billing day became the 28th forever after
-- February, and 'quarterly' fell through to +1 month.

create or replace function public.subscription_charge_date(p_anchor date, p_period text, p_k integer)
returns date
language sql
immutable
set search_path = public
as $$
    select case coalesce(p_period, 'monthly')
        when 'weekly'    then p_anchor + (7 * p_k)
        when 'custom'    then p_anchor + (30 * p_k)
        when 'quarterly' then (p_anchor + make_interval(months => 3 * p_k))::date
        when 'yearly'    then (p_anchor + make_interval(months => 12 * p_k))::date
        else                  (p_anchor + make_interval(months => p_k))::date
    end;
$$;

-- First charge date on the schedule that is >= p_from (k >= 0).
create or replace function public.subscription_first_charge_on_or_after(p_anchor date, p_period text, p_from date)
returns date
language plpgsql
immutable
set search_path = public
as $$
declare
    v_k integer := 0;
    v_d date;
begin
    if p_anchor is null then
        return null;
    end if;
    if p_from <= p_anchor then
        return p_anchor;
    end if;
    -- Jump close to p_from, then walk; bounded so a bad row can't spin.
    v_k := greatest(0, case coalesce(p_period, 'monthly')
        when 'weekly'    then (p_from - p_anchor) / 7
        when 'custom'    then (p_from - p_anchor) / 30
        when 'quarterly' then ((extract(year from p_from) - extract(year from p_anchor)) * 12
                               + extract(month from p_from) - extract(month from p_anchor))::int / 3
        when 'yearly'    then (extract(year from p_from) - extract(year from p_anchor))::int
        else                  ((extract(year from p_from) - extract(year from p_anchor)) * 12
                               + extract(month from p_from) - extract(month from p_anchor))::int
    end - 1);
    for i in 1..1000 loop
        v_d := public.subscription_charge_date(p_anchor, p_period, v_k);
        if v_d >= p_from then
            return v_d;
        end if;
        v_k := v_k + 1;
    end loop;
    return v_d;
end;
$$;

create or replace function public.subscription_anchor(p_start date, p_next date, p_period text)
returns date
language sql
immutable
set search_path = public
as $$
    select case
        when p_start is null then p_next
        when p_next is null then p_start
        when p_next >= p_start
             and public.subscription_first_charge_on_or_after(p_start, p_period, p_next) = p_next then p_start
        else p_next
    end;
$$;

-- Same signature as before (the insert/update trigger and older callers use it).
create or replace function public.calculate_next_subscription_payment(p_start_date date, p_period text, p_from_date date default current_date)
returns date
language sql
stable
set search_path = public
as $$
    select public.subscription_first_charge_on_or_after(p_start_date, p_period, p_from_date);
$$;

-- Kept for compatibility; quarterly and custom were wrong (+1 month).
create or replace function public.add_subscription_period(p_date date, p_period text)
returns date
language sql
immutable
set search_path = public
as $$
    select public.subscription_charge_date(p_date, p_period, 1);
$$;

create or replace function public.rollover_subscription_dates(p_today date default current_date)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row record;
    v_count integer := 0;
begin
    for v_row in
        select id, start_date, billing_period, next_payment_date
          from public.subscriptions
         where is_active = true
           and next_payment_date < p_today
    loop
        update public.subscriptions
           set next_payment_date = public.subscription_first_charge_on_or_after(
                   public.subscription_anchor(v_row.start_date, v_row.next_payment_date, v_row.billing_period),
                   v_row.billing_period,
                   p_today)
         where id = v_row.id;
        v_count := v_count + 1;
    end loop;
    return v_count;
end;
$$;

revoke execute on function public.rollover_subscription_dates(date) from public, anon, authenticated;
