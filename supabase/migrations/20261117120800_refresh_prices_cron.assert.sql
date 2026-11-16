-- Assertions for 20261117120800_refresh_prices_cron.sql (dry run, rolled back).
-- SAFETY: this file writes test rows (and impersonates users). It refuses to run
-- unless the session is marked as a dry run inside BEGIN … ROLLBACK:
--   db_dryrun.py <(echo "select set_config('akifi.dry_run','on',true);") <migration>.sql <this file>
-- (it also matches the CLI's <version>_<name>.sql pattern — never `supabase db push` it).
do $$
begin
    if coalesce(current_setting('akifi.dry_run', true), '') <> 'on' then
        raise exception 'Assertion file: run only via the dry-run helper with akifi.dry_run=on (BEGIN … ROLLBACK).';
    end if;
end $$;

do $$
declare v_before bigint; v_q record; v_cmd text;
    v_secret text := (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret');
begin
    if (select count(*) from cron.job where jobname = 'refresh-portfolio-prices') <> 1 then
        raise exception 'ASSERT FAILED: refresh-portfolio-prices not scheduled exactly once';
    end if;
    select command into v_cmd from cron.job where jobname = 'refresh-portfolio-prices' and schedule = '0 6 * * *';
    if v_cmd is null or v_cmd like '%anon_key%' or v_cmd not like '%name = ''cron_secret''%' then
        raise exception 'ASSERT FAILED: refresh-portfolio-prices command';
    end if;
    select coalesce(max(id), 0) into v_before from net.http_request_queue;
    execute v_cmd;
    select * into v_q from net.http_request_queue where id > v_before order by id desc limit 1;
    if v_q.url not like '%/functions/v1/refresh-portfolio-prices'
       or v_q.headers->>'x-cron-secret' is distinct from v_secret
       or v_q.headers->>'Authorization' is distinct from 'Bearer ' || v_secret then
        raise exception 'ASSERT FAILED: refresh-portfolio-prices request shape';
    end if;
end $$;
select 'refresh-prices cron assertions passed' as result;
