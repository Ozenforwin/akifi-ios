-- Net worth snapshots: point-in-time captures of
-- net_worth = sum(account balances) + sum(asset values) - sum(liabilities)
-- stored in the user's base currency. Snapshots are taken once per day
-- (UNIQUE on user + date) and drive the history chart.
CREATE TABLE IF NOT EXISTS net_worth_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    snapshot_date DATE NOT NULL,
    accounts_total BIGINT NOT NULL,
    assets_total BIGINT NOT NULL,
    liabilities_total BIGINT NOT NULL,
    net_worth BIGINT NOT NULL,
    currency TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, snapshot_date)
);

CREATE INDEX IF NOT EXISTS idx_net_worth_snapshots_user_date
    ON net_worth_snapshots(user_id, snapshot_date DESC);

ALTER TABLE net_worth_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "snapshots_own_select" ON net_worth_snapshots;
DROP POLICY IF EXISTS "snapshots_own_insert" ON net_worth_snapshots;
DROP POLICY IF EXISTS "snapshots_own_update" ON net_worth_snapshots;
DROP POLICY IF EXISTS "snapshots_own_delete" ON net_worth_snapshots;

CREATE POLICY "snapshots_own_select" ON net_worth_snapshots FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "snapshots_own_insert" ON net_worth_snapshots FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "snapshots_own_update" ON net_worth_snapshots FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "snapshots_own_delete" ON net_worth_snapshots FOR DELETE USING (user_id = auth.uid());
