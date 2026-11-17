do $$ begin
if public.auth_session_is_active('00000000-0000-4000-8000-000000000000') then raise exception 'ASSERT FAILED: random session active'; end if;
if not public.auth_session_is_active((select id from auth.sessions where not_after is null or not_after > now() order by created_at desc limit 1)) then raise exception 'ASSERT FAILED: live session not active'; end if;
if has_function_privilege('authenticated','public.auth_session_is_active(uuid)','EXECUTE') then raise exception 'ASSERT FAILED: authenticated can call'; end if;
end $$;
select 'auth_session_is_active assertions passed' as result;
