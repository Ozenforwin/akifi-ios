-- Backward-compat trigger for amount_native.
-- Legacy clients (and every iOS build < multi_currency_v2) do not set
-- `amount_native` on INSERT. The Phase 1 NOT NULL check would reject those
-- rows, so we auto-fill the column to `amount` when it's absent.
CREATE OR REPLACE FUNCTION public.transactions_fill_amount_native()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.amount_native IS NULL THEN
    NEW.amount_native := NEW.amount;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_transactions_fill_amount_native ON public.transactions;
CREATE TRIGGER trg_transactions_fill_amount_native
BEFORE INSERT OR UPDATE ON public.transactions
FOR EACH ROW
EXECUTE FUNCTION public.transactions_fill_amount_native();

COMMENT ON FUNCTION public.transactions_fill_amount_native() IS
  'Phase 1 compat: auto-fill amount_native = amount when client omits it. Remove once all clients write both columns explicitly.';
