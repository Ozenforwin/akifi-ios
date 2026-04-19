-- Lot-based contribution history для точного time-weighted accrual.
-- Каждое пополнение — отдельная строка с собственной start_date.
-- InterestCalculator считает accrued sum per lot, не на aggregate principal,
-- что исключает занижение процентов при многократных пополнениях.
--
-- cross-currency поля (source_currency, source_amount, fx_rate) фиксируют
-- курс на момент пополнения, чтобы ретроактивная FX-коррекция не требовала
-- пересчёта истории.
CREATE TABLE IF NOT EXISTS deposit_contributions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    deposit_id UUID NOT NULL REFERENCES deposits(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE DEFAULT auth.uid(),

    amount BIGINT NOT NULL CHECK (amount > 0),
    contributed_at DATE NOT NULL,

    source_account_id UUID REFERENCES accounts(id) ON DELETE SET NULL,
    source_currency TEXT,
    source_amount BIGINT,
    fx_rate NUMERIC(18,8),

    transfer_group_id UUID,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_deposit_contributions_deposit ON deposit_contributions(deposit_id, contributed_at);
CREATE INDEX IF NOT EXISTS idx_deposit_contributions_user ON deposit_contributions(user_id);

ALTER TABLE deposit_contributions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "contrib_own_select" ON deposit_contributions;
DROP POLICY IF EXISTS "contrib_own_insert" ON deposit_contributions;
DROP POLICY IF EXISTS "contrib_own_delete" ON deposit_contributions;

CREATE POLICY "contrib_own_select" ON deposit_contributions FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "contrib_own_insert" ON deposit_contributions FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "contrib_own_delete" ON deposit_contributions FOR DELETE USING (user_id = auth.uid());
