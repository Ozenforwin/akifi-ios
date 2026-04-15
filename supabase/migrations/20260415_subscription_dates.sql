-- Migration: Subscription charge dates + payment history
-- Date: 2026-04-15
-- Feature: charge dates in subscriptions, per-subscription payment log
-- See: PRD feature-subscription-dates, ADR-004-subscription-date-engine
--
-- Safe to run multiple times (IF NOT EXISTS guards).

-- 1) Add nullable last_payment_date to subscriptions ------------------------
ALTER TABLE public.subscriptions
    ADD COLUMN IF NOT EXISTS last_payment_date TIMESTAMPTZ NULL;

COMMENT ON COLUMN public.subscriptions.last_payment_date
    IS 'Most recent actual charge date. NULL means unknown (legacy row).';

-- 2) Create subscription_payments ------------------------------------------
CREATE TABLE IF NOT EXISTS public.subscription_payments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subscription_id UUID NOT NULL
        REFERENCES public.subscriptions(id) ON DELETE CASCADE,
    amount          NUMERIC(18,2) NOT NULL CHECK (amount >= 0),
    currency        TEXT NOT NULL DEFAULT 'RUB',
    payment_date    TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_subscription_payments_subscription_id
    ON public.subscription_payments(subscription_id);

CREATE INDEX IF NOT EXISTS idx_subscription_payments_payment_date
    ON public.subscription_payments(payment_date DESC);

COMMENT ON TABLE public.subscription_payments
    IS 'Append-only log of payments recorded against a subscription.';

-- 3) RLS -------------------------------------------------------------------
ALTER TABLE public.subscription_payments ENABLE ROW LEVEL SECURITY;

-- Users may SELECT payments for subscriptions they own.
DROP POLICY IF EXISTS "subscription_payments_select_own"
    ON public.subscription_payments;
CREATE POLICY "subscription_payments_select_own"
    ON public.subscription_payments
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.subscriptions s
            WHERE s.id = subscription_payments.subscription_id
              AND s.user_id = auth.uid()
        )
    );

-- Users may INSERT payments only for their own subscriptions.
DROP POLICY IF EXISTS "subscription_payments_insert_own"
    ON public.subscription_payments;
CREATE POLICY "subscription_payments_insert_own"
    ON public.subscription_payments
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.subscriptions s
            WHERE s.id = subscription_payments.subscription_id
              AND s.user_id = auth.uid()
        )
    );

-- Users may UPDATE their own payment rows.
DROP POLICY IF EXISTS "subscription_payments_update_own"
    ON public.subscription_payments;
CREATE POLICY "subscription_payments_update_own"
    ON public.subscription_payments
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM public.subscriptions s
            WHERE s.id = subscription_payments.subscription_id
              AND s.user_id = auth.uid()
        )
    );

-- Users may DELETE their own payment rows.
DROP POLICY IF EXISTS "subscription_payments_delete_own"
    ON public.subscription_payments;
CREATE POLICY "subscription_payments_delete_own"
    ON public.subscription_payments
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM public.subscriptions s
            WHERE s.id = subscription_payments.subscription_id
              AND s.user_id = auth.uid()
        )
    );
