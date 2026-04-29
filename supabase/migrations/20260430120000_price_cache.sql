-- Cache backing the `fetch-price` edge function. The function reads
-- from this table first (30-minute TTL — see the function code) and
-- only hits Twelve Data / CoinGecko on miss. Public read so any
-- authenticated user benefits from a peer's recent fetch; only the
-- service-role key (used inside the edge function) can write.
--
-- (ticker, currency) is the natural key — the same ticker quoted in
-- different currencies (e.g. VOO in USD vs. EUR shadow listings) gets
-- separate cache rows.
CREATE TABLE IF NOT EXISTS price_cache (
    ticker TEXT NOT NULL,
    currency TEXT NOT NULL,
    last_price NUMERIC(20,8) NOT NULL CHECK (last_price >= 0),
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source TEXT NOT NULL CHECK (source IN ('twelvedata', 'coingecko', 'manual')),
    PRIMARY KEY (ticker, currency)
);

CREATE INDEX IF NOT EXISTS idx_price_cache_fetched_at ON price_cache(fetched_at);

ALTER TABLE price_cache ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "price_cache_authenticated_read" ON price_cache;

-- Any signed-in user can read; service_role bypasses RLS for writes.
CREATE POLICY "price_cache_authenticated_read"
    ON price_cache FOR SELECT
    TO authenticated
    USING (true);
