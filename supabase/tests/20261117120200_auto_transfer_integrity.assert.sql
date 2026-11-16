-- Assertions for 20261117120200_auto_transfer_integrity.sql (dry run, rolled back).
-- Fixtures: «Семейный» fecd570b… (RUB; owner Vladimir, editor Olga);
--   Vladimir's cards: RUB 9b075428…, USD e087ff3d…; Olga's RUB card 8085d0ea….
-- Calls use NAMED arguments with exactly the keys the iOS client sends
-- (13 for create, 11 for update) — PostgREST resolves overloads the same way.
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

-- ── Vladimir creates a «Семейный» expense paid from HIS RUB card ───────────
select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true),
       set_config('role','authenticated',true);
do $$
declare v_id uuid; v_g uuid;
begin
    v_id := public.create_expense_with_auto_transfer(
        p_account_id => 'fecd570b-150f-4f4f-96ec-111399f22bfe', p_category_id => null,
        p_amount => 1000, p_currency => 'RUB', p_date => now(),
        p_description => 'dry-run vlad paid', p_merchant_name => null,
        p_payment_source_account_id => '9b075428-e95b-4aa2-8f2c-2b412994c397',
        p_source_amount => null, p_source_currency => null,
        p_foreign_amount => null, p_foreign_currency => null, p_fx_rate => null);
    select auto_transfer_group_id into v_g from public.transactions where id = v_id;
    if (select count(*) from public.transactions where auto_transfer_group_id = v_g) <> 3 then
        raise exception 'ASSERT FAILED: 13-arg create did not write a triplet';
    end if;
    perform set_config('test.vlad_tx', v_id::text, true);
    perform set_config('test.vlad_g', v_g::text, true);
end $$;

-- ── Olga (co-editor) cannot half-edit / half-delete it ─────────────────────
reset role;
select set_config('request.jwt.claims','{"sub":"66673fe4-69ee-429f-b0a2-81b9e838b41d","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','66673fe4-69ee-429f-b0a2-81b9e838b41d',true),
       set_config('role','authenticated',true);
do $$
declare v_id uuid := current_setting('test.vlad_tx')::uuid; v_n int; v_own uuid; v_g uuid;
begin
    begin
        perform public.update_expense_with_auto_transfer(
            p_expense_id => v_id, p_amount => 2000, p_category_id => null, p_date => now(),
            p_description => 'olga edit', p_merchant_name => null,
            p_foreign_amount => null, p_foreign_currency => null, p_fx_rate => null,
            p_source_amount => null, p_source_currency => null);
        raise exception 'ASSERT FAILED: co-editor update of a partner-paid auto-transfer succeeded (out-leg left stale)';
    exception when insufficient_privilege then null; end;

    begin
        perform public.delete_expense_with_auto_transfer(v_id);
        raise exception 'ASSERT FAILED: co-editor delete of a partner-paid auto-transfer succeeded (out-leg orphaned)';
    exception when insufficient_privilege then null; end;

    -- Legit for Olga: a plain transaction on «Семейный» …
    insert into public.transactions (user_id, account_id, amount, amount_native, currency, type, date, description)
    values (auth.uid(), 'fecd570b-150f-4f4f-96ec-111399f22bfe', 1, 1, 'RUB', 'expense', now(), 'dry-run');
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: editor cannot add a transaction'; end if;

    -- … and a full create / edit / delete cycle of HER OWN auto-transfer.
    v_own := public.create_expense_with_auto_transfer(
        p_account_id => 'fecd570b-150f-4f4f-96ec-111399f22bfe', p_category_id => null,
        p_amount => 500, p_currency => 'RUB', p_date => now(),
        p_description => 'dry-run olga paid', p_merchant_name => null,
        p_payment_source_account_id => '8085d0ea-f4e0-46f8-9f8e-486993d3ae77',
        p_source_amount => null, p_source_currency => null,
        p_foreign_amount => null, p_foreign_currency => null, p_fx_rate => null);
    select auto_transfer_group_id into v_g from public.transactions where id = v_own;
    perform public.update_expense_with_auto_transfer(
        p_expense_id => v_own, p_amount => 600, p_category_id => null, p_date => now(),
        p_description => 'olga edit', p_merchant_name => null,
        p_foreign_amount => null, p_foreign_currency => null, p_fx_rate => null,
        p_source_amount => null, p_source_currency => null);
    if (select count(*) from public.transactions where auto_transfer_group_id = v_g and amount_native = 600) <> 3 then
        raise exception 'ASSERT FAILED: own same-currency edit did not update all three legs';
    end if;
    perform set_config('test.olga_tx', v_own::text, true);
end $$;

-- ── Vladimir: still all three of his legs intact; cannot half-edit Olga's ──
reset role;
select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true),
       set_config('role','authenticated',true);
do $$
declare
    v_id uuid := current_setting('test.vlad_tx')::uuid;
    v_g  uuid := current_setting('test.vlad_g')::uuid;
    v_x  uuid; v_gx uuid; v_out numeric; v_fa numeric;
