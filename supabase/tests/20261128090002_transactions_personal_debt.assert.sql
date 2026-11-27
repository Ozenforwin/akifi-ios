-- Assertions for 20261128090002_transactions_personal_debt.sql (dry run, rolled back).
-- Needs 20261128090000_debt_accounts.sql applied first (one check uses a debt account).
-- Fixtures are created inside the transaction from four existing users read
-- at runtime (A owner, B editor, C viewer of a fresh shared account S; D an
-- outsider). No prod id is hard-coded; no existing row is modified.
-- SAFETY: writes test rows and impersonates users — dry run only:
--   db_dryrun.py <(echo "select set_config('akifi.dry_run','on',true);") \
--     20261128090000_debt_accounts.sql 20261128090002_transactions_personal_debt.sql <this file>
do $$
begin
    if coalesce(current_setting('akifi.dry_run', true), '') <> 'on' then
        raise exception 'Assertion file: run only via the dry-run helper with akifi.dry_run=on (BEGIN … ROLLBACK).';
    end if;
end $$;

-- ── Setup as DB owner, no JWT ──────────────────────────────────────────────
do $$
declare
    v_u uuid[];
begin
    perform set_config('request.jwt.claims', '{}', true),
            set_config('request.jwt.claim.sub', '', true),
            set_config('request.jwt.claim.role', '', true);

    select array_agg(x.id order by x.created_at, x.id) into v_u
      from (select u.id, u.created_at from auth.users u join profiles p on p.id = u.id
             order by u.created_at, u.id limit 4) x;
    if coalesce(cardinality(v_u), 0) < 4 then
        raise exception 'ASSERT FAILED: fixture missing (need 4 users with profiles)';
    end if;
    perform set_config('test.a', v_u[1]::text, true), set_config('test.b', v_u[2]::text, true),
            set_config('test.c', v_u[3]::text, true), set_config('test.d', v_u[4]::text, true),
            set_config('test.s',  gen_random_uuid()::text, true),
            set_config('test.ca', gen_random_uuid()::text, true),
            set_config('test.cb', gen_random_uuid()::text, true),
            set_config('test.x',  gen_random_uuid()::text, true),
            set_config('test.e1', gen_random_uuid()::text, true),
            set_config('test.e2', gen_random_uuid()::text, true),
            set_config('test.e4', gen_random_uuid()::text, true),
            set_config('test.e5', gen_random_uuid()::text, true),
            set_config('test.r1', gen_random_uuid()::text, true);

    insert into accounts (id, user_id, name, icon, color, initial_balance, currency, account_type)
    values (current_setting('test.s')::uuid,  v_u[1], 'akifi-test shared', 'person.2.fill',  '#3B82F6', 0, 'rub', 'checking'),
           (current_setting('test.ca')::uuid, v_u[1], 'akifi-test card A', 'creditcard.fill', '#3B82F6', 0, 'rub', 'checking'),
           (current_setting('test.cb')::uuid, v_u[2], 'akifi-test card B', 'creditcard.fill', '#3B82F6', 0, 'rub', 'checking'),
           (current_setting('test.x')::uuid,  v_u[1], 'akifi-test debt',   'person.fill',     '#F59E0B', 0, 'rub', 'debt');
    insert into account_members (account_id, user_id, role)
    values (current_setting('test.s')::uuid, v_u[2], 'editor'),
           (current_setting('test.s')::uuid, v_u[3], 'viewer');
end $$;

-- ── As B (editor of S, authenticated, RLS on) ─────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.b'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_a  uuid := current_setting('test.a')::uuid;
    v_b  uuid := current_setting('test.b')::uuid;
    v_d  uuid := current_setting('test.d')::uuid;
    v_s  uuid := current_setting('test.s')::uuid;
    v_cb uuid := current_setting('test.cb')::uuid;
    v_g  uuid;
    v_e3 uuid;
    v_e6 uuid;
    v_grp uuid;
