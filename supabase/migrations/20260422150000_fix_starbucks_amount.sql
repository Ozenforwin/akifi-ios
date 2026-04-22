-- User correction: the two Starbucks receipts from October 2023 were
-- 49 000 IDR each (not 490 000 — typo in the previous reconciliation
-- round `20260422140000`). Same historical IDR→RUB rates, just one
-- zero off on the foreign amount.
--
--   2023-10-01: 49 000 IDR @ 0.006341 → 310.71 ₽
--   2023-10-02: 49 000 IDR @ 0.006357 → 311.49 ₽

BEGIN;

-- Append to the existing backup table (idempotent — skips duplicates).
INSERT INTO backup_20260422.transactions_three_anomalies
SELECT * FROM transactions
WHERE id IN (
    '12cb4012-4828-4b99-b3e6-e4735d43baf3',
    '6ab0bd93-95ca-4cfb-b742-28c574fd93f4'
)
AND NOT EXISTS (
    SELECT 1 FROM backup_20260422.transactions_three_anomalies b
    WHERE b.id = transactions.id
      AND b.amount = 3107.09  -- the wrong-by-10x snapshot we just wrote
);

UPDATE transactions
SET
    amount           = 310.71,
    amount_native    = 310.71,
    currency         = 'RUB',
    foreign_amount   = 49000,
    foreign_currency = 'IDR',
    fx_rate          = 0.006341,
    description      = 'Чек: Starbucks · 49000 IDR'
WHERE id = '12cb4012-4828-4b99-b3e6-e4735d43baf3';

UPDATE transactions
SET
    amount           = 311.49,
    amount_native    = 311.49,
    currency         = 'RUB',
    foreign_amount   = 49000,
    foreign_currency = 'IDR',
    fx_rate          = 0.006357,
    description      = 'Чек: Starbucks · 49000 IDR'
WHERE id = '6ab0bd93-95ca-4cfb-b742-28c574fd93f4';

COMMIT;