begin
    if (select count(*) from public.transactions where auto_transfer_group_id = v_g and amount_native = 1000) <> 3 then
        raise exception 'ASSERT FAILED: rejected co-editor calls changed the triplet';
    end if;

    begin
        perform public.update_expense_with_auto_transfer(
            p_expense_id => current_setting('test.olga_tx')::uuid, p_amount => 1, p_category_id => null, p_date => now(),
            p_description => 'vlad edit', p_merchant_name => null,
            p_foreign_amount => null, p_foreign_currency => null, p_fx_rate => null,
            p_source_amount => null, p_source_currency => null);
        raise exception 'ASSERT FAILED: owner half-edited an expense paid from the editor''s card';
    exception when insufficient_privilege then null; end;

    -- Payer edits his own triplet: all three legs follow.
    perform public.update_expense_with_auto_transfer(
        p_expense_id => v_id, p_amount => 1500, p_category_id => null, p_date => now(),
        p_description => 'vlad edit', p_merchant_name => null,
        p_foreign_amount => null, p_foreign_currency => null, p_fx_rate => null,
        p_source_amount => null, p_source_currency => null);
    if (select count(*) from public.transactions where auto_transfer_group_id = v_g and amount_native = 1500) <> 3 then
        raise exception 'ASSERT FAILED: payer edit did not update all three legs';
    end if;

    -- Cross-currency triplet: «Семейный» (RUB) paid from the USD card, 9 250 ₽ = $100.
    v_x := public.create_expense_with_auto_transfer(
        p_account_id => 'fecd570b-150f-4f4f-96ec-111399f22bfe', p_category_id => null,
        p_amount => 9250, p_currency => 'RUB', p_date => now(),
        p_description => 'dry-run cross', p_merchant_name => null,
        p_payment_source_account_id => 'e087ff3d-fcbd-4548-b45f-b24cdf44b793',
        p_source_amount => 100, p_source_currency => 'USD',
        p_foreign_amount => 100, p_foreign_currency => 'USD', p_fx_rate => 92.5);
    select auto_transfer_group_id into v_gx from public.transactions where id = v_x;

    -- 11 keys with p_source_amount = NULL on a cross-currency triplet (what the
    -- delegating 6-/9-arg overloads pass): the USD leg keeps the frozen rate
    -- instead of receiving the RUB amount (the 92.5x bug).
    perform public.update_expense_with_auto_transfer(
        p_expense_id => v_x, p_amount => 11100, p_category_id => null, p_date => now(),
        p_description => 'no source amount', p_merchant_name => null,
        p_foreign_amount => 120, p_foreign_currency => 'USD', p_fx_rate => 92.5,
        p_source_amount => null, p_source_currency => null);
    select amount_native into v_out from public.transactions
     where transfer_group_id = v_gx and type = 'expense';
    if v_out <> 120.00 then
        raise exception 'ASSERT FAILED: wrote % into the USD leg (expected 120.00)', v_out;
    end if;
    select foreign_amount into v_fa from public.transactions where id = v_x;
    if v_fa <> 120 then raise exception 'ASSERT FAILED: foreign_amount %', v_fa; end if;

    -- Current client (11 keys, explicit source amount) wins.
    perform public.update_expense_with_auto_transfer(
        p_expense_id => v_x, p_amount => 9500, p_category_id => null, p_date => now(),
        p_description => 'ios edit', p_merchant_name => null,
        p_foreign_amount => null, p_foreign_currency => null, p_fx_rate => null,
        p_source_amount => 101.23, p_source_currency => 'USD');
    select amount_native into v_out from public.transactions where transfer_group_id = v_gx and type = 'expense';
    if v_out <> 101.23 then raise exception 'ASSERT FAILED: explicit source amount ignored (%)', v_out; end if;
    if (select amount_native from public.transactions where transfer_group_id = v_gx and type = 'income') <> 9500 then
        raise exception 'ASSERT FAILED: transfer-in not updated';
    end if;

    -- Payer deletes: all three gone; a replayed delete is a no-op.
    perform public.delete_expense_with_auto_transfer(v_id);
    if exists (select 1 from public.transactions where auto_transfer_group_id = v_g) then
        raise exception 'ASSERT FAILED: payer delete left rows behind';
    end if;
    perform public.delete_expense_with_auto_transfer(v_id);

    -- Passing a leg id to update is refused.
    begin
        perform public.update_expense_with_auto_transfer(
            p_expense_id => (select id from public.transactions where transfer_group_id = v_gx and type = 'income'),
            p_amount => 1, p_category_id => null, p_date => now(), p_description => null, p_merchant_name => null,
            p_foreign_amount => null, p_foreign_currency => null, p_fx_rate => null,
            p_source_amount => null, p_source_currency => null);
        raise exception 'ASSERT FAILED: update accepted a transfer leg as the expense';
    exception when invalid_parameter_value then null; end;
end $$;

-- ── Olga deletes her own triplet ───────────────────────────────────────────
reset role;
select set_config('request.jwt.claims','{"sub":"66673fe4-69ee-429f-b0a2-81b9e838b41d","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','66673fe4-69ee-429f-b0a2-81b9e838b41d',true),
       set_config('role','authenticated',true);
