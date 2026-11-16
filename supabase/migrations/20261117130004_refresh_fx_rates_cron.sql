-- Hourly refresh of public.fx_rates (20261117130000) by the
-- `refresh-fx-rates` edge function.
--
-- Apply AFTER the function is deployed:
--   1. supabase/config.toml: [functions.refresh-fx-rates] verify_jwt = false
--      (the caller presents the cron secret, not a JWT)
--   2. supabase functions deploy refresh-fx-rates --no-verify-jwt --project-ref fnvwfrkixjqdifitlifr
--   3. CRON_SECRET (function env) must equal vault secret `cron_secret` —
--      both already exist for the other cron jobs; nothing new to create.
--
-- Same pattern as every other job in this project: URL and secret come from
-- vault.decrypted_secrets, never from cron.job.command in clear text. The
-- secret travels in a header, never in the URL.

create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
    if exists (select 1 from cron.job where jobname = 'refresh-fx-rates-hourly') then
        perform cron.unschedule('refresh-fx-rates-hourly');
    end if;
end $$;

select cron.schedule(
    'refresh-fx-rates-hourly',
    '7 * * * *',  -- hh:07 UTC; open.er-api.com updates once a day, hourly keeps us within an hour of it
    $$
      select net.http_post(
          url     := (select rtrim(decrypted_secret, '/') || '/functions/v1/refresh-fx-rates'
                      from vault.decrypted_secrets where name = 'project_url' limit 1),
          headers := jsonb_build_object(
              'Content-Type',  'application/json',
              'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)
          ),
          body    := '{"source":"pg_cron"}'::jsonb
      );
    $$
);
