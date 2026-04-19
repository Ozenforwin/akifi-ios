-- Savings Challenges
-- Gamified micro-goals linked (optionally) to a SavingsGoal.
-- Four types: no_cafe, round_up, weekly_amount, category_limit.

CREATE TABLE IF NOT EXISTS savings_challenges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE DEFAULT auth.uid(),

    type TEXT NOT NULL
        CHECK (type IN ('no_cafe', 'round_up', 'weekly_amount', 'category_limit')),
    title TEXT NOT NULL,
    description TEXT,

    -- Kopecks / minor units (nullable; only needed for some types).
    target_amount BIGINT,

    duration_days INTEGER NOT NULL CHECK (duration_days > 0 AND duration_days <= 730),
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,

    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'completed', 'abandoned')),

    -- Running progress in minor units. Semantics depend on challenge type:
    --   no_cafe        — accumulated violating expenses (lower is better, 0 = perfect)
    --   round_up       — accumulated round-up savings
    --   weekly_amount  — accumulated goal contributions during period
    --   category_limit — accumulated expenses in the tracked category
    progress_amount BIGINT NOT NULL DEFAULT 0,

    -- Optional links
    category_id UUID REFERENCES categories(id) ON DELETE SET NULL,
    linked_goal_id UUID REFERENCES savings_goals(id) ON DELETE SET NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- RLS
ALTER TABLE savings_challenges ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own challenges"
    ON savings_challenges FOR SELECT
    USING (user_id = auth.uid());

CREATE POLICY "Users can insert own challenges"
    ON savings_challenges FOR INSERT
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own challenges"
    ON savings_challenges FOR UPDATE
    USING (user_id = auth.uid());

CREATE POLICY "Users can delete own challenges"
    ON savings_challenges FOR DELETE
    USING (user_id = auth.uid());

-- Indexes
CREATE INDEX idx_savings_challenges_user_status
    ON savings_challenges(user_id, status);
CREATE INDEX idx_savings_challenges_user_end_date
    ON savings_challenges(user_id, end_date);

-- Auto-updated_at trigger (reuses the schema-level helper if present,
-- otherwise creates a local one).
CREATE OR REPLACE FUNCTION set_savings_challenges_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_savings_challenges_updated_at
    BEFORE UPDATE ON savings_challenges
    FOR EACH ROW
    EXECUTE FUNCTION set_savings_challenges_updated_at();
