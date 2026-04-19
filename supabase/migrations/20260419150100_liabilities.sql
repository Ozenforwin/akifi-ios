-- Liabilities: debts (mortgages, loans, credit-card revolving balances,
-- miscellaneous debts). `current_balance` is the remaining principal as
-- of today; `original_amount` and `interest_rate` are optional metadata
-- for the UI to show amortization context.
CREATE TABLE IF NOT EXISTS liabilities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    name TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN (
        'mortgage', 'loan', 'credit_card', 'personal_debt', 'other'
    )),
    current_balance BIGINT NOT NULL,
    original_amount BIGINT,
    interest_rate NUMERIC(5,3),
    currency TEXT NOT NULL,
    icon TEXT,
    color TEXT,
    notes TEXT,
    monthly_payment BIGINT,
    end_date DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_liabilities_user ON liabilities(user_id);

ALTER TABLE liabilities ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "liabilities_own_select" ON liabilities;
DROP POLICY IF EXISTS "liabilities_own_insert" ON liabilities;
DROP POLICY IF EXISTS "liabilities_own_update" ON liabilities;
DROP POLICY IF EXISTS "liabilities_own_delete" ON liabilities;

CREATE POLICY "liabilities_own_select" ON liabilities FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "liabilities_own_insert" ON liabilities FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "liabilities_own_update" ON liabilities FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "liabilities_own_delete" ON liabilities FOR DELETE USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION set_liabilities_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_liabilities_updated_at ON liabilities;
CREATE TRIGGER trg_liabilities_updated_at
    BEFORE UPDATE ON liabilities FOR EACH ROW
    EXECUTE FUNCTION set_liabilities_updated_at();
