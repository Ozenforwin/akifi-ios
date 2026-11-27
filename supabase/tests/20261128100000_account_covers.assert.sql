-- Assertions for 20261128100000_account_covers.sql (dry run, rolled back).
-- Fixtures are created inside the transaction: four existing users play
-- A (owner), B (editor of A's shared account), V (viewer of it) and C (a
-- stranger); the accounts and storage objects are new rows. No prod id is
-- hard-coded and no real row is changed (everything is rolled back).
-- SAFETY: this file writes test rows (and impersonates users). It refuses to
-- run unless the session is marked as a dry run inside BEGIN … ROLLBACK:
--   db_dryrun.py <(echo "select set_config('akifi.dry_run','on',true);") \
--     20261128100000_account_covers.sql <this file>
-- (the debt migrations 20261128090000… must be applied or in the same run:
-- the fixture creates an account_type = 'debt' account).
do $$
begin
    if coalesce(current_setting('akifi.dry_run', true), '') <> 'on' then
        raise exception 'Assertion file: run only via the dry-run helper with akifi.dry_run=on (BEGIN … ROLLBACK).';
    end if;
end $$;

-- Storage refuses direct DELETEs on storage.objects unless this is set (the
-- Storage API sets it itself); harmless where that guard does not exist.
select set_config('storage.allow_delete_query', 'true', true);

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
             limit 4) s;
    if coalesce(array_length(v_users, 1), 0) < 4 then
        raise exception 'ASSERT FAILED: fixture missing (four users with profiles)';
    end if;

    perform set_config('test.a', v_users[1]::text, true),
            set_config('test.b', v_users[2]::text, true),
            set_config('test.v', v_users[3]::text, true),
            set_config('test.c', v_users[4]::text, true),
            set_config('test.s', gen_random_uuid()::text, true),   -- A's shared account
            set_config('test.d', gen_random_uuid()::text, true),   -- A's debt account
            set_config('test.p', gen_random_uuid()::text, true),   -- C's own account
            set_config('test.o1', gen_random_uuid()::text, true),  -- cover object ids
            set_config('test.o2', gen_random_uuid()::text, true),
            set_config('test.o3', gen_random_uuid()::text, true);

    insert into accounts (id, user_id, name, icon, color, initial_balance, currency)
    values (current_setting('test.s')::uuid, v_users[1], 'akifi-test shared', '🏠', '#3B82F6', 0, 'rub'),
           (current_setting('test.p')::uuid, v_users[4], 'akifi-test stranger', '💳', '#3B82F6', 0, 'rub');
    insert into accounts (id, user_id, name, icon, color, initial_balance, currency, account_type)
    values (current_setting('test.d')::uuid, v_users[1], 'akifi-test debt', '👤', '#F59E0B', 0, 'rub', 'debt');

    -- Owner memberships (the on-insert trigger may already have added them).
    insert into account_members (account_id, user_id, role)
    select x.account_id, x.user_id, 'owner'
      from (values (current_setting('test.s')::uuid, v_users[1]),
                   (current_setting('test.d')::uuid, v_users[1]),
                   (current_setting('test.p')::uuid, v_users[4])) x(account_id, user_id)
     where not exists (select 1 from account_members m
                        where m.account_id = x.account_id and m.user_id = x.user_id);
    insert into account_members (account_id, user_id, role)
    values (current_setting('test.s')::uuid, v_users[2], 'editor'),
           (current_setting('test.s')::uuid, v_users[3], 'viewer');

    perform set_config('test.n1', current_setting('test.s') || '/' || current_setting('test.o1') || '.jpg', true),
            set_config('test.n2', current_setting('test.s') || '/' || current_setting('test.o2') || '.jpg', true),
            set_config('test.n3', current_setting('test.s') || '/' || current_setting('test.o3') || '.jpg', true);
end $$;

-- ── Bucket ─────────────────────────────────────────────────────────────────
do $$
begin
    if not exists (select 1 from storage.buckets
                    where id = 'account-covers' and public = false
                      and file_size_limit = 2 * 1024 * 1024
                      and allowed_mime_types = array['image/jpeg']) then
        raise exception 'ASSERT FAILED: account-covers bucket is not private / 2 MB / image/jpeg';
    end if;
