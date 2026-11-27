-- Dry run: begin; <capture below>; <migration>; <compare below>; rollback;
-- On prod data (no three-party setups) every budget's numbers must be
-- identical before and after; an out-of-range p_today must be refused.
do $$
declare v_diff int; v_ok boolean;
begin
    perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
    select count(*) into v_diff
      from s7_before b
      join lateral (select public.get_budget_metrics(current_date, null, null, b.uid) m) a on true
     where (b.m - 'generated_at') is distinct from (a.m - 'generated_at');
    if v_diff <> 0 then raise exception 'ASSERT FAILED: % users see different metrics', v_diff; end if;

    v_ok := false;
    begin perform public.get_budget_metrics(current_date - 30, null, null, (select uid from s7_before limit 1));
    exception when invalid_parameter_value then v_ok := true; end;
    if not v_ok then raise exception 'ASSERT FAILED: past p_today accepted'; end if;
end $$;
select 'budget metrics members-only: identical on prod data' as result;
