-- get_account_settlement v2 — personal spending from a shared account (1.6.0).
--
-- Everything v1 (20261117090000) returned is still returned with the same
-- meaning; for accounts without personal marks every v1 field is identical
-- (checked on prod data by the assertion file). New:
--
-- 1. 100 % attribution. A main auto-transfer expense (type = expense,
--    transfer_group_id IS NULL, auto_transfer_group_id IS NOT NULL) with
--    personal_debt_user_id = M, M a current member, is NOT split by weights:
--      fair_share(M) += amount, nobody else gets a share of it.
--    The remaining (shared) expenses are split exactly like v1 (weights,
--    half-up, residual one kopeck at a time in member order). Contributions,
--    settlements and payers are unchanged, so:
--      M paid it from M's own card  -> +amount contributed, +amount fair: 0;
--      partner P paid it            -> P +amount contributed, M +amount fair:
--                                      M owes P the full amount.
--    Per-transaction marks on such an expense: M's share is the full amount,
--    everyone else's share is 0 (a mark for them is a no-op).
--    A mark for a user who is no longer a member is ignored here: the
--    expense is split by weights like any shared one.
-- 2. personal_debts — what members owe THE ACCOUNT for personal spending
--    paid from the shared account's own money:
--      expenses = Σ direct expenses (type = expense, transfer_group_id NULL,
--                 auto_transfer_group_id NULL) with personal_debt_user_id = M
--      repaid   = Σ repayment legs (type = income, transfer_group_id set,
--                 auto_transfer_group_id NULL) with personal_debt_user_id = M
--      owed     = max(expenses − repaid, 0)   (raw numbers are returned too)
--    One entry per current member (member order, zeros included), then any
--    former member with a non-zero entry (is_member = false). These rows are
--    NOT part of balances: direct expenses and manual transfers stay outside
--    the who-owes-whom math, as in v1.
--
-- Shape (kopecks = minor units ×100 of the account currency):
--   { "version": 2, "account_id", "currency", "total_expenses", "tx_count",
--     "balances": [ { "user_id", "contributed", "fair_share",
--                     "personal_share" } ],            -- personal_share ⊂ fair_share
--     "payers":   { "<main expense id>": "<payer user id>" },
--     "personal_debts": [ { "user_id", "owed", "expenses", "repaid",
--                           "is_member" } ] }
-- balances is still empty when there are no auto-transfer expenses
-- (personal_debts is returned in that case too). Σ fair_share =
-- total_expenses whenever weights sum to > 0.
-- Old clients (1.5.x) decode version/total_expenses/balances/payers and
-- ignore the new keys; their offline fallback does not know personal marks,
-- so it may report settlement_integrity_mismatch once marks are used — the
-- server value is what they display.

