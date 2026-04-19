-- Custom split weights per shared-account member.
-- `split_weight` is a relative numeric (not necessarily summing to 1).
-- SettlementCalculator normalizes at compute time:
--   fairShare(M) = totalExpenses * weight(M) / sum(weights for members)
-- Default 1.0 keeps equal-split behavior (MVP) intact for existing rows.
ALTER TABLE account_members
    ADD COLUMN IF NOT EXISTS split_weight NUMERIC(6,3) NOT NULL DEFAULT 1.0
        CHECK (split_weight >= 0);
