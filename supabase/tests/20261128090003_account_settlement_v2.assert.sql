-- Assertions for 20261128090003_account_settlement_v2.sql (dry run, rolled back).
-- Needs 20261128090000 and 20261128090002 applied first.
--
-- Part 1 — parity: a verbatim copy of v1 (20261117090000) is created as a
-- temporary function; for EVERY account with two or more members on this
-- database, v2 must return exactly v1's fields (personal_share / personal_debts
-- aside) as long as no personal marks exist — i.e. old clients see the same
-- numbers. Runs before any fixture row is written.
-- Part 2 — numbers on a fresh shared account S (A owner, B editor, weights
-- 1:1) built inside the transaction from two existing users read at runtime:
--   E1 shared 100.00 paid by A from A's card          -> split 50/50 (v1 behaviour)
--   E2 B's personal 30.00 paid by B from B's card     -> nets to zero for B
--   E3 B's personal 40.00 paid by A from A's card     -> B owes A the full 40.00
--   E4 B's personal 25.00 from S's own money          -> B owes S 25.00
--   R1 B repays 10.00 (card B -> S, leg marked B)     -> B owes S 15.00
--   R2 B repays 20.00 more                            -> owed clamps at 0, raw kept
-- SAFETY: writes test rows and impersonates users — dry run only:
--   db_dryrun.py <(echo "select set_config('akifi.dry_run','on',true);") \
--     20261128090000_debt_accounts.sql 20261128090002_transactions_personal_debt.sql \
--     20261128090003_account_settlement_v2.sql <this file>
do $$
begin
    if coalesce(current_setting('akifi.dry_run', true), '') <> 'on' then
        raise exception 'Assertion file: run only via the dry-run helper with akifi.dry_run=on (BEGIN … ROLLBACK).';
    end if;
end $$;

-- v1, verbatim from 20261117090000 (only the name/schema and SECURITY
-- DEFINER differ: the dry run is the DB owner already).
create function pg_temp.account_settlement_v1(p_account_id uuid)
returns jsonb
language plpgsql
stable
set search_path = public
as $v1$
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
$v1$;

-- v2 reduced to v1's keys (drops version, personal_debts, balances[].personal_share).
create function pg_temp.settlement_as_v1(p jsonb)
returns jsonb
language sql
immutable
as $f$
    select (p - 'version' - 'personal_debts')
           || jsonb_build_object('balances',
                  coalesce((select jsonb_agg(b - 'personal_share' order by o)
                              from jsonb_array_elements(p->'balances') with ordinality e(b, o)), '[]'::jsonb));
$f$;

-- ── Part 1: v2 == v1 on every real shared account (no marks exist yet) ───
do $$
declare
    r     record;
    v1    jsonb;
    v2    jsonb;
    v_n   int := 0;
begin
    if exists (select 1 from transactions where personal_debt_user_id is not null) then
        raise notice 'personal marks already exist: parity is checked on unmarked accounts only';
    end if;
    for r in
        select a.id, a.user_id
          from accounts a
         where (select count(*) from account_members m where m.account_id = a.id) > 1
           and not exists (select 1 from transactions t
                            where t.account_id = a.id and t.personal_debt_user_id is not null)
         order by a.id
    loop
        perform set_config('request.jwt.claims', json_build_object('sub', r.user_id, 'role', 'authenticated')::text, true),
                set_config('request.jwt.claim.sub', r.user_id::text, true),
                set_config('request.jwt.claim.role', 'authenticated', true);
        v1 := pg_temp.account_settlement_v1(r.id);
        v2 := public.get_account_settlement(r.id);
        if (v2->>'version')::int <> 2 then
            raise exception 'ASSERT FAILED: version % on %', v2->>'version', r.id;
        end if;
        if pg_temp.settlement_as_v1(v2) <> (v1 - 'version') then
            raise exception 'ASSERT FAILED: v2 differs from v1 on account %: v1=% v2=%', r.id, v1, v2;
        end if;
        if exists (select 1 from jsonb_array_elements(v2->'personal_debts') d
                    where (d->>'owed')::bigint <> 0 or (d->>'expenses')::bigint <> 0 or (d->>'repaid')::bigint <> 0) then
            raise exception 'ASSERT FAILED: personal_debts not zero on unmarked account %: %', r.id, v2->'personal_debts';
        end if;
        if exists (select 1 from jsonb_array_elements(v2->'balances') b where (b->>'personal_share')::bigint <> 0) then
            raise exception 'ASSERT FAILED: personal_share not zero on unmarked account %', r.id;
        end if;
        v_n := v_n + 1;
    end loop;
    raise notice 'settlement v1/v2 parity checked on % shared accounts', v_n;
