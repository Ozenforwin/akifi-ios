-- ADR-001 Phase 3: extend auto-transfer RPCs with foreign-currency params.
-- Main expense row receives the user's original entry values
-- (foreign_amount / foreign_currency / fx_rate). Transfer legs do not carry
-- foreign fields — they're system-generated and always in their leg's
-- native currency.
--
-- This migration OVERLOADS the existing signatures; the 8-arg / 10-arg
-- versions are not dropped, so older clients keep working during rollout.

CREATE OR REPLACE FUNCTION public.create_expense_with_auto_transfer(
    p_account_id uuid,
    p_category_id uuid,
    p_amount numeric,
    p_currency text,
    p_date timestamp with time zone,
    p_description text,
    p_merchant_name text,
    p_payment_source_account_id uuid,
    p_source_amount numeric DEFAULT NULL,
    p_source_currency text DEFAULT NULL,
    p_foreign_amount numeric DEFAULT NULL,
    p_foreign_currency text DEFAULT NULL,
    p_fx_rate numeric DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
AS $function$
DECLARE
    v_expense_id UUID;
    v_group_id UUID;
    v_transfer_desc TEXT;
    v_source_amount NUMERIC;
    v_source_currency TEXT;
BEGIN
    IF p_payment_source_account_id IS NULL OR p_payment_source_account_id = p_account_id THEN
        INSERT INTO transactions(
            account_id, category_id,
            amount, amount_native, currency,
            foreign_amount, foreign_currency, fx_rate,
            date, description, merchant_name, type, user_id
        )
        VALUES (
            p_account_id, p_category_id,
            p_amount, p_amount, p_currency,
            p_foreign_amount, p_foreign_currency, p_fx_rate,
            p_date, p_description, p_merchant_name, 'expense', auth.uid()
        )
        RETURNING id INTO v_expense_id;
        RETURN v_expense_id;
    END IF;

    v_group_id := gen_random_uuid();
    v_transfer_desc := 'Авто-перевод: ' || COALESCE(NULLIF(p_description, ''), 'расход');

    -- Same-currency fallback if cross-currency params weren't provided.
    v_source_amount := COALESCE(p_source_amount, p_amount);
    v_source_currency := COALESCE(p_source_currency, p_currency);

    -- 1. The main expense on target account (carries foreign_* fields).
    INSERT INTO transactions(
        account_id, category_id,
        amount, amount_native, currency,
        foreign_amount, foreign_currency, fx_rate,
        date, description, merchant_name, type,
        payment_source_account_id, auto_transfer_group_id, user_id
    )
    VALUES (
        p_account_id, p_category_id,
        p_amount, p_amount, p_currency,
        p_foreign_amount, p_foreign_currency, p_fx_rate,
        p_date, p_description, p_merchant_name, 'expense',
        p_payment_source_account_id, v_group_id, auth.uid()
    )
    RETURNING id INTO v_expense_id;

    -- 2. Transfer-out on source account (in source's own currency). No
    --    foreign fields — it's a system-generated leg.
    INSERT INTO transactions(
        account_id, amount, amount_native, currency,
        date, description, type,
        transfer_group_id, auto_transfer_group_id, user_id
    )
    VALUES (
        p_payment_source_account_id, v_source_amount, v_source_amount, v_source_currency,
        p_date, v_transfer_desc, 'expense',
        v_group_id, v_group_id, auth.uid()
    );

    -- 3. Transfer-in on target account (in target currency). No foreign fields.
    INSERT INTO transactions(
        account_id, amount, amount_native, currency,
        date, description, type,
        transfer_group_id, auto_transfer_group_id, user_id
    )
    VALUES (
        p_account_id, p_amount, p_amount, p_currency,
        p_date, v_transfer_desc, 'income',
        v_group_id, v_group_id, auth.uid()
    );

    RETURN v_expense_id;
END;
$function$;

COMMENT ON FUNCTION public.create_expense_with_auto_transfer(
    uuid, uuid, numeric, text, timestamp with time zone, text, text, uuid, numeric, text, numeric, text, numeric
) IS 'ADR-001 Phase 3 overload: adds foreign_amount / foreign_currency / fx_rate for multi-currency entry on the main expense row.';


-- Update RPC mirror: also accept optional foreign_* so edits stay consistent.
CREATE OR REPLACE FUNCTION public.update_expense_with_auto_transfer(
    p_expense_id uuid,
    p_amount numeric,
    p_category_id uuid,
    p_date timestamp with time zone,
    p_description text,
    p_merchant_name text,
    p_foreign_amount numeric DEFAULT NULL,
    p_foreign_currency text DEFAULT NULL,
    p_fx_rate numeric DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_group_id UUID;
    v_transfer_desc TEXT;
BEGIN
    UPDATE transactions
    SET amount = p_amount,
        amount_native = p_amount,
        foreign_amount = p_foreign_amount,
        foreign_currency = p_foreign_currency,
        fx_rate = p_fx_rate,
        category_id = p_category_id,
        date = p_date,
        description = p_description,
        merchant_name = p_merchant_name
    WHERE id = p_expense_id
    RETURNING auto_transfer_group_id INTO v_group_id;

    IF v_group_id IS NOT NULL THEN
        v_transfer_desc := 'Авто-перевод: ' || COALESCE(NULLIF(p_description, ''), 'расход');
        UPDATE transactions
        SET amount = p_amount,
            amount_native = p_amount,
            date = p_date,
            description = v_transfer_desc
        WHERE transfer_group_id = v_group_id AND id <> p_expense_id;
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.update_expense_with_auto_transfer(
    uuid, numeric, uuid, timestamp with time zone, text, text, numeric, text, numeric
) IS 'ADR-001 Phase 3 overload: syncs foreign_* fields on the main expense when the user edits a cross-currency auto-transfer entry.';
