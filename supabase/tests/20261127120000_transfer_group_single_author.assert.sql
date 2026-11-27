-- Dry run: begin; <migration>; <this file>; rollback;
do $$
declare
    v_acc  uuid;  v_a uuid;  v_b uuid;  v_b_card uuid;  v_g uuid;  v_t uuid;
    v_new  uuid := gen_random_uuid();
    v_ok   boolean;
begin
    -- A shared account with two members, and an auto-transfer leg by A on it.
    select a.id into v_acc from accounts a
     where (select count(*) from account_members m where m.account_id = a.id) > 1 limit 1;
    select t.user_id, t.auto_transfer_group_id, t.transfer_group_id into v_a, v_g, v_t
      from transactions t
     where t.account_id = v_acc and t.auto_transfer_group_id is not null and t.transfer_group_id is not null
     order by t.created_at desc limit 1;
    select m.user_id into v_b from account_members m where m.account_id = v_acc and m.user_id <> v_a limit 1;
    select a.id into v_b_card from accounts a where a.user_id = v_b and a.id <> v_acc limit 1;
    if v_t is null or v_b is null or v_b_card is null then raise exception 'ASSERT FAILED: fixture missing'; end if;

    -- 1. B plants a row with A's transfer group on B's own card: refused.
    v_ok := false;
    begin
        insert into transactions(id, user_id, account_id, amount, amount_native, type, date, transfer_group_id)
        values (v_new, v_b, v_b_card, 0.01, 0.01, 'expense', now(), v_t);
    exception when insufficient_privilege then v_ok := true;
    end;
    if not v_ok then raise exception 'ASSERT FAILED: foreign transfer_group_id accepted'; end if;

    -- 2. Same with A's auto-transfer group: refused.
    v_ok := false;
    begin
        insert into transactions(id, user_id, account_id, amount, amount_native, type, date, auto_transfer_group_id)
        values (v_new, v_b, v_b_card, 0.01, 0.01, 'expense', now(), v_g);
    exception when insufficient_privilege then v_ok := true;
    end;
    if not v_ok then raise exception 'ASSERT FAILED: foreign auto_transfer_group_id accepted'; end if;

    -- 3. A manual transfer by one user: both legs accepted.
    v_g := gen_random_uuid();
    insert into transactions(user_id, account_id, amount, amount_native, type, date, transfer_group_id)
    values (v_b, v_b_card, 1, 1, 'expense', now(), v_g);
    insert into transactions(user_id, account_id, amount, amount_native, type, date, transfer_group_id)
    values (v_b, v_acc, 1, 1, 'income', now(), v_g);
    if (select count(*) from transactions where transfer_group_id = v_g) <> 2 then
        raise exception 'ASSERT FAILED: same-author transfer refused';
    end if;
end $$;
select 'transfer group single author: all assertions passed' as result;