end $$;

-- ── Part 2 setup (DB owner, no JWT) ───────────────────────────────────────
do $$
declare
    v_u uuid[];
begin
    perform set_config('request.jwt.claims', '{}', true),
            set_config('request.jwt.claim.sub', '', true),
            set_config('request.jwt.claim.role', '', true);
    select array_agg(x.id order by x.created_at, x.id) into v_u
      from (select u.id, u.created_at from auth.users u join profiles p on p.id = u.id
             order by u.created_at, u.id limit 2) x;
    if coalesce(cardinality(v_u), 0) < 2 then
        raise exception 'ASSERT FAILED: fixture missing (need 2 users with profiles)';
    end if;
    perform set_config('test.a', v_u[1]::text, true), set_config('test.b', v_u[2]::text, true),
            set_config('test.s',  gen_random_uuid()::text, true),
            set_config('test.ca', gen_random_uuid()::text, true),
            set_config('test.cb', gen_random_uuid()::text, true);
    insert into accounts (id, user_id, name, icon, color, initial_balance, currency)
    values (current_setting('test.s')::uuid,  v_u[1], 'akifi-test shared', 'person.2.fill',  '#3B82F6', 0, 'rub'),
           (current_setting('test.ca')::uuid, v_u[1], 'akifi-test card A', 'creditcard.fill', '#3B82F6', 0, 'rub'),
           (current_setting('test.cb')::uuid, v_u[2], 'akifi-test card B', 'creditcard.fill', '#3B82F6', 0, 'rub');
    insert into account_members (account_id, user_id, role)
    values (current_setting('test.s')::uuid, v_u[2], 'editor');
end $$;

-- ── Part 2 (DB owner connection, client JWTs: RPCs write as the author) ──
do $$
declare
    v_a  uuid := current_setting('test.a')::uuid;
    v_b  uuid := current_setting('test.b')::uuid;
    v_s  uuid := current_setting('test.s')::uuid;
    v_ca uuid := current_setting('test.ca')::uuid;
    v_cb uuid := current_setting('test.cb')::uuid;
    v_e1 uuid; v_e2 uuid; v_e3 uuid; v_g uuid;
    v1   jsonb;
    v2   jsonb;
    v_pd jsonb;

    -- helpers (inline): delta / fair / contributed / personal_share of a user in v2
