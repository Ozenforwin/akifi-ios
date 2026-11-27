-- Assertions for 20261128090000_debt_accounts.sql + 20261128090001_debts_summary_rpc.sql
-- (dry run, rolled back). Fixtures are created inside the transaction; the
-- only real rows used are two existing users (A owns at least one budget,
-- B is anyone else) and, read-only until rolled back, one existing budget of
-- A and one existing subscription. No prod id is hard-coded.
-- SAFETY: this file writes test rows (and impersonates users). It refuses to
-- run unless the session is marked as a dry run inside BEGIN … ROLLBACK:
--   db_dryrun.py <(echo "select set_config('akifi.dry_run','on',true);") \
--     20261128090000_debt_accounts.sql 20261128090001_debts_summary_rpc.sql <this file>
do $$
begin
    if coalesce(current_setting('akifi.dry_run', true), '') <> 'on' then
        raise exception 'Assertion file: run only via the dry-run helper with akifi.dry_run=on (BEGIN … ROLLBACK).';
    end if;
end $$;

-- ── Setup as DB owner, no JWT ──────────────────────────────────────────────
do $$
declare
    v_a uuid;
    v_b uuid;
begin
    perform set_config('request.jwt.claims', '{}', true),
            set_config('request.jwt.claim.sub', '', true),
            set_config('request.jwt.claim.role', '', true);

    select b.user_id into v_a
      from budgets b join profiles p on p.id = b.user_id
     order by b.created_at, b.id limit 1;
    select u.id into v_b
      from auth.users u join profiles p on p.id = u.id
     where u.id <> v_a
     order by u.created_at, u.id limit 1;
    if v_a is null or v_b is null then
        raise exception 'ASSERT FAILED: fixture missing (a budget owner and a second user)';
    end if;

    perform set_config('test.a',  v_a::text, true),
            set_config('test.b',  v_b::text, true),
            set_config('test.ca', gen_random_uuid()::text, true),
            set_config('test.cb', gen_random_uuid()::text, true),
            set_config('test.s2', gen_random_uuid()::text, true),
            set_config('test.x',  gen_random_uuid()::text, true),
            set_config('test.y',  gen_random_uuid()::text, true),
            set_config('test.z',  gen_random_uuid()::text, true);

    insert into accounts (id, user_id, name, icon, color, initial_balance, currency)
    values (current_setting('test.ca')::uuid, v_a, 'akifi-test card A', 'creditcard.fill', '#3B82F6', 0, 'rub'),
           (current_setting('test.cb')::uuid, v_b, 'akifi-test card B', 'creditcard.fill', '#3B82F6', 0, 'rub'),
           (current_setting('test.s2')::uuid, v_a, 'akifi-test shared', 'person.2.fill', '#3B82F6', 0, 'rub');
    insert into account_members (account_id, user_id, role)
    values (current_setting('test.s2')::uuid, v_b, 'editor');
end $$;

-- ── As A (authenticated, RLS on): create, move money, summary, rules ──────
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.a'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_a    uuid := current_setting('test.a')::uuid;
    v_b    uuid := current_setting('test.b')::uuid;
    v_ca   uuid := current_setting('test.ca')::uuid;
    v_x    uuid := current_setting('test.x')::uuid;
    v_y    uuid := current_setting('test.y')::uuid;
    v_z    uuid := current_setting('test.z')::uuid;
    v_g    uuid;
    v_base jsonb;
    v_s    jsonb;
    v_d    jsonb;
    v_t    jsonb;
    v_base_owed bigint;
    v_base_iowe bigint;
    v_base_open int;
    v_budget uuid;