end $$;

-- ── As A (owner, authenticated): upload, point the account at it ──────────
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.a'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_s  uuid := current_setting('test.s')::uuid;
    v_d  uuid := current_setting('test.d')::uuid;
    v_p  uuid := current_setting('test.p')::uuid;
    v_n1 text := current_setting('test.n1');
    v_n2 text := current_setting('test.n2');
begin
    insert into storage.objects (bucket_id, name, owner) values ('account-covers', v_n1, auth.uid());
    if not exists (select 1 from storage.objects where bucket_id = 'account-covers' and name = v_n1) then
        raise exception 'ASSERT FAILED: owner cannot read their own cover object';
    end if;

    -- The row may only point at an uploaded object.
    begin
        update accounts set cover_path = v_n2 where id = v_s;
        raise exception 'ASSERT FAILED: cover_path accepted for a missing object';
    exception when foreign_key_violation then
        if sqlerrm not like 'account_cover_missing%' then raise; end if;
    end;

    update accounts set cover_path = v_n1 where id = v_s;
    if (select cover_path from accounts where id = v_s) is distinct from v_n1 then
        raise exception 'ASSERT FAILED: owner could not set the cover';
    end if;
    -- Other edits of the account are not affected by the cover guard.
    update accounts set name = 'akifi-test shared (cover)' where id = v_s;
    if not found then raise exception 'ASSERT FAILED: owner could not rename an account with a cover'; end if;

    -- Uploads only into an owned, non-debt account folder, exact name shape.
    begin
        insert into storage.objects (bucket_id, name, owner)
        values ('account-covers', v_d::text || '/' || gen_random_uuid()::text || '.jpg', auth.uid());
        raise exception 'ASSERT FAILED: cover uploaded for a debt account';
    exception when insufficient_privilege then null;
    end;
    begin
        insert into storage.objects (bucket_id, name, owner)
        values ('account-covers', v_p::text || '/' || gen_random_uuid()::text || '.jpg', auth.uid());
        raise exception 'ASSERT FAILED: cover uploaded into someone else''s account';
    exception when insufficient_privilege then null;
    end;
    begin
        insert into storage.objects (bucket_id, name, owner)
        values ('account-covers', v_s::text || '/cover.jpg', auth.uid());
        raise exception 'ASSERT FAILED: malformed cover name accepted';
    exception when insufficient_privilege then null;
    end;
    begin
        insert into storage.objects (bucket_id, name, owner)
        values ('account-covers', v_s::text || '/' || gen_random_uuid()::text || '.png', auth.uid());
        raise exception 'ASSERT FAILED: non-jpg cover name accepted';
    exception when insufficient_privilege then null;
    end;
    -- A debt account can never have a cover (no object can exist for it).
    begin
        update accounts set cover_path = v_d::text || '/' || gen_random_uuid()::text || '.jpg' where id = v_d;
        raise exception 'ASSERT FAILED: debt account got a cover';
    exception when foreign_key_violation or check_violation then null;
    end;
end $$;

-- ── As B (editor of the shared account): sees it, cannot change it ────────
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.b'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_s  uuid := current_setting('test.s')::uuid;
    v_n1 text := current_setting('test.n1');
    v_n  int;
