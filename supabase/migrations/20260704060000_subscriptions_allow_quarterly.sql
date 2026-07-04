-- The iOS subscription form has offered a "quarterly" billing period since
-- the tracker shipped, but the CHECK constraint only allowed
-- weekly/monthly/yearly — every quarterly INSERT/UPDATE died with 23514 and
-- the client swallowed the error, so the subscription silently never saved.
--
-- Widen the constraint to match the client's BillingPeriod enum. 'custom'
-- exists in the Swift enum but no UI creates it yet, so it stays excluded
-- until a real writer appears.

ALTER TABLE public.subscriptions
    DROP CONSTRAINT subscriptions_billing_period_check;

ALTER TABLE public.subscriptions
    ADD CONSTRAINT subscriptions_billing_period_check
    CHECK (billing_period = ANY (ARRAY['weekly'::text, 'monthly'::text, 'quarterly'::text, 'yearly'::text]));
