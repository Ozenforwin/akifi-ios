-- Budget invites share the "/invite/*" universal-link path with account
-- invites (the AASA whitelists only that path). OLD app versions handle
-- that link by calling accept_account_invite unconditionally — a budget
-- token would die with invite_not_found there, and old clients have no
-- budget fallback.
--
-- Server-side fallback: when the token isn't an account invite, delegate
-- to accept_budget_invite. Old clients then accept budget invites through
-- the only RPC they know. Bonus: the budget RPC returns its jsonb values
-- as strings ('success','true'), which the legacy [String: String] client
-- decoder parses fine.

create or replace function public.accept_account_invite(p_token text)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
    v_clean text;
    v_invite record;
begin
    v_clean := lower(replace(p_token, ' ', ''));

    if length(v_clean) = 16 then
        select * into v_invite from public.account_invites
        where token_prefix = v_clean and status = 'pending'
        limit 1;
    else
        select * into v_invite from public.account_invites
        where token_hash = encode(digest(v_clean, 'sha256'), 'hex')
          and status = 'pending'
        limit 1;
    end if;

    if v_invite is null then
        -- Not an account invite — maybe a budget one (shared link path).
        return public.accept_budget_invite(p_token);
    end if;

    if v_invite.expires_at < now() then
        update public.account_invites set status = 'revoked' where id = v_invite.id;
        return jsonb_build_object('success', false, 'error', 'invite_expired');
    end if;
    if exists (
        select 1 from public.account_members
        where account_id = v_invite.account_id and user_id = auth.uid()
    ) then
        return jsonb_build_object('success', false, 'error', 'already_member');
    end if;

    insert into public.account_members (account_id, user_id, role, invited_by)
    values (v_invite.account_id, auth.uid(), v_invite.role, v_invite.created_by);

    update public.account_invites
    set status = 'accepted', accepted_by = auth.uid(), accepted_at = now()
    where id = v_invite.id;

    return jsonb_build_object(
        'success', true,
        'account_id', v_invite.account_id,
        'role', v_invite.role
    );
end;
$$;