begin
    -- 1. The author marks their own direct expense for themselves.
    insert into transactions (id, user_id, account_id, amount, amount_native, currency, type, date, personal_debt_user_id)
    values (current_setting('test.e1')::uuid, v_b, v_s, 25, 25, 'RUB', 'expense', now(), v_b);
    -- 2. An editor marks a co-member.
    insert into transactions (id, user_id, account_id, amount, amount_native, currency, type, date, personal_debt_user_id)
    values (current_setting('test.e2')::uuid, v_b, v_s, 10, 10, 'RUB', 'expense', now(), v_a);
    -- (unmarked expense by B and a marked one, used by A below)
    insert into transactions (id, user_id, account_id, amount, amount_native, currency, type, date)
    values (current_setting('test.e4')::uuid, v_b, v_s, 7, 7, 'RUB', 'expense', now());
    insert into transactions (id, user_id, account_id, amount, amount_native, currency, type, date, personal_debt_user_id)
    values (current_setting('test.e5')::uuid, v_b, v_s, 8, 8, 'RUB', 'expense', now(), v_b);

    -- 3. Not a member of the account.
    begin
        insert into transactions (user_id, account_id, amount, amount_native, type, date, personal_debt_user_id)
        values (v_b, v_s, 1, 1, 'expense', now(), v_d);
        raise exception 'ASSERT FAILED: outsider marked as personal debtor';
    exception when check_violation then
        if sqlerrm not like 'personal_debt_not_member%' then raise; end if;
    end;
    -- 4. Not a shared account.
    begin
        insert into transactions (user_id, account_id, amount, amount_native, type, date, personal_debt_user_id)
        values (v_b, v_cb, 1, 1, 'expense', now(), v_b);
        raise exception 'ASSERT FAILED: personal mark on a personal card';
    exception when check_violation then
        if sqlerrm not like 'personal_debt_not_shared%' then raise; end if;
    end;
    -- 5. Plain income is neither an expense nor a repayment leg.
    begin
        insert into transactions (user_id, account_id, amount, amount_native, type, date, personal_debt_user_id)
        values (v_b, v_s, 1, 1, 'income', now(), v_b);
        raise exception 'ASSERT FAILED: personal mark on a plain income';
    exception when check_violation then
        if sqlerrm not like 'personal_debt_invalid_row%' then raise; end if;
    end;
    -- 6. Repayment «Погасить»: manual transfer card B -> S, income leg marked for B.
    v_g := gen_random_uuid();
    insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id)
    values (v_b, v_cb, 5, 5, 'RUB', 'expense', now(), v_g);
    insert into transactions (id, user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id, personal_debt_user_id)
    values (current_setting('test.r1')::uuid, v_b, v_s, 5, 5, 'RUB', 'income', now(), v_g, v_b);
    -- 7. … only for oneself, even for an editor.
    begin
        v_g := gen_random_uuid();
        insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id)
        values (v_b, v_cb, 5, 5, 'RUB', 'expense', now(), v_g);
        insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id, personal_debt_user_id)
        values (v_b, v_s, 5, 5, 'RUB', 'income', now(), v_g, v_a);
        raise exception 'ASSERT FAILED: repayment recorded for somebody else';
    exception when insufficient_privilege then
        if sqlerrm not like 'personal_debt_repayment_self_only%' then raise; end if;
    end;
    -- 8. «Оплачено с» + personal in one call (15-arg overload): only the main expense is marked.
    v_e3 := public.create_expense_with_auto_transfer(
        v_s, null, 40, 'RUB', now(), 'akifi-test personal', null, v_cb,
        null, null, null, null, null, gen_random_uuid(), v_b);
    select auto_transfer_group_id into v_grp from transactions where id = v_e3;
    if (select personal_debt_user_id from transactions where id = v_e3) is distinct from v_b then
        raise exception 'ASSERT FAILED: 15-arg create did not mark the main expense';
    end if;
    if (select count(*) from transactions where auto_transfer_group_id = v_grp) <> 3
       or exists (select 1 from transactions where auto_transfer_group_id = v_grp and id <> v_e3
                   and personal_debt_user_id is not null) then
        raise exception 'ASSERT FAILED: 15-arg create triplet shape';
    end if;
    -- 9. … the transfer legs of an auto-transfer can never carry the mark.
    begin
        update transactions set personal_debt_user_id = v_b
         where auto_transfer_group_id = v_grp and type = 'income';
        raise exception 'ASSERT FAILED: personal mark on an auto-transfer leg';
    exception when check_violation then
        if sqlerrm not like 'personal_debt_invalid_row%' then raise; end if;
    end;
    -- 10. 15-arg with NULL = the 14-arg behaviour.
    v_e6 := public.create_expense_with_auto_transfer(
        v_s, null, 3, 'RUB', now(), 'akifi-test shared', null, v_cb,
        null, null, null, null, null, gen_random_uuid(), null);
    if (select personal_debt_user_id from transactions where id = v_e6) is not null then
        raise exception 'ASSERT FAILED: 15-arg create with NULL marked the expense';
    end if;
    -- 11. A client that does not know the column moves a marked row: the mark
    --     is dropped, the statement is not refused.
    update transactions set account_id = v_cb where id = current_setting('test.e1')::uuid;
    if (select personal_debt_user_id from transactions where id = current_setting('test.e1')::uuid) is not null then
        raise exception 'ASSERT FAILED: mark kept on a row moved to a personal card';
    end if;
    -- 12. An editor clears a mark.
    update transactions set personal_debt_user_id = null where id = current_setting('test.e2')::uuid;
    if (select personal_debt_user_id from transactions where id = current_setting('test.e2')::uuid) is not null then
        raise exception 'ASSERT FAILED: editor could not clear a mark';
    end if;
