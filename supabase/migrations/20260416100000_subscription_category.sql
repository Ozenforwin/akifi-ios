-- Add category_id to subscriptions for budget integration
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS category_id UUID REFERENCES categories(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_subscriptions_category ON subscriptions(category_id) WHERE category_id IS NOT NULL;