begin
    -- Baseline (A may already have real debts once this is live).
    v_base := public.debts_summary();
    if (v_base->>'version')::int <> 1 or jsonb_typeof(v_base->'debts') <> 'array' then
        raise exception 'ASSERT FAILED: debts_summary shape %', v_base;
    end if;
    select coalesce((t->>'owed_to_me')::bigint, 0), coalesce((t->>'i_owe')::bigint, 0), coalesce((t->>'open_count')::int, 0)
      into v_base_owed, v_base_iowe, v_base_open
      from jsonb_array_elements(v_base->'totals') t where t->>'currency' = 'RUB';
    v_base_owed := coalesce(v_base_owed, 0); v_base_iowe := coalesce(v_base_iowe, 0); v_base_open := coalesce(v_base_open, 0);

    -- 1. create_debt: account (type debt, balance 0, lower-case currency) + details.
    if public.create_debt(v_x, 'Маша', 'RUB', null, null, '  Маша  ', '+7 900 000-00-00',
                          current_date + 30, true, 'на ремонт') <> v_x then
        raise exception 'ASSERT FAILED: create_debt returned another id';
    end if;
    if not exists (select 1 from accounts
                    where id = v_x and user_id = v_a and account_type = 'debt'
                      and currency = 'rub' and initial_balance = 0) then
        raise exception 'ASSERT FAILED: debt account row';
    end if;
    if (select counterparty_name from debts where account_id = v_x) is distinct from 'Маша' then
        raise exception 'ASSERT FAILED: debts row missing or name not trimmed';
    end if;
    if not exists (select 1 from account_members where account_id = v_x and user_id = v_a and role = 'owner') then
        raise exception 'ASSERT FAILED: owner membership of the debt account';
    end if;
    -- Offline retry with the same id: 23505, no second debt.
    begin
        perform public.create_debt(v_x, 'Маша', 'rub', null, null, 'Маша', null, null, false, null);
        raise exception 'ASSERT FAILED: create_debt retry accepted';
    exception when unique_violation then null;
    end;
    perform public.create_debt(v_y, 'Петя', 'rub', 'person.fill', '#10B981', 'Петя', null, null, false, null);

    -- 2. The four actions are ordinary manual transfers.
    v_g := gen_random_uuid();   -- «Дал в долг» 500: card -> X
    insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id)
    values (v_a, v_ca, 500, 500, 'RUB', 'expense', now(), v_g),
           (v_a, v_x,  500, 500, 'RUB', 'income',  now(), v_g);
    v_g := gen_random_uuid();   -- «Мне вернули» 200: X -> card
    insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id)
    values (v_a, v_x,  200, 200, 'RUB', 'expense', now(), v_g),
           (v_a, v_ca, 200, 200, 'RUB', 'income',  now(), v_g);
    v_g := gen_random_uuid();   -- «Взял в долг» 1000: Y -> card
    insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id)
    values (v_a, v_y,  1000, 1000, 'RUB', 'expense', now(), v_g),
           (v_a, v_ca, 1000, 1000, 'RUB', 'income',  now(), v_g);
    v_g := gen_random_uuid();   -- «Я вернул» 300.55: card -> Y
    insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id)
    values (v_a, v_ca, 300.55, 300.55, 'RUB', 'expense', now(), v_g),
           (v_a, v_y,  300.55, 300.55, 'RUB', 'income',  now(), v_g);

    v_s := public.debts_summary();
    select d into v_d from jsonb_array_elements(v_s->'debts') d where d->>'account_id' = v_x::text;
    if (v_d->>'balance')::bigint <> 30000 or v_d->>'direction' <> 'owed_to_me'
       or (v_d->>'tx_count')::int <> 2 or (v_d->>'has_details')::boolean is not true
       or (v_d->>'remind')::boolean is not true or v_d->>'currency' <> 'RUB'
       or (v_d->>'is_overdue')::boolean or (v_d->>'is_closed')::boolean then
        raise exception 'ASSERT FAILED: X summary %', v_d;
    end if;
    select d into v_d from jsonb_array_elements(v_s->'debts') d where d->>'account_id' = v_y::text;
    if (v_d->>'balance')::bigint <> -69945 or v_d->>'direction' <> 'i_owe' then
        raise exception 'ASSERT FAILED: Y summary %', v_d;
    end if;
    select t into v_t from jsonb_array_elements(v_s->'totals') t where t->>'currency' = 'RUB';
    if (v_t->>'owed_to_me')::bigint <> v_base_owed + 30000
       or (v_t->>'i_owe')::bigint <> v_base_iowe + 69945
       or (v_t->>'open_count')::int <> v_base_open + 2 then
        raise exception 'ASSERT FAILED: totals % (base owed %, i_owe %, open %)', v_t, v_base_owed, v_base_iowe, v_base_open;
    end if;

    -- 3. Overdue.
    update debts set due_date = (v_s->>'today')::date - 1 where account_id = v_x;
    select d into v_d from jsonb_array_elements(public.debts_summary()->'debts') d where d->>'account_id' = v_x::text;
    if (v_d->>'is_overdue')::boolean is not true then
        raise exception 'ASSERT FAILED: overdue not flagged %', v_d;
    end if;

    -- 4. Closing removes the debt from the totals, keeps it in the list.
    update debts set closed_at = now() where account_id = v_y;
    v_s := public.debts_summary();
    select d into v_d from jsonb_array_elements(v_s->'debts') d where d->>'account_id' = v_y::text;
    if (v_d->>'is_closed')::boolean is not true or (v_d->>'is_overdue')::boolean then
        raise exception 'ASSERT FAILED: closed debt %', v_d;
    end if;
    select t into v_t from jsonb_array_elements(v_s->'totals') t where t->>'currency' = 'RUB';
    if (v_t->>'i_owe')::bigint <> v_base_iowe or (v_t->>'open_count')::int <> v_base_open + 1 then
        raise exception 'ASSERT FAILED: totals after close %', v_t;
    end if;
    -- Open debts are listed before closed ones.
    if (select min(o) from jsonb_array_elements(v_s->'debts') with ordinality e(d, o) where d->>'account_id' = v_y::text)
       < (select max(o) from jsonb_array_elements(v_s->'debts') with ordinality e(d, o) where (d->>'is_closed')::boolean is false) then
        raise exception 'ASSERT FAILED: closed debt listed before an open one';
    end if;

    -- 5. A reminder needs a due date.
    begin
        update debts set due_date = null where account_id = v_x;
        raise exception 'ASSERT FAILED: remind without due_date accepted';
    exception when check_violation then null;
    end;

    -- 6. account_type 'debt' is fixed at creation (client sessions).
    begin
        update accounts set account_type = 'checking' where id = v_x;
        raise exception 'ASSERT FAILED: debt account converted to checking';
    exception when insufficient_privilege then null;
    end;
    begin
        update accounts set account_type = 'debt' where id = v_ca;
        raise exception 'ASSERT FAILED: card converted to a debt account';
    exception when insufficient_privilege then null;
    end;
    -- Renaming a debt account still works.
    update accounts set name = 'Маша (ремонт)' where id = v_x;

    -- 7. Owner fields of the details row are immutable.
    begin
        update debts set user_id = v_b where account_id = v_x;
        raise exception 'ASSERT FAILED: debts.user_id changed';
    exception when insufficient_privilege then null;
    end;
    begin
        update debts set account_id = v_ca where account_id = v_x;
        raise exception 'ASSERT FAILED: debts.account_id changed';
    exception when insufficient_privilege then null;
    end;

    -- 8. Not primary, not shareable, not linkable to a budget.
    begin
        perform public.set_my_primary_account(v_x);
        raise exception 'ASSERT FAILED: debt account made primary';
    exception when check_violation then
        if sqlerrm not like 'debt_account_not_primary%' then raise; end if;
    end;
    begin
        perform public.create_account_invite(v_x, 'viewer', 72);
        raise exception 'ASSERT FAILED: invite for a debt account created';
    exception when check_violation then
        if sqlerrm not like 'debt_account_not_shareable%' then raise; end if;
    end;
    select id into v_budget from budgets where user_id = v_a order by created_at, id limit 1;
    begin
        update budgets set account_ids = array[v_x] where id = v_budget;
        raise exception 'ASSERT FAILED: budget linked to a debt account (budget %)', v_budget;
    exception when check_violation then
        if sqlerrm not like 'debt_account_not_linkable%' then raise; end if;
    end;

    -- 9. The CHECK constraint knows 'debt' and nothing invented.
    begin
        insert into accounts (user_id, name, icon, color, initial_balance, currency, account_type)
        values (v_a, 'akifi-test loan', 'x', '#000000', 0, 'rub', 'loan');
        raise exception 'ASSERT FAILED: unknown account_type accepted';
    exception when check_violation then null;
    end;

    -- 10. Details only on a debt account.
    begin
        insert into debts (account_id, user_id, counterparty_name) values (v_ca, v_a, 'Кто-то');
        raise exception 'ASSERT FAILED: debts row on a card accepted';
    exception when check_violation then
        if sqlerrm not like 'debt_account_required%' then raise; end if;
    end;

    -- 11. Interrupted two-step create (account without details) is still listed.
    insert into accounts (id, user_id, name, icon, color, initial_balance, currency, account_type)
    values (v_z, v_a, 'akifi-test orphan', 'person.fill', '#000000', 0, 'usd', 'debt');
    select d into v_d from jsonb_array_elements(public.debts_summary()->'debts') d where d->>'account_id' = v_z::text;
    if (v_d->>'has_details')::boolean is not false or v_d->>'counterparty_name' <> 'akifi-test orphan'
       or v_d->>'currency' <> 'USD' or v_d->>'direction' <> 'settled' then
        raise exception 'ASSERT FAILED: orphan debt account %', v_d;
    end if;