end $$;

-- ── As C (viewer of S): RLS keeps a viewer read-only ──────────────────────
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.c'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_c uuid := current_setting('test.c')::uuid;
    v_s uuid := current_setting('test.s')::uuid;
    v_n int;
begin
    begin
        insert into transactions (user_id, account_id, amount, amount_native, type, date, personal_debt_user_id)
        values (v_c, v_s, 1, 1, 'expense', now(), v_c);
        raise exception 'ASSERT FAILED: viewer wrote a transaction';
    exception when insufficient_privilege then null;
    end;
    update transactions set personal_debt_user_id = v_c where id = current_setting('test.e4')::uuid;
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: viewer changed a mark'; end if;
end $$;

-- ── As A (owner of S) ─────────────────────────────────────────────────────
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.a'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_a  uuid := current_setting('test.a')::uuid;
    v_b  uuid := current_setting('test.b')::uuid;
    v_s  uuid := current_setting('test.s')::uuid;
    v_ca uuid := current_setting('test.ca')::uuid;
    v_x  uuid := current_setting('test.x')::uuid;
    v_g  uuid;
begin
    -- The owner marks another member's expense, and re-assigns a mark.
    update transactions set personal_debt_user_id = v_b where id = current_setting('test.e4')::uuid;
    update transactions set personal_debt_user_id = v_a where id = current_setting('test.e5')::uuid;
    if (select personal_debt_user_id from transactions where id = current_setting('test.e4')::uuid) is distinct from v_b
       or (select personal_debt_user_id from transactions where id = current_setting('test.e5')::uuid) is distinct from v_a then
        raise exception 'ASSERT FAILED: owner could not set marks';
    end if;
    -- … but cannot record or undo a repayment on someone else's behalf.
    begin
        v_g := gen_random_uuid();
        insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id)
        values (v_a, v_ca, 5, 5, 'RUB', 'expense', now(), v_g);
        insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id, personal_debt_user_id)
        values (v_a, v_s, 5, 5, 'RUB', 'income', now(), v_g, v_b);
        raise exception 'ASSERT FAILED: owner recorded a repayment for B';
    exception when insufficient_privilege then
        if sqlerrm not like 'personal_debt_repayment_self_only%' then raise; end if;
    end;
    begin
        update transactions set personal_debt_user_id = null where id = current_setting('test.r1')::uuid;
        raise exception 'ASSERT FAILED: owner cleared B''s repayment';
    exception when insufficient_privilege then
        if sqlerrm not like 'personal_debt_forbidden%' then raise; end if;
    end;
    -- Debt accounts are never shared, so never personal.
    begin
        insert into transactions (user_id, account_id, amount, amount_native, type, date, personal_debt_user_id)
        values (v_a, v_x, 1, 1, 'expense', now(), v_a);
        raise exception 'ASSERT FAILED: personal mark on a debt account';
    exception when check_violation then
        if sqlerrm not like 'personal_debt_not_shared%' then raise; end if;
    end;
end $$;

