-- Atomic RPC functions for the payment-source feature.
-- Used by iOS TransactionRepository instead of raw INSERT/UPDATE/DELETE
-- so that the expense row and its auto-transfer pair (when present)
-- stay in sync.

-- Create: expense with optional auto-transfer pair. Returns the expense row id.
CREATE OR REPLACE FUNCTION create_expense_with_auto_transfer(
    p_account_id UUID,
    p_category_id UUID,
    p_amount NUMERIC,
    p_currency TEXT,
    p_date TIMESTAMPTZ,
    p_description TEXT,
    p_merchant_name TEXT,
    p_payment_source_account_id UUID
) RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_expense_id UUID;
    v_group_id UUID;
    v_transfer_desc TEXT;
BEGIN
    IF p_payment_source_account_id IS NULL OR p_payment_source_account_id = p_account_id THEN
        INSERT INTO transactions(account_id, category_id, amount, currency, date, description, merchant_name, type, user_id)
        VALUES (p_account_id, p_category_id, p_amount, p_currency, p_date, p_description, p_merchant_name, 'expense', auth.uid())
        RETURNING id INTO v_expense_id;
        RETURN v_expense_id;
    END IF;

    v_group_id := gen_random_uuid();
    v_transfer_desc := 'Авто-перевод: ' || COALESCE(NULLIF(p_description, ''), 'расход');

    -- 1. The main expense on target account.
    INSERT INTO transactions(account_id, category_id, amount, currency, date, description, merchant_name, type,
                             payment_source_account_id, auto_transfer_group_id, user_id)
    VALUES (p_account_id, p_category_id, p_amount, p_currency, p_date, p_description, p_merchant_name, 'expense',
            p_payment_source_account_id, v_group_id, auth.uid())
    RETURNING id INTO v_expense_id;

    -- 2. Transfer-out on source account (debits source).
    INSERT INTO transactions(account_id, amount, currency, date, description, type, transfer_group_id, auto_transfer_group_id, user_id)
    VALUES (p_payment_source_account_id, p_amount, p_currency, p_date, v_transfer_desc, 'expense', v_group_id, v_group_id, auth.uid());

    -- 3. Transfer-in on target account (credits target).
    INSERT INTO transactions(account_id, amount, currency, date, description, type, transfer_group_id, auto_transfer_group_id, user_id)
    VALUES (p_account_id, p_amount, p_currency, p_date, v_transfer_desc, 'income', v_group_id, v_group_id, auth.uid());

    RETURN v_expense_id;
END;
$$;

-- Delete: expense + its auto-transfer pair atomically.
CREATE OR REPLACE FUNCTION delete_expense_with_auto_transfer(p_expense_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_group_id UUID;
BEGIN
    SELECT auto_transfer_group_id INTO v_group_id FROM transactions WHERE id = p_expense_id;

    IF v_group_id IS NOT NULL THEN
        DELETE FROM transactions WHERE auto_transfer_group_id = v_group_id;
    ELSE
        DELETE FROM transactions WHERE id = p_expense_id;
    END IF;
END;
$$;

-- Update: expense + sync auto-transfer pair (amount/date/description).
-- Category + merchant apply only to the expense, not to the transfer legs.
CREATE OR REPLACE FUNCTION update_expense_with_auto_transfer(
    p_expense_id UUID,
    p_amount NUMERIC,
    p_category_id UUID,
    p_date TIMESTAMPTZ,
    p_description TEXT,
    p_merchant_name TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_group_id UUID;
    v_transfer_desc TEXT;
BEGIN
    UPDATE transactions
    SET amount = p_amount,
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
            date = p_date,
            description = v_transfer_desc
        WHERE transfer_group_id = v_group_id AND id <> p_expense_id;
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION create_expense_with_auto_transfer(UUID, UUID, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION delete_expense_with_auto_transfer(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION update_expense_with_auto_transfer(UUID, NUMERIC, UUID, TIMESTAMPTZ, TEXT, TEXT) TO authenticated;