end $$;

-- ── As B (authenticated): A's debts are invisible and untouchable ─────────
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.b'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_b uuid := current_setting('test.b')::uuid;
    v_x uuid := current_setting('test.x')::uuid;
    v_y uuid := current_setting('test.y')::uuid;
    v_n int;
begin
    if exists (select 1 from accounts where id in (v_x, v_y)) then
        raise exception 'ASSERT FAILED: B sees A''s debt accounts';
    end if;
    if exists (select 1 from debts where account_id in (v_x, v_y)) then
        raise exception 'ASSERT FAILED: B sees A''s debts rows';
    end if;
    if exists (select 1 from transactions where account_id in (v_x, v_y)) then
        raise exception 'ASSERT FAILED: B sees A''s debt movements';
    end if;
    if exists (select 1 from jsonb_array_elements(public.debts_summary()->'debts') d
                where d->>'account_id' in (v_x::text, v_y::text)) then
        raise exception 'ASSERT FAILED: debts_summary leaks A''s debts to B';
    end if;
    begin
        perform public.get_account_settlement(v_x);
        raise exception 'ASSERT FAILED: B read the settlement of A''s debt account';
    exception when insufficient_privilege then null;
    end;
    begin
        insert into transactions (user_id, account_id, amount, amount_native, type, date)
        values (v_b, v_x, 1, 1, 'income', now());
        raise exception 'ASSERT FAILED: B wrote on A''s debt account';
    exception when insufficient_privilege then null;
    end;
    begin
        insert into debts (account_id, user_id, counterparty_name) values (v_x, v_b, 'B');
        raise exception 'ASSERT FAILED: B attached details to A''s debt account';
    exception when check_violation or insufficient_privilege then null;
    end;
    update debts set note = 'changed by B' where account_id = v_x;
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: B updated A''s debt'; end if;
    delete from debts where account_id = v_x;
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: B deleted A''s debt'; end if;
end $$;

