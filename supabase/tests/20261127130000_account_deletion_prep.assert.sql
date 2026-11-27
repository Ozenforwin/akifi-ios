-- Dry run: begin; <migration>; <this file>; rollback;
-- Simulates the owner of a shared account deleting their account.
do $$
declare
    v_acc uuid; v_owner uuid; v_partner uuid;
    v_partner_tx int; v_partner_tx_cat int; v_partner_budgets int;
    v_res jsonb; v_ok boolean;
begin
    select a.id, a.user_id into v_acc, v_owner from accounts a
     where (select count(*) from account_members m where m.account_id = a.id) > 1 limit 1;
    select m.user_id into v_partner from account_members m where m.account_id = v_acc and m.user_id <> v_owner limit 1;
    if v_partner is null then raise exception 'ASSERT FAILED: fixture missing'; end if;

    select count(*), count(category_id) into v_partner_tx, v_partner_tx_cat
      from transactions where account_id = v_acc and user_id = v_partner;
    select count(*) into v_partner_budgets from budget_members where user_id = v_partner;

    -- A client can't call it.
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
    v_ok := false;
    begin perform public.prepare_account_deletion(v_owner);
    exception when insufficient_privilege then v_ok := true; end;
    if not v_ok then raise exception 'ASSERT FAILED: callable by a client'; end if;

    perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
    v_res := public.prepare_account_deletion(v_owner);
    raise notice 'prepare: %', v_res;
    if (v_res->>'accounts_transferred')::int < 1 then raise exception 'ASSERT FAILED: shared account not transferred'; end if;

    delete from auth.users where id = v_owner;   -- what auth.admin.deleteUser does

    if not exists (select 1 from accounts where id = v_acc and user_id = v_partner) then
        raise exception 'ASSERT FAILED: shared account lost';
    end if;
    if not exists (select 1 from account_members where account_id = v_acc and user_id = v_partner and role = 'owner') then
        raise exception 'ASSERT FAILED: partner is not owner';
    end if;
    if (select count(*) from transactions where account_id = v_acc and user_id = v_partner) <> v_partner_tx then
        raise exception 'ASSERT FAILED: partner transactions lost';
    end if;
    if (select count(category_id) from transactions where account_id = v_acc and user_id = v_partner) <> v_partner_tx_cat then
        raise exception 'ASSERT FAILED: partner rows lost their category';
    end if;
    if (select count(*) from budget_members where user_id = v_partner) <> v_partner_budgets then
        raise exception 'ASSERT FAILED: partner budgets lost';
    end if;
    if exists (select 1 from transactions where user_id = v_owner) then
        raise exception 'ASSERT FAILED: leaver rows kept';
    end if;
end $$;
select 'account deletion prep: all assertions passed' as result;
