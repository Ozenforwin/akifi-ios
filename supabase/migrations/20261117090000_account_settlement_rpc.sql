-- get_account_settlement — "who owes whom" for a shared account, computed on
-- the server so every member gets the SAME answer.
--
-- Why: until now the iOS client computed settlement balances from
-- `dataStore.transactions`, which is RLS-filtered — each member sees the
-- shared account's rows plus only their OWN personal accounts. Resolving the
-- payer of an auto-transfer needs the source leg on the payer's personal card,
-- which the other member cannot see. One client path fell back to the leg's
-- creator, another skipped the row, so on 2026-11-16 the two members of
-- «Семейный» saw −1 541 ₽ and +43 622 ₽ for the same data (correct: one owed
-- the other 5 858.92 ₽). This function sees every row, so the result does not
-- depend on who is asking — and fixing the math is a migration, not an App
-- Store release.
--
-- Semantics mirror SettlementCalculator.compute (cumulative, all-time):
--   * total     = Σ main expense legs of auto-transfer triplets on the account
--                 (type = expense, transfer_group_id IS NULL,
--                  auto_transfer_group_id IS NOT NULL). Direct expenses and
--                 legacy manual transfers are ignored, as in the client.
--   * fair share = total · weight / Σweights, half-up to the kopeck, residual
--                 distributed one kopeck at a time in member order.
--   * contributions: every auto-transfer leg on the account (both group ids
--                 set) credits (+income / −expense) its PAYER.
--   * payer     = owner of the peer leg's account (same transfer_group_id,
--                 on another account) when that owner is a member; otherwise
--                 the leg's creator (the auto-transfer RPC writes all three
--                 legs as the paying user).
--   * settlements: from_user +amount, to_user −amount (all of them).
--   * per-transaction marks: settled member +share, payer −share, where share
--                 = expense · weight(member) / Σweights; a payer's mark on
--                 their own expense is a no-op.
-- Amounts: `amount_native` is in the account's currency (ADR-001), so no FX
-- is involved. Each row is rounded to kopecks before summing, exactly like
-- the client's decoder does.
--
-- Returns ONE jsonb value (never a row set), so PostgREST max-rows cannot
-- truncate it (ADR-003):
--   { "version": 1, "account_id", "currency", "total_expenses", "tx_count",
--     "balances": [ { "user_id", "contributed", "fair_share" } ],   -- kopecks
--     "payers":   { "<main expense id>": "<payer user id>" } }
-- `balances` is empty when there are no auto-transfer expenses (the client
-- shows its "no activity yet" state).

create or replace function public.get_account_settlement(p_account_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_uid      uuid := auth.uid();
    v_members  uuid[];
    v_weights  numeric[];
    v_n        int;
    v_sum_w    numeric;
    v_total    bigint;
    v_tx_count bigint;
    v_fair     bigint[];
    v_residual bigint;
    v_i        int;
    v_contrib  jsonb;
    v_payers   jsonb;
    v_balances jsonb;
    v_currency text;
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

    select coalesce(sum(round(t.amount_native * 100)), 0)::bigint, count(*)
      into v_total, v_tx_count
      from transactions t
     where t.account_id = p_account_id
       and t.type = 'expense'
       and t.transfer_group_id is null
       and t.auto_transfer_group_id is not null;

    if v_total = 0 then
        return jsonb_build_object(
            'version', 1, 'account_id', p_account_id, 'currency', v_currency,
            'total_expenses', 0, 'tx_count', 0,
            'balances', '[]'::jsonb, 'payers', '{}'::jsonb);
    end if;

    -- Fair shares with the rounding residual spread so Σ fair = total.
    v_fair := array_fill(0::bigint, array[v_n]);
    if v_sum_w > 0 then
        for v_i in 1..v_n loop
            v_fair[v_i] := round(v_total * v_weights[v_i] / v_sum_w)::bigint;
        end loop;
        select v_total - coalesce(sum(x), 0) into v_residual from unnest(v_fair) x;
        v_i := 1;
        while v_residual <> 0 and v_i <= v_n loop
            v_fair[v_i] := v_fair[v_i] + sign(v_residual)::bigint;
            v_residual  := v_residual - sign(v_residual)::bigint;
            v_i := v_i + 1;
        end loop;
    end if;

    with acct_rows as (
        select t.id, t.user_id, t.type, t.transfer_group_id, t.auto_transfer_group_id,
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
        select r.id, r.auto_transfer_group_id, r.k
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
               round(e.k * coalesce(mw.weight, 1.0) / v_sum_w)::bigint as share
          from transaction_member_settlements m
          join main_exp e     on e.id = m.transaction_id
          join group_payer gp on gp.auto_transfer_group_id = e.auto_transfer_group_id
          left join member_weight mw on mw.user_id = m.settled_for_user_id
         where m.shared_account_id = p_account_id
           and gp.payer <> m.settled_for_user_id
           and v_sum_w > 0
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
               'fair_share', v_fair[i]) order by i), '[]'::jsonb)
      into v_balances
      from generate_subscripts(v_members, 1) as i;

    return jsonb_build_object(
        'version', 1, 'account_id', p_account_id, 'currency', v_currency,
        'total_expenses', v_total, 'tx_count', v_tx_count,
        'balances', v_balances, 'payers', v_payers);
end;
$$;

revoke all on function public.get_account_settlement(uuid) from public, anon;
grant execute on function public.get_account_settlement(uuid) to authenticated;

comment on function public.get_account_settlement(uuid) is
    'Who-owes-whom for a shared account, identical for every member (see migration 20261117090000). Single jsonb, kopecks.';