-- ── DB owner (service-like): data rules hold for every role ───────────────
reset role;
do $$
declare
    v_a   uuid := current_setting('test.a')::uuid;
    v_b   uuid := current_setting('test.b')::uuid;
    v_x   uuid := current_setting('test.x')::uuid;
    v_y   uuid := current_setting('test.y')::uuid;
    v_s2  uuid := current_setting('test.s2')::uuid;
    v_sub uuid;
begin
    perform set_config('request.jwt.claims', '{}', true),
            set_config('request.jwt.claim.sub', '', true),
            set_config('request.jwt.claim.role', '', true);

    -- Sharing a debt account is refused even without RLS (accept_account_invite path).
    begin
        insert into account_members (account_id, user_id, role) values (v_x, v_b, 'viewer');
        raise exception 'ASSERT FAILED: debt account shared';
    exception when check_violation then
        if sqlerrm not like 'debt_account_not_shareable%' then raise; end if;
    end;
    -- A shared account cannot become a debt account.
    begin
        update accounts set account_type = 'debt' where id = v_s2;
        raise exception 'ASSERT FAILED: shared account turned into a debt account';
    exception when check_violation then
        if sqlerrm not like 'debt_account_not_shareable%' then raise; end if;
    end;
    -- A debt account with details cannot silently stop being one.
    begin
        update accounts set account_type = 'checking' where id = v_x;
        raise exception 'ASSERT FAILED: debt account with details converted';
    exception when check_violation then null;
    end;
    -- The owner of a debt account is fixed for every role.
    begin
        update accounts set user_id = v_b where id = v_x;
        raise exception 'ASSERT FAILED: debt account handed to another user';
    exception when insufficient_privilege then null;
    end;

    -- Subscriptions cannot be charged to a debt account (service-role JWT so
    -- the Mini App's own account check steps aside; the debt rule does not).
    perform set_config('request.jwt.claims', '{"role":"service_role"}', true),
            set_config('request.jwt.claim.role', 'service_role', true);
    select id into v_sub from subscriptions order by created_at, id limit 1;
    if v_sub is null then
        raise notice 'no subscriptions on this database: subscription link check skipped';
    else
        begin
            update subscriptions set account_id = v_x where id = v_sub;
            raise exception 'ASSERT FAILED: subscription linked to a debt account';
        exception when check_violation then
            if sqlerrm not like 'debt_account_not_linkable%' then raise; end if;
        end;
    end if;

    -- Deleting the debt account removes its details.
    delete from accounts where id = v_y;
    if exists (select 1 from debts where account_id = v_y) then
        raise exception 'ASSERT FAILED: debts row survived its account';
    end if;
end $$;

select 'debt accounts: all assertions passed' as result;
