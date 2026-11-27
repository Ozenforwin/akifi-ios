-- Review 2026-11-27, S4: cache for the fx-historical edge function, which
-- replaces the APILayer key that shipped inside the iOS app. Historical
-- quotes never change, so one row per (date, base, quote) forever.
-- Service role only: RLS on, no policies, no grants to clients.
create table if not exists public.fx_rates_historical (
    rate_date  date        not null,
    base       text        not null check (base ~ '^[A-Z]{3}$'),
    quote      text        not null check (quote ~ '^[A-Z]{3}$'),
    rate       numeric     not null check (rate > 0),
    fetched_by uuid        references auth.users(id) on delete set null,
    fetched_at timestamptz not null default now(),
    primary key (rate_date, base, quote)
);
alter table public.fx_rates_historical enable row level security;
revoke all on public.fx_rates_historical from anon, authenticated;
create index if not exists fx_rates_historical_fetched_by_idx
    on public.fx_rates_historical (fetched_by, fetched_at);