begin
    if not exists (select 1 from storage.objects where bucket_id = 'account-covers' and name = v_n1) then
        raise exception 'ASSERT FAILED: editor cannot read the shared account''s cover';
    end if;
    if (select cover_path from accounts where id = v_s) is distinct from v_n1 then
        raise exception 'ASSERT FAILED: editor does not see cover_path';
    end if;

    begin
        insert into storage.objects (bucket_id, name, owner)
        values ('account-covers', v_s::text || '/' || gen_random_uuid()::text || '.jpg', auth.uid());
        raise exception 'ASSERT FAILED: editor uploaded a cover';
    exception when insufficient_privilege then null;
    end;
    update storage.objects set metadata = '{"dry":"editor"}'
     where bucket_id = 'account-covers' and name = v_n1;
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: editor overwrote the cover object'; end if;
    delete from storage.objects where bucket_id = 'account-covers' and name = v_n1;
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: editor deleted the cover object'; end if;

    begin
        update accounts set cover_path = null where id = v_s;
        raise exception 'ASSERT FAILED: editor removed the cover';
    exception when insufficient_privilege then
        if sqlerrm not like 'account_cover_owner_only%' then raise; end if;
    end;
    -- Editors keep every other edit they had.
    update accounts set name = 'akifi-test shared (editor)' where id = v_s;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: editor can no longer rename the shared account'; end if;
end $$;

-- ── As V (viewer): sees it, cannot change it ──────────────────────────────
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.v'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.v'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_s  uuid := current_setting('test.s')::uuid;
    v_n1 text := current_setting('test.n1');
    v_n  int;
begin
    if not exists (select 1 from storage.objects where bucket_id = 'account-covers' and name = v_n1) then
        raise exception 'ASSERT FAILED: viewer cannot read the shared account''s cover';
    end if;
    update accounts set cover_path = null where id = v_s;
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: viewer changed the cover'; end if;
    delete from storage.objects where bucket_id = 'account-covers' and name = v_n1;
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: viewer deleted the cover object'; end if;
end $$;

-- ── As C (stranger): nothing to see, nothing to touch ─────────────────────
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.c'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_s  uuid := current_setting('test.s')::uuid;
    v_n1 text := current_setting('test.n1');
    v_n  int;
begin
    if exists (select 1 from storage.objects where bucket_id = 'account-covers' and name = v_n1) then
        raise exception 'ASSERT FAILED: a stranger can read the cover';
    end if;
    if exists (select 1 from storage.objects
                where bucket_id = 'account-covers' and name like v_s::text || '/%') then
        raise exception 'ASSERT FAILED: a stranger can list the account''s covers';
    end if;
    begin
        insert into storage.objects (bucket_id, name, owner)
        values ('account-covers', v_s::text || '/' || gen_random_uuid()::text || '.jpg', auth.uid());
        raise exception 'ASSERT FAILED: a stranger uploaded a cover';
    exception when insufficient_privilege then null;
    end;
    -- No other bucket's "<auth.uid()>/…" policy leaks into this bucket.
    begin
        insert into storage.objects (bucket_id, name, owner)
        values ('account-covers', auth.uid()::text || '/' || gen_random_uuid()::text || '.jpg', auth.uid());
        raise exception 'ASSERT FAILED: an upload into a user-id folder of account-covers was accepted (a policy without a bucket check?)';
    exception when insufficient_privilege then null;
    end;
    delete from storage.objects where bucket_id = 'account-covers' and name = v_n1;
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: a stranger deleted the cover'; end if;
    update accounts set cover_path = null where id = v_s;
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: a stranger changed the cover'; end if;
end $$;

-- ── anon: nothing ─────────────────────────────────────────────────────────
reset role;
select set_config('request.jwt.claims', '{"role":"anon"}', true),
       set_config('request.jwt.claim.sub', '', true),
       set_config('request.jwt.claim.role', 'anon', true),
       set_config('role', 'anon', true);
do $$
begin
    if exists (select 1 from storage.objects where bucket_id = 'account-covers') then
        raise exception 'ASSERT FAILED: anon can list account covers';
    end if;
end $$;

-- ── As A again: replace (new object, row, delete old), then remove ────────
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.a'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);

do $$
declare
    v_s  uuid := current_setting('test.s')::uuid;
    v_n1 text := current_setting('test.n1');
    v_n2 text := current_setting('test.n2');
    v_n  int;
