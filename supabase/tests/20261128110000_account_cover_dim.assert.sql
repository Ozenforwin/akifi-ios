-- Assertions for 20261128110000_account_cover_dim.sql (dry run, rolled back).
-- Fixtures inside the transaction: three existing users play A (owner),
-- B (editor of A's shared account) and C (a stranger); the account is a new
-- row. No prod id is hard-coded and no real row is changed.
-- SAFETY: writes test rows and impersonates users — runs only inside
-- BEGIN … ROLLBACK with akifi.dry_run=on (see the covers assert file).
do $$
begin
    if coalesce(current_setting('akifi.dry_run', true), '') <> 'on' then
        raise exception 'Assertion file: run only via the dry-run helper with akifi.dry_run=on (BEGIN … ROLLBACK).';
    end if;
end $$;

-- ── Setup as DB owner, no JWT ──────────────────────────────────────────────
do $$
declare
    v_users uuid[];
begin
    perform set_config('request.jwt.claims', '{}', true),
            set_config('request.jwt.claim.sub', '', true),
            set_config('request.jwt.claim.role', '', true);

    select array_agg(id order by created_at, id) into v_users
      from (select u.id, u.created_at
              from auth.users u join profiles p on p.id = u.id
             order by u.created_at, u.id
             limit 3) s;
    if coalesce(array_length(v_users, 1), 0) < 3 then
        raise exception 'ASSERT FAILED: fixture missing (three users with profiles)';
    end if;

    perform set_config('test.a', v_users[1]::text, true),
            set_config('test.b', v_users[2]::text, true),
            set_config('test.c', v_users[3]::text, true),
            set_config('test.s', gen_random_uuid()::text, true);

    insert into accounts (id, user_id, name, icon, color, initial_balance, currency)
    values (current_setting('test.s')::uuid, v_users[1], 'akifi-test dim', '🏠', '#3B82F6', 0, 'rub');
    insert into account_members (account_id, user_id, role)
    select current_setting('test.s')::uuid, v_users[1], 'owner'
     where not exists (select 1 from account_members m
                        where m.account_id = current_setting('test.s')::uuid and m.user_id = v_users[1]);
    insert into account_members (account_id, user_id, role)
    values (current_setting('test.s')::uuid, v_users[2], 'editor');

    if (select cover_dim from accounts where id = current_setting('test.s')::uuid) is not null then
        raise exception 'ASSERT FAILED: a new account must be on automatic dimming (null)';
    end if;
end $$;

-- ── As A (owner) ───────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.a'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_s uuid := current_setting('test.s')::uuid;
begin
    update accounts set cover_dim = 35 where id = v_s;
    if (select cover_dim from accounts where id = v_s) is distinct from 35::smallint then
        raise exception 'ASSERT FAILED: owner could not set the dimming';
    end if;
    update accounts set cover_dim = null where id = v_s;
    if (select cover_dim from accounts where id = v_s) is not null then
        raise exception 'ASSERT FAILED: owner could not return to automatic dimming';
    end if;
    begin
        update accounts set cover_dim = 101 where id = v_s;
        raise exception 'ASSERT FAILED: dimming above 100 accepted';
    exception when check_violation then null;
    end;
    begin
        update accounts set cover_dim = -1 where id = v_s;
        raise exception 'ASSERT FAILED: negative dimming accepted';
    exception when check_violation then null;
    end;
    update accounts set cover_dim = 70 where id = v_s;
end $$;

-- ── As B (editor): may rename, may not change the dimming ─────────────────
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.b'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_s uuid := current_setting('test.s')::uuid;
    v_n int;
begin
    if (select cover_dim from accounts where id = v_s) is distinct from 70::smallint then
        raise exception 'ASSERT FAILED: editor does not see the owner''s dimming';
    end if;
    begin
        update accounts set cover_dim = 10 where id = v_s;
        get diagnostics v_n = row_count;
        -- Either RLS hides the row from an editor's UPDATE (0 rows) or the
        -- guard refuses it; it must never change.
    exception when insufficient_privilege then
        if sqlerrm not like 'account_cover_owner_only%' then raise; end if;
    end;
    if (select cover_dim from accounts where id = v_s) is distinct from 70::smallint then
        raise exception 'ASSERT FAILED: editor changed the dimming';
    end if;
end $$;

-- ── As C (stranger): sees nothing, changes nothing ─────────────────────────
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.c'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_s uuid := current_setting('test.s')::uuid;
begin
    begin
        update accounts set cover_dim = 5 where id = v_s;
    exception when insufficient_privilege then null;
    end;
end $$;

-- ── Back as DB owner: the value is untouched; service paths unrestricted ──
reset role;
select set_config('request.jwt.claims', '{}', true),
       set_config('request.jwt.claim.sub', '', true),
       set_config('request.jwt.claim.role', '', true);

do $$
declare
    v_s uuid := current_setting('test.s')::uuid;
begin
    if (select cover_dim from accounts where id = v_s) is distinct from 70::smallint then
        raise exception 'ASSERT FAILED: a stranger changed the dimming';
    end if;
    update accounts set cover_dim = 20 where id = v_s;
    if (select cover_dim from accounts where id = v_s) is distinct from 20::smallint then
        raise exception 'ASSERT FAILED: the database owner could not set the dimming';
    end if;
end $$;

select 'ASSERTIONS PASSED' as result;
