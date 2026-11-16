-- Assertions for 20261117120300_storage_policies.sql (dry run, rolled back).
-- The journal-photos bucket is empty on prod, so a probe object is created
-- inside the dry run. Avatar owners are looked up from the existing objects
-- (one lower-case, one upper-case legacy name).
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

-- ── Vladimir uploads a journal photo into his folder ───────────────────────
select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true),
       set_config('role','authenticated',true);
insert into storage.objects (bucket_id, name, owner)
values ('journal-photos', '2ebaaa87-1e23-46f7-a66e-c85d2bb8227c/note-dry-run/photo.jpg', '2ebaaa87-1e23-46f7-a66e-c85d2bb8227c');
do $$
begin
    if (select count(*) from storage.objects where bucket_id = 'journal-photos') <> 1 then
        raise exception 'ASSERT FAILED: owner cannot list own journal photo';
    end if;
    -- Own avatar: upload + overwrite (upsert path).
    insert into storage.objects (bucket_id, name, owner)
    values ('avatars', 'avatars/2ebaaa87-1e23-46f7-a66e-c85d2bb8227c.jpg', auth.uid());
    update storage.objects set metadata = '{"dry":"run"}'
     where bucket_id = 'avatars' and name = 'avatars/2ebaaa87-1e23-46f7-a66e-c85d2bb8227c.jpg';
    if not found then raise exception 'ASSERT FAILED: owner cannot overwrite own avatar'; end if;
    -- Someone else's avatar: neither overwrite nor pre-create.
    update storage.objects set metadata = '{"dry":"hijack"}'
     where bucket_id = 'avatars' and name <> 'avatars/2ebaaa87-1e23-46f7-a66e-c85d2bb8227c.jpg';
    if found then raise exception 'ASSERT FAILED: user overwrote another user''s avatar'; end if;
    begin
        insert into storage.objects (bucket_id, name, owner)
        values ('avatars', 'avatars/66673fe4-69ee-429f-b0a2-81b9e838b41d.jpg', auth.uid());
        raise exception 'ASSERT FAILED: user created another user''s avatar';
    exception when insufficient_privilege then null; end;
end $$;

-- ── Olga cannot list Vladimir's journal photos ─────────────────────────────
reset role;
select set_config('request.jwt.claims','{"sub":"66673fe4-69ee-429f-b0a2-81b9e838b41d","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','66673fe4-69ee-429f-b0a2-81b9e838b41d',true),
       set_config('role','authenticated',true);
do $$
begin
    if exists (select 1 from storage.objects where bucket_id = 'journal-photos') then
        raise exception 'ASSERT FAILED: another user can list journal photos';
    end if;
end $$;

-- ── anon cannot list journal photos; the bucket stays public ───────────────
reset role;
select set_config('request.jwt.claims','{"role":"anon"}',true), set_config('request.jwt.claim.sub','',true),
       set_config('role','anon',true);
do $$
begin
    if exists (select 1 from storage.objects where bucket_id = 'journal-photos') then
        raise exception 'ASSERT FAILED: anon can list journal photos';
    end if;
end $$;
reset role;
do $$
begin
    if not (select public from storage.buckets where id = 'journal-photos') then
        raise exception 'ASSERT FAILED: journal-photos bucket is no longer public (existing URLs would break)';
    end if;
end $$;

-- ── Existing avatar owners can still overwrite their own (incl. upper-case name) ──
select set_config('test.av_upper', (select owner::text from storage.objects where bucket_id = 'avatars' and name <> lower(name) limit 1), true),
       set_config('test.av_lower', (select owner::text from storage.objects where bucket_id = 'avatars' and name = lower(name) limit 1), true);
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.av_upper'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.av_upper'), true),
       set_config('role','authenticated',true);
do $$
begin
    update storage.objects set metadata = coalesce(metadata, '{}'::jsonb) where bucket_id = 'avatars';
    if not found then raise exception 'ASSERT FAILED: legacy upper-case avatar owner locked out'; end if;
end $$;
reset role;
select set_config('request.jwt.claims', json_build_object('sub', current_setting('test.av_lower'), 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', current_setting('test.av_lower'), true),
       set_config('role','authenticated',true);
do $$
declare v_n int;
begin
    update storage.objects set metadata = coalesce(metadata, '{}'::jsonb) where bucket_id = 'avatars';
    get diagnostics v_n = row_count;
    if v_n <> 1 then raise exception 'ASSERT FAILED: avatar owner updated % rows (expected only their own)', v_n; end if;
end $$;
reset role;
select 'S9 assertions passed' as result;
