-- Per-member, per-transaction settlement marks for shared accounts.
-- Complements `settlements` (cumulative net-paid records). A row here
-- means: "the share of `transaction_id` that `settled_for_user_id` owed
-- the payer has been resolved off-book — exclude this share from the
-- shared-account imbalance calculation."
--
-- Math contract (see SettlementCalculator):
--   Each non-payer member's share of the txn = amount * weight / sum(weights)
--   When the share is settled, the calculator credits the settled member's
--   `contributed` by their share and debits the original payer by the same.
--   Once every non-payer has settled, the txn's net contribution to the
--   imbalance is zero — same as if the txn had been split evenly off-app.

CREATE TABLE IF NOT EXISTS transaction_member_settlements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    shared_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    settled_for_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    settled_by_user_id UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
    settled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    note TEXT,
    UNIQUE(transaction_id, settled_for_user_id)
);

CREATE INDEX IF NOT EXISTS idx_txn_member_settlements_account
    ON transaction_member_settlements(shared_account_id);

CREATE INDEX IF NOT EXISTS idx_txn_member_settlements_txn
    ON transaction_member_settlements(transaction_id);

ALTER TABLE transaction_member_settlements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "txn_member_settle_read" ON transaction_member_settlements;
DROP POLICY IF EXISTS "txn_member_settle_insert" ON transaction_member_settlements;
DROP POLICY IF EXISTS "txn_member_settle_delete" ON transaction_member_settlements;

-- Any member of the shared account (or its owner) can read marks.
CREATE POLICY "txn_member_settle_read" ON transaction_member_settlements FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM account_members m
        WHERE m.account_id = shared_account_id AND m.user_id = auth.uid()
    )
    OR EXISTS (
        SELECT 1 FROM accounts a
        WHERE a.id = shared_account_id AND a.user_id = auth.uid()
    )
);

-- Members can mark a share as settled — for themselves OR on behalf of
-- another member they share the account with. Insert always records the
-- caller as `settled_by_user_id` for audit.
CREATE POLICY "txn_member_settle_insert" ON transaction_member_settlements FOR INSERT WITH CHECK (
    settled_by_user_id = auth.uid()
    AND (
        EXISTS (
            SELECT 1 FROM account_members m
            WHERE m.account_id = shared_account_id AND m.user_id = auth.uid()
        )
        OR EXISTS (
            SELECT 1 FROM accounts a
            WHERE a.id = shared_account_id AND a.user_id = auth.uid()
        )
    )
);

-- Only the original marker can delete (undo). Avoids a member silently
-- reverting another member's reconciliation.
CREATE POLICY "txn_member_settle_delete" ON transaction_member_settlements FOR DELETE USING (
    settled_by_user_id = auth.uid()
);
