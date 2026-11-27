-- Dry run: begin; <migration>; <this file>; rollback;
do $$
declare v_acc uuid; v_owner uuid; v_stranger uuid; v_token text; r jsonb;
begin
    select a.id, a.user_id into v_acc, v_owner from accounts a
     where (select count(*) from account_members m where m.account_id = a.id) > 1 limit 1;
    select u.id into v_stranger from auth.users u
     where not exists (select 1 from account_members m where m.account_id = v_acc and m.user_id = u.id) limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
    v_token := public.create_account_invite(v_acc, 'viewer', 24);
    perform set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
    r := public.preview_invite(v_token);
    if (r->>'found')::boolean is not true or r->>'kind' <> 'account' or r->>'role' <> 'viewer' or r->>'target_name' is null then
        raise exception 'ASSERT FAILED: full token preview %', r; end if;
    r := public.preview_invite(upper(substr(v_token, 1, 16)));
    if (r->>'found')::boolean is not true then raise exception 'ASSERT FAILED: short code preview %', r; end if;
    if (select status from account_invites where token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex')) <> 'pending' then
        raise exception 'ASSERT FAILED: preview changed the invite'; end if;
    r := public.preview_invite('0000000000000000');
    if (r->>'found')::boolean is not false then raise exception 'ASSERT FAILED: bogus code found'; end if;
    perform set_config('request.jwt.claims', '{}', true);
    r := public.preview_invite(v_token);
    if (r->>'found')::boolean is not false then raise exception 'ASSERT FAILED: anonymous preview'; end if;
end $$;
select 'preview_invite: all assertions passed' as result;
