-- fx_rates — one server-side FX table so every number the server computes
-- (budget metrics, pushes) converts currencies the same way for everyone.
--
-- Convention matches the iOS client's `CurrencyManager.rates` (open.er-api
-- latest/USD): per_usd[X] = units of X per 1 USD, so
--     amount_in_Y = amount_in_X / per_usd[X] * per_usd[Y]
-- exactly like `NetWorthCalculator.convert`. A missing code means "no
-- conversion" (1:1) on both sides — the same fail-safe contract, so the
-- server and the offline client fallback agree.
--
-- Writers: only the `refresh-fx-rates` edge function (service role, hourly
-- pg_cron, see 20261117130004). Readers: any signed-in user (rates are
-- public market data); anon gets nothing.
--
-- The seed below is a fallback snapshot (open.er-api.com, 2026-11-16) so the
-- table is never empty before the first refresh. `on conflict do nothing`
-- keeps fresher rows if the migration is re-applied.

create table if not exists public.fx_rates (
    code       text        primary key,
    per_usd    numeric     not null,
    updated_at timestamptz not null default now(),
    constraint fx_rates_code_format check (code ~ '^[A-Z]{3}$'),
    constraint fx_rates_positive    check (per_usd > 0)
);

comment on table public.fx_rates is
    'Units of <code> per 1 USD (USD pivot, same as the iOS client rates). Written by the refresh-fx-rates edge function only.';

alter table public.fx_rates enable row level security;

drop policy if exists "Signed-in users read fx rates" on public.fx_rates;
create policy "Signed-in users read fx rates" on public.fx_rates
    for select to authenticated
    using (true);

-- No insert/update/delete policies: the service role bypasses RLS, nobody
-- else may write. Belt and braces on the table grants as well.
revoke all on table public.fx_rates from anon;
revoke insert, update, delete, truncate on table public.fx_rates from authenticated;
grant select on table public.fx_rates to authenticated;
grant all on table public.fx_rates to service_role;

insert into public.fx_rates (code, per_usd, updated_at) values
    ('USD', 1,            '2026-11-16 00:02:31+00'),
    ('RUB', 82.5688,      '2026-11-16 00:02:31+00'),
    ('EUR', 0.906623,     '2026-11-16 00:02:31+00'),
    ('GBP', 0.756564,     '2026-11-16 00:02:31+00'),
    ('CNY', 6.678399,     '2026-11-16 00:02:31+00'),
    ('JPY', 159.784314,   '2026-11-16 00:02:31+00'),
    ('VND', 25715.743135, '2026-11-16 00:02:31+00'),
    ('THB', 33.895948,    '2026-11-16 00:02:31+00'),
    ('IDR', 18221.875738, '2026-11-16 00:02:31+00'),
    ('KZT', 445.556053,   '2026-11-16 00:02:31+00'),
    ('TRY', 50.370257,    '2026-11-16 00:02:31+00'),
    ('AED', 3.6725,       '2026-11-16 00:02:31+00'),
    ('GEL', 2.593504,     '2026-11-16 00:02:31+00'),
    ('CZK', 22.131377,    '2026-11-16 00:02:31+00'),
    ('RSD', 106.527313,   '2026-11-16 00:02:31+00'),
    ('AMD', 360.41034,    '2026-11-16 00:02:31+00'),
    ('UAH', 45.438593,    '2026-11-16 00:02:31+00'),
    ('BYN', 3.000174,     '2026-11-16 00:02:31+00'),
    ('KGS', 87.482046,    '2026-11-16 00:02:31+00'),
    ('UZS', 11918.862499, '2026-11-16 00:02:31+00'),
    ('INR', 94.399626,    '2026-11-16 00:02:31+00'),
    ('CHF', 0.839107,     '2026-11-16 00:02:31+00'),
    ('PLN', 3.995861,     '2026-11-16 00:02:31+00'),
    ('KRW', 1335.9116,    '2026-11-16 00:02:31+00'),
    ('MYR', 4.087603,     '2026-11-16 00:02:31+00'),
    ('SGD', 1.287631,     '2026-11-16 00:02:31+00'),
    ('PHP', 63.910763,    '2026-11-16 00:02:31+00'),
    ('HKD', 7.845516,     '2026-11-16 00:02:31+00'),
    ('CAD', 1.426617,     '2026-11-16 00:02:31+00'),
    ('AUD', 1.475643,     '2026-11-16 00:02:31+00'),
    ('ILS', 3.210966,     '2026-11-16 00:02:31+00'),
    ('BRL', 5.663557,     '2026-11-16 00:02:31+00'),
    ('MXN', 18.544914,    '2026-11-16 00:02:31+00')
on conflict (code) do nothing;

-- Same arithmetic as NetWorthCalculator.convert (amount in minor units):
-- identical codes or a missing/zero rate on either side → unchanged;
-- otherwise round(amount / from * to), half away from zero like
-- NSDecimalRound(.plain).
create or replace function public.fx_convert_minor(p_amount numeric, p_from text, p_to text)
returns bigint
language sql
stable
set search_path = public
as $$
    select case
        when p_amount is null then null
        when upper(coalesce(p_from, '')) = upper(coalesce(p_to, '')) then round(p_amount)::bigint
        else coalesce(
            (select round(p_amount / f.per_usd * t.per_usd)::bigint
               from fx_rates f, fx_rates t
              where f.code = upper(p_from) and t.code = upper(p_to)
                and f.per_usd > 0 and t.per_usd > 0),
            round(p_amount)::bigint)
    end
$$;

revoke all on function public.fx_convert_minor(numeric, text, text) from public, anon;
grant execute on function public.fx_convert_minor(numeric, text, text) to authenticated, service_role;
