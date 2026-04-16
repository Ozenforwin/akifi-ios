-- Financial Notes / Journal
CREATE TABLE IF NOT EXISTS financial_notes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    title TEXT,
    content TEXT NOT NULL DEFAULT '',
    transaction_id UUID REFERENCES transactions(id) ON DELETE SET NULL,
    tags TEXT[] DEFAULT '{}',
    mood TEXT CHECK (mood IS NULL OR mood IN ('great','good','neutral','worried','stressed')),
    photo_urls TEXT[] DEFAULT '{}',
    note_type TEXT NOT NULL DEFAULT 'freeform'
        CHECK (note_type IN ('transaction','reflection','freeform')),
    period_start DATE,
    period_end DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE financial_notes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own notes"
    ON financial_notes FOR SELECT
    USING (user_id = auth.uid());

CREATE POLICY "Users can insert own notes"
    ON financial_notes FOR INSERT
    WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own notes"
    ON financial_notes FOR UPDATE
    USING (user_id = auth.uid());

CREATE POLICY "Users can delete own notes"
    ON financial_notes FOR DELETE
    USING (user_id = auth.uid());

CREATE INDEX idx_financial_notes_user_date ON financial_notes(user_id, created_at DESC);
CREATE INDEX idx_financial_notes_transaction ON financial_notes(transaction_id) WHERE transaction_id IS NOT NULL;
CREATE INDEX idx_financial_notes_type ON financial_notes(user_id, note_type);
