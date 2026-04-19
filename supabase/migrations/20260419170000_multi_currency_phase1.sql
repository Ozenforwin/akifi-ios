-- Phase 1 of multi-currency migration (ADR-001).
-- Purely additive. No behavioural change on its own.
-- Backup: schema `backup_20260419` snapshots all mutable tables (2026-04-19).

ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS amount_native    NUMERIC,
  ADD COLUMN IF NOT EXISTS foreign_amount   NUMERIC,
  ADD COLUMN IF NOT EXISTS foreign_currency TEXT,
  ADD COLUMN IF NOT EXISTS fx_rate          NUMERIC(18, 8);

COMMENT ON COLUMN public.transactions.amount_native    IS 'Canonical amount in account.currency (ADR-001). amount_native = foreign_amount * fx_rate when foreign_currency is set.';
COMMENT ON COLUMN public.transactions.foreign_amount   IS 'User-entered amount in foreign_currency. NULL when entry was in account.currency.';
COMMENT ON COLUMN public.transactions.foreign_currency IS 'ISO code of user-entered currency (uppercase). NULL when entry was in account.currency.';
COMMENT ON COLUMN public.transactions.fx_rate          IS 'Frozen rate at entry time: foreign_currency -> account.currency. NULL when no FX.';

-- Naive backfill: treat legacy rows as already-in-account-currency.
-- Reconciliation UI (Phase 4) will let the user audit and correct
-- cross-currency rows manually.
UPDATE public.transactions
SET amount_native = amount
WHERE amount_native IS NULL;

-- Safety invariant for new rows: once backfill is done, amount_native must
-- never be NULL. We add the constraint as NOT VALID first so the migration
-- doesn't re-check every row; we validate in a second statement.
ALTER TABLE public.transactions
  ADD CONSTRAINT transactions_amount_native_not_null
  CHECK (amount_native IS NOT NULL) NOT VALID;

ALTER TABLE public.transactions
  VALIDATE CONSTRAINT transactions_amount_native_not_null;

-- Sanity check — fail migration if counts drifted.
DO $$
DECLARE
  legacy_count BIGINT;
  native_count BIGINT;
BEGIN
  SELECT COUNT(*) INTO legacy_count FROM public.transactions WHERE amount IS NOT NULL;
  SELECT COUNT(*) INTO native_count FROM public.transactions WHERE amount_native IS NOT NULL;
  IF legacy_count != native_count THEN
    RAISE EXCEPTION 'Backfill mismatch: amount=% rows, amount_native=% rows', legacy_count, native_count;
  END IF;
END $$;
