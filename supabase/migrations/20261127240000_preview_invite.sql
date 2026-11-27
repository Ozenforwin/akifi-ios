-- Review 2026-11-27, S2 (server half): preview an invite before joining it.
-- The 1.5.8 confirmation screen shows who invites, to what, with which role
-- and (budgets) whether a category filter limits what members see. Same
-- token resolution as accept_*_invite (hashed 16-char code or full token),
-- read-only, and an invite whose author lost the right to invite looks
-- unknown, exactly like accept_* treats it. Only a session holding the
-- token learns these names.
create or replace function public.preview_invite(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions
as $$
declare
    v_clean text := lower(replace(coalesce(p_token, ''), ' ', ''));
    v_hash text;
    v_acc record;
    v_bud record;
begin
    if auth.uid() is null then
        return jsonb_build_object('found', false, 'error', 'invite_not_found');
    end if;
    if length(v_clean) < 16 then
        return jsonb_build_object('found', false, 'error', 'invite_not_found');
    end if;
    v_hash := encode(digest(v_clean, 'sha256'), 'hex');

    select i.role, i.expires_at, a.name as target_name, p.full_name as inviter_name
      into v_acc
      from public.account_invites i
      join public.accounts a on a.id = i.account_id
      left join public.profiles p on p.id = i.created_by
     where i.status = 'pending'
       and (case when length(v_clean) = 16 then i.token_prefix_hash = v_hash
                 else i.token_hash = v_hash end)
       and exists (select 1 from public.account_members m
                    where m.account_id = i.account_id and m.user_id = i.created_by
                      and m.role in ('owner', 'editor'))
     limit 1;

    if found then
        if v_acc.expires_at < now() then
            return jsonb_build_object('found', false, 'error', 'invite_expired');
        end if;
        return jsonb_build_object(
            'found', true, 'kind', 'account', 'role', v_acc.role,
            'inviter_name', nullif(trim(v_acc.inviter_name), ''),
            'target_name', v_acc.target_name,
            'expires_at', v_acc.expires_at);
    end if;

    select i.role, i.expires_at, b.name as target_name, p.full_name as inviter_name,
           (coalesce(cardinality(b.category_ids), 0) > 0) as category_filter
      into v_bud
      from public.budget_invites i
      join public.budgets b on b.id = i.budget_id
      left join public.profiles p on p.id = i.created_by
     where i.status = 'pending'
       and (case when length(v_clean) = 16 then i.token_prefix_hash = v_hash
                 else i.token_hash = v_hash end)
       and (exists (select 1 from public.budget_members m
                     where m.budget_id = i.budget_id and m.user_id = i.created_by
                       and m.role in ('owner', 'editor'))
            or b.user_id = i.created_by)
     limit 1;

    if found then
        if v_bud.expires_at < now() then
            return jsonb_build_object('found', false, 'error', 'invite_expired');
        end if;
        return jsonb_build_object(
            'found', true, 'kind', 'budget', 'role', v_bud.role,
            'inviter_name', nullif(trim(v_bud.inviter_name), ''),
            'target_name', v_bud.target_name,
            'category_filter', v_bud.category_filter,
            'expires_at', v_bud.expires_at);
    end if;

    return jsonb_build_object('found', false, 'error', 'invite_not_found');
end;
$$;

revoke execute on function public.preview_invite(text) from public, anon;
grant execute on function public.preview_invite(text) to authenticated;

revoke execute on function public.preview_invite(text) from public, anon;
grant execute on function public.preview_invite(text) to authenticated;
