-- assistant-query JWT grace path (S10, 2026-11-17 review): an expired access
-- token is accepted for up to 2 h only if its signature verifies AND the
-- session it belongs to is still alive (not signed out / revoked). The edge
-- function calls this as service_role; clients cannot.
create or replace function public.auth_session_is_active(p_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
    select exists (
        select 1
          from auth.sessions s
         where s.id = p_session_id
           and (s.not_after is null or s.not_after > now())
    );
$$;

revoke all on function public.auth_session_is_active(uuid) from public, anon, authenticated;
grant execute on function public.auth_session_is_active(uuid) to service_role;
