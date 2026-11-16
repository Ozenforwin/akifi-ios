-- Assertions for 20261117120000_account_budget_owner_guards.sql.
-- Run with the dry-run helper AFTER the migration (BEGIN … ROLLBACK), see SAFETY below.
-- Fixtures: Vladimir 2ebaaa87… (owner), Olga 66673fe4… (editor),
--           shared account «Семейный» fecd570b…, Vladimir's personal RUB account 9b075428….
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

-- ── As Olga (editor of «Семейный») ─────────────────────────────────────────
select set_config('request.jwt.claims','{"sub":"66673fe4-69ee-429f-b0a2-81b9e838b41d","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','66673fe4-69ee-429f-b0a2-81b9e838b41d',true),
       set_config('role','authenticated',true);

do $$
declare v_n int;
begin
    -- Hole: editor writes own id into accounts.user_id.
    begin
        update public.accounts set user_id = auth.uid() where id = 'fecd570b-150f-4f4f-96ec-111399f22bfe';
        raise exception 'ASSERT FAILED: editor changed accounts.user_id';
    exception when insufficient_privilege then null;
    end;

    -- Hole: editor changes the currency of a shared account.
    begin
        update public.accounts set currency = 'usd' where id = 'fecd570b-150f-4f4f-96ec-111399f22bfe';
        raise exception 'ASSERT FAILED: editor changed accounts.currency';
    exception when insufficient_privilege then null;
    end;

    -- Legit: the account form sends every field, currency unchanged (lower-cased).
    update public.accounts
       set name = name || ' (dry-run)', icon = icon, color = color, currency = 'rub', initial_balance = initial_balance
     where id = 'fecd570b-150f-4f4f-96ec-111399f22bfe';
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: editor cannot rename the shared account (% rows)', v_n; end if;

    -- Legit for editors: add a transaction to «Семейный».
    insert into public.transactions (user_id, account_id, amount, amount_native, currency, type, date, description)
    values (auth.uid(), 'fecd570b-150f-4f4f-96ec-111399f22bfe', 1, 1, 'RUB', 'expense', now(), 'dry-run');
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: editor cannot add a transaction'; end if;

    -- Editor cannot delete the shared account (and therefore its history).
    delete from public.accounts where id = 'fecd570b-150f-4f4f-96ec-111399f22bfe';
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: editor deleted the shared account'; end if;
end $$;

-- ── As Vladimir (owner) ────────────────────────────────────────────────────
reset role;
select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true),
       set_config('role','authenticated',true);

do $$
declare v_n int; v_new uuid;
begin
    -- Legit: owner renames; a case-only currency change is not a change.
    update public.accounts set name = 'Семейный (dry-run)', currency = 'RUB'
     where id = 'fecd570b-150f-4f4f-96ec-111399f22bfe';
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: owner cannot rename the account'; end if;
    update public.accounts set currency = 'rub' where id = 'fecd570b-150f-4f4f-96ec-111399f22bfe';

    -- Owner cannot change the currency once the account has transactions.
    begin
        update public.accounts set currency = 'usd' where id = '9b075428-e95b-4aa2-8f2c-2b412994c397';
        raise exception 'ASSERT FAILED: currency changed on an account with transactions';
    exception when check_violation then null;
    end;

    -- Owner cannot hand the account to someone else through UPDATE either.
    begin
        update public.accounts set user_id = '66673fe4-69ee-429f-b0a2-81b9e838b41d'
         where id = '9b075428-e95b-4aa2-8f2c-2b412994c397';
        raise exception 'ASSERT FAILED: owner rewrote accounts.user_id';
    exception when insufficient_privilege then null;
    end;

    -- Legit: an empty account can still switch currency.
    insert into public.accounts (user_id, name, currency) values (auth.uid(), 'dry-run empty', 'rub')
    returning id into v_new;
    update public.accounts set currency = 'usd' where id = v_new;
    get diagnostics v_n = row_count;
    if v_n <> 1 or (select currency from public.accounts where id = v_new) <> 'usd' then
        raise exception 'ASSERT FAILED: currency change on an empty account was refused';
    end if;

    -- Budget owned by Vladimir; Olga is made an editor below (as the DB owner,
    -- since clients can no longer insert budget_members).
    insert into public.budgets (user_id, amount, category_ids, name) values (auth.uid(), 1000, '{}', 'dry-run budget')
    returning id into v_new;
    perform set_config('test.budget_id', v_new::text, true);
end $$;

reset role;
insert into public.budget_members (budget_id, user_id, role)
values (current_setting('test.budget_id')::uuid, '66673fe4-69ee-429f-b0a2-81b9e838b41d', 'editor');

select set_config('request.jwt.claims','{"sub":"66673fe4-69ee-429f-b0a2-81b9e838b41d","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','66673fe4-69ee-429f-b0a2-81b9e838b41d',true),
       set_config('role','authenticated',true);

do $$
declare v_n int; v_b uuid := current_setting('test.budget_id')::uuid;
begin
    begin
        update public.budgets set user_id = auth.uid() where id = v_b;
        raise exception 'ASSERT FAILED: budget editor changed budgets.user_id';
    exception when insufficient_privilege then null;
    end;

    update public.budgets set name = 'renamed by editor', amount = 1200 where id = v_b;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: budget editor cannot edit the budget'; end if;

    delete from public.budgets where id = v_b;
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: budget editor deleted the budget'; end if;
end $$;

-- Service role / DB owner keep the repair path (e.g. fixing a wrong currency).
reset role;
select set_config('request.jwt.claims','{"role":"service_role"}',true), set_config('request.jwt.claim.sub','',true);
update public.accounts set currency = 'rub' where id = '9b075428-e95b-4aa2-8f2c-2b412994c397';
select 'S5 assertions passed' as result;
