-- Per-user default payment source for each target account.
-- When creating a transaction with account_id = <target>, the client
-- looks up user_account_defaults(auth.uid(), target) and pre-selects
-- default_source_id in the "Оплачено с" picker. If unset, defaults
-- to the target account itself (= regular expense, no auto-transfer).

CREATE TABLE IF NOT EXISTS user_account_defaults (
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    default_source_id UUID REFERENCES accounts(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, account_id)
);

ALTER TABLE user_account_defaults ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_account_defaults_own_select" ON user_account_defaults;
DROP POLICY IF EXISTS "user_account_defaults_own_insert" ON user_account_defaults;
DROP POLICY IF EXISTS "user_account_defaults_own_update" ON user_account_defaults;
DROP POLICY IF EXISTS "user_account_defaults_own_delete" ON user_account_defaults;

CREATE POLICY "user_account_defaults_own_select" ON user_account_defaults
    FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "user_account_defaults_own_insert" ON user_account_defaults
    FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "user_account_defaults_own_update" ON user_account_defaults
    FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "user_account_defaults_own_delete" ON user_account_defaults
    FOR DELETE USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION set_user_account_defaults_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_user_account_defaults_updated_at ON user_account_defaults;
CREATE TRIGGER trg_user_account_defaults_updated_at
    BEFORE UPDATE ON user_account_defaults
    FOR EACH ROW
    EXECUTE FUNCTION set_user_account_defaults_updated_at();
