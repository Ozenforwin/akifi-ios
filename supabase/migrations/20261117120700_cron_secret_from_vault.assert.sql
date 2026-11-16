-- Assertions for 20261117120700_cron_secret_from_vault.sql (dry run, rolled back).
-- Order: <prereq: vault.create_secret('cron_secret' …) + md5 GUCs>, migration, this file.
-- No secret value is ever selected into the output: only equality / md5 checks.
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

-- 1) Jobs replaced in place, no secret literal, no anon key, coaching job untouched.
do $$
declare v_ids text; r record;
begin
    select string_agg(jobname || '=' || jobid, ',' order by jobname) into v_ids from cron.job;
    if v_ids <> current_setting('test.jobids') then
        raise exception 'ASSERT FAILED: cron jobs added/removed/renumbered: % (was %)', v_ids, current_setting('test.jobids');
    end if;
    for r in select jobname, schedule, command from cron.job
              where jobname in ('smart-notifications-inactivity', 'smart-notifications-weekly-pace',
                                'check-subscriptions-daily-0900-utc') loop
        if r.command like '%concat(''Bearer '', ''%' or r.command like '%anon_key%'
           or r.command not like '%name = ''cron_secret''%'
           or r.command not like '%x-cron-secret%' or r.command not like '%Authorization%' then
            raise exception 'ASSERT FAILED: job % still carries a literal / anon key or lacks the vault secret', r.jobname;
        end if;
    end loop;
    if (select schedule from cron.job where jobname = 'check-subscriptions-daily-0900-utc') <> '0 9 * * *'
       or (select schedule from cron.job where jobname = 'smart-notifications-inactivity') <> '0 10 * * *'
       or (select schedule from cron.job where jobname = 'smart-notifications-weekly-pace') <> '0 10 * * 3' then
        raise exception 'ASSERT FAILED: schedules changed';
    end if;
    if (select md5(command) from cron.job where jobname = 'coaching-reminders-check') <> current_setting('test.coaching_cmd_md5') then
        raise exception 'ASSERT FAILED: coaching-reminders-check was modified';
    end if;
    -- The vault copy is the value check-subscriptions has been using.
    if (select md5(decrypted_secret) from vault.decrypted_secrets where name = 'cron_secret')
       <> current_setting('test.cron_literal_md5') then
        raise exception 'ASSERT FAILED: vault cron_secret differs from the current CRON_SECRET literal';
    end if;
    if (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
       not like 'https://fnvwfrkixjqdifitlifr.supabase.co%' then
        raise exception 'ASSERT FAILED: vault project_url does not point at the prod project';
    end if;
end $$;

-- 2) Each job command, executed here, enqueues the right request (rolled back,
--    pg_net only sends committed rows).
do $$
declare
    r record; v_before bigint; v_q record;
    v_secret text := (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret');
begin
    for r in select jobname, command from cron.job
              where jobname in ('smart-notifications-inactivity', 'smart-notifications-weekly-pace',
                                'check-subscriptions-daily-0900-utc') loop
        select coalesce(max(id), 0) into v_before from net.http_request_queue;
        execute r.command;
        select * into v_q from net.http_request_queue where id > v_before order by id desc limit 1;
        if v_q.id is null then raise exception 'ASSERT FAILED: % enqueued nothing', r.jobname; end if;
        if v_q.headers->>'x-cron-secret' is distinct from v_secret
           or v_q.headers->>'Authorization' is distinct from 'Bearer ' || v_secret then
            raise exception 'ASSERT FAILED: % does not send the vault secret in both headers', r.jobname;
        end if;
        if r.jobname like 'smart-notifications%' and v_q.url not like '%/functions/v1/smart-notifications' then
            raise exception 'ASSERT FAILED: % wrong url', r.jobname;
        end if;
        if r.jobname like 'check-subscriptions%' and v_q.url <> 'https://fnvwfrkixjqdifitlifr.supabase.co/functions/v1/check-subscriptions' then
            raise exception 'ASSERT FAILED: check-subscriptions url changed';
        end if;
    end loop;
end $$;

-- 3) The transaction trigger sends amount_native + both auth headers.
select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true),
       set_config('role','authenticated',true);
select set_config('test.q_before', (select coalesce(max(id), 0)::text from net.http_request_queue), true);
insert into public.transactions (user_id, account_id, type, date, amount, amount_native, currency,
                                 foreign_amount, foreign_currency, fx_rate, description)
values ('2ebaaa87-1e23-46f7-a66e-c85d2bb8227c', '9b075428-e95b-4aa2-8f2c-2b412994c397', 'expense', now(),
        500000, 1900, 'RUB', 500000, 'VND', 0.0038, 'dry-run notify');
reset role;
do $$
declare v_q record; v_body jsonb; v_secret text := (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret');
begin
    select * into v_q from net.http_request_queue where id > current_setting('test.q_before')::bigint order by id desc limit 1;
    if v_q.id is null then raise exception 'ASSERT FAILED: trigger enqueued nothing'; end if;
    v_body := convert_from(v_q.body, 'UTF8')::jsonb;
    if v_q.headers->>'x-cron-secret' is distinct from v_secret
       or v_q.headers->>'Authorization' is distinct from 'Bearer ' || v_secret then
        raise exception 'ASSERT FAILED: trigger does not authenticate with the vault secret';
    end if;
    if (v_body->>'amount_native')::numeric <> 1900 or (v_body->>'amount')::numeric <> 1900
       or v_body->>'trigger' <> 'transaction_insert' or v_body->>'account_id' is null then
        raise exception 'ASSERT FAILED: trigger body %', v_body;
    end if;
end $$;

select 'cron/vault assertions passed' as result;
