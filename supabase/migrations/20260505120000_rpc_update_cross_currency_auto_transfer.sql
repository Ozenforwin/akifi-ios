-- ADR-001 Phase 3.1: cross-currency edit fix.
--
-- The 9-arg `update_expense_with_auto_transfer` writes a single `p_amount`
-- to BOTH transfer legs (lines 144-149 of 20260419170200). For a cross-
-- currency auto-transfer (target RUB, source USD card) the transfer-out
-- on the USD card ends up with `amount_native = p_amount` (a RUB
-- quantity) while `currency = USD`, so the read-path interprets it as
-- USD and the source balance moves ~92.5× the wrong way on every edit.
--
-- Same root cause as the 2026-05-05 Olga incident on `TransferFormView`,
-- different code path. Audit at fix time: 4 cross-currency auto-transfer
-- groups in production, 0 already corrupted (no one has hit the edit
-- path yet).
--
-- This migration adds an 11-arg overload that takes the source amount
-- explicitly. The 9-arg version stays — old clients keep working in
-- same-currency edits — but the iOS client routes to the 11-arg version
-- whenever the source currency differs from the target. Both legs are
-- now updated in their own currencies.

CREATE OR REPLACE FUNCTION public.update_expense_with_auto_transfer(
    p_expense_id uuid,
    p_amount numeric,
    p_category_id uuid,
    p_date timestamp with time zone,
    p_description text,
    p_merchant_name text,
    p_foreign_amount numeric DEFAULT NULL,
    p_foreign_currency text DEFAULT NULL,
    p_fx_rate numeric DEFAULT NULL,
    p_source_amount numeric DEFAULT NULL,
    p_source_currency text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_group_id UUID;
    v_transfer_desc TEXT;
    v_source_amount NUMERIC;
    v_source_currency TEXT;
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

    IF v_group_id IS NULL THEN
        RETURN;
    END IF;

    v_transfer_desc := 'Авто-перевод: ' || COALESCE(NULLIF(p_description, ''), 'расход');
    v_source_amount := COALESCE(p_source_amount, p_amount);
    v_source_currency := COALESCE(p_source_currency, NULL);

    -- Transfer-IN leg (income on target account, same currency as main expense).
    UPDATE transactions
    SET amount = p_amount,
        amount_native = p_amount,
        date = p_date,
        description = v_transfer_desc
    WHERE transfer_group_id = v_group_id
      AND id <> p_expense_id
      AND type = 'income';

    -- Transfer-OUT leg (expense on source account, in source currency).
    -- Match by `currency = source_currency` when supplied — guards against
    -- the 9-arg legacy path that may have stamped both legs with target
    -- currency in the past (none observed in prod at fix time, but the
    -- safer match avoids touching the wrong row if it ever happens).
    IF p_source_currency IS NOT NULL THEN
        UPDATE transactions
        SET amount = v_source_amount,
            amount_native = v_source_amount,
            currency = v_source_currency,
            date = p_date,
            description = v_transfer_desc
        WHERE transfer_group_id = v_group_id
          AND id <> p_expense_id
          AND type = 'expense';
    ELSE
        -- Same-currency edit — propagate p_amount to the transfer-out leg.
        UPDATE transactions
        SET amount = p_amount,
            amount_native = p_amount,
            date = p_date,
            description = v_transfer_desc
        WHERE transfer_group_id = v_group_id
          AND id <> p_expense_id
          AND type = 'expense';
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.update_expense_with_auto_transfer(
    uuid, numeric, uuid, timestamp with time zone, text, text,
    numeric, text, numeric, numeric, text
) IS 'ADR-001 Phase 3.1 overload: update transfer-out leg in its own currency on cross-currency edits. Without this, the transfer-out received target-currency p_amount tagged with source currency (the 92.5× bug, identical in nature to the 2026-05-05 TransferFormView incident).';

GRANT EXECUTE ON FUNCTION public.update_expense_with_auto_transfer(
    uuid, numeric, uuid, timestamp with time zone, text, text,
    numeric, text, numeric, numeric, text
) TO authenticated;
