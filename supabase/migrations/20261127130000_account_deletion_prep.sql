-- Review 2026-11-27, A2: deleting an account destroyed the partner's data.
--
-- delete-account removed the auth user; accounts.user_id and budgets.user_id
-- cascade from auth.users, and transactions.account_id cascades from
-- accounts. So when the OWNER of «Семейный» deleted their account, the
-- shared account, every partner transaction on it, its settlements and the
-- shared budgets disappeared for the partner. Separately, three foreign keys
-- to auth.users had no ON DELETE action, so deleting anyone who had invited a
-- budget member or created a budget invite failed half-way — after the old
-- function had already deleted most of their rows.
--
-- prepare_account_deletion(user) runs (service role only, one transaction)
-- before auth.admin.deleteUser:
--   * shared accounts and shared budgets the user owns pass to the remaining
--     member (owner > editor > viewer, then the earliest member);
--   * the user's categories that other people's transactions still use pass
--     to the account owner (or are merged into a same-named category the
--     heir already has), so partner rows keep their category;
--   * "who recorded it" on settlements that survive (the user is not a party)
--     moves to a party, because settled_by / settled_by_user_id are NOT NULL
--     and the iOS 1.5.7 models require them.
-- Everything the user wrote themselves still goes with them (FK cascades).

alter table public.budget_members drop constraint if exists budget_members_invited_by_fkey;
alter table public.budget_members
    add constraint budget_members_invited_by_fkey
    foreign key (invited_by) references auth.users(id) on delete set null;

alter table public.budget_invites drop constraint if exists budget_invites_created_by_fkey;
alter table public.budget_invites
    add constraint budget_invites_created_by_fkey
    foreign key (created_by) references auth.users(id) on delete cascade;

alter table public.budget_invites drop constraint if exists budget_invites_accepted_by_fkey;
alter table public.budget_invites
    add constraint budget_invites_accepted_by_fkey
    foreign key (accepted_by) references auth.users(id) on delete set null;

create or replace function public.prepare_account_deletion(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    r          record;
    v_heir     uuid;
    v_target   uuid;
    v_accounts int := 0;
    v_budgets  int := 0;
    v_cats     int := 0;
    v_merged   int := 0;
    v_settl    int := 0;
begin
    if coalesce(auth.role(), '') in ('authenticated', 'anon') then
        raise exception 'prepare_account_deletion is service-role only' using errcode = '42501';
    end if;
    if p_user_id is null then
        raise exception 'p_user_id is required' using errcode = '22004';
    end if;

    -- 1. Shared accounts owned by the user -> remaining member.
    for r in
        select a.id from accounts a
         where a.user_id = p_user_id
           and exists (select 1 from account_members m where m.account_id = a.id and m.user_id <> p_user_id)
    loop
        select m.user_id into v_heir
          from account_members m
         where m.account_id = r.id and m.user_id <> p_user_id
         order by case m.role when 'owner' then 0 when 'editor' then 1 else 2 end, m.created_at, m.user_id
         limit 1;
        update accounts set user_id = v_heir where id = r.id;
        update account_members set role = 'owner' where account_id = r.id and user_id = v_heir;
        -- Account-scoped categories belong to the account, keep them with it.
        update categories set user_id = v_heir where account_id = r.id and user_id = p_user_id;
        v_accounts := v_accounts + 1;
    end loop;

    -- 2. Shared budgets owned by the user -> remaining member.
    for r in
        select b.id from budgets b
         where b.user_id = p_user_id
           and exists (select 1 from budget_members m where m.budget_id = b.id and m.user_id <> p_user_id)
    loop
        select m.user_id into v_heir
          from budget_members m
         where m.budget_id = r.id and m.user_id <> p_user_id
         order by case m.role when 'owner' then 0 when 'editor' then 1 else 2 end, m.created_at, m.user_id
         limit 1;
        update budgets set user_id = v_heir where id = r.id;
        update budget_members set role = 'owner' where budget_id = r.id and user_id = v_heir;
        v_budgets := v_budgets + 1;
    end loop;

    -- 3. The user's personal categories still used by other people's rows.
    for r in
        select c.id, c.type, c.name,
               (select a.user_id
                  from transactions t join accounts a on a.id = t.account_id
                 where t.category_id = c.id and t.user_id <> p_user_id and a.user_id <> p_user_id
                 order by t.created_at desc limit 1) as heir
          from categories c
         where c.user_id = p_user_id
           and c.account_id is null
           and exists (select 1 from transactions t where t.category_id = c.id and t.user_id <> p_user_id)
    loop
        continue when r.heir is null;
        select c2.id into v_target
          from categories c2
         where c2.user_id = r.heir and c2.type = r.type and c2.name = r.name
           and c2.account_id is null and c2.id <> r.id
         limit 1;
        if v_target is not null then
            update transactions set category_id = v_target
             where category_id = r.id and user_id <> p_user_id;
            v_merged := v_merged + 1;
        else
            update categories set user_id = r.heir where id = r.id;
            v_cats := v_cats + 1;
        end if;
        v_target := null;
    end loop;

    -- 4. Settlements that survive the user: move "recorded by" to a party.
    update settlements
       set settled_by = from_user_id
     where settled_by = p_user_id
       and from_user_id <> p_user_id and to_user_id <> p_user_id;
    get diagnostics v_settl = row_count;

    update transaction_member_settlements
       set settled_by_user_id = settled_for_user_id
     where settled_by_user_id = p_user_id
       and settled_for_user_id <> p_user_id;

    return jsonb_build_object(
        'accounts_transferred',   v_accounts,
        'budgets_transferred',    v_budgets,
        'categories_transferred', v_cats,
        'categories_merged',      v_merged,
        'settlements_reassigned', v_settl
    );
end;
$$;

revoke execute on function public.prepare_account_deletion(uuid) from public, anon, authenticated;
grant execute on function public.prepare_account_deletion(uuid) to service_role;
