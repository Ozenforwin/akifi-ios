-- Auto-transfer triplets: all-or-nothing edits (S7) and idempotent create (Y3).
--
-- An "auto-transfer" is three rows sharing auto_transfer_group_id = G:
--   main expense  type=expense, transfer_group_id IS NULL, on the target account
--   transfer-in   type=income,  transfer_group_id = G,     on the target account
--   transfer-out  type=expense, transfer_group_id = G,     on the payer's card
-- (prod 2026-11-17: 150 complete triplets + 8 legacy pairs whose source
-- account was deleted.)
--
-- S7. update_/delete_expense_with_auto_transfer are SECURITY INVOKER, so RLS
-- silently skips legs the caller cannot write. When a co-editor edits or
-- deletes an expense on «Семейный» that the OTHER member paid from a
-- personal card, the out-leg on that card is left untouched / orphaned and
-- the call still returns success. Now every call counts the rows it
-- touched against the real size of the group (auto_transfer_group_size,
-- SECURITY DEFINER — the caller may not even SEE the other member's leg)
-- and raises 42501 when they differ; the whole call rolls back. The payer
-- can still edit/delete their own triplets; the other member gets an error
-- instead of a half-applied change.
--
-- The legacy 6-arg and 9-arg update overloads wrote the TARGET-currency
-- amount into the source leg (the 92.5x bug on cross-currency triplets).
-- They now delegate to the 11-arg version, which for a cross-currency
-- triplet without an explicit p_source_amount rescales the out-leg by the
-- triplet's own frozen rate (old out / old main) instead of copying p_amount.
-- No overload is dropped. Note: since the 11-arg overload exists, a call with
-- exactly the 6 or 9 legacy keys cannot be resolved (42725 / PGRST203 —
-- identical leading types plus defaults; same for the 8-arg create), so those
-- overloads are effectively unreachable; they are fixed so they stay correct
-- if ever reached. The current iOS client sends 13 keys (create) and 11 keys
-- (update), which resolve uniquely.
--
-- Y3. create_expense_with_auto_transfer gains a 14-arg overload with p_id:
-- the client-generated id of the main expense. An offline-queue retry after a
-- timeout then fails with 23505 (unique_violation) instead of creating a
-- second triplet; the client treats 23505 as "already created". p_id has NO
-- default (and therefore neither have the other params), so PostgREST routes
-- a 13-key body to the 13-arg overload and a 14-key body to this one — no
-- "Could not choose the best candidate function" ambiguity. The 13-arg
-- overload now delegates here with p_id = NULL (same behaviour as before).

-- ── Helper: true size of a group, independent of the caller's RLS ─────────
create or replace function public.auto_transfer_group_size(p_group_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
    -- Answers only callers who can see at least one row of the group.
    select case
        when p_group_id is null then 0
        when not exists (
            select 1 from public.transactions t
             where t.auto_transfer_group_id = p_group_id
               and (t.user_id = auth.uid() or public.is_account_member(t.account_id))
        ) then 0
        else (select count(*)::int from public.transactions t where t.auto_transfer_group_id = p_group_id)
    end;
$$;

revoke all on function public.auto_transfer_group_size(uuid) from public, anon;
grant execute on function public.auto_transfer_group_size(uuid) to authenticated, service_role;


-- ── Y3: create with a client-supplied main-expense id ─────────────────────
create or replace function public.create_expense_with_auto_transfer(
    p_account_id uuid,
    p_category_id uuid,
    p_amount numeric,
    p_currency text,
    p_date timestamp with time zone,
    p_description text,
    p_merchant_name text,
    p_payment_source_account_id uuid,
    p_source_amount numeric,
    p_source_currency text,
    p_foreign_amount numeric,
    p_foreign_currency text,
    p_fx_rate numeric,
    p_id uuid
)
returns uuid
language plpgsql
set search_path = public
as $$
declare
    v_expense_id      uuid := coalesce(p_id, gen_random_uuid());
    v_group_id        uuid;
    v_transfer_desc   text;
    v_source_amount   numeric;
    v_source_currency text;
begin
    if p_payment_source_account_id is null or p_payment_source_account_id = p_account_id then
        insert into public.transactions (
            id, account_id, category_id,
            amount, amount_native, currency,
            foreign_amount, foreign_currency, fx_rate,
            date, description, merchant_name, type, user_id
        ) values (
            v_expense_id, p_account_id, p_category_id,
            p_amount, p_amount, p_currency,
            p_foreign_amount, p_foreign_currency, p_fx_rate,
            p_date, p_description, p_merchant_name, 'expense', auth.uid()
        );
        return v_expense_id;
    end if;

    v_group_id := gen_random_uuid();
    v_transfer_desc := 'Авто-перевод: ' || coalesce(nullif(p_description, ''), 'расход');
    v_source_amount := coalesce(p_source_amount, p_amount);
    v_source_currency := coalesce(p_source_currency, p_currency);

    -- 1. Main expense on the target account.
    insert into public.transactions (
        id, account_id, category_id,
        amount, amount_native, currency,
        foreign_amount, foreign_currency, fx_rate,
        date, description, merchant_name, type,
        payment_source_account_id, auto_transfer_group_id, user_id
    ) values (
        v_expense_id, p_account_id, p_category_id,
        p_amount, p_amount, p_currency,
        p_foreign_amount, p_foreign_currency, p_fx_rate,
        p_date, p_description, p_merchant_name, 'expense',
        p_payment_source_account_id, v_group_id, auth.uid()
    );

    -- 2. Transfer-out on the source account, in the source account's currency.
    insert into public.transactions (
        account_id, amount, amount_native, currency,
        date, description, type,
        transfer_group_id, auto_transfer_group_id, user_id
    ) values (
        p_payment_source_account_id, v_source_amount, v_source_amount, v_source_currency,
        p_date, v_transfer_desc, 'expense',
        v_group_id, v_group_id, auth.uid()
    );

    -- 3. Transfer-in on the target account.
    insert into public.transactions (
        account_id, amount, amount_native, currency,
        date, description, type,
        transfer_group_id, auto_transfer_group_id, user_id
    ) values (
        p_account_id, p_amount, p_amount, p_currency,
        p_date, v_transfer_desc, 'income',
        v_group_id, v_group_id, auth.uid()
    );

    return v_expense_id;
end;
$$;

revoke all on function public.create_expense_with_auto_transfer(
    uuid, uuid, numeric, text, timestamp with time zone, text, text, uuid,
    numeric, text, numeric, text, numeric, uuid) from public, anon;
grant execute on function public.create_expense_with_auto_transfer(
    uuid, uuid, numeric, text, timestamp with time zone, text, text, uuid,
    numeric, text, numeric, text, numeric, uuid) to authenticated, service_role;

comment on function public.create_expense_with_auto_transfer(
    uuid, uuid, numeric, text, timestamp with time zone, text, text, uuid,
    numeric, text, numeric, text, numeric, uuid) is
    'Y3: 13-arg create + p_id (main expense id, client-generated; retry -> 23505). All 14 keys required. Migration 20261117120200.';

-- The 13-arg overload keeps its signature and defaults; it now delegates.
create or replace function public.create_expense_with_auto_transfer(
    p_account_id uuid,
    p_category_id uuid,
    p_amount numeric,
    p_currency text,
    p_date timestamp with time zone,
    p_description text,
    p_merchant_name text,
    p_payment_source_account_id uuid,
    p_source_amount numeric default null::numeric,
    p_source_currency text default null::text,
    p_foreign_amount numeric default null::numeric,
    p_foreign_currency text default null::text,
    p_fx_rate numeric default null::numeric
)
returns uuid
language plpgsql
set search_path = public
as $$
begin
    return public.create_expense_with_auto_transfer(
        p_account_id, p_category_id, p_amount, p_currency, p_date,
        p_description, p_merchant_name, p_payment_source_account_id,
        p_source_amount, p_source_currency,
        p_foreign_amount, p_foreign_currency, p_fx_rate,
        null::uuid);
end;
$$;


-- ── S7: update — canonical 11-arg overload ────────────────────────────────
create or replace function public.update_expense_with_auto_transfer(
    p_expense_id uuid,
    p_amount numeric,
    p_category_id uuid,
    p_date timestamp with time zone,
    p_description text,
    p_merchant_name text,
    p_foreign_amount numeric default null::numeric,
    p_foreign_currency text default null::text,
    p_fx_rate numeric default null::numeric,
    p_source_amount numeric default null::numeric,
    p_source_currency text default null::text
)
returns void
language plpgsql
set search_path = public
as $$
declare
    v_main        public.transactions%rowtype;
    v_group_id    uuid;
    v_group_size  integer;
    v_touched     integer := 0;
    v_n           integer;
    v_desc        text;
    v_main_ccy    text;
    v_out_native  numeric;
    v_out_ccy     text;
    v_out_amount  numeric;
    v_out_label   text;
begin
    select * into v_main from public.transactions where id = p_expense_id;
    if not found then
        raise exception 'Expense % not found', p_expense_id using errcode = 'P0002';
    end if;
    if v_main.transfer_group_id is not null then
        raise exception 'Pass the main expense of the auto-transfer, not a transfer leg'
            using errcode = '22023';
    end if;

    v_group_id := v_main.auto_transfer_group_id;
    -- Count BEFORE touching anything; includes legs the caller cannot see.
    v_group_size := public.auto_transfer_group_size(v_group_id);

    -- Old out-leg (if visible) for the frozen-rate rescale below.
    if v_group_id is not null then
        select t.amount_native, a.currency into v_out_native, v_out_ccy
          from public.transactions t
          left join public.accounts a on a.id = t.account_id
         where t.transfer_group_id = v_group_id and t.id <> p_expense_id and t.type = 'expense'
         limit 1;
        select a.currency into v_main_ccy from public.accounts a where a.id = v_main.account_id;
    end if;

    update public.transactions
       set amount = p_amount,
           amount_native = p_amount,
           foreign_amount = p_foreign_amount,
           foreign_currency = p_foreign_currency,
           fx_rate = p_fx_rate,
           category_id = p_category_id,
           date = p_date,
           description = p_description,
           merchant_name = p_merchant_name
     where id = p_expense_id;
    get diagnostics v_n = row_count;
    if v_n <> 1 then
        raise exception 'Expense % is not editable by you', p_expense_id using errcode = '42501';
    end if;
    v_touched := 1;

    if v_group_id is null then
        return;
    end if;

    v_desc := 'Авто-перевод: ' || coalesce(nullif(p_description, ''), 'расход');

    -- Transfer-in (target account, same currency as the main expense).
    update public.transactions
       set amount = p_amount, amount_native = p_amount, date = p_date, description = v_desc
     where transfer_group_id = v_group_id and id <> p_expense_id and type = 'income';
    get diagnostics v_n = row_count;
    v_touched := v_touched + v_n;

    -- Transfer-out (payer's card, in ITS currency).
    if p_source_amount is not null then
        v_out_amount := p_source_amount;
        v_out_label := p_source_currency;
    elsif v_out_ccy is null or v_main_ccy is null or lower(v_out_ccy) = lower(v_main_ccy) then
        v_out_amount := p_amount;
    elsif v_main.amount_native is not null and v_main.amount_native <> 0 and v_out_native is not null then
        -- Cross-currency and the caller did not send the source amount
        -- (legacy 6-/9-arg path): keep the triplet's frozen rate.
        v_out_amount := round(v_out_native * p_amount / v_main.amount_native, 2);
    else
        raise exception 'Cross-currency auto-transfer needs p_source_amount' using errcode = '22023';
    end if;

    update public.transactions
       set amount = v_out_amount,
           amount_native = v_out_amount,
           currency = coalesce(v_out_label, currency),
           date = p_date,
           description = v_desc
     where transfer_group_id = v_group_id and id <> p_expense_id and type = 'expense';
    get diagnostics v_n = row_count;
    v_touched := v_touched + v_n;

    if v_touched <> v_group_size then
        raise exception 'Auto-transfer % includes rows on an account you cannot edit (% of % writable)',
            v_group_id, v_touched, v_group_size
            using errcode = '42501',
                  hint = 'Only the member who paid (owner of the source card) can edit or delete this expense.';
    end if;
end;
$$;

-- Legacy 9-arg overload → canonical (source amount unknown → frozen-rate rescale).
create or replace function public.update_expense_with_auto_transfer(
    p_expense_id uuid,
    p_amount numeric,
    p_category_id uuid,
    p_date timestamp with time zone,
    p_description text,
    p_merchant_name text,
    p_foreign_amount numeric default null::numeric,
    p_foreign_currency text default null::text,
    p_fx_rate numeric default null::numeric
)
returns void
language plpgsql
set search_path = public
as $$
begin
    perform public.update_expense_with_auto_transfer(
        p_expense_id, p_amount, p_category_id, p_date, p_description, p_merchant_name,
        p_foreign_amount, p_foreign_currency, p_fx_rate,
        null::numeric, null::text);
end;
$$;

-- Legacy 6-arg overload (pre-ADR-001 clients): it never touched foreign_*,
-- so pass the row's current values through unchanged.
create or replace function public.update_expense_with_auto_transfer(
    p_expense_id uuid,
    p_amount numeric,
    p_category_id uuid,
    p_date timestamp with time zone,
    p_description text,
    p_merchant_name text
)
returns void
language plpgsql
set search_path = public
as $$
declare
    v_fa numeric; v_fc text; v_fx numeric;
begin
    select t.foreign_amount, t.foreign_currency, t.fx_rate into v_fa, v_fc, v_fx
      from public.transactions t where t.id = p_expense_id;
    perform public.update_expense_with_auto_transfer(
        p_expense_id, p_amount, p_category_id, p_date, p_description, p_merchant_name,
        v_fa, v_fc, v_fx,
        null::numeric, null::text);
end;
$$;


-- ── S7: delete ────────────────────────────────────────────────────────────
create or replace function public.delete_expense_with_auto_transfer(p_expense_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
    v_group_id   uuid;
    v_group_size integer;
    v_n          integer;
begin
    select auto_transfer_group_id into v_group_id from public.transactions where id = p_expense_id;
    if not found then
        return;  -- already gone: a replayed delete stays a no-op
    end if;

    if v_group_id is null then
        delete from public.transactions where id = p_expense_id;
        get diagnostics v_n = row_count;
        if v_n <> 1 then
            raise exception 'Transaction % is not deletable by you', p_expense_id using errcode = '42501';
        end if;
        return;
    end if;

    v_group_size := public.auto_transfer_group_size(v_group_id);
    delete from public.transactions where auto_transfer_group_id = v_group_id;
    get diagnostics v_n = row_count;
    if v_n <> v_group_size then
        raise exception 'Auto-transfer % includes rows on an account you cannot edit (% of % deletable)',
            v_group_id, v_n, v_group_size
            using errcode = '42501',
                  hint = 'Only the member who paid (owner of the source card) can edit or delete this expense.';
    end if;
end;
$$;

notify pgrst, 'reload schema';
