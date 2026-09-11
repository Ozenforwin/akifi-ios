-- refresh-portfolio-prices cron — vault-based (supersedes 20260501100000,
-- which was never applied to production).
--
-- The original version read `app.settings.refresh_prices_url`,
-- `app.settings.cron_secret` AND `app.settings.service_role_key` from
-- database GUCs set via ALTER DATABASE. Two problems: (1) it never shipped
-- because those settings were never provisioned, so no price cron has ever
-- run in production; (2) a service-role key in a database-level GUC is
-- readable by any session through current_setting() — a far wider blast
-- radius than the function needs. `refresh-portfolio-prices` is gated by
-- `x-cron-secret` alone (see index.ts), so no service-role key is needed.
--
-- This version follows the pattern every other cron job in this project
-- already uses (smart-notifications-*, coaching-reminders-check): read
-- `project_url` and the secret from `vault.decrypted_secrets`.
--
-- Prerequisites (one-time, outside version control):
--   1. supabase secrets set CRON_SECRET=<random>          -- function side
--   2. select vault.create_secret('<random>', 'cron_secret',
--        'x-cron-secret for refresh-portfolio-prices');   -- database side
--   3. supabase functions deploy refresh-portfolio-prices --no-verify-jwt

create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
    if exists (select 1 from cron.job where jobname = 'refresh-portfolio-prices') then
        perform cron.unschedule('refresh-portfolio-prices');
    end if;
end $$;

select cron.schedule(
    'refresh-portfolio-prices',
    '0 6 * * *',  -- 06:00 UTC daily
    $$
      select net.http_post(
          url     := (select rtrim(decrypted_secret, '/') || '/functions/v1/refresh-portfolio-prices'
                      from vault.decrypted_secrets where name = 'project_url' limit 1),
          headers := jsonb_build_object(
              'Content-Type',  'application/json',
              'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)
          ),
          body    := '{}'::jsonb
      );
    $$
);
