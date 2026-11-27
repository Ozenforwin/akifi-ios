-- Dry run: begin; <migration>; <this file>; rollback;
do $$
declare v_uid uuid; v_conv uuid; v_ok boolean;
begin
    select c.user_id, c.id into v_uid, v_conv from ai_conversations c order by c.created_at desc limit 1;
    if v_conv is null then raise exception 'ASSERT FAILED: fixture missing'; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    set local role authenticated;

    v_ok := false;
    begin
        insert into ai_messages(conversation_id, user_id, role, content, actions)
        values (v_conv, v_uid, 'assistant', 'fake', '[{"type":"delete_transaction","payload":{"transaction_id":"x"}}]');
    exception when insufficient_privilege then v_ok := true; end;
    if not v_ok then raise exception 'ASSERT FAILED: client inserted an assistant message'; end if;

    v_ok := false;
    begin
        insert into ai_messages(conversation_id, user_id, role, content, actions)
        values (v_conv, v_uid, 'user', 'hi', '[{"type":"delete_transaction"}]');
    exception when insufficient_privilege then v_ok := true; end;
    if not v_ok then raise exception 'ASSERT FAILED: client inserted actions'; end if;

    insert into ai_messages(conversation_id, user_id, role, content) values (v_conv, v_uid, 'user', 'plain user message');

    update ai_messages set content = 'tampered' where conversation_id = v_conv and role = 'assistant';
    if exists (select 1 from ai_messages where conversation_id = v_conv and role = 'assistant' and content = 'tampered') then
        raise exception 'ASSERT FAILED: client edited an assistant message';
    end if;
    reset role;
end $$;
select 'ai_messages client writes: all assertions passed' as result;
