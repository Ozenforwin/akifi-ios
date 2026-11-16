-- Assertions for 20261117120600_definer_search_path_policy_hygiene.sql (dry run, rolled back).
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

-- 1) No SECURITY DEFINER function in public is left without a pinned search_path.
do $$
declare v text;
begin
    select string_agg(p.oid::regprocedure::text, ', ') into v
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prosecdef
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%');
    if v is not null then raise exception 'ASSERT FAILED: definer functions without search_path: %', v; end if;
end $$;

-- 2) + 3) behaviour as Vladimir.
select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true),
       set_config('role','authenticated',true);
do $$
declare v_cat uuid; v_inc uuid; v_rule uuid; v_conv uuid; v_msg uuid; v_goal uuid;
begin
    insert into public.categories (user_id, name, type, scope) values (auth.uid(), 'dry-run exp', 'expense', 'personal')
    returning id into v_cat;
    insert into public.categories (user_id, name, type, scope) values (auth.uid(), 'dry-run inc', 'income', 'personal')
    returning id into v_inc;

    -- Strict rule: category type must match tx_type.
    insert into public.category_rules (user_id, category_id, tx_type, pattern) values (auth.uid(), v_cat, 'expense', 'dry')
    returning id into v_rule;
    begin
        insert into public.category_rules (user_id, category_id, tx_type, pattern) values (auth.uid(), v_inc, 'expense', 'dry');
        raise exception 'ASSERT FAILED: rule with mismatched category type inserted';
    exception when insufficient_privilege then null; end;
    begin  -- account the caller cannot write
        insert into public.category_rules (user_id, category_id, tx_type, pattern, account_id)
        values (auth.uid(), v_cat, 'expense', 'dry', '8085d0ea-f4e0-46f8-9f8e-486993d3ae77');
        raise exception 'ASSERT FAILED: rule on a foreign account inserted';
    exception when insufficient_privilege then null; end;
    begin
        update public.category_rules set category_id = v_inc where id = v_rule;
        raise exception 'ASSERT FAILED: rule updated to a mismatched category';
    exception when insufficient_privilege then null; end;
    update public.category_rules set pattern = 'dry2' where id = v_rule;
    if not found then raise exception 'ASSERT FAILED: legit rule update refused'; end if;

    -- ai_messages: own conversation ok; a conversation the caller cannot write → refused.
    insert into public.ai_conversations (user_id, title) values (auth.uid(), 'dry-run') returning id into v_conv;
    insert into public.ai_messages (conversation_id, user_id, role, content) values (v_conv, auth.uid(), 'user', 'hi')
    returning id into v_msg;
    perform set_config('test.vlad_msg', v_msg::text, true);

    -- savings goal trigger still recomputes (rewritten with qualified names).
    insert into public.savings_goals (user_id, name, target_amount) values (auth.uid(), 'dry-run', 100) returning id into v_goal;
    insert into public.savings_contributions (goal_id, user_id, amount) values (v_goal, auth.uid(), 100);
    if (select status from public.savings_goals where id = v_goal) <> 'completed' then
        raise exception 'ASSERT FAILED: savings trigger did not recompute the goal';
    end if;
end $$;

reset role;
select set_config('request.jwt.claims','{"sub":"66673fe4-69ee-429f-b0a2-81b9e838b41d","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','66673fe4-69ee-429f-b0a2-81b9e838b41d',true),
       set_config('role','authenticated',true);
do $$
declare v_conv uuid;
begin
    insert into public.ai_conversations (user_id, title) values (auth.uid(), 'olga dry-run') returning id into v_conv;
    perform set_config('test.olga_conv', v_conv::text, true);
end $$;

reset role;
select set_config('request.jwt.claims','{"sub":"2ebaaa87-1e23-46f7-a66e-c85d2bb8227c","role":"authenticated"}',true),
       set_config('request.jwt.claim.sub','2ebaaa87-1e23-46f7-a66e-c85d2bb8227c',true),
       set_config('role','authenticated',true);
do $$
begin
    begin
        insert into public.ai_messages (conversation_id, user_id, role, content)
        values (current_setting('test.olga_conv')::uuid, auth.uid(), 'user', 'injected');
        raise exception 'ASSERT FAILED: message inserted into a foreign conversation';
    exception when insufficient_privilege then null; end;
    begin
        update public.ai_messages set conversation_id = current_setting('test.olga_conv')::uuid
         where id = current_setting('test.vlad_msg')::uuid;
        raise exception 'ASSERT FAILED: message moved into a foreign conversation';
    exception when insufficient_privilege then null; end;
end $$;

reset role;
select 'Review #12 assertions passed' as result;
