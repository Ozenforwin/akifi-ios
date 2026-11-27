-- Dry run: begin; <migration>; <this file>; rollback;
-- Acts as a real Telegram-linked user through PostgREST's role.
do $$
declare
    v_uid  uuid;
    v_tg   text;
    v_mail text;
    r      record;
begin
    select u.id, u.raw_user_meta_data->>'telegram_id', p.email
      into v_uid, v_tg, v_mail
      from auth.users u join public.profiles p on p.id = u.id
     where u.raw_user_meta_data->>'telegram_id' is not null
       and p.telegram_user_id::text = u.raw_user_meta_data->>'telegram_id'
     order by u.created_at limit 1;
    if v_uid is null then raise exception 'ASSERT FAILED: no fixture user'; end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    set local role authenticated;

    -- 1. a foreign chat id and a foreign e-mail are ignored, the name is saved
    update public.profiles
       set telegram_chat_id = 4242424242, email = 'tg_4242424242@telegram.local', full_name = 'guard-test'
     where id = v_uid;
    select telegram_chat_id, email, full_name into r from public.profiles where id = v_uid;
    if r.telegram_chat_id::text is distinct from v_tg then raise exception 'ASSERT FAILED: foreign chat id accepted'; end if;
    if r.email is distinct from v_mail then raise exception 'ASSERT FAILED: foreign email accepted'; end if;
    if r.full_name is distinct from 'guard-test' then raise exception 'ASSERT FAILED: harmless field not saved'; end if;

    -- 2. a foreign telegram_user_id is ignored
    update public.profiles set telegram_user_id = 4242424242 where id = v_uid;
    if (select telegram_user_id::text from public.profiles where id = v_uid) is distinct from v_tg then
        raise exception 'ASSERT FAILED: foreign telegram_user_id accepted';
    end if;

    -- 3. unlinking is allowed, re-linking to the verified id is allowed
    update public.profiles set telegram_user_id = null, telegram_chat_id = null where id = v_uid;
    if (select telegram_user_id from public.profiles where id = v_uid) is not null then
        raise exception 'ASSERT FAILED: unlink refused';
    end if;
    update public.profiles set telegram_user_id = v_tg::bigint, telegram_chat_id = v_tg::bigint where id = v_uid;
    if (select telegram_chat_id::text from public.profiles where id = v_uid) is distinct from v_tg then
        raise exception 'ASSERT FAILED: verified re-link refused';
    end if;

    reset role;
    -- 4. service role / migrations are not restricted
    perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
    update public.profiles set telegram_chat_id = 4242424242 where id = v_uid;
    if (select telegram_chat_id from public.profiles where id = v_uid) <> 4242424242 then
        raise exception 'ASSERT FAILED: service role restricted';
    end if;
end $$;
select 'profiles identity guard: all assertions passed' as result;
