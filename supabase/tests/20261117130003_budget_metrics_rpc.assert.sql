-- Assertions for 20261117130000..130003 — dry-run helper only (BEGIN … ROLLBACK).
-- Both members of a shared budget must get identical metrics.
create temp table _m (who text, r jsonb) on commit drop;
grant all on _m to authenticated;

select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true), set_config('role','authenticated',true);
insert into _m select 'V', public.get_budget_metrics((now() at time zone 'Asia/Bangkok')::date, 'Asia/Bangkok');
reset role;
select set_config('request.jwt.claims','{"sub":"66673fe4-69ee-429f-b0a2-81b9e838b41d","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','66673fe4-69ee-429f-b0a2-81b9e838b41d',true), set_config('role','authenticated',true);
insert into _m select 'O', public.get_budget_metrics((now() at time zone 'Asia/Bangkok')::date, 'Asia/Bangkok');
reset role;

do $$
declare v_shared int; v_diff int;
begin
    with v as (select b->>'budget_id' id, b->>'spent' spent, b->>'effective_limit' lim, b->>'period_start' ps
                 from _m, jsonb_array_elements(r->'budgets') b where who = 'V'),
         o as (select b->>'budget_id' id, b->>'spent' spent, b->>'effective_limit' lim, b->>'period_start' ps
                 from _m, jsonb_array_elements(r->'budgets') b where who = 'O')
    select count(*), count(*) filter (where v.spent is distinct from o.spent or v.lim is distinct from o.lim or v.ps is distinct from o.ps)
      into v_shared, v_diff from v join o using (id);
    if v_shared = 0 then raise exception 'ASSERT FAILED: no shared budget visible to both members'; end if;
    if v_diff > 0 then raise exception 'ASSERT FAILED: % shared budgets differ between members', v_diff; end if;
    raise notice 'shared budgets identical: %', v_shared;
end $$;

-- A stranger gets nothing; anon cannot call it at all.
select set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true), set_config('role','authenticated',true);
do $$ begin
    if jsonb_array_length(public.get_budget_metrics(current_date)->'budgets') <> 0 then raise exception 'ASSERT FAILED: stranger sees budgets'; end if;
    begin
        perform public.get_budget_metrics(current_date, null, null, '2ebaaa87-1e23-46f7-a66e-c85d2bb8227c');
        raise exception 'ASSERT FAILED: authenticated used p_user_id';
    exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
    if has_function_privilege('anon','public.get_budget_metrics(date,text,uuid[],uuid)','EXECUTE') then raise exception 'ASSERT FAILED: anon can call'; end if;
    if exists (select 1 from public.budgets where currency is null) then raise exception 'ASSERT FAILED: null budget currency'; end if;
end $$;
select (select jsonb_agg(jsonb_build_object('name', b->>'name', 'spent', b->>'spent', 'limit', b->>'effective_limit', 'window', (b->>'period_start') || '..' || (b->>'period_end')))
          from _m, jsonb_array_elements(r->'budgets') b where who = 'O') as olga_view;
