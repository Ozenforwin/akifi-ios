-- Review 2026-11-27, N4: a subscription whose start_date is not on its own
-- billing schedule is anchored on next_payment_date; with a 29–31 anchor the
-- first short month clamps it (31.01 → 28.02) and the 28th then sticks for
-- good. check-subscriptions now persists such an anchor as start_date while
-- it is still the real billing day; this applies the same to existing rows
-- (backed up first). Anchors on days 1–28 can't be clamped and are left alone.
create schema if not exists backup_20261127;
create table if not exists backup_20261127.subscriptions_anchor as
    select s.*, now() as backed_up_at from public.subscriptions s where false;
insert into backup_20261127.subscriptions_anchor
select s.*, now() from public.subscriptions s
 where public.subscription_anchor(s.start_date, s.next_payment_date, s.billing_period) = s.next_payment_date
   and s.start_date is distinct from s.next_payment_date
   and extract(day from s.next_payment_date) >= 29;
update public.subscriptions s
   set start_date = s.next_payment_date
 where public.subscription_anchor(s.start_date, s.next_payment_date, s.billing_period) = s.next_payment_date
   and s.start_date is distinct from s.next_payment_date
   and extract(day from s.next_payment_date) >= 29;
