-- Settlement records for shared accounts. Created when a participant
-- marks a suggested settlement (from SettlementCalculator) as actually
-- paid, optionally linked to a real transfer pair between personal
-- accounts of the two users (linked_transfer_group_id).

CREATE TABLE IF NOT EXISTS settlements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    shared_account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    from_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    to_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    amount BIGINT NOT NULL,
    currency TEXT NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    settled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    settled_by UUID NOT NULL REFERENCES auth.users(id) DEFAULT auth.uid(),
    linked_transfer_group_id UUID,
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_settlements_account_period
    ON settlements(shared_account_id, period_end);

ALTER TABLE settlements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "settlements_members_read" ON settlements;
DROP POLICY IF EXISTS "settlements_members_insert" ON settlements;
DROP POLICY IF EXISTS "settlements_creator_delete" ON settlements;

CREATE POLICY "settlements_members_read" ON settlements FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM account_members m
        WHERE m.account_id = shared_account_id AND m.user_id = auth.uid()
    )
    OR EXISTS (
        SELECT 1 FROM accounts a
        WHERE a.id = shared_account_id AND a.user_id = auth.uid()
    )
);

CREATE POLICY "settlements_members_insert" ON settlements FOR INSERT WITH CHECK (
    settled_by = auth.uid()
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

CREATE POLICY "settlements_creator_delete" ON settlements FOR DELETE USING (settled_by = auth.uid());
