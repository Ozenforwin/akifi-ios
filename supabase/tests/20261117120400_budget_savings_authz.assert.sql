-- Assertions for 20261117120400_budget_savings_authz.sql (dry run, rolled back).
-- Olga's budget 0e502459… (Vladimir is not a member) is the "foreign" budget.
-- SAFETY: this file writes test rows (and impersonates users). It refuses to run
-- unless the session is marked as a dry run inside BEGIN … ROLLBACK:
--   db_dryrun.py <(echo "select set_config('akifi.dry_run','on',true);") <migration>.sql <this file>
-- (it also matches the CLI's <version>_<name>.sql pattern — never `supabase db push` it).
do $$
begin
    if coalesce(current_setting('akifi.dry_run', true), '') <> 'on' then
        raise exception 'Assertion file: run only via the dry-run helper with akifi.dry_run=on (BEGIN … ROLLBACK).';
    end if;
end $$;

-- ── Olga creates a savings goal (target for the cross-user attempt) ────────
select set_config('request.jwt.claims','{"sub":"66673fe4-69ee-429f-b0a2-81b9e838b41d","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','66673fe4-69ee-429f-b0a2-81b9e838b41d',true),
       set_config('role','authenticated',true);
do $$
declare v uuid;
begin
    insert into public.savings_goals (user_id, name, target_amount) values (auth.uid(), 'dry-run olga goal', 1000)
    returning id into v;
    perform set_config('test.olga_goal', v::text, true);
end $$;

-- ── As Vladimir ────────────────────────────────────────────────────────────
reset role;
select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true),
       set_config('role','authenticated',true);
do $$
declare v_b uuid; v_goal uuid; v_c uuid; v_ok boolean;
begin
    -- Alert on a budget he is not a member of → refused.
    begin
        perform public.record_budget_alert('0e502459-a3c9-410f-805e-714a6add3cbb', current_date, 80);
        raise exception 'ASSERT FAILED: alert recorded for a foreign budget';
    exception when insufficient_privilege then null; end;

    -- Own budget → recorded once.
    insert into public.budgets (user_id, amount, category_ids, name) values (auth.uid(), 1000, '{}', 'dry-run')
    returning id into v_b;
    perform set_config('test.own_budget', v_b::text, true);
    v_ok := public.record_budget_alert(v_b, current_date, 80);
    if not v_ok then raise exception 'ASSERT FAILED: alert on own budget not recorded'; end if;
    v_ok := public.record_budget_alert(v_b, current_date, 80);
    if v_ok then raise exception 'ASSERT FAILED: duplicate alert recorded'; end if;

    -- Savings: own goal works and the trigger updates it.
    insert into public.savings_goals (user_id, name, target_amount) values (auth.uid(), 'dry-run goal', 1000)
    returning id into v_goal;
    insert into public.savings_contributions (goal_id, user_id, amount) values (v_goal, auth.uid(), 250)
    returning id into v_c;
    if (select current_amount from public.savings_goals where id = v_goal) <> 250 then
        raise exception 'ASSERT FAILED: own contribution did not update the goal';
    end if;

    -- Contribution into someone else's goal → refused (insert and re-point).
    begin
        insert into public.savings_contributions (goal_id, user_id, amount)
        values (current_setting('test.olga_goal')::uuid, auth.uid(), 1000000);
        raise exception 'ASSERT FAILED: contribution into a foreign goal accepted';
    exception when insufficient_privilege then null; end;
    begin
        update public.savings_contributions set goal_id = current_setting('test.olga_goal')::uuid where id = v_c;
        raise exception 'ASSERT FAILED: contribution re-pointed to a foreign goal';
    exception when insufficient_privilege then null; end;
end $$;

-- upsert_budget_rollover is service-role only (20261117100000); call it as the
-- DB owner with Vladimir's claims to exercise the new membership check.
reset role;
do $$
declare v uuid;
begin
    begin
        perform public.upsert_budget_rollover('0e502459-a3c9-410f-805e-714a6add3cbb', current_date, current_date + 30, 0, 0);
        raise exception 'ASSERT FAILED: rollover written for a foreign budget';
    exception when insufficient_privilege then null; end;
    v := public.upsert_budget_rollover(current_setting('test.own_budget')::uuid, current_date, current_date + 30, 0, 10);
    if v is null then raise exception 'ASSERT FAILED: rollover for own budget not written'; end if;
end $$;

select 'Review #8 assertions passed' as result;
