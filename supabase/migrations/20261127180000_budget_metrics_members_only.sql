-- Review 2026-11-27, S7: get_budget_metrics counted every row on every
-- account any budget member could see, so a budget member saw (and via
-- by_member, identified) the spending of people outside the budget who
-- share an account with another member; p_today was not bounded, so the
-- numbers could be read for any past day. Now: members' rows, plus other
-- people's rows only on accounts explicitly linked to the budget; p_today
-- within two days of the UTC date. (Prod had no such three-party setup.)

CREATE OR REPLACE FUNCTION public.budget_metrics_one(p_budget_id uuid, p_today date, p_tz text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
    b             budgets%rowtype;
    v_ccy         text;
    v_tz          text;
    v_anchor      date;
    v_start       date;
    v_end         date;
    v_prev_start  date;
    v_prev_end    date;
    v_lo          date;
    v_members     uuid[];
    v_accounts    uuid[];
    v_cat_ids     uuid[];
    v_cat_names   text[];
    v_acc_filter  uuid[];
    v_limit       bigint;
    v_carry       bigint := 0;
    v_spent       bigint;
    v_spent_today bigint;
    v_prev_spent  bigint;
    v_tx_count    int;
    v_by_member   jsonb;
    v_row_codes   text[];
    v_fx_missing  text[];
    v_subs        bigint;
    v_sub_count   int;
    v_sub_codes   text[];
    v_total       int;
    v_elapsed     int;
    v_remaining   int;
    v_eff         bigint;
    v_left        bigint;
    v_left_free   bigint;
    v_safe        bigint;
    v_util        int;
    v_expected    numeric;
    v_pace        numeric;
    v_fx          jsonb;
    v_categories  jsonb;
begin
    select * into b from budgets where id = p_budget_id;
    if not found then
        return null;
    end if;

    v_ccy := upper(coalesce(nullif(btrim(b.currency), ''), 'RUB'));

    -- One window for every member: anchor the rolling month in the owner's
    -- zone (validated on write by trg_profiles_normalize_timezone).
    select p.timezone into v_tz from profiles p where p.id = b.user_id;
    v_tz := coalesce(v_tz, p_tz, 'UTC');
    v_anchor := case when b.created_at is null then null
                     else (b.created_at at time zone v_tz)::date end;

    select pb.period_start, pb.period_end into v_start, v_end
      from budget_period_bounds(b.period_type, p_today, v_anchor,
                                b.custom_start_date, b.custom_end_date) pb;

    if b.rollover_enabled then
        select pp.period_start, pp.period_end into v_prev_start, v_prev_end
          from budget_previous_period(b.period_type, v_start, v_anchor) pp;
        -- Only carry a period the budget existed for in full.
        if v_prev_start is not null and v_anchor is not null and v_anchor > v_prev_start then
            v_prev_start := null;
            v_prev_end   := null;
        end if;
    end if;
    v_lo := least(v_start, coalesce(v_prev_start, v_start));

    -- Members: budget_members (owner row comes from trg_budget_add_owner)
    -- plus the owner, defensively.
    select array_agg(distinct u) into v_members
      from (select b.user_id as u
            union
            select m.user_id from budget_members m where m.budget_id = b.id) x;

    -- Every account any member can see — together with the members' own
    -- rows this is the union of what each member's phone shows.
    select coalesce(array_agg(distinct am.account_id), '{}') into v_accounts
      from account_members am
     where am.user_id = any(v_members);

    v_cat_ids := coalesce(b.category_ids, '{}');
    select coalesce(array_agg(distinct budget_norm_name(c.name)), '{}') into v_cat_names
      from categories c
     where c.id = any(v_cat_ids);

    v_acc_filter := case when b.account_ids is null or cardinality(b.account_ids) = 0
                         then null else b.account_ids end;

    -- Budget.amount / Transaction.amountNative decode to kopecks by rounding.
    v_limit := round(b.amount * 100)::bigint;

    with rows as (
        select t.user_id,
               (t.date at time zone 'UTC')::date                   as d,
               round(coalesce(t.amount_native, t.amount) * 100)     as k,
               upper(coalesce(nullif(btrim(a.currency), ''), v_ccy)) as ccy
          from transactions t
          left join accounts a   on a.id = t.account_id
          left join categories c on c.id = t.category_id
         where t.type = 'expense'
           and t.transfer_group_id is null
           and t.date >= (v_lo::timestamp at time zone 'UTC')
           and t.date <  ((v_end + 1)::timestamp at time zone 'UTC')
           -- Members' own rows anywhere; other people's rows only on accounts the
           -- budget is explicitly linked to (the editor who links an account
           -- must be able to see it — validate_budget_account_access). Rows
           -- of people outside the budget on any account a member merely
           -- shares used to be counted and exposed via by_member (S7).
           and (t.user_id = any(v_members)
                or (v_acc_filter is not null and t.account_id = any(v_acc_filter)))
           and (cardinality(v_cat_ids) = 0
                or t.category_id = any(v_cat_ids)
                or budget_norm_name(c.name) = any(v_cat_names))
           and (v_acc_filter is null or t.account_id = any(v_acc_filter))
    ),
    conv as (
        select r.user_id, r.d, r.ccy,
               case when r.ccy = v_ccy or f.per_usd is null or tt.per_usd is null
                    then round(r.k)
                    else round(r.k / f.per_usd * tt.per_usd)
               end::bigint as kc,
               (r.ccy <> v_ccy and (f.per_usd is null or tt.per_usd is null)) as fx_missing
          from rows r
          left join fx_rates f  on f.code  = r.ccy
          left join fx_rates tt on tt.code = v_ccy
    )
    select
        coalesce((select sum(kc) from conv where d between v_start and v_end), 0),
        coalesce((select sum(kc) from conv where d = p_today), 0),
        (select count(*) from conv where d between v_start and v_end),
        coalesce((select sum(kc) from conv where d between v_prev_start and v_prev_end), 0),
        coalesce((select jsonb_agg(jsonb_build_object(
                             'user_id', x.user_id, 'spent', x.s, 'tx_count', x.n)
                         order by x.s desc, x.user_id)
                    from (select user_id, sum(kc)::bigint as s, count(*) as n
                            from conv where d between v_start and v_end
                           group by user_id) x), '[]'::jsonb),
        coalesce((select array_agg(distinct ccy) from conv), '{}'),
        coalesce((select array_agg(distinct ccy) from conv where fx_missing), '{}')
      into v_spent, v_spent_today, v_tx_count, v_prev_spent, v_by_member,
           v_row_codes, v_fx_missing;

    -- Subscriptions of ALL members (B3).
    select coalesce(sum(fx_convert_minor(
                        budget_normalize_period_amount(round(s.amount * 100)::bigint,
                                                       s.billing_period, b.period_type),
                        upper(s.currency), v_ccy)), 0),
           count(*),
           coalesce(array_agg(distinct upper(s.currency)), '{}')
      into v_subs, v_sub_count, v_sub_codes
      from subscriptions s
      left join categories c on c.id = s.category_id
     where s.user_id = any(v_members)
       and s.status = 'active'
       and (cardinality(v_cat_ids) = 0
            or s.category_id = any(v_cat_ids)
            or budget_norm_name(c.name) = any(v_cat_names));

    -- Rollover (M10).
    if b.rollover_enabled then
        select round(r.carry_in * 100)::bigint into v_carry
          from budget_rollovers r
         where r.budget_id = b.id
           and r.period_start <= p_today and r.period_end >= p_today
         order by r.period_start desc
         limit 1;
        if v_carry is null then
            v_carry := case when v_prev_start is not null
                            then greatest(0, v_limit - v_prev_spent) else 0 end;
        end if;
    end if;

    -- Days (D5): whole calendar days, today counted in both elapsed and
    -- remaining.
    v_total     := greatest(1, v_end - v_start + 1);
    v_elapsed   := least(v_total, greatest(0, p_today - v_start + 1));
    v_remaining := least(v_total, greatest(0, v_end - p_today + 1));

    v_eff       := v_limit + v_carry;
    v_left      := greatest(0, v_eff - v_spent);
    v_left_free := greatest(0, v_eff - v_spent - v_subs);
    v_safe      := case when v_remaining > 0 then v_left_free / v_remaining else v_left_free end;
    v_util      := case when v_eff > 0
                        then least(999, greatest(0, trunc(v_spent::numeric / v_eff * 100)))::int
                        when v_spent > 0 then 999 else 0 end;
    if v_elapsed > 0 and v_total > 0 then
        v_expected := v_eff::numeric * v_elapsed / v_total;
        v_pace := case when v_expected > 0 then round(v_spent / v_expected, 2)
                       when v_spent > 0 then 9.99 else 0 end;
    else
        v_pace := 0;
    end if;

    select coalesce(jsonb_object_agg(f.code, f.per_usd), '{}'::jsonb) into v_fx
      from fx_rates f
     where f.code = any(v_row_codes || v_sub_codes || array[v_ccy]);

    select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'icon', c.icon)
                              order by c.name, c.id), '[]'::jsonb)
      into v_categories
      from categories c
     where c.id = any(v_cat_ids);

    return jsonb_build_object(
        'budget_id',              b.id,
        'name',                   b.name,
        'currency',               v_ccy,
        'period_type',            b.period_type,
        'period_start',           v_start,
        'period_end',             v_end,
        'total_days',             v_total,
        'elapsed_days',           v_elapsed,
        'remaining_days',         v_remaining,
        'limit',                  v_limit,
        'carry_in',               v_carry,
        'effective_limit',        v_eff,
        'spent',                  v_spent,
        'spent_today',            v_spent_today,
        'remaining',              v_left,
        'subscription_committed', v_subs,
        'subscription_count',     v_sub_count,
        'free_remaining',         greatest(0, v_left - v_subs),
        'safe_to_spend_daily',    v_safe,
        'utilization',            v_util,
        'pace_ratio',             v_pace,
        'tx_count',               v_tx_count,
        'member_ids',             to_jsonb(v_members),
        'by_member',              v_by_member,
        'categories',             v_categories,
        'alert_thresholds',       to_jsonb(b.alert_thresholds),
        'fx',                     v_fx,
        'fx_missing',             to_jsonb(v_fx_missing));
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_budget_metrics(p_today date, p_tz text DEFAULT NULL::text, p_budget_ids uuid[] DEFAULT NULL::uuid[], p_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_uid uuid := auth.uid();
    v_tz  text;
    v_out jsonb;
begin
    if p_user_id is not null then
        -- Pushes compute "as" each member; only the service role may do so.
        if coalesce(auth.role(), '') <> 'service_role' then
            raise exception 'p_user_id is reserved for the service role'
                using errcode = '42501';
        end if;
        v_uid := p_user_id;
    end if;
    if v_uid is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;
    if p_today is null then
        raise exception 'p_today is required' using errcode = '22004';
    end if;
    -- "Today" is the caller's local day, so at most a day or two from UTC.
    -- Arbitrary past days let a member read the budget day by day (S7).
    if p_today not between (now() at time zone 'UTC')::date - 2
                       and (now() at time zone 'UTC')::date + 2 then
        raise exception 'p_today must be the current local date' using errcode = '22023';
    end if;

    -- A bad zone name must not fail the call: ignore it.
    if p_tz is not null then
        begin
            perform now() at time zone p_tz;
            v_tz := p_tz;
        exception when others then
            v_tz := null;
        end;
    end if;

    select coalesce(jsonb_agg(budget_metrics_one(b.id, p_today, v_tz)
                              order by b.created_at desc nulls last, b.id), '[]'::jsonb)
      into v_out
      from budgets b
     where b.is_active
       and (b.user_id = v_uid
            or exists (select 1 from budget_members m
                        where m.budget_id = b.id and m.user_id = v_uid))
       and (p_budget_ids is null or b.id = any(p_budget_ids));

    return jsonb_build_object(
        'version',      1,
        'today',        p_today,
        'generated_at', now(),
        'budgets',      v_out);
end;
$function$;