-- ── Trigger, not only RLS: client JWT on the DB-owner connection ──────────
-- (RLS is bypassed here, so these refusals come from the trigger alone.)
reset role;
do $$
declare
    v_a uuid := current_setting('test.a')::uuid;
    v_b uuid := current_setting('test.b')::uuid;
    v_c uuid := current_setting('test.c')::uuid;
    v_s uuid := current_setting('test.s')::uuid;
    v_cb uuid := current_setting('test.cb')::uuid;
    v_g uuid;
begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true),
            set_config('request.jwt.claim.sub', v_c::text, true),
            set_config('request.jwt.claim.role', 'authenticated', true);
    -- The author (here a viewer) may mark their own row for themselves …
    insert into transactions (user_id, account_id, amount, amount_native, type, date, personal_debt_user_id)
    values (v_c, v_s, 2, 2, 'expense', now(), v_c);
    -- … but only an owner/editor may mark someone else.
    begin
        insert into transactions (user_id, account_id, amount, amount_native, type, date, personal_debt_user_id)
        values (v_c, v_s, 2, 2, 'expense', now(), v_b);
        raise exception 'ASSERT FAILED: viewer marked another member';
    exception when insufficient_privilege then
        if sqlerrm not like 'personal_debt_forbidden%' then raise; end if;
    end;
    -- Nor change a mark someone else set.
    begin
        update transactions set personal_debt_user_id = v_c where id = current_setting('test.e4')::uuid;
        raise exception 'ASSERT FAILED: viewer changed another member''s mark';
    exception when insufficient_privilege then
        if sqlerrm not like 'personal_debt_forbidden%' then raise; end if;
    end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true),
            set_config('request.jwt.claim.sub', v_b::text, true);
    begin
        v_g := gen_random_uuid();
        insert into transactions (user_id, account_id, amount, amount_native, type, date, transfer_group_id, personal_debt_user_id)
        values (v_b, v_s, 5, 5, 'income', now(), v_g, v_a);
        raise exception 'ASSERT FAILED: repayment for somebody else (trigger)';
    exception when insufficient_privilege then
        if sqlerrm not like 'personal_debt_repayment_self_only%' then raise; end if;
    end;
end $$;

-- ── Service role / DB owner: data rules still hold ────────────────────────
do $$
declare
    v_a uuid := current_setting('test.a')::uuid;
    v_b uuid := current_setting('test.b')::uuid;
    v_d uuid := current_setting('test.d')::uuid;
    v_s uuid := current_setting('test.s')::uuid;
begin
    perform set_config('request.jwt.claims', '{}', true),
            set_config('request.jwt.claim.sub', '', true),
            set_config('request.jwt.claim.role', '', true);
    begin
        insert into transactions (user_id, account_id, amount, amount_native, type, date, personal_debt_user_id)
        values (v_a, v_s, 1, 1, 'expense', now(), v_d);
        raise exception 'ASSERT FAILED: service wrote a mark for an outsider';
    exception when check_violation then
        if sqlerrm not like 'personal_debt_not_member%' then raise; end if;
    end;
    -- Data repair may record a repayment for anyone (permission rules are for clients).
    insert into transactions (user_id, account_id, amount, amount_native, type, date, transfer_group_id, personal_debt_user_id)
    values (v_a, v_s, 1, 1, 'income', now(), gen_random_uuid(), v_b);
    -- A legacy edit turning a marked expense into an income drops the mark.
    update transactions set type = 'income' where id = current_setting('test.e4')::uuid;
    if (select personal_debt_user_id from transactions where id = current_setting('test.e4')::uuid) is not null then
        raise exception 'ASSERT FAILED: mark kept on an expense turned into income';
    end if;
    -- Deleting the marked user's auth row sets the column to NULL (FK), not a cascade.
    if (select confdeltype from pg_constraint
         where conrelid = 'public.transactions'::regclass and contype = 'f'
           and conkey = array[(select attnum from pg_attribute
                                where attrelid = 'public.transactions'::regclass
                                  and attname = 'personal_debt_user_id')]) <> 'n' then
        raise exception 'ASSERT FAILED: personal_debt_user_id FK is not ON DELETE SET NULL';
    end if;
end $$;

select 'personal debt marks: all assertions passed' as result;
