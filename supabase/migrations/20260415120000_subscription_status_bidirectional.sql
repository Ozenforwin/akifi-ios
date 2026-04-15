-- Migration: Bidirectional sync between `status` and `is_active`
-- Date: 2026-04-15
-- Hotfix: v1.2.1 clients (still on prod because v1.2.2 was skipped in App Store
-- release) use `UPDATE subscriptions SET is_active=false` as soft-delete.
-- The previous v1.2.3 trigger (20260415090000_subscription_status.sql) synced
-- only one direction (status -> is_active), which re-derived is_active=true
-- from the unchanged status='active', silently ignoring the delete.
--
-- This migration makes the sync bidirectional:
--   * UPDATE changes `status`           -> derive is_active (status authoritative)
--   * UPDATE changes only `is_active`   -> derive status from is_active (legacy path)
--   * UPDATE changes both               -> status wins (new clients know best)
--   * INSERT with status                -> derive is_active
--   * INSERT with only is_active=false  -> derive status='cancelled'
--
-- Same function name as in 20260415090000 so the existing trigger
-- trg_subscriptions_sync_is_active picks up the new body automatically.
-- See: ADR-005-subscription-status-and-matcher

CREATE OR REPLACE FUNCTION public.subscriptions_sync_is_active()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS NOT NULL AND NEW.status <> 'active' THEN
            NEW.is_active := (NEW.status = 'active');
        ELSIF NEW.is_active IS FALSE THEN
            NEW.status := 'cancelled';
        ELSE
            NEW.is_active := (COALESCE(NEW.status, 'active') = 'active');
            NEW.status    := COALESCE(NEW.status, 'active');
        END IF;
        RETURN NEW;
    END IF;

    -- UPDATE
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        -- status changed (v1.2.3+ client) -- authoritative
        NEW.is_active := (NEW.status = 'active');
    ELSIF NEW.is_active IS DISTINCT FROM OLD.is_active THEN
        -- only is_active changed (v1.2.1 legacy client) -- derive status
        NEW.status := CASE WHEN NEW.is_active THEN 'active' ELSE 'cancelled' END;
    END IF;
    RETURN NEW;
END;
$$;
