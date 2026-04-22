-- Reconciliation: three remaining user-reported anomalies.
-- User provided the real amounts; historical FX from APILayer fills the
-- rate, amount_native gets recomputed to match.
--
--   2026-04-17 `Энергетик`  was 64 ₫    → actually 25 000 ₫
--              VND→RUB 2026-04-17: 0.002895 → 72.38 ₽
--
--   2023-10-01 `Starbucks · 49 IDR` (1.00 ₽) → actually 490 000 IDR
--              IDR→RUB 2023-10-01: 0.006341 → 3 107.09 ₽
--
--   2023-10-02 `Starbucks · 49 IDR` (1.00 ₽) → actually 490 000 IDR
--              IDR→RUB 2023-10-02: 0.006357 → 3 114.93 ₽
--
-- Description suffix for both Starbucks rows is updated from "49 IDR"
-- to "490000 IDR" so a future audit reader sees the true entry value.

BEGIN;

CREATE SCHEMA IF NOT EXISTS backup_20260422;

CREATE TABLE IF NOT EXISTS backup_20260422.transactions_three_anomalies AS
SELECT * FROM transactions
WHERE id IN (
    'ee712d03-dd9f-4d0d-a517-8f1f142314b1',
    '12cb4012-4828-4b99-b3e6-e4735d43baf3',
    '6ab0bd93-95ca-4cfb-b742-28c574fd93f4'
);

-- Энергетик 25 000 ₫ → 72.38 ₽
UPDATE transactions
SET
    amount           = 72.38,
    amount_native    = 72.38,
    currency         = 'RUB',
    foreign_amount   = 25000,
    foreign_currency = 'VND',
    fx_rate          = 0.002895
WHERE id = 'ee712d03-dd9f-4d0d-a517-8f1f142314b1';

-- Starbucks 2023-10-01: 490 000 IDR → 3 107.09 ₽
UPDATE transactions
SET
    amount           = 3107.09,
    amount_native    = 3107.09,
    currency         = 'RUB',
    foreign_amount   = 490000,
    foreign_currency = 'IDR',
    fx_rate          = 0.006341,
    description      = 'Чек: Starbucks · 490000 IDR'
WHERE id = '12cb4012-4828-4b99-b3e6-e4735d43baf3';

-- Starbucks 2023-10-02: 490 000 IDR → 3 114.93 ₽
UPDATE transactions
SET
    amount           = 3114.93,
    amount_native    = 3114.93,
    currency         = 'RUB',
    foreign_amount   = 490000,
    foreign_currency = 'IDR',
    fx_rate          = 0.006357,
    description      = 'Чек: Starbucks · 490000 IDR'
WHERE id = '6ab0bd93-95ca-4cfb-b742-28c574fd93f4';

COMMIT;
