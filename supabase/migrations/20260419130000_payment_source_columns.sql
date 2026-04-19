-- Payment source on transactions: lets a user record that they paid for
-- a shared-account expense from a different (usually personal) account.
-- When payment_source_account_id differs from account_id, the expense
-- is created together with an auto-transfer pair (source → target)
-- linked via auto_transfer_group_id.

ALTER TABLE transactions
    ADD COLUMN IF NOT EXISTS payment_source_account_id UUID REFERENCES accounts(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS auto_transfer_group_id UUID;

CREATE INDEX IF NOT EXISTS idx_transactions_auto_transfer_group
    ON transactions(auto_transfer_group_id)
    WHERE auto_transfer_group_id IS NOT NULL;
