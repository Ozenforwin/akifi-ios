-- Assets: anything the user owns that has monetary value but isn't
-- tracked as a liquid account balance (real estate, vehicles, crypto
-- stashes outside exchange accounts, collectibles, investments).
-- Current value is user-maintained; no mark-to-market automation.
CREATE TABLE IF NOT EXISTS assets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE DEFAULT auth.uid(),
    name TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN (
        'real_estate', 'vehicle', 'crypto', 'investment', 'collectible', 'cash', 'other'
    )),
    current_value BIGINT NOT NULL,
    currency TEXT NOT NULL,
    icon TEXT,
    color TEXT,
    notes TEXT,
    acquired_date DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_assets_user ON assets(user_id);

ALTER TABLE assets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "assets_own_select" ON assets;
DROP POLICY IF EXISTS "assets_own_insert" ON assets;
DROP POLICY IF EXISTS "assets_own_update" ON assets;
DROP POLICY IF EXISTS "assets_own_delete" ON assets;

CREATE POLICY "assets_own_select" ON assets FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "assets_own_insert" ON assets FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "assets_own_update" ON assets FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "assets_own_delete" ON assets FOR DELETE USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION set_assets_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_assets_updated_at ON assets;
CREATE TRIGGER trg_assets_updated_at
    BEFORE UPDATE ON assets FOR EACH ROW
    EXECUTE FUNCTION set_assets_updated_at();
