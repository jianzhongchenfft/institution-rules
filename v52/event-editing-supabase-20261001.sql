-- 事件追蹤：已送出紀錄可編輯＋可調整填表時間
-- 測試環境套用日期：2026-10-01
-- 注意：created_at / submitted_at 保留為系統稽核時間，不作為一般畫面與列印的填表時間。

begin;

alter table public.tracking_event_initial_reports
  add column if not exists form_filled_at timestamptz;
alter table public.tracking_event_followups
  add column if not exists form_filled_at timestamptz;
alter table public.tracking_event_closures
  add column if not exists form_filled_at timestamptz;

update public.tracking_event_initial_reports
set form_filled_at=coalesce(submitted_at,created_at,now())
where form_filled_at is null;
update public.tracking_event_followups
set form_filled_at=coalesce(created_at,now())
where form_filled_at is null;
update public.tracking_event_closures
set form_filled_at=coalesce(created_at,now())
where form_filled_at is null;

alter table public.tracking_event_initial_reports
  alter column form_filled_at set default now(),
  alter column form_filled_at set not null;
alter table public.tracking_event_followups
  alter column form_filled_at set default now(),
  alter column form_filled_at set not null;
alter table public.tracking_event_closures
  alter column form_filled_at set default now(),
  alter column form_filled_at set not null;

