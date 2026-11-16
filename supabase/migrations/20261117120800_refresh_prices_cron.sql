-- refresh-portfolio-prices daily cron (supersedes 20260911120000, which was
-- never applied: prod cron.job has no such job as of 2026-11-17).
--
-- APPLY ONLY AFTER the function is deployed — as of 2026-11-17 it is NOT
-- deployed on prod (absent from the project's function list), so the job
-- would just collect daily 404s:
--     supabase functions deploy refresh-portfolio-prices --no-verify-jwt --project-ref fnvwfrkixjqdifitlifr
-- (`[functions.refresh-portfolio-prices] verify_jwt = false` belongs in
-- config.toml — review item S11; the bearer below is CRON_SECRET, not a JWT,
-- so a gateway that verifies JWTs would reject every run.)
--
-- Same authentication as 20261117120700: x-cron-secret AND
-- Authorization: Bearer, both from vault `cron_secret`; the function itself
-- checks x-cron-secret. Requires vault secrets `project_url`, `cron_secret`.

do $$
begin
    if not exists (select 1 from vault.secrets where name = 'cron_secret')
       or not exists (select 1 from vault.secrets where name = 'project_url') then
        raise exception 'vault secrets "cron_secret" / "project_url" are required. Nothing was changed.';
    end if;
end $$;

select cron.schedule(
    'refresh-portfolio-prices',
    '0 6 * * *',  -- 06:00 UTC daily
    $cmd$
  select net.http_post(
      url     := (select rtrim(decrypted_secret, '/') || '/functions/v1/refresh-portfolio-prices'
                    from vault.decrypted_secrets where name = 'project_url' limit 1),
      headers := (select jsonb_build_object(
                      'Content-Type',  'application/json',
                      'x-cron-secret', s.decrypted_secret,
                      'Authorization', 'Bearer ' || s.decrypted_secret)
                    from vault.decrypted_secrets s where s.name = 'cron_secret' limit 1),
      body    := '{}'::jsonb
  );
    $cmd$
);
