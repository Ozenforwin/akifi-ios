-- Assertions for 20261117140000 — run only through the dry-run helper (BEGIN … ROLLBACK).
do $$
begin
    -- Month-end clamping from the anchor, not from the previous date.
    if public.subscription_charge_date('2026-01-31', 'monthly', 1) <> '2026-02-28' then raise exception 'ASSERT FAILED: Jan31+1m'; end if;
    if public.subscription_charge_date('2026-01-31', 'monthly', 2) <> '2026-03-31' then raise exception 'ASSERT FAILED: Jan31+2m'; end if;
    if public.subscription_charge_date('2026-01-31', 'monthly', 3) <> '2026-04-30' then raise exception 'ASSERT FAILED: Jan31+3m'; end if;
    if public.subscription_charge_date('2024-01-31', 'monthly', 1) <> '2024-02-29' then raise exception 'ASSERT FAILED: leap Feb'; end if;
    if public.subscription_charge_date('2024-02-29', 'yearly', 1) <> '2025-02-28' then raise exception 'ASSERT FAILED: yearly Feb29'; end if;
    if public.subscription_charge_date('2024-02-29', 'yearly', 4) <> '2028-02-29' then raise exception 'ASSERT FAILED: yearly leap again'; end if;
    if public.subscription_charge_date('2025-11-30', 'quarterly', 1) <> '2026-02-28' then raise exception 'ASSERT FAILED: quarterly from Nov30'; end if;
    if public.subscription_charge_date('2025-11-30', 'quarterly', 2) <> '2026-05-30' then raise exception 'ASSERT FAILED: quarterly k=2'; end if;
    if public.subscription_charge_date('2026-01-01', 'weekly', 3) <> '2026-01-22' then raise exception 'ASSERT FAILED: weekly'; end if;
    if public.subscription_charge_date('2026-01-01', 'custom', 2) <> '2026-03-02' then raise exception 'ASSERT FAILED: custom 30d'; end if;
    -- The old chained bug: Mar 31 after Feb must be back on the 31st.
    if public.calculate_next_subscription_payment('2026-01-31', 'monthly', '2026-03-01') <> '2026-03-31' then raise exception 'ASSERT FAILED: next after Feb'; end if;
    if public.calculate_next_subscription_payment('2026-01-31', 'monthly', '2026-01-31') <> '2026-01-31' then raise exception 'ASSERT FAILED: on the anchor day'; end if;
    if public.add_subscription_period('2026-01-15', 'quarterly') <> '2026-04-15' then raise exception 'ASSERT FAILED: quarterly was +1 month'; end if;
    -- Anchor fallback for legacy rows (start_date = "day it was added").
    if public.subscription_anchor('2026-03-10', '2026-12-05', 'monthly') <> '2026-12-05' then raise exception 'ASSERT FAILED: legacy anchor'; end if;
    if public.subscription_anchor('2026-01-31', '2026-04-30', 'monthly') <> '2026-01-31' then raise exception 'ASSERT FAILED: on-schedule anchor'; end if;
    if public.subscription_anchor(null, '2026-04-30', 'monthly') <> '2026-04-30' then raise exception 'ASSERT FAILED: null start'; end if;
end $$;

-- Every active prod subscription keeps its current next_payment_date as a
-- charge date of its own schedule (nothing would move if recomputed today).
do $$
declare v_bad integer;
begin
    select count(*) into v_bad
      from public.subscriptions s
     where s.is_active and s.next_payment_date is not null
       and public.subscription_first_charge_on_or_after(
               public.subscription_anchor(s.start_date, s.next_payment_date, s.billing_period),
               s.billing_period, s.next_payment_date) <> s.next_payment_date;
    if v_bad > 0 then raise exception 'ASSERT FAILED: % active subscriptions would move', v_bad; end if;
end $$;

select 'subscription schedule assertions passed' as result;
