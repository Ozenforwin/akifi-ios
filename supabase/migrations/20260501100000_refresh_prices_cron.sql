-- Daily cron that prefetches prices for every (ticker, currency)
-- tuple referenced in `investment_holdings`. Calls the
-- `refresh-portfolio-prices` edge function via pg_net so we stay
-- inside the project's free-tier API budget no matter how many
-- users tap "Pull current price" later in the day.
--
-- The cron job lives in the `cron` schema (Supabase exposes pg_cron
-- there). The HTTP call uses pg_net's queued POST mechanism so the
-- transaction returns immediately — the actual call resolves in the
-- background and shows up in `net._http_response`.

-- Required extensions. Supabase pre-installs them; the IF NOT EXISTS
-- keeps the migration idempotent on local dev.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Schedule (or reschedule) the daily refresh job. Older pg_cron
-- doesn't upsert by name, so we drop first.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'refresh-portfolio-prices') THEN
        PERFORM cron.unschedule('refresh-portfolio-prices');
    END IF;
END $$;

-- The job itself. We use `net.http_post` (pg_net) which queues the
-- request and returns immediately — the actual HTTP call lands in
-- `net._http_response` after the cron tick.
SELECT cron.schedule(
    'refresh-portfolio-prices',
    '0 6 * * *',  -- 06:00 UTC daily
    $$
      SELECT net.http_post(
          url     := current_setting('app.settings.refresh_prices_url'),
          body    := '{}'::JSONB,
          headers := jsonb_build_object(
              'Content-Type',     'application/json',
              'x-cron-secret',    current_setting('app.settings.cron_secret'),
              'Authorization',    'Bearer ' || current_setting('app.settings.service_role_key')
          )
      );
    $$
);

-- The settings above (`app.settings.*`) must be set on the database
-- once via a one-time `ALTER DATABASE ... SET ...`. We do *not* set
-- them in this migration because they hold service-role secrets and
-- shouldn't sit in version control. See deployment notes in the
-- commit body.
