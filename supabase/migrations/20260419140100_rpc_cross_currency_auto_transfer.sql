-- Extend create_expense_with_auto_transfer with optional cross-currency
-- params. When p_source_amount + p_source_currency are supplied, the
-- transfer-out leg on the source account uses them instead of the target
-- amount/currency. Expense + transfer-in legs still use the target amount.
--
-- Callers that don't care (same-currency source) continue to pass NULL
-- for both and get the original same-currency behavior.
--
-- Creates a second overload alongside the original 8-arg version; PostgREST
-- routes by argument-name set in the JSON body.
CREATE OR REPLACE FUNCTION create_expense_with_auto_transfer(
    p_account_id UUID,
    p_category_id UUID,
    p_amount NUMERIC,
    p_currency TEXT,
    p_date TIMESTAMPTZ,
    p_description TEXT,
    p_merchant_name TEXT,
    p_payment_source_account_id UUID,
    p_source_amount NUMERIC DEFAULT NULL,
    p_source_currency TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_expense_id UUID;
    v_group_id UUID;
    v_transfer_desc TEXT;
    v_source_amount NUMERIC;
    v_source_currency TEXT;
BEGIN
    IF p_payment_source_account_id IS NULL OR p_payment_source_account_id = p_account_id THEN
        INSERT INTO transactions(account_id, category_id, amount, currency, date, description, merchant_name, type, user_id)
        VALUES (p_account_id, p_category_id, p_amount, p_currency, p_date, p_description, p_merchant_name, 'expense', auth.uid())
        RETURNING id INTO v_expense_id;
        RETURN v_expense_id;
    END IF;

    v_group_id := gen_random_uuid();
    v_transfer_desc := 'Авто-перевод: ' || COALESCE(NULLIF(p_description, ''), 'расход');

    v_source_amount := COALESCE(p_source_amount, p_amount);
    v_source_currency := COALESCE(p_source_currency, p_currency);

    INSERT INTO transactions(account_id, category_id, amount, currency, date, description, merchant_name, type,
                             payment_source_account_id, auto_transfer_group_id, user_id)
    VALUES (p_account_id, p_category_id, p_amount, p_currency, p_date, p_description, p_merchant_name, 'expense',
            p_payment_source_account_id, v_group_id, auth.uid())
    RETURNING id INTO v_expense_id;

    INSERT INTO transactions(account_id, amount, currency, date, description, type, transfer_group_id, auto_transfer_group_id, user_id)
    VALUES (p_payment_source_account_id, v_source_amount, v_source_currency, p_date, v_transfer_desc, 'expense', v_group_id, v_group_id, auth.uid());

    INSERT INTO transactions(account_id, amount, currency, date, description, type, transfer_group_id, auto_transfer_group_id, user_id)
    VALUES (p_account_id, p_amount, p_currency, p_date, v_transfer_desc, 'income', v_group_id, v_group_id, auth.uid());

    RETURN v_expense_id;
END;
$$;

GRANT EXECUTE ON FUNCTION create_expense_with_auto_transfer(UUID, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, TEXT, UUID, NUMERIC, TEXT) TO authenticated;
