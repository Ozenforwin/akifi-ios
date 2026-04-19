-- Account classification. Checking = default для всех существующих, deposits
-- и investments отличаются только account_type — transfer-механика одинаковая.
ALTER TABLE accounts
    ADD COLUMN IF NOT EXISTS account_type TEXT NOT NULL DEFAULT 'checking'
        CHECK (account_type IN ('checking', 'savings', 'cash', 'deposit', 'investment'));

CREATE INDEX IF NOT EXISTS idx_accounts_user_type ON accounts(user_id, account_type);
