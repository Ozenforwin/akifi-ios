-- Budget creation from iOS was dead for "all categories" budgets:
-- `budgets.category_ids` is NOT NULL, the client sends `[]` when no
-- categories are picked, and `normalize_budget_before_save` collapsed that
-- empty array into NULL (`array_agg` over an empty `unnest` yields NULL) —
-- every such INSERT died with 23502 and the form looked like it did nothing.
--
-- Fix: after dedup, coalesce category_ids back to '{}'. Also coalesce an
-- incoming NULL to '{}' so legacy clients that drop the key survive too.
-- Empty array semantics are already "no category filter" everywhere
-- (BudgetMath, TMA).

create or replace function public.normalize_budget_before_save()
returns trigger
language plpgsql
as $$
begin
  -- Deduplicate category_ids; empty/NULL -> '{}' (NOT NULL column,
  -- empty means "all categories")
  new.category_ids := coalesce(
    (select array_agg(distinct v) from unnest(coalesce(new.category_ids, '{}')) v),
    '{}'
  );
  -- Deduplicate account_ids, empty array -> null
  if new.account_ids is not null then
    new.account_ids := (select array_agg(distinct v) from unnest(new.account_ids) v);
    if array_length(new.account_ids, 1) is null or array_length(new.account_ids, 1) = 0 then
      new.account_ids := null;
    end if;
  end if;
  -- Always bump updated_at
  new.updated_at := now();
  return new;
end;
$$;
