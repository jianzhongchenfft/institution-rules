-- Eight reviewed team-message RPC definitions from V35+V36 TEST Supabase.
-- Production initial installation only. No private helper functions are changed.
-- SECURITY DEFINER RPCs validate private.current_staff_user_id() and private.can_manage_cases().

CREATE OR REPLACE FUNCTION public.add_team_message_task(p_message_id uuid, p_description text, p_assignee_staff_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_actor uuid;
 v_owner uuid;
 v_closed timestamptz;
 v_position integer;
 v_new_id uuid;
 v_assignee_name text;
begin
 v_actor:=private.current_staff_user_id();
 if v_actor is null or not private.can_manage_cases() then raise exception '沒有操作訊息交辦的權限';end if;
 if p_description is null or char_length(btrim(p_description)) not between 1 and 1000 then
   raise exception '請輸入交辦內容（最多1000字）';end if;
 if p_assignee_staff_id is null then raise exception '請選擇承辦人';end if;
 select display_name into v_assignee_name from public.staff_users where id=p_assignee_staff_id
 and is_active and role in ('admin','organization_manager','business_manager','supervisor');
 if not found then raise exception '承辦人不存在或已停用';end if;
 select created_by_staff_id,closed_at into v_owner,v_closed from public.team_messages
 where id=p_message_id for update;
 if not found then raise exception '事件不存在';end if;
 if v_owner<>v_actor then raise exception '僅建立者可新增分工';end if;
 if v_closed is not null then raise exception '已結案事件不能新增分工';end if;
 select coalesce(max(sort_order),0)+1 into v_position from public.team_message_tasks where message_id=p_message_id;
 if v_position>20 then raise exception '一則事件最多20項分工';end if;
 insert into public.team_message_tasks(message_id,description,assignee_staff_id,sort_order)
 values(p_message_id,btrim(p_description),p_assignee_staff_id,v_position)
 returning id into v_new_id;
 insert into public.team_message_recipients(message_id,staff_id)
 values(p_message_id,p_assignee_staff_id) on conflict do nothing;
 insert into public.team_message_updates(message_id,staff_id,body,is_system)
 values(p_message_id,v_actor,'【新增分工｜'||left(v_assignee_name,80)||'】'||E'\n'||left(btrim(p_description),1000),true);
 return v_new_id;
end;
$function$

CREATE OR REPLACE FUNCTION public.create_team_message(p_description text, p_tasks jsonb DEFAULT '[]'::jsonb, p_recipient_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_id uuid;
 v_staff uuid;
 v_receiver uuid;
 v_row jsonb;
 v_task text;
 v_assignee uuid;
 v_number integer:=0;
begin
 v_staff:=private.current_staff_user_id();
 if v_staff is null or not private.can_manage_cases() then
  raise exception '您沒有使用訊息交辦的權限';
 end if;
 if p_description is null or char_length(btrim(p_description)) not between 1 and 5000 then
  raise exception '請填寫訊息說明（最多5000字）';
 end if;
 if p_tasks is null or jsonb_typeof(p_tasks)<>'array' or jsonb_array_length(p_tasks)>20 then
  raise exception '分工格式錯誤或超過20項';
 end if;
 foreach v_receiver in array coalesce(p_recipient_ids,array(
  select s.id from public.staff_users s where s.is_active
   and s.role in ('admin','organization_manager','business_manager','supervisor')
 )) loop
  if v_receiver is null or not exists(
   select 1 from public.staff_users s where s.id=v_receiver and s.is_active
    and s.role in ('admin','organization_manager','business_manager','supervisor')
  ) then raise exception '通知對象包含無效帳號';end if;
 end loop;
 insert into public.team_messages(description,created_by_staff_id)
  values (btrim(p_description),v_staff) returning id into v_id;
 insert into public.team_message_recipients(message_id,staff_id,read_at)
  values(v_id,v_staff,null);
 foreach v_receiver in array coalesce(p_recipient_ids,array(
  select s.id from public.staff_users s where s.is_active
   and s.role in ('admin','organization_manager','business_manager','supervisor')
 )) loop
  insert into public.team_message_recipients(message_id,staff_id)
   values(v_id,v_receiver) on conflict do nothing;
 end loop;
 for v_row in select value from jsonb_array_elements(p_tasks) loop
  v_number:=v_number+1;
  v_task:=btrim(coalesce(v_row->>'description',''));
  if char_length(v_task) not between 1 and 1000 then
   raise exception '第%項分工內容不可空白，最多1000字',v_number;
  end if;
  if coalesce(v_row->>'assignee_staff_id','') !~* '^[0-9a-f-]{36}$' then
   raise exception '第%項分工尚未指定承辦人',v_number;
  end if;
  v_assignee:=(v_row->>'assignee_staff_id')::uuid;
  if not exists(select 1 from public.staff_users s where s.id=v_assignee and s.is_active
   and s.role in ('admin','organization_manager','business_manager','supervisor')) then
   raise exception '第%項分工承辦人無效',v_number;
  end if;
  insert into public.team_message_tasks(message_id,description,assignee_staff_id,sort_order)
   values (v_id,v_task,v_assignee,v_number);
  insert into public.team_message_recipients(message_id,staff_id)
   values(v_id,v_assignee) on conflict do nothing;
 end loop;
 return v_id;
end $function$

CREATE OR REPLACE FUNCTION public.team_message_attention_count()
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
select case when not private.can_manage_cases() then 0 else
 (
  select count(*)::integer from (
   select t.message_id
   from public.team_message_tasks t
   join public.team_messages m on m.id=t.message_id
   where m.closed_at is null
     and t.cancelled_at is null
     and t.assignee_staff_id=private.current_staff_user_id()
     and not t.is_done
   union
   select m.id
   from public.team_messages m
   where m.closed_at is null
     and m.created_by_staff_id=private.current_staff_user_id()
     and exists (select 1 from public.team_message_tasks t where t.message_id=m.id)
     and (
      not exists (
       select 1 from public.team_message_tasks t
       where t.message_id=m.id and t.cancelled_at is null and not t.is_done
      )
      or exists (
       select 1 from public.team_message_tasks t
       where t.message_id=m.id and t.cancelled_at is null and t.assistance_needed
      )
     )
  ) attention_messages
 )
end;
$function$

CREATE OR REPLACE FUNCTION public.team_message_edit_help(p_task_id uuid, p_note text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_actor uuid;
 v_assignee uuid;
 v_creator uuid;
 v_mid uuid;
 v_update_id uuid;
 v_note text:=btrim(coalesce(p_note,''));
 v_old_note text;
 v_description text;
 v_help boolean;
 v_instruction boolean;
 v_done boolean;
 v_cancelled timestamptz;
 v_closed timestamptz;
 v_updated uuid;
begin
 v_actor:=private.current_staff_user_id();
 if v_actor is null or not private.can_manage_cases() then
  raise exception '沒有操作訊息交辦的權限';
 end if;
 select t.message_id,t.assignee_staff_id,m.created_by_staff_id,
        t.help_update_id,t.help_note,t.description,
        t.assistance_needed,t.instruction_pending,t.is_done,t.cancelled_at,m.closed_at
 into v_mid,v_assignee,v_creator,v_update_id,v_old_note,v_description,
      v_help,v_instruction,v_done,v_cancelled,v_closed
 from public.team_message_tasks t
 join public.team_messages m on m.id=t.message_id
 where t.id=p_task_id
 for update of t,m;
 if not found then raise exception '分工不存在';end if;
 if v_actor<>v_assignee then raise exception '只有原承辦人能修改自己的執行困難';end if;
 if v_closed is not null or v_cancelled is not null or v_done or not v_help or v_instruction then
  raise exception '建立者已回覆，或分工已完成、取消、結案，不能再修改原困難';
 end if;
 if char_length(v_note) not between 1 and 1700 then
  raise exception '執行困難說明不可空白，最多1700字';
 end if;
 if v_update_id is null or v_old_note is null then
  raise exception '找不到本次執行困難的原始歷程，請聯繫管理者';
 end if;
 if v_note=v_old_note then raise exception '執行困難說明沒有變更';end if;
 update public.team_message_updates u
 set body='【執行困難｜'||left(v_description,110)||'】'||E'\n'||v_note
 where u.id=v_update_id and u.message_id=v_mid and u.staff_id=v_assignee
   and u.is_system and u.voided_at is null
 returning u.id into v_updated;
 if v_updated is null then raise exception '原始執行困難紀錄不存在或無法修改';end if;
 update public.team_message_tasks set help_note=v_note where id=p_task_id;
 update public.team_message_recipients
 set read_at=null where message_id=v_mid and staff_id=v_creator;
 return v_mid;
end;
$function$

CREATE OR REPLACE FUNCTION public.team_message_manage_event(p_message_id uuid, p_action text, p_description text DEFAULT NULL::text, p_notify boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_actor uuid;
 v_owner uuid;
 v_closed timestamptz;
 v_old_text text;
 v_new_text text;
 v_history text;
begin
 v_actor:=private.current_staff_user_id();
 if v_actor is null or not private.can_manage_cases() then
  raise exception '沒有操作訊息交辦的權限';
 end if;
 select created_by_staff_id,closed_at,description
 into v_owner,v_closed,v_old_text
 from public.team_messages
 where id=p_message_id
 for update;
 if not found then raise exception '訊息不存在';end if;
 if v_owner<>v_actor then raise exception '僅事件建立者可以操作';end if;

 if p_action='edit' then
  if v_closed is not null then raise exception '請先重新開啟已結案事件';end if;
  v_new_text:=btrim(coalesce(p_description,''));
  if char_length(v_new_text) not between 1 and 5000 then
   raise exception '事件內容不可空白，最多5000字';
  end if;
  if v_new_text=v_old_text then raise exception '內容沒有變更';end if;

  update public.team_messages set description=v_new_text where id=p_message_id;
  if coalesce(p_notify,true) then
   update public.team_message_recipients set read_at=null where message_id=p_message_id;
  end if;
  v_history:=case when coalesce(p_notify,true) then '【修改事件內容｜已通知閱讀對象】'
                  else '【修改事件內容｜未通知】' end
             ||E'\n原內容：'||v_old_text||E'\n新內容：'||v_new_text;

 elsif p_action='reopen' then
  if v_closed is null then raise exception '此事件尚未結案';end if;
  update public.team_messages set closed_at=null where id=p_message_id;
  v_history:='【重新開啟事件】本事件由建立者重新開啟，原分工狀態維持不變。';
 else
  raise exception '未知的事件操作';
 end if;

 insert into public.team_message_updates(message_id,staff_id,body,is_system)
 values(p_message_id,v_actor,v_history,true);
 return p_message_id;
end;
$function$

CREATE OR REPLACE FUNCTION public.team_message_manage_task(p_task_id uuid, p_action text, p_description text DEFAULT NULL::text, p_assignee_staff_id uuid DEFAULT NULL::uuid, p_notify boolean DEFAULT true, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_actor uuid;
 v_mid uuid;
 v_owner uuid;
 v_closed timestamptz;
 v_cancelled timestamptz;
 v_old_description text;
 v_old_assignee uuid;
 v_new_assignee uuid;
 v_new_description text;
 v_old_name text;
 v_new_name text;
 v_change_person boolean;
 v_change_text boolean;
 v_notify boolean;
 v_reason text:=btrim(coalesce(p_reason,''));
 v_note text;
begin
 v_actor:=private.current_staff_user_id();
 if v_actor is null or not private.can_manage_cases() then raise exception '沒有操作訊息交辦的權限';end if;

 select t.message_id,m.created_by_staff_id,m.closed_at,t.cancelled_at,t.description,t.assignee_staff_id
 into v_mid,v_owner,v_closed,v_cancelled,v_old_description,v_old_assignee
 from public.team_message_tasks t
 join public.team_messages m on m.id=t.message_id
 where t.id=p_task_id for update of t,m;
 if not found then raise exception '分工不存在';end if;
 if v_owner<>v_actor then raise exception '僅建立者可編輯或取消分工';end if;
 if v_closed is not null then raise exception '已結案事件不可修改分工';end if;
 if v_cancelled is not null then raise exception '已取消的分工不可再修改';end if;

 if p_action='edit' then
   v_new_description:=btrim(coalesce(p_description,''));
   v_new_assignee:=p_assignee_staff_id;
   if char_length(v_new_description) not between 1 and 1000 then raise exception '交辦內容不可空白，最多1000字';end if;
   if v_new_assignee is null or not exists(
     select 1 from public.staff_users s where s.id=v_new_assignee and s.is_active
       and s.role in ('admin','organization_manager','business_manager','supervisor')
   ) then raise exception '請選擇有效承辦人';end if;
   v_change_text:=v_new_description is distinct from v_old_description;
   v_change_person:=v_new_assignee is distinct from v_old_assignee;
   if not (v_change_text or v_change_person) then raise exception '分工內容與承辦人皆未更動';end if;
   v_notify:=coalesce(p_notify,true) or v_change_person;
   select display_name into v_old_name from public.staff_users where id=v_old_assignee;
   select display_name into v_new_name from public.staff_users where id=v_new_assignee;
   update public.team_message_tasks set
     description=v_new_description,
     assignee_staff_id=v_new_assignee,
     is_done=case when v_notify then false else is_done end,
     assistance_needed=case when v_notify then false else assistance_needed end,
     instruction_pending=case when v_notify then true else instruction_pending end
   where id=p_task_id;
   if v_change_person then
     insert into public.team_message_recipients(message_id,staff_id)
     values(v_mid,v_new_assignee) on conflict do nothing;
   end if;
   v_note:=case when v_change_person then
      '【改派分工】'||left(coalesce(v_old_name,'原承辦人'),60)||' → '||left(coalesce(v_new_name,'新承辦人'),60)
      when v_notify then '【修改分工（有新指示）】'
      else '【分工文字修正（不通知）】' end
     ||E'\n原內容：'||left(v_old_description,720)
     ||E'\n新內容：'||left(v_new_description,720);
 elsif p_action='cancel' then
   if char_length(v_reason)>500 then raise exception '取消分工原因不可超過500字';end if;
   update public.team_message_tasks set
     cancelled_at=now(),cancelled_by_staff_id=v_actor,cancel_reason=nullif(v_reason,''),
     is_done=false,assistance_needed=false,instruction_pending=false
   where id=p_task_id;
   v_note:='【取消分工｜'||left(v_old_description,220)||'】'||case when v_reason<>'' then E'\n原因：'||v_reason else '' end;
 else raise exception '未知的分工管理操作';
 end if;

 insert into public.team_message_updates(message_id,staff_id,body,is_system)
 values(v_mid,v_actor,left(v_note,2000),true);
 return v_mid;
end;
$function$

CREATE OR REPLACE FUNCTION public.team_message_task_action(p_task_id uuid, p_action text, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_actor uuid;
 v_mid uuid;
 v_assignee uuid;
 v_assignee_name text;
 v_creator uuid;
 v_closed timestamptz;
 v_done boolean;
 v_help boolean;
 v_instruction boolean;
 v_cancelled timestamptz;
 v_description text;
 v_note text:=btrim(coalesce(p_note,''));
 v_audit text;
 v_audit_id uuid;
begin
 v_actor:=private.current_staff_user_id();
 if v_actor is null or not private.can_manage_cases() then raise exception '沒有操作訊息交辦的權限';end if;
 select t.message_id,t.assignee_staff_id,m.created_by_staff_id,m.closed_at,
        t.is_done,t.assistance_needed,t.instruction_pending,t.cancelled_at,t.description,
        s.display_name
 into v_mid,v_assignee,v_creator,v_closed,v_done,v_help,v_instruction,v_cancelled,v_description,v_assignee_name
 from public.team_message_tasks t
 join public.team_messages m on m.id=t.message_id
 left join public.staff_users s on s.id=t.assignee_staff_id
 where t.id=p_task_id
 for update of t,m;
 if not found then raise exception '分工不存在';end if;
 if v_closed is not null then raise exception '結案後不得修改分工';end if;
 if v_cancelled is not null then raise exception '已取消的分工不可再操作';end if;
 if p_action='request_help' then
   if v_actor<>v_assignee or v_done or v_help or v_instruction then
     raise exception '只有尚未完成且沒有新指示待確認的承辦人可回報執行困難';
   end if;
   if char_length(v_note) not between 1 and 1700 then raise exception '請填寫執行困難原因';end if;
   update public.team_message_tasks set assistance_needed=true,instruction_pending=false where id=p_task_id;
   v_audit:='【執行困難｜'||left(v_description,110)||'】'||E'\n'||v_note;
 elsif p_action='guide' then
   if v_actor<>v_creator or not v_help then raise exception '只有建立者可對執行困難提供新指示';end if;
   if char_length(v_note) not between 1 and 1700 then raise exception '請填寫新指示';end if;
   update public.team_message_tasks set assistance_needed=false,instruction_pending=true where id=p_task_id;
   v_audit:='【新指示｜'||left(v_description,110)||'】'||E'\n'||v_note;
 elsif p_action='redo' then
   if v_actor<>v_creator or not v_done then raise exception '只有建立者可將已完成分工退回重辦';end if;
   if char_length(v_note) not between 1 and 1700 then raise exception '請填寫退回重辦的指示';end if;
   update public.team_message_tasks set is_done=false,assistance_needed=false,instruction_pending=true where id=p_task_id;
   v_audit:='【退回重辦｜'||left(v_description,110)||'】'||E'\n'||v_note;
 elsif p_action='ack' then
   if v_actor<>v_assignee or not v_instruction then raise exception '沒有待確認的新指示';end if;
   update public.team_message_tasks set instruction_pending=false where id=p_task_id;
 elsif p_action='complete' then
   if v_done then raise exception '此項分工已完成';end if;
   if v_help or v_instruction then raise exception '執行困難或新指示待確認時，不能勾選完成';end if;
   update public.team_message_tasks set is_done=true where id=p_task_id;
   v_audit:='【分工完成｜'||left(v_description,220)||'】（承辦人：'||left(coalesce(v_assignee_name,'原承辦人'),70)||'）';
 elsif p_action='reopen' then
   if not v_done then raise exception '此項分工尚未完成';end if;
   update public.team_message_tasks set is_done=false where id=p_task_id;
   v_audit:='【取消完成勾選｜'||left(v_description,220)||'】（承辦人：'||left(coalesce(v_assignee_name,'原承辦人'),70)||'）';
 else
   raise exception '未知分工操作';
 end if;
 if v_audit is not null then
   insert into public.team_message_updates(message_id,staff_id,body,is_system)
   values(v_mid,v_actor,v_audit,true) returning id into v_audit_id;
   if p_action='request_help' then
     update public.team_message_tasks
       set help_note=v_note,help_update_id=v_audit_id where id=p_task_id;
   end if;
 end if;
 return v_mid;
end;
$function$

CREATE OR REPLACE FUNCTION public.void_team_message_update(p_update_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_actor uuid;
 v_author uuid;
 v_owner uuid;
 v_mid uuid;
 v_system boolean;
 v_void timestamptz;
begin
 v_actor:=private.current_staff_user_id();
 if v_actor is null or not private.can_manage_cases() then raise exception '沒有操作訊息交辦的權限';end if;
 select u.message_id,u.staff_id,u.is_system,u.voided_at,m.created_by_staff_id
 into v_mid,v_author,v_system,v_void,v_owner
 from public.team_message_updates u join public.team_messages m on m.id=u.message_id
 where u.id=p_update_id for update of u;
 if not found then raise exception '回報不存在';end if;
 if v_system then raise exception '系統操作歷程不可作廢';end if;
 if v_void is not null then raise exception '這筆回報已作廢';end if;
 if v_actor<>v_author and v_actor<>v_owner then raise exception '只有原輸入者或事件建立者可作廢';end if;
 update public.team_message_updates set voided_at=now(),voided_by_staff_id=v_actor where id=p_update_id;
 return v_mid;
end;
$function$


-- Protect RPCs from anonymous execution; permit only authenticated.
REVOKE ALL ON FUNCTION public.add_team_message_task(uuid,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_team_message_task(uuid,text,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.create_team_message(text,jsonb,uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_team_message(text,jsonb,uuid[]) TO authenticated;
REVOKE ALL ON FUNCTION public.team_message_attention_count() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.team_message_attention_count() TO authenticated;
REVOKE ALL ON FUNCTION public.team_message_edit_help(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.team_message_edit_help(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.team_message_manage_event(uuid,text,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.team_message_manage_event(uuid,text,text,boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.team_message_manage_task(uuid,text,text,uuid,boolean,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.team_message_manage_task(uuid,text,text,uuid,boolean,text) TO authenticated;
REVOKE ALL ON FUNCTION public.team_message_task_action(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.team_message_task_action(uuid,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.void_team_message_update(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.void_team_message_update(uuid) TO authenticated;