do $$
declare v_id uuid := current_setting('test.olga_tx')::uuid; v_g uuid;
begin
    select auto_transfer_group_id into v_g from public.transactions where id = v_id;
    perform set_config('test.olga_g', v_g::text, true);
    perform public.delete_expense_with_auto_transfer(v_id);
end $$;
reset role;  -- verify as DB owner: no hidden leg left on her card
do $$
begin
    if exists (select 1 from public.transactions where auto_transfer_group_id = current_setting('test.olga_g')::uuid) then
        raise exception 'ASSERT FAILED: own delete left rows behind';
    end if;
end $$;

-- ── Y3: idempotent create with p_id (14 keys) ──────────────────────────────
reset role;
select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true),
       set_config('role','authenticated',true);
do $$
declare v_pid uuid := gen_random_uuid(); v_ret uuid; v_pid2 uuid := gen_random_uuid();
begin
    v_ret := public.create_expense_with_auto_transfer(
        p_account_id => 'fecd570b-150f-4f4f-96ec-111399f22bfe', p_category_id => null,
        p_amount => 777, p_currency => 'RUB', p_date => now(),
        p_description => 'dry-run p_id', p_merchant_name => null,
        p_payment_source_account_id => '9b075428-e95b-4aa2-8f2c-2b412994c397',
        p_source_amount => null, p_source_currency => null,
        p_foreign_amount => null, p_foreign_currency => null, p_fx_rate => null,
        p_id => v_pid);
    if v_ret <> v_pid then raise exception 'ASSERT FAILED: p_id not used as the expense id'; end if;
    if (select count(*) from public.transactions
         where auto_transfer_group_id = (select auto_transfer_group_id from public.transactions where id = v_pid)) <> 3 then
        raise exception 'ASSERT FAILED: p_id create did not write a triplet';
    end if;

    begin  -- the retry after a timeout
        perform public.create_expense_with_auto_transfer(
            p_account_id => 'fecd570b-150f-4f4f-96ec-111399f22bfe', p_category_id => null,
            p_amount => 777, p_currency => 'RUB', p_date => now(),
            p_description => 'dry-run p_id', p_merchant_name => null,
            p_payment_source_account_id => '9b075428-e95b-4aa2-8f2c-2b412994c397',
            p_source_amount => null, p_source_currency => null,
            p_foreign_amount => null, p_foreign_currency => null, p_fx_rate => null,
            p_id => v_pid);
        raise exception 'ASSERT FAILED: retry with the same p_id created a duplicate';
    exception when unique_violation then null; end;
    if (select count(*) from public.transactions where description = 'dry-run p_id' and user_id = auth.uid()) <> 1 then
        raise exception 'ASSERT FAILED: duplicate main expense after retry';
    end if;

    -- p_id on the plain path (no payment source) too.
    v_ret := public.create_expense_with_auto_transfer(
        p_account_id => '9b075428-e95b-4aa2-8f2c-2b412994c397', p_category_id => null,
        p_amount => 5, p_currency => 'RUB', p_date => now(),
        p_description => 'dry-run plain p_id', p_merchant_name => null,
        p_payment_source_account_id => null,
        p_source_amount => null, p_source_currency => null,
        p_foreign_amount => null, p_foreign_currency => null, p_fx_rate => null,
        p_id => v_pid2);
    if v_ret <> v_pid2 or not exists (select 1 from public.transactions where id = v_pid2) then
        raise exception 'ASSERT FAILED: plain-path p_id';
    end if;
end $$;

-- The new overload is not callable by anon; the 13-arg one still is resolvable.
reset role;
do $$
begin
    if has_function_privilege('anon',
        'public.create_expense_with_auto_transfer(uuid,uuid,numeric,text,timestamptz,text,text,uuid,numeric,text,numeric,text,numeric,uuid)',
        'execute') then
        raise exception 'ASSERT FAILED: anon can execute the 14-arg create';
    end if;
    if not has_function_privilege('authenticated',
        'public.create_expense_with_auto_transfer(uuid,uuid,numeric,text,timestamptz,text,text,uuid,numeric,text,numeric,text,numeric,uuid)',
        'execute') then
        raise exception 'ASSERT FAILED: authenticated cannot execute the 14-arg create';
    end if;
end $$;
-- The legacy 6-/9-arg overloads cannot be resolved by name or position since
-- the 11-arg overload exists (42725, identical leading types + defaults); they
-- are kept but must delegate to the canonical overload.
do $$
begin
    if pg_get_functiondef('public.update_expense_with_auto_transfer(uuid,numeric,uuid,timestamptz,text,text)'::regprocedure)
       not like '%null::numeric, null::text)%'
    or pg_get_functiondef('public.update_expense_with_auto_transfer(uuid,numeric,uuid,timestamptz,text,text,numeric,text,numeric)'::regprocedure)
       not like '%null::numeric, null::text)%' then
        raise exception 'ASSERT FAILED: legacy update overloads do not delegate';
    end if;
end $$;
select 'S7/Y3 assertions passed' as result;
