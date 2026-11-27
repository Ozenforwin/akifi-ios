-- Review 2026-11-27: N2 (weekly digest never had a schedule), N3 (no pg_net
-- timeout: every call was cut at 5 s, the response lost while cron.job_run_details
-- says "succeeded"), S13 (coaching-reminders was called with the anon key and
-- accepted any bearer; it now requires CRON_SECRET like the other functions).
--
-- Every job uses the vault pattern of 20261117120700 (no secret in cron.job)
-- plus an explicit timeout_milliseconds. cron.schedule with an existing
-- jobname updates the job in place. Apply as postgres.
--
-- send-weekly-digest: Monday 06:00 UTC = 09:00 MSK / 13:00 ICT; the function
-- covers the last 7 full days in each user's zone and dedups per week, and
-- since 87139f8 it sends only to users with digest_opt_in = true.

select cron.schedule(
    'check-subscriptions-daily-0900-utc',
    '0 9 * * *',
    $cmd$
  select net.http_post(
      url     := (select rtrim(decrypted_secret, '/') || '/functions/v1/check-subscriptions'
                    from vault.decrypted_secrets where name = 'project_url' limit 1),
      headers := (select jsonb_build_object(
                      'Content-Type',  'application/json',
                      'x-cron-secret', s.decrypted_secret,
                      'Authorization', 'Bearer ' || s.decrypted_secret)
                    from vault.decrypted_secrets s where s.name = 'cron_secret' limit 1),
      body    := '{"source":"pg_cron"}'::jsonb,
      timeout_milliseconds := 120000
  );
    $cmd$
);

select cron.schedule(
    'smart-notifications-inactivity',
    '0 10 * * *',
    $cmd$
  select net.http_post(
      url     := (select rtrim(decrypted_secret, '/') || '/functions/v1/smart-notifications'
                    from vault.decrypted_secrets where name = 'project_url' limit 1),
      headers := (select jsonb_build_object(
                      'Content-Type',  'application/json',
                      'x-cron-secret', s.decrypted_secret,
                      'Authorization', 'Bearer ' || s.decrypted_secret)
                    from vault.decrypted_secrets s where s.name = 'cron_secret' limit 1),
      body    := '{"trigger":"cron_inactivity"}'::jsonb,
      timeout_milliseconds := 120000
  );
    $cmd$
);

select cron.schedule(
    'smart-notifications-weekly-pace',
    '0 10 * * 3',
    $cmd$
  select net.http_post(
      url     := (select rtrim(decrypted_secret, '/') || '/functions/v1/smart-notifications'
                    from vault.decrypted_secrets where name = 'project_url' limit 1),
      headers := (select jsonb_build_object(
                      'Content-Type',  'application/json',
                      'x-cron-secret', s.decrypted_secret,
                      'Authorization', 'Bearer ' || s.decrypted_secret)
                    from vault.decrypted_secrets s where s.name = 'cron_secret' limit 1),
      body    := '{"trigger":"cron_weekly_pace"}'::jsonb,
      timeout_milliseconds := 120000
  );
    $cmd$
);

select cron.schedule(
    'coaching-reminders-check',
    '*/15 * * * *',
    $cmd$
  select net.http_post(
      url     := (select rtrim(decrypted_secret, '/') || '/functions/v1/coaching-reminders'
                    from vault.decrypted_secrets where name = 'project_url' limit 1),
      headers := (select jsonb_build_object(
                      'Content-Type',  'application/json',
                      'x-cron-secret', s.decrypted_secret,
                      'Authorization', 'Bearer ' || s.decrypted_secret)
                    from vault.decrypted_secrets s where s.name = 'cron_secret' limit 1),
      body    := '{"source":"pg_cron"}'::jsonb,
      timeout_milliseconds := 60000
  );
    $cmd$
);

select cron.schedule(
    'refresh-portfolio-prices',
    '0 6 * * *',
    $cmd$
  select net.http_post(
      url     := (select rtrim(decrypted_secret, '/') || '/functions/v1/refresh-portfolio-prices'
                    from vault.decrypted_secrets where name = 'project_url' limit 1),
      headers := (select jsonb_build_object(
                      'Content-Type',  'application/json',
                      'x-cron-secret', s.decrypted_secret,
                      'Authorization', 'Bearer ' || s.decrypted_secret)
                    from vault.decrypted_secrets s where s.name = 'cron_secret' limit 1),
      body    := '{}'::jsonb,
      timeout_milliseconds := 300000
  );
    $cmd$
);

select cron.schedule(
    'refresh-fx-rates-hourly',
    '7 * * * *',
    $cmd$
  select net.http_post(
      url     := (select rtrim(decrypted_secret, '/') || '/functions/v1/refresh-fx-rates'
                    from vault.decrypted_secrets where name = 'project_url' limit 1),
      headers := (select jsonb_build_object(
                      'Content-Type',  'application/json',
                      'x-cron-secret', s.decrypted_secret,
                      'Authorization', 'Bearer ' || s.decrypted_secret)
                    from vault.decrypted_secrets s where s.name = 'cron_secret' limit 1),
      body    := '{"source":"pg_cron"}'::jsonb,
      timeout_milliseconds := 60000
  );
    $cmd$
);

select cron.schedule(
    'send-weekly-digest-monday',
    '0 6 * * 1',
    $cmd$
  select net.http_post(
      url     := (select rtrim(decrypted_secret, '/') || '/functions/v1/send-weekly-digest'
                    from vault.decrypted_secrets where name = 'project_url' limit 1),
      headers := (select jsonb_build_object(
                      'Content-Type',  'application/json',
                      'x-cron-secret', s.decrypted_secret,
                      'Authorization', 'Bearer ' || s.decrypted_secret)
                    from vault.decrypted_secrets s where s.name = 'cron_secret' limit 1),
      body    := '{"source":"pg_cron"}'::jsonb,
      timeout_milliseconds := 300000
  );
    $cmd$
);

-- Transaction-insert trigger: same call, 30 s timeout (pg_net is async;
-- the insert never waits for it).
CREATE OR REPLACE FUNCTION public.notify_on_transaction_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_url    text;
    v_secret text;
begin
    -- Transfers are not real expenses/income.
    if new.transfer_group_id is not null then
        return new;
    end if;

    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_secret
      from vault.decrypted_secrets where name = 'cron_secret' limit 1;
    if v_url is null or v_secret is null then
        return new;
    end if;

    perform net.http_post(
        url     := rtrim(v_url, '/') || '/functions/v1/smart-notifications',
        headers := jsonb_build_object(
            'Content-Type',  'application/json',
            'x-cron-secret', v_secret,
            'Authorization', 'Bearer ' || v_secret
        ),
        body    := jsonb_build_object(
            'trigger',        'transaction_insert',
            'transaction_id', new.id,
            'user_id',        new.user_id,
            'account_id',     new.account_id,
            'amount',         coalesce(new.amount_native, new.amount),
            'amount_native',  coalesce(new.amount_native, new.amount),
            'type',           new.type,
            'category_id',    new.category_id
        ),
        -- pg_net gives up after 5 s by default and the response is lost;
        -- the function keeps running, but failures become invisible.
        timeout_milliseconds := 30000
    );

    return new;
end;
$function$;
