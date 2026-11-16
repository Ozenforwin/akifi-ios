-- Assertions for 20261117120100_settlement_insert_policies.sql (dry run, rolled back).
-- Fixtures: Vladimir 2ebaaa87… (owner), Olga 66673fe4… (editor), «Семейный» fecd570b….
-- A third real user is added to «Семейный» as a VIEWER later in the dry run.
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

-- ── Setup as DB owner ──────────────────────────────────────────────────────
select set_config('test.third',
       (select u.id::text from auth.users u
         where u.id not in ('2ebaaa87-1e23-46f7-a66e-c85d2bb8227c', '66673fe4-69ee-429f-b0a2-81b9e838b41d')
         order by u.created_at limit 1), true);
-- A main auto-transfer expense on «Семейный» Olga has not marked yet, and one
-- of Olga's own transactions on another account.
select set_config('test.main_tx',
       (select t.id::text from public.transactions t
         where t.account_id = 'fecd570b-150f-4f4f-96ec-111399f22bfe'
           and t.type = 'expense' and t.transfer_group_id is null and t.auto_transfer_group_id is not null
           and not exists (select 1 from public.transaction_member_settlements m
                            where m.transaction_id = t.id
                              and m.settled_for_user_id = '66673fe4-69ee-429f-b0a2-81b9e838b41d')
         order by t.date desc, t.id limit 1), true);
select set_config('test.other_tx',
       (select t.id::text from public.transactions t
         where t.account_id = '8085d0ea-f4e0-46f8-9f8e-486993d3ae77' order by t.id limit 1), true);

-- ── As Olga (editor, a party of the debt) ──────────────────────────────────
select set_config('request.jwt.claims','{"sub":"66673fe4-69ee-429f-b0a2-81b9e838b41d","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','66673fe4-69ee-429f-b0a2-81b9e838b41d',true),
       set_config('role','authenticated',true);

do $$
declare
    v_fam   constant uuid := 'fecd570b-150f-4f4f-96ec-111399f22bfe';
    v_vlad  constant uuid := '2ebaaa87-1e23-46f7-a66e-c85d2bb8227c';
    v_olga  constant uuid := '66673fe4-69ee-429f-b0a2-81b9e838b41d';
    v_s     jsonb;
    v_delta bigint;
    v_n     int;
begin
    -- Baseline: the server settlement says Vladimir owes Olga 5 858.91 ₽.
    v_s := public.get_account_settlement(v_fam);
    select (b->>'contributed')::bigint - (b->>'fair_share')::bigint into v_delta
      from jsonb_array_elements(v_s->'balances') b where b->>'user_id' = v_olga::text;
    if v_delta <> 585891 then raise exception 'ASSERT FAILED: baseline delta % <> 585891', v_delta; end if;

    -- Rejected shapes (each must violate the policy, SQLSTATE 42501).
    begin
        insert into public.settlements (shared_account_id, from_user_id, to_user_id, amount, currency, period_start, period_end, settled_by)
        values (v_fam, v_vlad, v_olga, -585891, 'rub', current_date, current_date, v_olga);
        raise exception 'ASSERT FAILED: negative settlement accepted';
    exception when insufficient_privilege then null; end;
    begin
        insert into public.settlements (shared_account_id, from_user_id, to_user_id, amount, currency, period_start, period_end, settled_by)
        values (v_fam, v_vlad, v_olga, 0, 'rub', current_date, current_date, v_olga);
        raise exception 'ASSERT FAILED: zero settlement accepted';
    exception when insufficient_privilege then null; end;
    begin
        insert into public.settlements (shared_account_id, from_user_id, to_user_id, amount, currency, period_start, period_end, settled_by)
        values (v_fam, v_olga, v_olga, 100, 'rub', current_date, current_date, v_olga);
        raise exception 'ASSERT FAILED: self-settlement accepted';
    exception when insufficient_privilege then null; end;
    begin  -- settled_by spoofed
        insert into public.settlements (shared_account_id, from_user_id, to_user_id, amount, currency, period_start, period_end, settled_by)
        values (v_fam, v_vlad, v_olga, 100, 'rub', current_date, current_date, v_vlad);
        raise exception 'ASSERT FAILED: spoofed settled_by accepted';
    exception when insufficient_privilege then null; end;
    begin  -- wrong currency
        insert into public.settlements (shared_account_id, from_user_id, to_user_id, amount, currency, period_start, period_end, settled_by)
        values (v_fam, v_vlad, v_olga, 100, 'usd', current_date, current_date, v_olga);
        raise exception 'ASSERT FAILED: settlement in a foreign currency accepted';
    exception when insufficient_privilege then null; end;

    -- Marks: not on the account / spoofed marker → rejected.
    begin
        insert into public.transaction_member_settlements (transaction_id, shared_account_id, settled_for_user_id, settled_by_user_id)
        values (current_setting('test.other_tx')::uuid, v_fam, v_olga, v_olga);
        raise exception 'ASSERT FAILED: mark for a transaction outside the shared account accepted';
    exception when insufficient_privilege then null; end;
    begin
        insert into public.transaction_member_settlements (transaction_id, shared_account_id, settled_for_user_id, settled_by_user_id)
        values (current_setting('test.main_tx')::uuid, v_fam, v_olga, v_vlad);
        raise exception 'ASSERT FAILED: mark with spoofed settled_by_user_id accepted';
    exception when insufficient_privilege then null; end;

    -- Legit: per-transaction mark on a «Семейный» expense.
    insert into public.transaction_member_settlements (transaction_id, shared_account_id, settled_for_user_id, settled_by_user_id)
    values (current_setting('test.main_tx')::uuid, v_fam, v_olga, v_olga);
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: legit mark rejected'; end if;
    -- (undo it so the settlement check below starts from the baseline)
    delete from public.transaction_member_settlements
     where transaction_id = current_setting('test.main_tx')::uuid and settled_for_user_id = v_olga;

    -- Legit: Olga records that Vladimir paid her the full debt.
    insert into public.settlements (shared_account_id, from_user_id, to_user_id, amount, currency, period_start, period_end, settled_by)
    values (v_fam, v_vlad, v_olga, 585891, 'RUB', current_date, current_date, v_olga);
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: legit settlement rejected'; end if;

    v_s := public.get_account_settlement(v_fam);
    select (b->>'contributed')::bigint - (b->>'fair_share')::bigint into v_delta
      from jsonb_array_elements(v_s->'balances') b where b->>'user_id' = v_olga::text;
    if v_delta <> 0 then raise exception 'ASSERT FAILED: debt not closed by the settlement (delta %)', v_delta; end if;
