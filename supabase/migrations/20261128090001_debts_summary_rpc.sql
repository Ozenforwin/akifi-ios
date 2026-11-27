-- debts_summary() — every debt of the caller with its server-computed
-- balance, in ONE jsonb value (never a row set), so PostgREST max-rows can't
-- truncate it (ADR-003). The «Долги» screen and the Home "мне должны / я
-- должен" line read this; the client's own sum over dataStore.transactions
-- is only the offline fallback.
--
-- balance (minor units of the debt account's currency, ×100 like every other
-- RPC here) = initial_balance·100 + Σ round(amount_native·100) over the debt
-- account's income rows − the same over its expense rows. amount_native is
-- in the account's currency (ADR-001); each row is rounded before summing,
-- exactly like the client decoder. > 0: they owe me, < 0: I owe them.
--
-- Shape (version 1):
--   { "version": 1, "today": "YYYY-MM-DD",
--     "debts": [ { "account_id", "name", "icon", "color", "currency",
--                  "balance", "direction": "owed_to_me" | "i_owe" | "settled",
--                  "counterparty_name", "counterparty_contact", "due_date",
--                  "remind", "note", "closed_at", "is_closed", "is_overdue",
--                  "has_details", "tx_count", "last_movement_at", "created_at" } ],
--     "totals": [ { "currency", "owed_to_me", "i_owe", "open_count" } ] }
-- debts: open first, then by due_date (nulls last), created_at, account_id.
-- totals: open debts only (closed_at is null), one entry per currency, no FX.
-- today: the caller's local date (profiles.timezone, UTC when unknown);
-- is_overdue = open, balance <> 0 and due_date < today.
-- A debt account without a debts row (interrupted two-step create) is
-- listed with has_details = false and counterparty_name = the account name.

create or replace function public.debts_summary()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
    v_uid    uuid := auth.uid();
    v_tz     text;
    v_today  date;
    v_debts  jsonb;
    v_totals jsonb;
begin
    if v_uid is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    select p.timezone into v_tz from public.profiles p where p.id = v_uid;
    v_today := (now() at time zone coalesce(v_tz, 'UTC'))::date;

    with acc as (
        select a.id, a.name, a.icon, a.color, upper(a.currency) as currency,
               coalesce(a.initial_balance, 0)::bigint * 100 as opening, a.created_at
          from public.accounts a
         where a.user_id = v_uid
           and a.account_type = 'debt'
    ),
    mv as (
        select t.account_id,
               sum(case t.type
                       when 'income'  then  round(t.amount_native * 100)
                       when 'expense' then -round(t.amount_native * 100)
                       else 0 end)::bigint as net,
               count(*)::int as n,
               max(t.date) as last_at
          from public.transactions t
          join acc on acc.id = t.account_id
         group by t.account_id
    ),
    r as (
        select acc.id, acc.name, acc.icon, acc.color, acc.currency, acc.created_at,
               acc.opening + coalesce(mv.net, 0) as balance,
               coalesce(mv.n, 0) as n, mv.last_at,
               d.account_id is not null as has_details,
               coalesce(d.counterparty_name, acc.name) as counterparty_name,
               d.counterparty_contact, d.due_date, coalesce(d.remind, false) as remind,
               d.note, d.closed_at
          from acc
          left join mv on mv.account_id = acc.id
          left join public.debts d on d.account_id = acc.id
    )
    select
        coalesce(jsonb_agg(jsonb_build_object(
            'account_id',           r.id,
            'name',                 r.name,
            'icon',                 r.icon,
            'color',                r.color,
            'currency',             r.currency,
            'balance',              r.balance,
            'direction',            case when r.balance > 0 then 'owed_to_me'
                                         when r.balance < 0 then 'i_owe'
                                         else 'settled' end,
            'counterparty_name',    r.counterparty_name,
            'counterparty_contact', r.counterparty_contact,
            'due_date',             r.due_date,
            'remind',               r.remind,
            'note',                 r.note,
            'closed_at',            r.closed_at,
            'is_closed',            r.closed_at is not null,
            'is_overdue',           r.closed_at is null and r.balance <> 0
                                    and r.due_date is not null and r.due_date < v_today,
            'has_details',          r.has_details,
            'tx_count',             r.n,
            'last_movement_at',     r.last_at,
            'created_at',           r.created_at)
          order by (r.closed_at is not null), r.due_date nulls last, r.created_at, r.id), '[]'::jsonb),
        coalesce((
            select jsonb_agg(jsonb_build_object(
                       'currency',   x.currency,
                       'owed_to_me', x.owed_to_me,
                       'i_owe',      x.i_owe,
                       'open_count', x.n) order by x.currency)
              from (select r2.currency,
                           coalesce(sum(r2.balance) filter (where r2.balance > 0), 0)::bigint  as owed_to_me,
                           coalesce(-sum(r2.balance) filter (where r2.balance < 0), 0)::bigint as i_owe,
                           count(*)::int as n
                      from r r2
                     where r2.closed_at is null
                     group by r2.currency) x), '[]'::jsonb)
      into v_debts, v_totals
      from r;

    return jsonb_build_object(
        'version', 1,
        'today',   v_today,
        'debts',   v_debts,
        'totals',  v_totals);
end;
$$;

revoke all on function public.debts_summary() from public, anon;
grant execute on function public.debts_summary() to authenticated, service_role;

comment on function public.debts_summary() is
    'All debts of the caller with server-computed balances (minor units, account currency). Single jsonb (ADR-003). Migration 20261128090001.';
