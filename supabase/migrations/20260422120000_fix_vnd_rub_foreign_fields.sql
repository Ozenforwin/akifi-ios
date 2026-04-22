-- Reconciliation: VND-on-RUB transactions written without foreign_* fields
-- Root cause: legacy TMA write-path left `amount_native` in the entered foreign
-- value (VND nominal) and `currency = 'VND'` on rows whose account is in RUB,
-- violating ADR-001 invariant "amount_native is in account.currency". iOS
-- `Transaction.init(from:)` then decodes `76000.00` into `7_600_000` kopecks
-- and displays it as ₽76 000 on a RUB account → the "Транспорт 307 317 ₽"
-- screenshot bug.
--
-- Strategy:
--   1. Snapshot affected rows into `backup_20260422` schema (keep ≥ 3 months).
--   2. For rows in an auto-transfer group: take the true RUB amount from the
--      paired transfer-out leg on a RUB source account (bit-exact — that leg
--      was written correctly by the same TMA flow).
--   3. For orphan rows: fall back to a hardcoded 1 VND = 0.00290 RUB (close
--      to the 2026-04-17…20 band; precise recomputation is deferred to
--      the Phase 6 Reconciliation UI with historical rates).
--
-- Scope: only `tx.currency = 'VND'` on `account.currency = 'RUB'` and
-- `foreign_amount IS NULL`. Other legacy cross-currency combos (RUB-on-USD
-- for ByBit, etc.) are out of scope — they need their own dedicated fix
-- per `project_multi_currency_plan.md`.

BEGIN;

CREATE SCHEMA IF NOT EXISTS backup_20260422;

CREATE TABLE IF NOT EXISTS backup_20260422.transactions_vnd_rub_fix AS
SELECT t.*
FROM transactions t
JOIN accounts a ON a.id = t.account_id
WHERE UPPER(t.currency) = 'VND'
  AND UPPER(a.currency) = 'RUB'
  AND t.foreign_amount IS NULL;

-- Phase A: rows in an auto-transfer group — use the paired RUB leg's amount.
WITH pair_rates AS (
    SELECT
        broken.id                   AS broken_id,
        broken.amount               AS vnd_amount,
        (
            SELECT p.amount
            FROM transactions p
            JOIN accounts pa ON pa.id = p.account_id
            WHERE p.auto_transfer_group_id = broken.auto_transfer_group_id
              AND p.account_id <> broken.account_id
              AND UPPER(pa.currency) = 'RUB'
              AND p.transfer_group_id IS NOT NULL
            LIMIT 1
        )                           AS rub_amount
    FROM transactions broken
    JOIN accounts a ON a.id = broken.account_id
    WHERE UPPER(broken.currency) = 'VND'
      AND UPPER(a.currency) = 'RUB'
      AND broken.foreign_amount IS NULL
      AND broken.auto_transfer_group_id IS NOT NULL
)
UPDATE transactions AS t
SET
    foreign_amount   = pr.vnd_amount,
    foreign_currency = 'VND',
    fx_rate          = pr.rub_amount / NULLIF(pr.vnd_amount, 0),
    amount           = pr.rub_amount,
    amount_native    = pr.rub_amount,
    currency         = 'RUB'
FROM pair_rates pr
WHERE t.id = pr.broken_id
  AND pr.rub_amount IS NOT NULL;

-- Phase B: orphan rows without an auto-transfer group — approximate via a
-- band-of-the-period rate. A user with the Reconciliation UI (Phase 6) can
-- tighten per-row using an actual historical quote.
UPDATE transactions AS t
SET
    foreign_amount   = t.amount,
    foreign_currency = 'VND',
    fx_rate          = 0.00290,
    amount           = t.amount * 0.00290,
    amount_native    = t.amount * 0.00290,
    currency         = 'RUB'
FROM accounts a
WHERE a.id = t.account_id
  AND UPPER(t.currency) = 'VND'
  AND UPPER(a.currency) = 'RUB'
  AND t.foreign_amount IS NULL;

COMMIT;
