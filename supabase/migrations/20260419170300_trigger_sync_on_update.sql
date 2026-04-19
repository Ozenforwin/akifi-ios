-- Fix Phase 1 trigger: also sync amount_native when a legacy client UPDATEs
-- `amount` but omits `amount_native`. Without this, TMA edits of the amount
-- field leave amount_native stale and balances drift.
--
-- Decision matrix:
--   INSERT:                     fill amount_native if NULL (same as before)
--   UPDATE, client sent both:   leave as-is (iOS Phase 3 path)
--   UPDATE, client sent amount only, NO foreign entry: sync amount_native
--   UPDATE with foreign_amount: never auto-sync (amount_native is decoupled
--                               from amount by design)
CREATE OR REPLACE FUNCTION public.transactions_fill_amount_native()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.amount_native IS NULL THEN
            NEW.amount_native := NEW.amount;
        END IF;
        RETURN NEW;
    END IF;

    -- UPDATE branch
    IF NEW.amount_native IS NULL THEN
        NEW.amount_native := NEW.amount;
    ELSIF NEW.amount <> OLD.amount
          AND NEW.amount_native = OLD.amount_native
          AND NEW.foreign_amount IS NULL THEN
        -- Legacy client changed amount but didn't touch amount_native.
        -- Only safe to auto-sync when this isn't a foreign-entry row.
        NEW.amount_native := NEW.amount;
    END IF;
    RETURN NEW;
END;
$$;
