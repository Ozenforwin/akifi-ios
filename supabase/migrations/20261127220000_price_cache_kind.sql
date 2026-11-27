-- Review 2026-11-27, M16: price_cache was keyed by (ticker, currency) only, so
-- a holding of one kind could overwrite the price of another: any signed-in
-- user calling fetch-price {BTC, kind: etf} cached the Grayscale ETF (~$45)
-- under (BTC, USD), and every crypto BTC read $45 for 30 minutes. The kind is
-- now part of the key. The table is empty on prod, so no data is affected.
alter table public.price_cache add column if not exists kind text not null default '';
alter table public.price_cache drop constraint if exists price_cache_pkey;
alter table public.price_cache add constraint price_cache_pkey primary key (ticker, currency, kind);
