-- Migration: Subscription status enum (active / paused / cancelled)
-- Date: 2026-04-15
-- Feature: subscription lifecycle states; supersedes boolean `is_active`.
-- See: ADR-005-subscription-status-and-matcher
--
-- Safe to run multiple times (IF NOT EXISTS guards). Backward compatible:
-- column `is_active` is NOT dropped so that v1.2.2 clients keep working.

-- 1) Add status column ------------------------------------------------------
ALTER TABLE public.subscriptions
    ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active';

-- Drop any prior CHECK constraint (idempotent re-run).
ALTER TABLE public.subscriptions
    DROP CONSTRAINT IF EXISTS subscriptions_status_check;

ALTER TABLE public.subscriptions
    ADD CONSTRAINT subscriptions_status_check
    CHECK (status IN ('active', 'paused', 'cancelled'));

COMMENT ON COLUMN public.subscriptions.status
    IS 'Lifecycle state: active | paused | cancelled. Supersedes is_active.';

-- 2) Backfill from is_active (only for rows still at default 'active') ------
UPDATE public.subscriptions
   SET status = CASE WHEN is_active THEN 'active' ELSE 'cancelled' END
 WHERE status = 'active'
   AND is_active = FALSE;

-- 3) Index for list queries filtered by status -----------------------------
CREATE INDEX IF NOT EXISTS idx_subscriptions_user_status
    ON public.subscriptions(user_id, status);

-- 4) Keep `is_active` in sync via trigger so legacy v1.2.2 clients keep
--    working (they filter by is_active=true).
CREATE OR REPLACE FUNCTION public.subscriptions_sync_is_active()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.is_active := (NEW.status = 'active');
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_subscriptions_sync_is_active ON public.subscriptions;
CREATE TRIGGER trg_subscriptions_sync_is_active
    BEFORE INSERT OR UPDATE OF status, is_active ON public.subscriptions
    FOR EACH ROW
    EXECUTE FUNCTION public.subscriptions_sync_is_active();