begin
    insert into storage.objects (bucket_id, name, owner) values ('account-covers', v_n2, auth.uid());
    update accounts set cover_path = v_n2 where id = v_s;
    delete from storage.objects where bucket_id = 'account-covers' and name = v_n1;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: owner could not delete the replaced cover (% rows)', v_n; end if;

    update accounts set cover_path = null where id = v_s;
    if (select cover_path from accounts where id = v_s) is not null then
        raise exception 'ASSERT FAILED: owner could not remove the cover';
    end if;
    delete from storage.objects where bucket_id = 'account-covers' and name = v_n2;
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: owner could not delete the removed cover'; end if;
end $$;

-- ── DB owner: the CHECKs hold for every role; the heir owns the cover ─────
reset role;
do $$
declare
    v_a  uuid := current_setting('test.a')::uuid;
    v_b  uuid := current_setting('test.b')::uuid;
    v_s  uuid := current_setting('test.s')::uuid;
    v_d  uuid := current_setting('test.d')::uuid;
    v_p  uuid := current_setting('test.p')::uuid;
    v_u  text := gen_random_uuid()::text;
begin
    perform set_config('request.jwt.claims', '{}', true),
            set_config('request.jwt.claim.sub', '', true),
            set_config('request.jwt.claim.role', '', true);

    begin
        update accounts set cover_path = v_p::text || '/' || v_u || '.jpg' where id = v_s;
        raise exception 'ASSERT FAILED: cover_path of another account''s folder accepted';
    exception when check_violation then null;
    end;
    begin
        update accounts set cover_path = v_s::text || '/' || v_u || '.png' where id = v_s;
        raise exception 'ASSERT FAILED: non-jpg cover_path accepted';
    exception when check_violation then null;
    end;
    begin
        update accounts set cover_path = upper(v_s::text) || '/' || v_u || '.jpg' where id = v_s;
        raise exception 'ASSERT FAILED: upper-case cover_path accepted';
    exception when check_violation then null;
    end;
    begin
        update accounts set cover_path = v_s::text || '/../' || v_u || '.jpg' where id = v_s;
        raise exception 'ASSERT FAILED: cover_path with a traversal accepted';
    exception when check_violation then null;
    end;
    begin
        update accounts set cover_path = v_d::text || '/' || v_u || '.jpg' where id = v_d;
        raise exception 'ASSERT FAILED: debt account cover accepted';
    exception when check_violation then
        if sqlerrm not like '%accounts_cover_not_on_debt%' then raise; end if;
    end;

    -- prepare_account_deletion hands a shared account to the remaining
    -- member (accounts.user_id + the member's role); the cover goes with it.
    update accounts set user_id = v_b where id = v_s;
    update account_members set role = 'owner' where account_id = v_s and user_id = v_b;
    update account_members set role = 'editor' where account_id = v_s and user_id = v_a;
end $$;

select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.b'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);
do $$
declare
    v_s  uuid := current_setting('test.s')::uuid;
    v_n3 text := current_setting('test.n3');
begin
    insert into storage.objects (bucket_id, name, owner) values ('account-covers', v_n3, auth.uid());
    update accounts set cover_path = v_n3 where id = v_s;
    if (select cover_path from accounts where id = v_s) is distinct from v_n3 then
        raise exception 'ASSERT FAILED: the new owner could not set the cover';
    end if;
end $$;

reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.a'), true),
       set_config('request.jwt.claim.role', 'authenticated', true),
       set_config('role', 'authenticated', true);
do $$
declare
    v_s  uuid := current_setting('test.s')::uuid;
    v_n3 text := current_setting('test.n3');
    v_n  int;
begin
    if not exists (select 1 from storage.objects where bucket_id = 'account-covers' and name = v_n3) then
        raise exception 'ASSERT FAILED: the former owner (now a member) cannot read the cover';
    end if;
    begin
        update accounts set cover_path = null where id = v_s;
        raise exception 'ASSERT FAILED: the former owner removed the cover';
    exception when insufficient_privilege then null;
    end;
    delete from storage.objects where bucket_id = 'account-covers' and name = v_n3;
    get diagnostics v_n = row_count;
    if v_n <> 0 then raise exception 'ASSERT FAILED: the former owner deleted the cover object'; end if;
end $$;
reset role;

select 'account covers: all assertions passed' as result;
