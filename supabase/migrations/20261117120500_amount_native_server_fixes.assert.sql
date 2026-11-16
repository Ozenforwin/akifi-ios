-- Assertions for 20261117120500_amount_native_server_fixes.sql (dry run, rolled back).
-- Vladimir's RUB cards: 9b075428… and 212300e8….
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

select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true),
       set_config('role','authenticated',true);
do $$
declare
    v_card  constant uuid := '9b075428-e95b-4aa2-8f2c-2b412994c397';
    v_card2 constant uuid := '212300e8-739e-467b-ad19-07a3b44b89e7';
    v_cat uuid; v_t uuid; v_s numeric; v_n numeric;
begin
    -- ── get_budget_suggestion ──────────────────────────────────────────────
    insert into public.categories (user_id, name, type, scope) values (auth.uid(), 'dry-run cat', 'expense', 'personal')
    returning id into v_cat;
    -- 500 000 VND typed on a RUB card ≈ 1 900 ₽ (ADR-001 example).
    insert into public.transactions (user_id, account_id, category_id, type, date, amount, amount_native, currency,
                                     foreign_amount, foreign_currency, fx_rate, description)
    values (auth.uid(), v_card, v_cat, 'expense', now(), 500000, 1900, 'RUB', 500000, 'VND', 0.0038, 'dry-run vnd');
    -- A categorised transfer leg must not count.
    insert into public.transactions (user_id, account_id, category_id, type, date, amount, amount_native, currency,
                                     transfer_group_id, description)
    values (auth.uid(), v_card, v_cat, 'expense', now(), 1000, 1000, 'RUB', gen_random_uuid(), 'dry-run transfer');

    v_s := public.get_budget_suggestion(array[v_cat], array[v_card], 3);
    if v_s <> 1900 then raise exception 'ASSERT FAILED: array overload suggests % (expected 1900)', v_s; end if;
    v_s := public.get_budget_suggestion(v_cat, array[v_card], 3);
    if v_s <> 1900 then raise exception 'ASSERT FAILED: single overload suggests % (expected 1900)', v_s; end if;

    -- ── transactions_fill_amount_native ────────────────────────────────────
    -- Drifted no-foreign row (amount 100, amount_native 99).
    insert into public.transactions (user_id, account_id, type, date, amount, amount_native, currency, description)
    values (auth.uid(), v_card, 'expense', now(), 100, 99, 'RUB', 'dry-run drift') returning id into v_t;

    update public.transactions set currency = 'rub' where id = v_t;              -- case-only relabel
    if (select amount_native from public.transactions where id = v_t) <> 99 then
        raise exception 'ASSERT FAILED: case-only relabel recomputed amount_native';
    end if;
    update public.transactions set description = 'renamed' where id = v_t;        -- unrelated edit
    if (select amount_native from public.transactions where id = v_t) <> 99 then
        raise exception 'ASSERT FAILED: unrelated edit recomputed amount_native';
    end if;
    update public.transactions set account_id = v_card2 where id = v_t;           -- legacy move
    if (select amount_native from public.transactions where id = v_t) <> 100 then
        raise exception 'ASSERT FAILED: account move did not recompute amount_native';
    end if;
    update public.transactions set amount_native = 98 where id = v_t;             -- reset drift
    update public.transactions set currency = 'USD' where id = v_t;               -- legacy relabel
    if (select amount_native from public.transactions where id = v_t) <> 100 then
        raise exception 'ASSERT FAILED: currency relabel did not recompute amount_native';
    end if;
    update public.transactions set amount = 250 where id = v_t;                   -- legacy amount edit (old behaviour)
    if (select amount_native from public.transactions where id = v_t) <> 250 then
        raise exception 'ASSERT FAILED: amount edit did not recompute amount_native';
    end if;
    update public.transactions set account_id = v_card, amount = 300, amount_native = 55 where id = v_t;  -- explicit writer
    if (select amount_native from public.transactions where id = v_t) <> 55 then
        raise exception 'ASSERT FAILED: explicit amount_native was overwritten';
    end if;

    -- Foreign-entry rows are never auto-synced.
    select id into v_t from public.transactions where description = 'dry-run vnd' and user_id = auth.uid();
    update public.transactions set account_id = v_card2, amount = 600000 where id = v_t;
    select amount_native into v_n from public.transactions where id = v_t;
    if v_n <> 1900 then raise exception 'ASSERT FAILED: foreign row amount_native changed to %', v_n; end if;

    -- INSERT without amount_native still fills it.
    insert into public.transactions (user_id, account_id, type, date, amount, currency, description)
    values (auth.uid(), v_card, 'expense', now(), 42, 'RUB', 'dry-run fill') returning id into v_t;
    if (select amount_native from public.transactions where id = v_t) <> 42 then
        raise exception 'ASSERT FAILED: insert fill';
    end if;
end $$;
reset role;
select 'ADR-001 server assertions passed' as result;
