-- Review 2026-11-27, S3: a partner could take credit for someone else's
-- auto-transfer with one row on their own card.
--
-- get_account_settlement credits the owner of the newest row that shares the
-- leg's transfer_group_id on another member's account, and the transactions
-- INSERT policy lets a user write any transfer_group_id on an account they
-- can edit. Editor B saw group G on A's income leg in the shared account,
-- inserted 0.01 on B's own card with G, and the settlement moved A's
-- contribution to B. The same planted row satisfied the "all three rows
-- touched" check of update_expense_with_auto_transfer.
--
-- Every legitimate group is written by one user (the auto-transfer RPCs run
-- as the author; a manual transfer is two inserts by the same user), and
-- prod has 0 groups with more than one author. So: a row may join an
-- existing transfer_group_id / auto_transfer_group_id only if every row
-- already in that group has the same author. Applies to every role.

create or replace function public.guard_transfer_group_single_author()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.transfer_group_id is not null
       and (tg_op = 'INSERT' or new.transfer_group_id is distinct from old.transfer_group_id
            or new.user_id is distinct from old.user_id)
       and exists (select 1 from public.transactions t
                    where t.transfer_group_id = new.transfer_group_id
                      and t.id <> new.id
                      and t.user_id is distinct from new.user_id) then
        raise exception 'transfer group % belongs to another user', new.transfer_group_id
            using errcode = '42501';
    end if;

    if new.auto_transfer_group_id is not null
       and (tg_op = 'INSERT' or new.auto_transfer_group_id is distinct from old.auto_transfer_group_id
            or new.user_id is distinct from old.user_id)
       and exists (select 1 from public.transactions t
                    where t.auto_transfer_group_id = new.auto_transfer_group_id
                      and t.id <> new.id
                      and t.user_id is distinct from new.user_id) then
        raise exception 'auto-transfer group % belongs to another user', new.auto_transfer_group_id
            using errcode = '42501';
    end if;

    return new;
end;
$$;

revoke execute on function public.guard_transfer_group_single_author() from public, anon, authenticated;

drop trigger if exists trg_transfer_group_single_author on public.transactions;
create trigger trg_transfer_group_single_author
    before insert or update of transfer_group_id, auto_transfer_group_id, user_id
    on public.transactions
    for each row execute function public.guard_transfer_group_single_author();