begin
    -- E1: shared, A pays from A's card.
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true),
            set_config('request.jwt.claim.sub', v_a::text, true),
            set_config('request.jwt.claim.role', 'authenticated', true);
    v_e1 := public.create_expense_with_auto_transfer(
        v_s, null, 100, 'RUB', now(), 'akifi-test E1', null, v_ca,
        null, null, null, null, null, gen_random_uuid(), null);

    -- (e) old fields unchanged for non-personal rows.
    v1 := pg_temp.account_settlement_v1(v_s);
    v2 := public.get_account_settlement(v_s);
    if pg_temp.settlement_as_v1(v2) <> (v1 - 'version') then
        raise exception 'ASSERT FAILED: (e) v2 <> v1 without marks: v1=% v2=%', v1, v2;
    end if;
    if (select (b->>'contributed')::bigint - (b->>'fair_share')::bigint
          from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_a::text) <> 5000
       or (select (b->>'contributed')::bigint - (b->>'fair_share')::bigint
             from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_b::text) <> -5000 then
        raise exception 'ASSERT FAILED: (e) E1 split %', v2->'balances';
    end if;

    -- E2 (a): B's personal expense paid from B's own card -> no effect on B's delta.
    perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true),
            set_config('request.jwt.claim.sub', v_b::text, true);
    v_e2 := public.create_expense_with_auto_transfer(
        v_s, null, 30, 'RUB', now(), 'akifi-test E2', null, v_cb,
        null, null, null, null, null, gen_random_uuid(), v_b);
    v2 := public.get_account_settlement(v_s);
    if (select (b->>'contributed')::bigint - (b->>'fair_share')::bigint
          from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_b::text) <> -5000
       or (select (b->>'fair_share')::bigint from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_b::text) <> 8000
       or (select (b->>'personal_share')::bigint from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_b::text) <> 3000
       or (select (b->>'contributed')::bigint from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_b::text) <> 3000 then
        raise exception 'ASSERT FAILED: (a) personal via own card %', v2->'balances';
    end if;

    -- E3 (b): B's personal expense paid by A from A's card -> B owes A the full 40.00.
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true),
            set_config('request.jwt.claim.sub', v_a::text, true);
    v_e3 := public.create_expense_with_auto_transfer(
        v_s, null, 40, 'RUB', now(), 'akifi-test E3', null, v_ca,
        null, null, null, null, null, gen_random_uuid(), v_b);
    v1 := pg_temp.account_settlement_v1(v_s);
    v2 := public.get_account_settlement(v_s);
    if (select (b->>'contributed')::bigint - (b->>'fair_share')::bigint
          from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_a::text) <> 9000
       or (select (b->>'contributed')::bigint - (b->>'fair_share')::bigint
             from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_b::text) <> -9000 then
        raise exception 'ASSERT FAILED: (b) personal via partner card %', v2->'balances';
    end if;
    if (v2->>'total_expenses')::bigint <> 17000 or (v2->>'tx_count')::int <> 3
       or (select sum((b->>'fair_share')::bigint) from jsonb_array_elements(v2->'balances') b) <> 17000 then
        raise exception 'ASSERT FAILED: totals / Σ fair_share %', v2;
    end if;
    -- Contributions, payers and totals keep v1's meaning; only fair shares move.
    if (v2->'payers') <> (v1->'payers') or (v2->'total_expenses') <> (v1->'total_expenses')
       or (v2->'tx_count') <> (v1->'tx_count')
       or (select jsonb_agg(b->'contributed' order by b->>'user_id') from jsonb_array_elements(v2->'balances') b)
          <> (select jsonb_agg(b->'contributed' order by b->>'user_id') from jsonb_array_elements(v1->'balances') b) then
        raise exception 'ASSERT FAILED: v1 fields moved: v1=% v2=%', v1, v2;
    end if;
    if v2->'payers'->>v_e3::text is distinct from v_a::text or v2->'payers'->>v_e2::text is distinct from v_b::text then
        raise exception 'ASSERT FAILED: payers %', v2->'payers';
    end if;

    -- E4 (c): B's personal expense from S's own money -> B owes S; balances unchanged.
    perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true),
            set_config('request.jwt.claim.sub', v_b::text, true);
    insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, personal_debt_user_id)
    values (v_b, v_s, 25, 25, 'RUB', 'expense', now(), v_b);
    v2 := public.get_account_settlement(v_s);
    select d into v_pd from jsonb_array_elements(v2->'personal_debts') d where d->>'user_id' = v_b::text;
    if (v_pd->>'owed')::bigint <> 2500 or (v_pd->>'expenses')::bigint <> 2500
       or (v_pd->>'repaid')::bigint <> 0 or (v_pd->>'is_member')::boolean is not true then
        raise exception 'ASSERT FAILED: (c) personal debt to the account %', v_pd;
    end if;
    if (select (d->>'owed')::bigint from jsonb_array_elements(v2->'personal_debts') d where d->>'user_id' = v_a::text) <> 0
       or jsonb_array_length(v2->'personal_debts') <> 2 then
        raise exception 'ASSERT FAILED: (c) personal_debts entries %', v2->'personal_debts';
    end if;
    if (select (b->>'contributed')::bigint - (b->>'fair_share')::bigint
          from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_b::text) <> -9000 then
        raise exception 'ASSERT FAILED: (c) a direct expense moved the balances %', v2->'balances';
    end if;

    -- R1 (d): partial repayment card B -> S.
    v_g := gen_random_uuid();
    insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id)
    values (v_b, v_cb, 10, 10, 'RUB', 'expense', now(), v_g);
    insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id, personal_debt_user_id)
    values (v_b, v_s, 10, 10, 'RUB', 'income', now(), v_g, v_b);
    v2 := public.get_account_settlement(v_s);
    select d into v_pd from jsonb_array_elements(v2->'personal_debts') d where d->>'user_id' = v_b::text;
    if (v_pd->>'owed')::bigint <> 1500 or (v_pd->>'expenses')::bigint <> 2500 or (v_pd->>'repaid')::bigint <> 1000 then
        raise exception 'ASSERT FAILED: (d) partial repayment %', v_pd;
    end if;
    if (select (b->>'contributed')::bigint - (b->>'fair_share')::bigint
          from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_b::text) <> -9000 then
        raise exception 'ASSERT FAILED: (d) a repayment moved the balances %', v2->'balances';
    end if;

    -- R2: over-repayment clamps owed at 0, raw numbers stay.
    v_g := gen_random_uuid();
    insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id)
    values (v_b, v_cb, 20, 20, 'RUB', 'expense', now(), v_g);
    insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, transfer_group_id, personal_debt_user_id)
    values (v_b, v_s, 20, 20, 'RUB', 'income', now(), v_g, v_b);
    v2 := public.get_account_settlement(v_s);
    select d into v_pd from jsonb_array_elements(v2->'personal_debts') d where d->>'user_id' = v_b::text;
    if (v_pd->>'owed')::bigint <> 0 or (v_pd->>'expenses')::bigint <> 2500 or (v_pd->>'repaid')::bigint <> 3000 then
        raise exception 'ASSERT FAILED: over-repayment %', v_pd;
    end if;

    -- Per-transaction marks on personal expenses: B's share of E3 is all of it;
    -- a mark for A on E2 (B's personal, B paid) is a no-op.
    insert into transaction_member_settlements (transaction_id, shared_account_id, settled_for_user_id, settled_by_user_id)
    values (v_e3, v_s, v_b, v_a), (v_e2, v_s, v_a, v_a);
    v2 := public.get_account_settlement(v_s);
    if (select (b->>'contributed')::bigint - (b->>'fair_share')::bigint
          from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_b::text) <> -5000
       or (select (b->>'contributed')::bigint - (b->>'fair_share')::bigint
             from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_a::text) <> 5000 then
        raise exception 'ASSERT FAILED: marks on personal expenses %', v2->'balances';
    end if;
    delete from transaction_member_settlements where transaction_id in (v_e2, v_e3);

    -- Unmarking E3 restores the v1 split for it (shared again).
    update transactions set personal_debt_user_id = null where id = v_e3;
    v1 := pg_temp.account_settlement_v1(v_s);
    v2 := public.get_account_settlement(v_s);
    if (select (b->>'fair_share')::bigint from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_a::text) <> 7000
       or (select (b->>'fair_share')::bigint from jsonb_array_elements(v2->'balances') b where b->>'user_id' = v_b::text) <> 10000 then
        raise exception 'ASSERT FAILED: unmarked E3 not split %', v2->'balances';
    end if;

    -- A member who left: their marks fall back to the weight split and their
    -- debt to the account is still reported (is_member = false).
    perform set_config('request.jwt.claims', '{}', true),
            set_config('request.jwt.claim.sub', '', true),
            set_config('request.jwt.claim.role', '', true);
    -- (re-mark E4-style debt first so the former member has a non-zero entry)
    insert into transactions (user_id, account_id, amount, amount_native, currency, type, date, personal_debt_user_id)
    values (v_b, v_s, 12, 12, 'RUB', 'expense', now(), v_b);
    delete from account_members where account_id = v_s and user_id = v_b;
    perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true),
            set_config('request.jwt.claim.sub', v_a::text, true),
            set_config('request.jwt.claim.role', 'authenticated', true);
    v2 := public.get_account_settlement(v_s);
    if jsonb_array_length(v2->'balances') <> 1
       or (v2->'balances'->0->>'fair_share')::bigint <> (v2->>'total_expenses')::bigint
       or (v2->'balances'->0->>'personal_share')::bigint <> 0 then
        raise exception 'ASSERT FAILED: former member marks not folded into the split %', v2->'balances';
    end if;
    select d into v_pd from jsonb_array_elements(v2->'personal_debts') d where d->>'user_id' = v_b::text;
    if v_pd is null or (v_pd->>'is_member')::boolean is not false or (v_pd->>'expenses')::bigint <> 3700 then
        raise exception 'ASSERT FAILED: former member personal debt %', v2->'personal_debts';
    end if;
end $$;

select 'settlement v2: all assertions passed' as result;
