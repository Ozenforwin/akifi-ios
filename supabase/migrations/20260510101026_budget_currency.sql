-- Per-budget currency. NULL on legacy rows = "treat as user's base currency"
-- (the historical implicit behaviour). New budgets set this explicitly so a
-- user can have a USD travel budget alongside a RUB groceries budget.
ALTER TABLE public.budgets
  ADD COLUMN IF NOT EXISTS currency TEXT;

COMMENT ON COLUMN public.budgets.currency IS 'ISO 4217 code (uppercase) the budget.amount is denominated in. NULL = base currency (legacy).';