create or replace function public.get_account_settlement(p_account_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_uid       uuid := auth.uid();
    v_members   uuid[];
    v_weights   numeric[];
    v_n         int;
    v_sum_w     numeric;
    v_total     bigint;
    v_tx_count  bigint;
    v_personal  bigint[];
    v_shared    bigint;
    v_fair      bigint[];
    v_residual  bigint;
    v_i         int;
    v_contrib   jsonb;
    v_payers    jsonb;
    v_balances  jsonb;
    v_currency  text;
    v_pdebts    jsonb;
begin
    -- Same audience as the RLS on `settlements`: members and the owner.
    if v_uid is null or not (
        exists (select 1 from account_members m
                where m.account_id = p_account_id and m.user_id = v_uid)
        or exists (select 1 from accounts a
                   where a.id = p_account_id and a.user_id = v_uid)
    ) then
        raise exception 'Access denied: not a member of this account'
            using errcode = '42501';
    end if;

    select a.currency into v_currency from accounts a where a.id = p_account_id;

    -- Members in a deterministic order (drives residual distribution).
    select coalesce(array_agg(m.user_id order by m.user_id), '{}'),
           coalesce(array_agg(coalesce(m.split_weight, 1.0)::numeric order by m.user_id), '{}')
      into v_members, v_weights
      from account_members m
     where m.account_id = p_account_id;
    if cardinality(v_members) = 0 then
        select array[a.user_id], array[1.0::numeric]
          into v_members, v_weights
          from accounts a where a.id = p_account_id;
    end if;
    v_n := cardinality(v_members);
    select coalesce(sum(w), 0) into v_sum_w from unnest(v_weights) w;

    -- Personal debts to the account (independent of the auto-transfer math).
    with pd as (
        select t.personal_debt_user_id as user_id,
               coalesce(sum(round(t.amount_native * 100)) filter (where t.type = 'expense'), 0)::bigint as expenses,
               coalesce(sum(round(t.amount_native * 100)) filter (where t.type = 'income'), 0)::bigint  as repaid
          from transactions t
         where t.account_id = p_account_id
           and t.personal_debt_user_id is not null
           and t.auto_transfer_group_id is null
           and ((t.type = 'expense' and t.transfer_group_id is null)
             or (t.type = 'income'  and t.transfer_group_id is not null))
         group by t.personal_debt_user_id
    ),
    people as (
        select m.user_id, m.ord, true as is_member
          from unnest(v_members) with ordinality as m(user_id, ord)
        union all
        select pd.user_id, null::bigint, false
          from pd
         where not (pd.user_id = any(v_members))
           and (pd.expenses <> 0 or pd.repaid <> 0)
    )
    select coalesce(jsonb_agg(jsonb_build_object(
               'user_id',   p.user_id,
               'owed',      greatest(coalesce(pd.expenses, 0) - coalesce(pd.repaid, 0), 0),
               'expenses',  coalesce(pd.expenses, 0),
               'repaid',    coalesce(pd.repaid, 0),
               'is_member', p.is_member)
             order by p.ord nulls last, p.user_id), '[]'::jsonb)
      into v_pdebts
      from people p
      left join pd on pd.user_id = p.user_id;

    select coalesce(sum(round(t.amount_native * 100)), 0)::bigint, count(*)
      into v_total, v_tx_count
      from transactions t
     where t.account_id = p_account_id
       and t.type = 'expense'
       and t.transfer_group_id is null
       and t.auto_transfer_group_id is not null;

    if v_total = 0 then
        return jsonb_build_object(
            'version', 2, 'account_id', p_account_id, 'currency', v_currency,
            'total_expenses', 0, 'tx_count', 0,
            'balances', '[]'::jsonb, 'payers', '{}'::jsonb,
            'personal_debts', v_pdebts);
    end if;

    -- Personal (100 %) part of the auto-transfer expenses, per current member.
    select coalesce(array_agg(coalesce(x.k, 0)::bigint order by m.ord), '{}')
      into v_personal
      from unnest(v_members) with ordinality as m(user_id, ord)
      left join (
          select t.personal_debt_user_id as uid, sum(round(t.amount_native * 100))::bigint as k
            from transactions t
           where t.account_id = p_account_id
             and t.type = 'expense'
             and t.transfer_group_id is null
             and t.auto_transfer_group_id is not null
             and t.personal_debt_user_id is not null
           group by t.personal_debt_user_id
      ) x on x.uid = m.user_id;
    select v_total - coalesce(sum(x), 0) into v_shared from unnest(v_personal) x;

    -- Shared part: fair shares with the rounding residual spread so
    -- Σ = shared total (v1 algorithm, applied to the shared part only).
    v_fair := array_fill(0::bigint, array[v_n]);
    if v_sum_w > 0 then
        for v_i in 1..v_n loop
            v_fair[v_i] := round(v_shared * v_weights[v_i] / v_sum_w)::bigint;
        end loop;
        select v_shared - coalesce(sum(x), 0) into v_residual from unnest(v_fair) x;
        v_i := 1;
        while v_residual <> 0 and v_i <= v_n loop
            v_fair[v_i] := v_fair[v_i] + sign(v_residual)::bigint;
            v_residual  := v_residual - sign(v_residual)::bigint;
            v_i := v_i + 1;
        end loop;
    end if;
    for v_i in 1..v_n loop
        v_fair[v_i] := v_fair[v_i] + v_personal[v_i];
    end loop;

    with acct_rows as (
        select t.id, t.user_id, t.type, t.transfer_group_id, t.auto_transfer_group_id,
               case when t.personal_debt_user_id = any(v_members)
                    then t.personal_debt_user_id end as personal,
               round(t.amount_native * 100)::bigint as k
          from transactions t
         where t.account_id = p_account_id
    ),
    legs as (
        select r.*,
               coalesce(
                   (select pa.user_id
                      from transactions peer
                      join accounts pa on pa.id = peer.account_id
                     where peer.transfer_group_id = r.transfer_group_id
                       and peer.id <> r.id
                       and peer.account_id <> p_account_id
                       and pa.user_id = any(v_members)
                     order by peer.created_at desc, peer.id
                     limit 1),
                   r.user_id) as payer
          from acct_rows r
         where r.transfer_group_id is not null
           and r.auto_transfer_group_id is not null
    ),
    main_exp as (
        select r.id, r.auto_transfer_group_id, r.k, r.personal
          from acct_rows r
         where r.type = 'expense'
           and r.transfer_group_id is null
           and r.auto_transfer_group_id is not null
    ),
    group_payer as (
        select distinct on (l.auto_transfer_group_id) l.auto_transfer_group_id, l.payer
          from legs l
         where l.type = 'income'
         order by l.auto_transfer_group_id, l.id
    ),
    member_weight as (
        select * from unnest(v_members, v_weights) as w(user_id, weight)
    ),
    marks as (
        select m.settled_for_user_id as settled_for,
               gp.payer,
               case when e.personal is not null
                    then case when e.personal = m.settled_for_user_id then e.k else 0 end
                    else round(e.k * coalesce(mw.weight, 1.0) / nullif(v_sum_w, 0))::bigint
               end as share
          from transaction_member_settlements m
          join main_exp e     on e.id = m.transaction_id
          join group_payer gp on gp.auto_transfer_group_id = e.auto_transfer_group_id
          left join member_weight mw on mw.user_id = m.settled_for_user_id
         where m.shared_account_id = p_account_id
           and gp.payer <> m.settled_for_user_id
           and (e.personal is not null or v_sum_w > 0)
    ),
    deltas as (
        select payer as user_id,
               case type when 'income' then k when 'expense' then -k else 0 end as amt
          from legs
        union all
        select s.from_user_id, s.amount from settlements s where s.shared_account_id = p_account_id
        union all
        select s.to_user_id, -s.amount from settlements s where s.shared_account_id = p_account_id
        union all
        select settled_for, share from marks
        union all
        select payer, -share from marks
    )
    select
        (select coalesce(jsonb_object_agg(user_id::text, amt), '{}'::jsonb)
           from (select user_id, sum(amt)::bigint as amt from deltas group by user_id) c),
        (select coalesce(jsonb_object_agg(e.id::text, gp.payer::text), '{}'::jsonb)
           from main_exp e
           join group_payer gp on gp.auto_transfer_group_id = e.auto_transfer_group_id)
      into v_contrib, v_payers;

    select coalesce(jsonb_agg(jsonb_build_object(
               'user_id', v_members[i],
               'contributed', coalesce((v_contrib ->> v_members[i]::text)::bigint, 0),
               'fair_share', v_fair[i],
               'personal_share', v_personal[i]) order by i), '[]'::jsonb)
      into v_balances
      from generate_subscripts(v_members, 1) as i;

    return jsonb_build_object(
        'version', 2, 'account_id', p_account_id, 'currency', v_currency,
        'total_expenses', v_total, 'tx_count', v_tx_count,
        'balances', v_balances, 'payers', v_payers,
        'personal_debts', v_pdebts);
end;
$$;

revoke all on function public.get_account_settlement(uuid) from public, anon;
grant execute on function public.get_account_settlement(uuid) to authenticated;

comment on function public.get_account_settlement(uuid) is
    'Who-owes-whom for a shared account, identical for every member. v2 (migration 20261128090003): personal marks — 100 % fair-share attribution and personal_debts to the account. Single jsonb, kopecks.';
