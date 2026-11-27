-- Dry run: begin; <migration>; <this file>; rollback;
do $$
declare v_uid uuid; r1 jsonb; r2 jsonb; r3 jsonb; v_ok boolean;
begin
    select id into v_uid from auth.users order by created_at limit 1;
    perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
    delete from ai_quota_ticks where user_id = v_uid;
    r1 := public.ai_quota_take(v_uid, 2);
    r2 := public.ai_quota_take(v_uid, 2);
    r3 := public.ai_quota_take(v_uid, 2);
    if (r1->>'allowed')::boolean is not true or (r2->>'allowed')::boolean is not true or (r3->>'allowed')::boolean is not false then
        raise exception 'ASSERT FAILED: % % %', r1, r2, r3;
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    v_ok := false;
    begin perform public.ai_quota_take(v_uid, 1000);
    exception when insufficient_privilege then v_ok := true; end;
    if not v_ok then raise exception 'ASSERT FAILED: client can take quota'; end if;
end $$;
select 'ai quota: all assertions passed' as result;
