-- Deposits: financial instrument with fixed interest rate, term, and
-- auto-accrual. 1:1 с Account (каждый депозит живёт на своём account_type=
-- 'deposit' счёте — transfer-механика и Net Worth работают из коробки).
-- `early_close_penalty_rate` оставлен на будущее (MVP всегда 0).
-- `rate` immutable после создания — если условия изменились, юзер создаёт
-- новый депозит, старый закрывается досрочно.
CREATE TABLE IF NOT EXISTS deposits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    account_id UUID NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,

    interest_rate NUMERIC(6,3) NOT NULL CHECK (interest_rate >= 0),
    compound_frequency TEXT NOT NULL DEFAULT 'monthly'
        CHECK (compound_frequency IN ('daily', 'monthly', 'quarterly', 'yearly', 'simple')),
    start_date DATE NOT NULL,
    end_date DATE,
    early_close_penalty_rate NUMERIC(6,3) NOT NULL DEFAULT 0 CHECK (early_close_penalty_rate >= 0),

    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'matured', 'closed_early')),
    closed_at TIMESTAMPTZ,
    return_to_account_id UUID REFERENCES accounts(id) ON DELETE SET NULL,

    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_deposits_user_status ON deposits(user_id, status);

ALTER TABLE deposits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "deposits_own_select" ON deposits;
DROP POLICY IF EXISTS "deposits_own_insert" ON deposits;
DROP POLICY IF EXISTS "deposits_own_update" ON deposits;
DROP POLICY IF EXISTS "deposits_own_delete" ON deposits;

CREATE POLICY "deposits_own_select" ON deposits FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "deposits_own_insert" ON deposits FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "deposits_own_update" ON deposits FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "deposits_own_delete" ON deposits FOR DELETE USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION set_deposits_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_deposits_updated_at ON deposits;
CREATE TRIGGER trg_deposits_updated_at
    BEFORE UPDATE ON deposits FOR EACH ROW
    EXECUTE FUNCTION set_deposits_updated_at();