CREATE OR REPLACE FUNCTION public.save_tracking_event_draft(payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event_id uuid := nullif(payload->>'event_id','')::uuid;
  v_staff_id uuid := private.current_staff_user_id();
  v_responsible uuid := coalesce(nullif(payload->>'responsible_staff_id','')::uuid, v_staff_id);
  v_category text := nullif(btrim(payload->>'category'),'');
  v_subject text := nullif(btrim(payload->>'subject'),'');
  v_form_filled_at timestamptz := coalesce(nullif(payload->>'form_filled_at','')::timestamptz, now());
begin
  if (select auth.uid()) is null or v_staff_id is null or not private.can_use_tracking_events() then
    raise exception '沒有事件追蹤權限' using errcode='42501';
  end if;
  if nullif(payload->>'event_date','') is null then raise exception '事件日期為必填'; end if;
  if v_category is null then raise exception '事件類別為必填'; end if;
  if v_category not in ('異常事件','居服員事件','服務暫停','居服回報','服務轉介','意見申訴','家庭／照顧風險','性騷擾','性侵害','其他') then
    raise exception '事件類別不正確';
  end if;
  if v_subject is null then raise exception '主旨為必填'; end if;
  if not exists(
    select 1
    from public.staff_users s
    where s.id=v_responsible
      and s.is_active=true
      and s.role in ('supervisor','business_manager','organization_manager','admin')
  ) then
    raise exception '負責追蹤人不正確';
  end if;

  perform private.validate_tracking_sensitive_payload(payload,v_category);

  if v_event_id is null then
    insert into public.tracking_events(
      event_date,event_time,category,subject,case_id,care_worker_id,reporter_type,reporter_name,
      registered_by_staff_id,responsible_staff_id,status,requires_followup,next_followup_date,
      tracking_note,is_sensitive,created_by
    ) values (
      (payload->>'event_date')::date,
      nullif(payload->>'event_time','')::time,
      v_category,v_subject,
      nullif(payload->>'case_id','')::uuid,
      nullif(payload->>'care_worker_id','')::uuid,
      nullif(payload->>'reporter_type',''),
      nullif(btrim(payload->>'reporter_name'),''),
      v_staff_id,v_responsible,'draft',
      coalesce(nullif(payload->>'requires_followup','')::boolean,true),
      nullif(payload->>'next_followup_date','')::date,
      nullif(btrim(payload->>'tracking_note'),''),
      v_category in ('性騷擾','性侵害'),
      (select auth.uid())
    ) returning id into v_event_id;

    insert into public.tracking_event_initial_reports(
      event_id,event_description,completed_actions,pending_tasks,line_notify,line_notify_status,form_filled_at
    ) values (
      v_event_id,
      coalesce(payload->>'event_description',''),
      coalesce(payload->>'completed_actions',''),
      coalesce(payload->>'pending_tasks',''),
      coalesce(nullif(payload->>'line_notify','')::boolean,true),
      'draft',
      v_form_filled_at
    );
  else
    if not exists(
      select 1
      from public.tracking_events e
      where e.id=v_event_id
        and e.status='draft'
        and (
          e.registered_by_staff_id=v_staff_id
          or private.can_manage_sensitive_tracking_events()
        )
    ) then
      raise exception '只有建立人或管理人員可以修改此草稿';
    end if;

    update public.tracking_events
    set event_date=(payload->>'event_date')::date,
        event_time=nullif(payload->>'event_time','')::time,
        category=v_category,
        subject=v_subject,
        case_id=nullif(payload->>'case_id','')::uuid,
        care_worker_id=nullif(payload->>'care_worker_id','')::uuid,
        reporter_type=nullif(payload->>'reporter_type',''),
        reporter_name=nullif(btrim(payload->>'reporter_name'),''),
        responsible_staff_id=v_responsible,
        requires_followup=coalesce(nullif(payload->>'requires_followup','')::boolean,true),
        next_followup_date=nullif(payload->>'next_followup_date','')::date,
        tracking_note=nullif(btrim(payload->>'tracking_note'),''),
        is_sensitive=v_category in ('性騷擾','性侵害')
    where id=v_event_id;

    update public.tracking_event_initial_reports
    set event_description=coalesce(payload->>'event_description',''),
        completed_actions=coalesce(payload->>'completed_actions',''),
        pending_tasks=coalesce(payload->>'pending_tasks',''),
        line_notify=coalesce(nullif(payload->>'line_notify','')::boolean,true),
        form_filled_at=v_form_filled_at,
        updated_at=now()
    where event_id=v_event_id;
  end if;

  perform private.save_tracking_sensitive_details(v_event_id,v_category,payload);

  return v_event_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.submit_tracking_event(p_event_id uuid, p_target_status text DEFAULT 'pending_followup'::text, p_line_notify boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  e public.tracking_events%rowtype;
  r public.tracking_event_initial_reports%rowtype;
  v_staff_id uuid := private.current_staff_user_id();
  v_staff_name text := private.current_staff_user_name();
  v_case_name text;
  v_worker_name text;
  v_message text;
begin
  if (select auth.uid()) is null or v_staff_id is null then
    raise exception 'authentication required' using errcode='42501';
  end if;

  select * into e
  from public.tracking_events
  where id=p_event_id
  for update;

  if not found or not private.can_edit_tracking_event(p_event_id) then
    raise exception '沒有處理此事件的權限' using errcode='42501';
  end if;
  if e.status <> 'draft' then raise exception '只有草稿可以送出初報'; end if;
  if p_target_status not in ('pending_followup','pending_close') then
    raise exception '初報送出狀態不正確';
  end if;

  select * into r
  from public.tracking_event_initial_reports
  where event_id=p_event_id
  for update;

  if btrim(coalesce(r.event_description,''))='' then raise exception '事件說明為必填'; end if;
  if btrim(coalesce(r.completed_actions,''))='' then raise exception '已完成處置為必填'; end if;
  if btrim(coalesce(r.pending_tasks,''))='' then raise exception '後續待辦為必填'; end if;
  if p_target_status='pending_followup' and e.requires_followup and e.next_followup_date is null then
    raise exception '需要後續追蹤時，請填寫下次追蹤日期';
  end if;

  perform private.validate_tracking_sensitive_submission(p_event_id,e.category);

  update public.tracking_event_initial_reports
  set submitted_by_staff_id=v_staff_id,
      submitted_by=(select auth.uid()),
      submitted_at=now(),
      form_filled_at=coalesce(form_filled_at,now()),
      line_notify=p_line_notify,
      line_notify_status=case when p_line_notify then 'queued' else 'skipped' end,
      updated_at=now()
  where event_id=p_event_id
  returning * into r;

  update public.tracking_events
  set status=p_target_status,
      next_followup_date=case when p_target_status='pending_followup' then next_followup_date else null end,
      requires_followup=(p_target_status='pending_followup')
  where id=p_event_id;

  insert into public.tracking_event_history(
    event_id,action_type,actor_staff_id,from_status,to_status,note
  )
  values(
    p_event_id,'initial_submitted',v_staff_id,'draft',p_target_status,'送出初報'
  );

  if p_line_notify then
    if e.is_sensitive then
      v_message := format(
        '🟠【新增敏感事件通知】%s事件類別：%s%s登錄人：%s%s日期：%s%s請至內部管理系統查看。',
        chr(10),e.category,chr(10),coalesce(v_staff_name,'—'),
        chr(10),to_char(e.event_date,'YYYY/MM/DD'),chr(10)
      );
    else
      select c.case_name into v_case_name
      from public.care_cases c
      where c.id=e.case_id;

      select w.worker_name into v_worker_name
      from public.care_workers w
      where w.id=e.care_worker_id;

      v_message := format(
        '🟠【新增事件追蹤通知】%s類別：%s%s登錄人：%s%s日期：%s%s主旨：%s%s個案／居服員：%s%s事件說明：%s%s已完成處置：%s%s後續待辦：%s',
        chr(10),e.category,chr(10),coalesce(v_staff_name,'—'),
        chr(10),to_char(e.event_date,'YYYY/MM/DD'),chr(10),e.subject,chr(10),
        concat_ws('／',nullif(v_case_name,''),nullif(v_worker_name,'')),
        chr(10),r.event_description,chr(10),r.completed_actions,chr(10),r.pending_tasks
      );
    end if;

    insert into public.tracking_event_line_queue(
      event_id,record_type,record_id,message_text
    )
    values(
      p_event_id,'initial',r.id,v_message
    );
  end if;

  return r.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.add_tracking_event_followup(payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event_id uuid := nullif(payload->>'event_id','')::uuid;
  e public.tracking_events%rowtype;
  v_id uuid;
  v_staff_id uuid := private.current_staff_user_id();
  v_staff_name text := private.current_staff_user_name();
  v_outcome text := nullif(payload->>'outcome','');
  v_line boolean := coalesce(nullif(payload->>'line_notify','')::boolean,true);
  v_method text := nullif(payload->>'followup_method','');
  v_latest text := nullif(btrim(payload->>'latest_status'),'');
  v_completed text := coalesce(payload->>'completed_actions','');
  v_pending text := coalesce(payload->>'pending_tasks','');
  v_next date := nullif(payload->>'next_followup_date','')::date;
  v_form_filled_at timestamptz := coalesce(nullif(payload->>'form_filled_at','')::timestamptz, now());
  v_message text;
begin
  if (select auth.uid()) is null or v_staff_id is null then
    raise exception 'authentication required' using errcode='42501';
  end if;

  select * into e
  from public.tracking_events
  where id=v_event_id
  for update;

  if not found or not private.can_edit_tracking_event(v_event_id) then
    raise exception '沒有處理此事件的權限' using errcode='42501';
  end if;
  if e.status in ('draft','closed','voided') then
    raise exception '目前事件狀態不能新增續報';
  end if;
  if nullif(payload->>'followup_date','') is null then
    raise exception '追蹤日期為必填';
  end if;
  if v_method not in ('phone','official_line','home_visit','interview','care_worker_report','case_manager_contact','other') then
    raise exception '追蹤方式不正確';
  end if;
  if v_latest is null then
    raise exception '最新狀況為必填';
  end if;
  if v_outcome not in ('continue','ready_to_close') then
    raise exception '請選擇目前事件處理狀態';
  end if;
  if v_outcome='continue' and v_next is null then
    raise exception '繼續追蹤時請填寫下次追蹤日期';
  end if;

  insert into public.tracking_event_followups(
    event_id,followup_date,followup_time,followup_method,latest_status,completed_actions,pending_tasks,
    outcome,next_followup_date,submitted_by_staff_id,submitted_by,line_notify,line_notify_status,
    prior_event_status,prior_next_followup_date,prior_requires_followup,prior_tracking_note,form_filled_at
  ) values(
    v_event_id,(payload->>'followup_date')::date,nullif(payload->>'followup_time','')::time,v_method,v_latest,v_completed,v_pending,
    v_outcome,v_next,v_staff_id,(select auth.uid()),v_line,case when v_line then 'queued' else 'skipped' end,
    e.status,e.next_followup_date,e.requires_followup,e.tracking_note,v_form_filled_at
  ) returning id into v_id;

  update public.tracking_events
  set status=case when v_outcome='ready_to_close' then 'pending_close' else 'tracking' end,
      requires_followup=(v_outcome='continue'),
      next_followup_date=case when v_outcome='continue' then v_next else null end,
      tracking_note=case when v_outcome='continue' then nullif(btrim(v_pending),'') else null end
  where id=v_event_id;

  insert into public.tracking_event_history(event_id,action_type,actor_staff_id,note)
  values(v_event_id,'followup_added',v_staff_id,'新增續報');

  if v_line then
    if e.is_sensitive then
      v_message := format('🔵【敏感事件續報通知】%s事件類別：%s%s追蹤人：%s%s請至內部管理系統查看。',
        chr(10),e.category,chr(10),coalesce(v_staff_name,'—'),chr(10));
    else
      v_message := format('🔵【事件續報】%s主旨：%s%s最新狀況：%s%s本次已完成處置：%s%s後續待辦：%s',
        chr(10),e.subject,chr(10),v_latest,chr(10),v_completed,chr(10),v_pending);
    end if;
    insert into public.tracking_event_line_queue(event_id,record_type,record_id,message_text)
    values(v_event_id,'followup',v_id,v_message);
  end if;

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.close_tracking_event(payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event_id uuid := nullif(payload->>'event_id','')::uuid;
  e public.tracking_events%rowtype;
  v_id uuid;
  v_staff_id uuid := private.current_staff_user_id();
  v_staff_name text := private.current_staff_user_name();
  v_final text := nullif(btrim(payload->>'final_status'),'');
  v_decision text := nullif(btrim(payload->>'closure_decision'),'');
  v_line boolean := coalesce(nullif(payload->>'line_notify','')::boolean,true);
  v_form_filled_at timestamptz := coalesce(nullif(payload->>'form_filled_at','')::timestamptz, now());
  v_message text;
begin
  if (select auth.uid()) is null or v_staff_id is null then raise exception 'authentication required' using errcode='42501'; end if;
  select * into e from public.tracking_events where id=v_event_id for update;
  if not found or not private.can_edit_tracking_event(v_event_id) then raise exception '沒有處理此事件的權限' using errcode='42501'; end if;
  if e.status <> 'pending_close' then raise exception '事件需先進入待結報狀態'; end if;
  if nullif(payload->>'close_date','') is null then raise exception '結報日期為必填'; end if;
  if v_final is null then raise exception '結案說明為必填'; end if;
  if v_decision is null then raise exception '結案判定為必填'; end if;

  insert into public.tracking_event_closures(
    event_id,close_date,final_status,closure_decision,closed_by_staff_id,closed_by,line_notify,line_notify_status,form_filled_at
  ) values(
    v_event_id,(payload->>'close_date')::date,v_final,v_decision,v_staff_id,(select auth.uid()),v_line,
    case when v_line then 'queued' else 'skipped' end,v_form_filled_at
  ) returning id into v_id;

  update public.tracking_events
  set status='closed',requires_followup=false,next_followup_date=null,tracking_note=null,closed_at=now()
  where id=v_event_id;

  insert into public.tracking_event_history(event_id,action_type,actor_staff_id,note)
  values(v_event_id,'closure_added',v_staff_id,'完成結報');

  if v_line then
    if e.is_sensitive then
      v_message := format('🟢【敏感事件結報通知】%s事件類別：%s%s結報人：%s%s請至內部管理系統查看。',
        chr(10),e.category,chr(10),coalesce(v_staff_name,'—'),chr(10));
    else
      v_message := format('🟢【事件結報】%s主旨：%s%s結案判定：%s%s結案說明：%s',
        chr(10),e.subject,chr(10),v_decision,chr(10),v_final);
    end if;
    insert into public.tracking_event_line_queue(event_id,record_type,record_id,message_text)
    values(v_event_id,'closure',v_id,v_message);
  end if;
  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_tracking_event_initial_report(payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event_id uuid := nullif(payload->>'event_id','')::uuid;
  e public.tracking_events%rowtype;
  r public.tracking_event_initial_reports%rowtype;
  v_staff_id uuid := private.current_staff_user_id();
  v_responsible uuid := nullif(payload->>'responsible_staff_id','')::uuid;
  v_category text := nullif(btrim(payload->>'category'),'');
  v_subject text := nullif(btrim(payload->>'subject'),'');
  v_form_filled_at timestamptz;
begin
  if (select auth.uid()) is null or v_staff_id is null then
    raise exception 'authentication required' using errcode='42501';
  end if;

  select * into e
  from public.tracking_events
  where id=v_event_id
  for update;

  if not found or not private.can_edit_tracking_event(v_event_id) then
    raise exception '沒有處理此事件的權限' using errcode='42501';
  end if;

  select * into r
  from public.tracking_event_initial_reports
  where event_id=v_event_id
  for update;

  if not found then raise exception '找不到初報紀錄'; end if;
  if nullif(payload->>'event_date','') is null then raise exception '事件日期為必填'; end if;
  if v_category is null or v_category not in ('異常事件','居服員事件','服務暫停','居服回報','服務轉介','意見申訴','家庭／照顧風險','性騷擾','性侵害','其他') then
    raise exception '事件類別不正確';
  end if;
  if v_subject is null then raise exception '主旨為必填'; end if;
  if nullif(btrim(payload->>'event_description'),'') is null then raise exception '事件說明為必填'; end if;
  if nullif(btrim(payload->>'completed_actions'),'') is null then raise exception '已完成處置為必填'; end if;
  if nullif(btrim(payload->>'pending_tasks'),'') is null then raise exception '後續待辦為必填'; end if;

  v_responsible := coalesce(v_responsible,e.responsible_staff_id);
  if not exists(
    select 1 from public.staff_users s
    where s.id=v_responsible and s.is_active=true
      and s.role in ('supervisor','business_manager','organization_manager','admin')
  ) then
    raise exception '負責追蹤人不正確';
  end if;

  perform private.validate_tracking_sensitive_payload(payload,v_category);
  v_form_filled_at := coalesce(nullif(payload->>'form_filled_at','')::timestamptz,r.form_filled_at,now());

  update public.tracking_events
  set event_date=(payload->>'event_date')::date,
      event_time=nullif(payload->>'event_time','')::time,
      category=v_category,
      subject=v_subject,
      case_id=nullif(payload->>'case_id','')::uuid,
      care_worker_id=nullif(payload->>'care_worker_id','')::uuid,
      reporter_type=nullif(payload->>'reporter_type',''),
      reporter_name=nullif(btrim(payload->>'reporter_name'),''),
      responsible_staff_id=v_responsible,
      is_sensitive=v_category in ('性騷擾','性侵害'),
      updated_at=now()
  where id=v_event_id;

  update public.tracking_event_initial_reports
  set event_description=payload->>'event_description',
      completed_actions=payload->>'completed_actions',
      pending_tasks=payload->>'pending_tasks',
      form_filled_at=v_form_filled_at,
      updated_at=now()
  where event_id=v_event_id
  returning * into r;

  perform private.save_tracking_sensitive_details(v_event_id,v_category,payload);

  insert into public.tracking_event_history(event_id,action_type,actor_staff_id,note)
  values(v_event_id,'initial_edited',v_staff_id,'修改初報');

  return r.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_tracking_event_followup(payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_followup_id uuid := nullif(payload->>'followup_id','')::uuid;
  f public.tracking_event_followups%rowtype;
  e public.tracking_events%rowtype;
  v_staff_id uuid := private.current_staff_user_id();
  v_method text := nullif(payload->>'followup_method','');
  v_latest text := nullif(btrim(payload->>'latest_status'),'');
  v_form_filled_at timestamptz;
  v_is_latest boolean := false;
begin
  if (select auth.uid()) is null or v_staff_id is null then
    raise exception 'authentication required' using errcode='42501';
  end if;

  select * into f
  from public.tracking_event_followups
  where id=v_followup_id
  for update;

  if not found then raise exception '找不到續報紀錄'; end if;
  if f.is_voided then raise exception '已作廢續報不可修改'; end if;

  select * into e
  from public.tracking_events
  where id=f.event_id
  for update;

  if not found or not private.can_edit_tracking_event(e.id) then
    raise exception '沒有處理此事件的權限' using errcode='42501';
  end if;
  if nullif(payload->>'followup_date','') is null then raise exception '追蹤日期為必填'; end if;
  if v_method not in ('phone','official_line','home_visit','interview','care_worker_report','case_manager_contact','other') then
    raise exception '追蹤方式不正確';
  end if;
  if v_latest is null then raise exception '最新狀況為必填'; end if;

  v_form_filled_at := coalesce(nullif(payload->>'form_filled_at','')::timestamptz,f.form_filled_at,f.created_at,now());

  update public.tracking_event_followups
  set followup_date=(payload->>'followup_date')::date,
      followup_time=nullif(payload->>'followup_time','')::time,
      followup_method=v_method,
      latest_status=v_latest,
      completed_actions=coalesce(payload->>'completed_actions',''),
      pending_tasks=coalesce(payload->>'pending_tasks',''),
      form_filled_at=v_form_filled_at
  where id=v_followup_id
  returning * into f;

  select exists(
    select 1
    from public.tracking_event_followups x
    where x.event_id=e.id and x.is_voided=false
      and x.id=v_followup_id
      and x.created_at=(
        select max(y.created_at)
        from public.tracking_event_followups y
        where y.event_id=e.id and y.is_voided=false
      )
  ) into v_is_latest;

  if v_is_latest and e.status='tracking' and f.outcome='continue' then
    update public.tracking_events
    set tracking_note=nullif(btrim(f.pending_tasks),''),
        updated_at=now()
    where id=e.id;
  end if;

  insert into public.tracking_event_history(event_id,action_type,actor_staff_id,note)
  values(e.id,'followup_edited',v_staff_id,'修改續報');

  return f.id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_tracking_event_closure(payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_closure_id uuid := nullif(payload->>'closure_id','')::uuid;
  c public.tracking_event_closures%rowtype;
  e public.tracking_events%rowtype;
  v_staff_id uuid := private.current_staff_user_id();
  v_final text := nullif(btrim(payload->>'final_status'),'');
  v_decision text := nullif(btrim(payload->>'closure_decision'),'');
  v_form_filled_at timestamptz;
begin
  if (select auth.uid()) is null or v_staff_id is null then
    raise exception 'authentication required' using errcode='42501';
  end if;

  select * into c
  from public.tracking_event_closures
  where id=v_closure_id
  for update;

  if not found then raise exception '找不到結報紀錄'; end if;

  select * into e
  from public.tracking_events
  where id=c.event_id
  for update;

  if not found or not private.can_edit_tracking_event(e.id) then
    raise exception '沒有處理此事件的權限' using errcode='42501';
  end if;
  if nullif(payload->>'close_date','') is null then raise exception '結報日期為必填'; end if;
  if v_decision is null then raise exception '結案判定為必填'; end if;
  if v_final is null then raise exception '結案說明為必填'; end if;

  v_form_filled_at := coalesce(nullif(payload->>'form_filled_at','')::timestamptz,c.form_filled_at,c.created_at,now());

  update public.tracking_event_closures
  set close_date=(payload->>'close_date')::date,
      closure_decision=v_decision,
      final_status=v_final,
      form_filled_at=v_form_filled_at
  where id=v_closure_id
  returning * into c;

  insert into public.tracking_event_history(event_id,action_type,actor_staff_id,note)
  values(e.id,'closure_edited',v_staff_id,'修改結報');

  return c.id;
end;
$function$
;

grant update (
  followup_date, followup_time, followup_method, latest_status,
  completed_actions, pending_tasks, form_filled_at
) on public.tracking_event_followups to authenticated;

drop policy if exists tracking_followups_content_update on public.tracking_event_followups;
create policy tracking_followups_content_update
on public.tracking_event_followups
for update to authenticated
using (private.can_edit_tracking_event(event_id) and is_voided=false)
with check (private.can_edit_tracking_event(event_id) and is_voided=false);

grant update (
  close_date, final_status, closure_decision, form_filled_at
) on public.tracking_event_closures to authenticated;

drop policy if exists tracking_closures_content_update on public.tracking_event_closures;
create policy tracking_closures_content_update
on public.tracking_event_closures
for update to authenticated
using (private.can_edit_tracking_event(event_id))
with check (private.can_edit_tracking_event(event_id));

revoke all on function public.update_tracking_event_initial_report(jsonb) from public;
revoke all on function public.update_tracking_event_followup(jsonb) from public;
revoke all on function public.update_tracking_event_closure(jsonb) from public;
grant execute on function public.update_tracking_event_initial_report(jsonb) to authenticated;
grant execute on function public.update_tracking_event_followup(jsonb) to authenticated;
grant execute on function public.update_tracking_event_closure(jsonb) to authenticated;

commit;
