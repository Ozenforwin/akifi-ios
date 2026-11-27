-- Dry run: begin; <migration>; <this file>; rollback;
do $$
declare
    v_acc uuid; v_owner uuid; v_partner uuid; v_stranger uuid;
    v_token text; v_inv record; v_res jsonb;
begin
    select a.id, a.user_id into v_acc, v_owner from accounts a
     where (select count(*) from account_members m where m.account_id = a.id) > 1 limit 1;
    select user_id into v_partner from account_members where account_id = v_acc and user_id <> v_owner limit 1;
    select u.id into v_stranger from auth.users u
     where not exists (select 1 from account_members m where m.account_id = v_acc and m.user_id = u.id) limit 1;
    if v_stranger is null then raise exception 'ASSERT FAILED: fixture missing'; end if;

    -- 1. A 100-year invite is capped at 7 days; the short code is not stored in clear.
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
    v_token := public.create_account_invite(v_acc, 'viewer', 876000);
    select * into v_inv from account_invites where token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex');
    if v_inv.expires_at > now() + interval '168 hours 1 minute' then raise exception 'ASSERT FAILED: lifetime not capped'; end if;
    if v_inv.token_prefix is not null or v_inv.token_prefix_hash is null then raise exception 'ASSERT FAILED: prefix stored in clear'; end if;

    -- 2. The short code still works.
    perform set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
    v_res := public.accept_account_invite(upper(substr(v_token, 1, 16)));
    if (v_res->>'success')::boolean is not true then raise exception 'ASSERT FAILED: short code refused: %', v_res; end if;
    delete from account_members where account_id = v_acc and user_id = v_stranger;

    -- 3. An invite made by the partner dies when the partner leaves.
    update account_members set role = 'editor' where account_id = v_acc and user_id = v_partner and role = 'viewer';
    perform set_config('request.jwt.claims', json_build_object('sub', v_partner, 'role', 'authenticated')::text, true);
    v_token := public.create_account_invite(v_acc, 'editor', 72);
    delete from account_members where account_id = v_acc and user_id = v_partner;
    if (select status from account_invites where token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex')) <> 'revoked' then
        raise exception 'ASSERT FAILED: departed member invite still pending';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
    v_res := public.accept_account_invite(v_token);
    if (v_res->>'success') = 'true' then raise exception 'ASSERT FAILED: revoked invite accepted'; end if;

    -- 4. No session, no accept.
    perform set_config('request.jwt.claims', '{}', true);
    v_res := public.accept_account_invite(v_token);
    if v_res->>'error' <> 'not_authenticated' then raise exception 'ASSERT FAILED: anonymous accept: %', v_res; end if;
end $$;
select 'invite hardening: all assertions passed' as result;
