-- S6 (2026-11-17 review): any member could "settle" a debt with any amount.
--
-- settlements_members_insert only checked `settled_by = auth.uid()` and that
-- the caller is a member: from/to could be anyone (even non-members), the
-- amount could be zero or negative, and a viewer could write. Only the
-- creator can delete such a row, and get_account_settlement
-- (20261117090000) sums every settlements / transaction_member_settlements
-- row as-is — so one bad row moves the debt both members see.
-- txn_member_settle_insert had the same gaps, plus it accepted marks for
-- transactions that are not on the shared account at all.
--
-- New INSERT rules (SELECT / DELETE policies are unchanged):
--   settlements
--     * settled_by = auth.uid()
--     * caller is owner/editor of the shared account
--     * caller is one of the two parties; from_user_id <> to_user_id
--     * both parties are members of the shared account
--     * amount > 0 (kopecks, bigint)
--     * currency = the account's currency (case-insensitive): the server
--       settlement sums the kopecks as-is, so a row in another currency would
--       silently be read as the account's currency.
--   transaction_member_settlements
--     * settled_by_user_id = auth.uid()
--     * caller is owner/editor of the shared account
--     * settled_for_user_id is a member of the shared account
--     * the transaction is on that shared account
-- Existing prod rows (6 settlements, 71 marks) all satisfy these rules
-- (checked 2026-11-17); the iOS client writes exactly these shapes
-- (SettlementViewModel.markSettled / toggleMemberSettlement).

-- Membership test for ANOTHER user, answered only to members of the same
-- account (so it is not a membership oracle for outsiders). SECURITY DEFINER
-- so the answer does not depend on what RLS lets the caller see.
create or replace function public.is_account_party(p_account_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select p_account_id is not null
       and p_user_id is not null
       and exists (select 1 from public.account_members me
                    where me.account_id = p_account_id and me.user_id = auth.uid())
       and (
            exists (select 1 from public.account_members m
                     where m.account_id = p_account_id and m.user_id = p_user_id)
         or exists (select 1 from public.accounts a
                     where a.id = p_account_id and a.user_id = p_user_id)
       );
$$;

revoke all on function public.is_account_party(uuid, uuid) from public, anon;
grant execute on function public.is_account_party(uuid, uuid) to authenticated, service_role;

drop policy if exists settlements_members_insert on public.settlements;
create policy settlements_members_insert on public.settlements
    for insert
    with check (
        settled_by = auth.uid()
        and public.is_account_editor_or_owner(shared_account_id)
        and auth.uid() in (from_user_id, to_user_id)
        and from_user_id <> to_user_id
        and public.is_account_party(shared_account_id, from_user_id)
        and public.is_account_party(shared_account_id, to_user_id)
        and amount > 0
        and exists (
            select 1 from public.accounts a
             where a.id = settlements.shared_account_id
               and lower(a.currency) = lower(settlements.currency)
        )
    );

drop policy if exists txn_member_settle_insert on public.transaction_member_settlements;
create policy txn_member_settle_insert on public.transaction_member_settlements
    for insert
    with check (
        settled_by_user_id = auth.uid()
        and public.is_account_editor_or_owner(shared_account_id)
        and public.is_account_party(shared_account_id, settled_for_user_id)
        and exists (
            select 1 from public.transactions t
             where t.id = transaction_member_settlements.transaction_id
               and t.account_id = transaction_member_settlements.shared_account_id
        )
    );
