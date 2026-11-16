-- Edge-function calls from the database authenticate with CRON_SECRET read
-- from Vault (2026-11-17 review: S4 server half, S11, M4 amount fix).
--
-- Before:
--   * notify_on_transaction_insert and the smart-notifications-* cron jobs
--     sent the ANON key as bearer. smart-notifications accepted ANY bearer
--     (S4), so the push pipeline was open to anyone holding the app's key;
--     once the function only accepts CRON_SECRET these calls would 401.
--   * check-subscriptions-daily-0900-utc carried CRON_SECRET as a plaintext
--     literal in cron.job.command (and therefore in every
--     cron.job_run_details row).
--   * notify_on_transaction_insert sent the legacy `amount` — on a
--     foreign-entry row that is the typed foreign number (500 000 VND on a RUB
--     account → a "large expense 500 000 ₽" push). It now sends amount_native
--     (account currency, ADR-001) as both `amount` and `amount_native`, plus
--     account_id.
-- After: every call sends `x-cron-secret: <cron_secret>` AND
-- `Authorization: Bearer <cron_secret>`, both read from
-- vault.decrypted_secrets at call time; nothing secret is stored in cron.job.
-- Accepted by the current smart-notifications / check-subscriptions code
-- (bearer === CRON_SECRET || x-cron-secret === CRON_SECRET) and by the
-- hardened versions, so apply THIS migration BEFORE deploying the S4 fix.
-- coaching-reminders-check (owned by the TMA repo) is not touched.
--
-- PREREQUISITE — the vault secret `cron_secret` must exist and equal the
-- edge-function secret CRON_SECRET. This migration refuses to run without it.
-- (Prod: created 2026-11-16 18:12 UTC; the dry run confirmed by md5 that it
-- equals the literal the check-subscriptions job sends today.)
-- To keep the CURRENT value (it is the literal in the check-subscriptions
-- job), copy it inside the database — the value is never printed — BEFORE
-- applying this file (afterwards the literal is gone):
--
--   select vault.create_secret(
--       (regexp_match((select command from cron.job where jobname = 'check-subscriptions-daily-0900-utc'),
--                     $re$concat\('Bearer ', '([^']+)'\)$re$))[1],
--       'cron_secret',
--       'CRON_SECRET for pg_cron jobs / DB triggers calling edge functions (x-cron-secret + Bearer)');
--
-- To rotate instead: `supabase secrets set CRON_SECRET=<new>` and
-- `select vault.create_secret('<new>', 'cron_secret', '…')` with the same value.

do $$
begin
    if not exists (select 1 from vault.secrets where name = 'cron_secret') then
        raise exception 'vault secret "cron_secret" is missing — create it first (see the header of 20261117120700). Nothing was changed.';
    end if;
    if not exists (select 1 from vault.secrets where name = 'project_url') then
        raise exception 'vault secret "project_url" is missing. Nothing was changed.';
    end if;
end $$;

create or replace function public.notify_on_transaction_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
        )
    );

    return new;
end;
$$;

-- cron.schedule with an existing (jobname, username) updates the job in
-- place (same jobid). The jobs belong to `postgres`; apply as postgres.
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
      body    := '{"trigger":"cron_inactivity"}'::jsonb
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
      body    := '{"trigger":"cron_weekly_pace"}'::jsonb
  );
    $cmd$
);

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
      body    := '{"source":"pg_cron"}'::jsonb
  );
    $cmd$
);