end $$;

-- ── Add the third user as a VIEWER of «Семейный» (DB owner) ───────────────
reset role;
insert into public.account_members (account_id, user_id, role)
values ('fecd570b-150f-4f4f-96ec-111399f22bfe', current_setting('test.third')::uuid, 'viewer');
select set_config('request.jwt.claims','{"sub":"66673fe4-69ee-429f-b0a2-81b9e838b41d","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','66673fe4-69ee-429f-b0a2-81b9e838b41d',true),
       set_config('role','authenticated',true);
do $$
begin
    begin  -- Olga is not one of the parties: Vladimir -> third member
        insert into public.settlements (shared_account_id, from_user_id, to_user_id, amount, currency, period_start, period_end, settled_by)
        values ('fecd570b-150f-4f4f-96ec-111399f22bfe', '2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',
                current_setting('test.third')::uuid, 100, 'rub', current_date, current_date, auth.uid());
        raise exception 'ASSERT FAILED: settlement between two other members accepted';
    exception when insufficient_privilege then null; end;
end $$;

-- ── As Vladimir (owner, the other party) ───────────────────────────────────
reset role;
select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true),
       set_config('role','authenticated',true);
do $$
declare v_n int;
begin
    insert into public.settlements (shared_account_id, from_user_id, to_user_id, amount, currency, period_start, period_end, settled_by)
    values ('fecd570b-150f-4f4f-96ec-111399f22bfe', '66673fe4-69ee-429f-b0a2-81b9e838b41d',
            '2ebaaa87-1e23-46f7-a66e-c85d2bb8227c', 100, 'rub', current_date, current_date, auth.uid());
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: owner settlement rejected'; end if;

    -- Mark for Olga's share made by the payer.
    insert into public.transaction_member_settlements (transaction_id, shared_account_id, settled_for_user_id, settled_by_user_id)
    values (current_setting('test.main_tx')::uuid, 'fecd570b-150f-4f4f-96ec-111399f22bfe',
            '66673fe4-69ee-429f-b0a2-81b9e838b41d', auth.uid());
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: payer mark rejected'; end if;
end $$;

-- ── As the third user (VIEWER of «Семейный») ───────────────────────────────
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.third'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.third'), true),
       set_config('role','authenticated',true);
do $$
begin
    begin
        insert into public.settlements (shared_account_id, from_user_id, to_user_id, amount, currency, period_start, period_end, settled_by)
        values ('fecd570b-150f-4f4f-96ec-111399f22bfe', auth.uid(), '2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',
                100, 'rub', current_date, current_date, auth.uid());
        raise exception 'ASSERT FAILED: viewer inserted a settlement';
    exception when insufficient_privilege then null; end;
    begin
        insert into public.transaction_member_settlements (transaction_id, shared_account_id, settled_for_user_id, settled_by_user_id)
        values (current_setting('test.main_tx')::uuid, 'fecd570b-150f-4f4f-96ec-111399f22bfe', auth.uid(), auth.uid());
        raise exception 'ASSERT FAILED: viewer inserted a mark';
    exception when insufficient_privilege then null; end;
    -- The membership helper does not answer for accounts the caller is not in.
    if public.is_account_party('9b075428-e95b-4aa2-8f2c-2b412994c397', '2ebaaa87-1e23-46f7-a66e-c85d2bb8227c') then
        raise exception 'ASSERT FAILED: is_account_party answered an outsider';
    end if;
end $$;

reset role;
select 'S6 assertions passed' as result;
