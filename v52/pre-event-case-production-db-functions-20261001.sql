-- 正式版同步前資料庫函式快照
-- 2026-10-01

-- private.refresh_case_plan_current
CREATE OR REPLACE FUNCTION private.refresh_case_plan_current(p_case_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_current_plan_id uuid;
  v_current_plan_date date;
begin
  select cp.id, cp.plan_date
    into v_current_plan_id, v_current_plan_date
  from public.care_plans cp
  where cp.case_id=p_case_id
    and coalesce(cp.is_voided,false)=false
  order by
    (cp.plan_date is not null) desc,
    cp.plan_date desc nulls last,
    cp.created_at desc,
    cp.id desc
  limit 1;

  update public.care_plans
  set is_current=false
  where case_id=p_case_id and is_current=true;

  if v_current_plan_id is not null then
    update public.care_plans
    set is_current=true
    where id=v_current_plan_id;
  end if;

  update public.case_approved_services
  set is_current=false
  where case_id=p_case_id and is_current=true;

  if v_current_plan_id is not null then
    update public.case_approved_services
    set is_current=true
    where case_id=p_case_id and care_plan_id=v_current_plan_id;
  end if;

  update public.service_budgets
  set is_current=false
  where case_id=p_case_id and is_current=true;

  if v_current_plan_id is not null then
    update public.service_budgets
    set is_current=true
    where case_id=p_case_id and care_plan_id=v_current_plan_id;
  end if;

  update public.care_cases
  set current_plan_date=v_current_plan_date,
      updated_at=now()
  where id=p_case_id;

  return v_current_plan_id;
end;
$function$
;

-- public.save_tracking_event_draft
CREATE OR REPLACE FUNCTION public.save_tracking_event_draft(payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event_id uuid := nullif(payload->>'event_id','')::uuid;
  v_staff_id uuid := private.current_staff_user_id();
  v_responsible uuid := coalesce(nullif(payload->>'responsible_staff_id','')::uuid,v_staff_id);
  v_category text := nullif(btrim(payload->>'category'),'');
  v_subject text := nullif(btrim(payload->>'subject'),'');
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
    select 1 from public.staff_users s
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
      event_id,event_description,completed_actions,pending_tasks,line_notify,line_notify_status
    ) values (
      v_event_id,
      coalesce(payload->>'event_description',''),
      coalesce(payload->>'completed_actions',''),
      coalesce(payload->>'pending_tasks',''),
      coalesce(nullif(payload->>'line_notify','')::boolean,true),
      'draft'
    );
  else
    if not exists(
      select 1 from public.tracking_events e
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
        line_notify=coalesce(nullif(payload->>'line_notify','')::boolean,true)
    where event_id=v_event_id;
  end if;

  perform private.save_tracking_sensitive_details(v_event_id,v_category,payload);
  return v_event_id;
end;
$function$
;

-- public.submit_tracking_event
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

  select * into e from public.tracking_events where id=p_event_id for update;
  if not found or not private.can_edit_tracking_event(p_event_id) then
    raise exception '沒有處理此事件的權限' using errcode='42501';
  end if;
  if e.status <> 'draft' then raise exception '只有草稿可以送出初報'; end if;
  if p_target_status not in ('pending_followup','pending_close') then raise exception '初報送出狀態不正確'; end if;

  select * into r from public.tracking_event_initial_reports where event_id=p_event_id for update;
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
      line_notify=p_line_notify,
      line_notify_status=case when p_line_notify then 'queued' else 'skipped' end
  where event_id=p_event_id
  returning * into r;

  update public.tracking_events
  set status=p_target_status,
      next_followup_date=case when p_target_status='pending_followup' then next_followup_date else null end,
      requires_followup=(p_target_status='pending_followup')
  where id=p_event_id;

  insert into public.tracking_event_history(event_id,action_type,actor_staff_id,from_status,to_status,note)
  values(p_event_id,'initial_submitted',v_staff_id,'draft',p_target_status,'送出初報');

  if p_line_notify then
    if e.is_sensitive then
      v_message := format(
        '🟠【新增敏感事件通知】%s事件類別：%s%s登錄人：%s%s日期：%s%s請至內部管理系統查看。',
        chr(10),e.category,chr(10),coalesce(v_staff_name,'—'),
        chr(10),to_char(e.event_date,'YYYY/MM/DD'),chr(10)
      );
    else
      select c.case_name into v_case_name from public.care_cases c where c.id=e.case_id;
      select w.worker_name into v_worker_name from public.care_workers w where w.id=e.care_worker_id;
      v_message := format(
        '🟠【新增事件追蹤通知】%s類別：%s%s登錄人：%s%s日期：%s%s主旨：%s%s個案／居服員：%s%s事件說明：%s%s已完成處置：%s%s後續待辦：%s',
        chr(10),e.category,chr(10),coalesce(v_staff_name,'—'),
        chr(10),to_char(e.event_date,'YYYY/MM/DD'),chr(10),e.subject,chr(10),
        concat_ws('／',nullif(v_case_name,''),nullif(v_worker_name,'')),
        chr(10),r.event_description,chr(10),r.completed_actions,chr(10),r.pending_tasks
      );
    end if;

    insert into public.tracking_event_line_queue(event_id,record_type,record_id,message_text)
    values(p_event_id,'initial',r.id,v_message);
  end if;

  return r.id;
end;
$function$
;

-- public.add_tracking_event_followup
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
  v_message text;
begin
  if (select auth.uid()) is null or v_staff_id is null then
    raise exception 'authentication required' using errcode='42501';
  end if;

  select * into e from public.tracking_events where id=v_event_id for update;
  if not found or not private.can_edit_tracking_event(v_event_id) then
    raise exception '沒有處理此事件的權限' using errcode='42501';
  end if;
  if e.status in ('draft','closed','voided') then raise exception '目前事件狀態不能新增續報'; end if;
  if nullif(payload->>'followup_date','') is null then raise exception '追蹤日期為必填'; end if;
  if v_method not in ('phone','official_line','home_visit','interview','care_worker_report','case_manager_contact','other') then
    raise exception '追蹤方式不正確';
  end if;
  if v_latest is null then raise exception '最新狀況為必填'; end if;
  if v_outcome not in ('continue','ready_to_close') then raise exception '請選擇目前事件處理狀態'; end if;
  if v_outcome='continue' and v_next is null then raise exception '繼續追蹤時請填寫下次追蹤日期'; end if;

  insert into public.tracking_event_followups(
    event_id,followup_date,followup_time,followup_method,latest_status,completed_actions,pending_tasks,
    outcome,next_followup_date,submitted_by_staff_id,submitted_by,line_notify,line_notify_status,
    prior_event_status,prior_next_followup_date,prior_requires_followup,prior_tracking_note
  ) values(
    v_event_id,(payload->>'followup_date')::date,nullif(payload->>'followup_time','')::time,v_method,v_latest,v_completed,v_pending,
    v_outcome,v_next,v_staff_id,(select auth.uid()),v_line,case when v_line then 'queued' else 'skipped' end,
    e.status,e.next_followup_date,e.requires_followup,e.tracking_note
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
      v_message := format(
        '🔵【敏感事件續報通知】%s事件類別：%s%s追蹤人：%s%s請至內部管理系統查看。',
        chr(10),e.category,chr(10),coalesce(v_staff_name,'—'),chr(10)
      );
    else
      v_message := format(
        '🔵【事件續報】%s主旨：%s%s最新狀況：%s%s本次已完成處置：%s%s後續待辦：%s',
        chr(10),e.subject,chr(10),v_latest,chr(10),v_completed,chr(10),v_pending
      );
    end if;
    insert into public.tracking_event_line_queue(event_id,record_type,record_id,message_text)
    values(v_event_id,'followup',v_id,v_message);
  end if;
  return v_id;
end;
$function$
;

-- public.close_tracking_event
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
  v_message text;
begin
  if (select auth.uid()) is null or v_staff_id is null then raise exception 'authentication required' using errcode='42501'; end if;
  select * into e from public.tracking_events where id=v_event_id for update;
  if not found or not private.can_edit_tracking_event(v_event_id) then raise exception '沒有處理此事件的權限' using errcode='42501'; end if;
  if e.status <> 'pending_close' then raise exception '事件需先進入待結報狀態'; end if;
  if nullif(payload->>'close_date','') is null then raise exception '結報日期為必填'; end if;
  if v_final is null then raise exception '最終狀況為必填'; end if;
  if v_decision is null then raise exception '結案判定為必填'; end if;

  insert into public.tracking_event_closures(
    event_id,close_date,final_status,closure_decision,closed_by_staff_id,closed_by,line_notify,line_notify_status
  ) values(
    v_event_id,(payload->>'close_date')::date,v_final,v_decision,v_staff_id,(select auth.uid()),v_line,
    case when v_line then 'queued' else 'skipped' end
  ) returning id into v_id;

  update public.tracking_events
  set status='closed',requires_followup=false,next_followup_date=null,tracking_note=null,closed_at=now()
  where id=v_event_id;

  insert into public.tracking_event_history(event_id,action_type,actor_staff_id,note)
  values(v_event_id,'closure_added',v_staff_id,'完成結報');

  if v_line then
    if e.is_sensitive then
      v_message := format(
        '🟢【敏感事件結報通知】%s事件類別：%s%s結報人：%s%s請至內部管理系統查看。',
        chr(10),e.category,chr(10),coalesce(v_staff_name,'—'),chr(10)
      );
    else
      v_message := format(
        '🟢【事件結報】%s主旨：%s%s最終狀況：%s%s結案判定：%s',
        chr(10),e.subject,chr(10),v_final,chr(10),v_decision
      );
    end if;
    insert into public.tracking_event_line_queue(event_id,record_type,record_id,message_text)
    values(v_event_id,'closure',v_id,v_message);
  end if;
  return v_id;
end;
$function$
;

-- public.update_case_profile
CREATE OR REPLACE FUNCTION public.update_case_profile(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_case_id uuid := nullif(payload->>'case_id','')::uuid;
  v_old_supervisor uuid;
  v_new_supervisor uuid := nullif(payload->>'supervisor_id','')::uuid;
  v_case_no text := upper(regexp_replace(btrim(coalesce(payload->>'case_no','')),'\s+','','g'));
  v_case_name text := btrim(coalesce(payload->>'case_name',''));
  v_usage text := nullif(btrim(payload->>'service_usage_type'),'');
  v_payment text := nullif(btrim(payload->>'payment_method'),'');
  v_status text := coalesce(nullif(payload->>'service_status',''),'active');
  v_staff_id uuid;
  v_staff_role text;
  v_contacts jsonb := coalesce(payload->'contacts','[]'::jsonb);
  item jsonb;
begin
  if v_case_id is null then raise exception '缺少個案資料'; end if;

  select c.supervisor_id into v_old_supervisor
  from public.care_cases c
  where c.id=v_case_id;

  if not found then raise exception '找不到個案'; end if;
  if not private.can_edit_case(v_old_supervisor) then raise exception '沒有修改此個案的權限'; end if;

  select s.id,s.role into v_staff_id,v_staff_role
  from public.staff_users s
  where lower(s.email)=lower(coalesce((select auth.jwt())->>'email',''))
    and s.is_active=true
  limit 1;

  if v_case_no='' then raise exception '個案編號為必填'; end if;
  if v_case_no ~ '\s' then raise exception '個案編號不可包含空格'; end if;
  if v_case_name='' then raise exception '個案姓名為必填'; end if;
  if v_usage is null or v_usage not in ('居家','喘息','居家+喘息') then
    raise exception '服務類別格式不正確';
  end if;
  if v_payment is not null and v_payment not in ('銀行匯款','超商繳款','現金繳費','不收費') then
    raise exception '繳款方式格式不正確';
  end if;
  if v_status not in ('active','suspended','closed') then
    raise exception '服務狀態格式不正確';
  end if;
  if v_new_supervisor is null then raise exception '負責督導為必填'; end if;

  if not exists(
    select 1 from public.staff_users s
    where s.id=v_new_supervisor and s.is_active=true and s.can_supervise=true
  ) then
    raise exception '所選人員目前不是可指派的督導';
  end if;

  if v_staff_role='supervisor' and v_new_supervisor is distinct from v_old_supervisor then
    raise exception '督導不可自行變更個案負責督導';
  end if;

  update public.care_cases
  set case_no=v_case_no,
      case_name=v_case_name,
      supervisor_id=v_new_supervisor,
      national_id=nullif(upper(btrim(payload->>'national_id')),''),
      birth_date=nullif(payload->>'birth_date','')::date,
      gender=nullif(payload->>'gender',''),
      address=nullif(btrim(payload->>'address'),''),
      phone=nullif(btrim(payload->>'phone'),''),
      cms_level=nullif(btrim(payload->>'cms_level'),''),
      identity_type=nullif(btrim(payload->>'identity_type'),''),
      has_disability=case when payload ? 'has_disability' and nullif(payload->>'has_disability','') is not null then (payload->>'has_disability')::boolean else null end,
      is_indigenous=case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null then (payload->>'is_indigenous')::boolean else null end,
      indigenous_group=case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null and (payload->>'is_indigenous')::boolean=false then null else nullif(btrim(payload->>'indigenous_group'),'') end,
      welfare_identity=nullif(btrim(payload->>'welfare_identity'),''),
      copay_rate=case nullif(btrim(payload->>'welfare_identity'),'') when '一般戶' then 16 when '中低收入戶' then 5 when '低收入戶' then 0 else nullif(payload->>'copay_rate','')::numeric end,
      a_unit_name=nullif(btrim(payload->>'a_unit_name'),''),
      case_manager_name=nullif(btrim(payload->>'case_manager_name'),''),
      case_manager_phone=nullif(btrim(payload->>'case_manager_phone'),''),
      assessor_name=nullif(btrim(payload->>'assessor_name'),''),
      service_usage_type=v_usage,
      payment_method=v_payment,
      service_status=v_status,
      notes=nullif(btrim(payload->>'notes'),''),
      updated_at=now()
  where id=v_case_id;

  if v_new_supervisor is distinct from v_old_supervisor then
    update public.case_supervisor_assignments
    set is_current=false, assigned_to=current_date
    where case_id=v_case_id and is_current=true;

    insert into public.case_supervisor_assignments(
      case_id,supervisor_id,assigned_from,is_current,created_by
    ) values(
      v_case_id,v_new_supervisor,current_date,true,(select auth.uid())
    );
  end if;

  if payload ? 'contacts' then
    delete from public.case_contacts where case_id=v_case_id;
    if jsonb_typeof(v_contacts)='array' then
      for item in select value from jsonb_array_elements(v_contacts)
      loop
        if btrim(coalesce(item->>'contact_name',''))<>'' then
          insert into public.case_contacts(
            case_id,contact_name,relationship,phone,is_primary_contact,
            is_primary_caregiver,is_secondary_caregiver,notes,source,source_import_id
          ) values(
            v_case_id,btrim(item->>'contact_name'),
            nullif(btrim(item->>'relationship'),''),
            nullif(btrim(item->>'phone'),''),
            coalesce(item->>'is_primary_contact','false')='true',
            coalesce(item->>'is_primary_caregiver','false')='true',
            coalesce(item->>'is_secondary_caregiver','false')='true',
            nullif(btrim(item->>'notes'),''),
            'manual',null
          );
        end if;
      end loop;
    end if;
  end if;

  return jsonb_build_object('case_id',v_case_id,'updated',true);
end;
$function$
;

-- public.import_case_html_data
CREATE OR REPLACE FUNCTION public.import_case_html_data(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_case_id uuid;
  v_plan_id uuid;
  v_import_id uuid;
  v_action text;
  v_case_no text := upper(regexp_replace(btrim(coalesce(payload->>'case_no','')),'\s+','','g'));
  v_national_id text := upper(btrim(coalesce(payload->>'national_id','')));
  v_supervisor uuid := nullif(payload->>'supervisor_id','')::uuid;
  v_match_case uuid := nullif(payload->>'match_case_id','')::uuid;
  v_service_usage_type text := nullif(btrim(payload->>'service_usage_type'),'');
  v_payment_method text := nullif(btrim(payload->>'payment_method'),'');
  v_staff_id uuid;
  v_staff_role text;
  v_existing_case_no text;
  v_existing_supervisor uuid;
  v_hash text := nullif(payload->>'source_hash','');
  v_plan jsonb := coalesce(payload->'care_plan','{}'::jsonb);
  v_contacts jsonb := coalesce(payload->'contacts','[]'::jsonb);
  v_services jsonb := coalesce(payload->'services','[]'::jsonb);
  v_budgets jsonb := coalesce(payload->'budgets','[]'::jsonb);
  v_current_plan_id uuid;
  v_import_is_current boolean := false;
  item jsonb;
begin
  if (select auth.uid()) is null or not private.can_manage_cases() then
    raise exception '沒有個案管理權限';
  end if;

  if v_case_no='' then raise exception '個案編號為必填'; end if;
  if v_case_no ~ '\s' then raise exception '個案編號不可包含空格'; end if;
  if v_service_usage_type is null or v_service_usage_type not in ('居家','喘息','居家+喘息') then
    raise exception '服務類別格式不正確';
  end if;
  if v_payment_method is not null
     and v_payment_method not in ('銀行匯款','超商繳款','現金繳費','不收費') then
    raise exception '繳款方式格式不正確';
  end if;

  select s.id,s.role into v_staff_id,v_staff_role
  from public.staff_users s
  where lower(s.email)=lower(coalesce((select auth.jwt())->>'email',''))
    and s.is_active=true
  limit 1;

  if v_staff_id is null then raise exception '找不到目前登入的內部人員資料'; end if;

  if v_staff_role='supervisor' then
    v_supervisor:=v_staff_id;
  end if;

  if v_supervisor is null then raise exception '負責督導為必填'; end if;
  if not exists(
    select 1 from public.staff_users s
    where s.id=v_supervisor and s.is_active=true and s.can_supervise=true
  ) then
    raise exception '所選人員目前不是可指派的督導';
  end if;

  if v_national_id<>'' then
    select c.id,c.case_no,c.supervisor_id
      into v_case_id,v_existing_case_no,v_existing_supervisor
    from public.care_cases c
    where upper(btrim(coalesce(c.national_id,'')))=v_national_id
    limit 1;
  end if;

  if v_case_id is null and v_match_case is not null then
    select c.id,c.case_no,c.supervisor_id
      into v_case_id,v_existing_case_no,v_existing_supervisor
    from public.care_cases c
    where c.id=v_match_case;
  end if;

  if v_case_id is not null then
    if not private.can_edit_case(v_existing_supervisor) then
      raise exception '此個案由其他督導負責，目前帳號僅能查閱，不能更新';
    end if;

    if coalesce(btrim(v_existing_case_no),'')<>'' and upper(btrim(v_existing_case_no))<>v_case_no then
      raise exception '個案編號與既有資料不一致';
    end if;

    if v_hash is not null and exists(
      select 1 from public.case_imports ci
      where ci.case_id=v_case_id and ci.source_hash=v_hash
    ) then
      return jsonb_build_object(
        'action','duplicate',
        'case_id',v_case_id,
        'case_no',coalesce(v_existing_case_no,v_case_no)
      );
    end if;

    update public.care_cases
    set service_usage_type=v_service_usage_type,
        payment_method=v_payment_method,
        import_source='html',
        imported_at=now(),
        updated_at=now()
    where id=v_case_id;

    v_action:='updated';
  else
    if exists(
      select 1 from public.care_cases c
      where upper(btrim(coalesce(c.case_no,'')))=v_case_no
    ) then
      raise exception '此個案編號已存在';
    end if;

    insert into public.care_cases(
      case_no,case_name,national_id,birth_date,gender,address,phone,lives_alone,
      cms_level,identity_type,has_disability,is_indigenous,indigenous_group,welfare_identity,copay_rate,assessment_date,plan_approval_date,a_unit_name,
      case_manager_name,case_manager_phone,assessor_name,current_plan_date,
      service_usage_type,payment_method,
      supervisor_id,service_status,import_source,imported_at,created_by
    ) values (
      v_case_no,
      nullif(payload->>'case_name',''),
      nullif(v_national_id,''),
      nullif(payload->>'birth_date','')::date,
      nullif(payload->>'gender',''),
      nullif(payload->>'address',''),
      nullif(payload->>'phone',''),
      case when payload ? 'lives_alone' then (payload->>'lives_alone')::boolean else null end,
      nullif(payload->>'cms_level',''),
      nullif(payload->>'identity_type',''),
      case when payload ? 'has_disability' and nullif(payload->>'has_disability','') is not null then (payload->>'has_disability')::boolean else null end,
      case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null then (payload->>'is_indigenous')::boolean else null end,
      case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null and (payload->>'is_indigenous')::boolean=false then null else nullif(payload->>'indigenous_group','') end,
      nullif(payload->>'welfare_identity',''),
      case nullif(payload->>'welfare_identity','') when '一般戶' then 16 when '中低收入戶' then 5 when '低收入戶' then 0 else nullif(payload->>'copay_rate','')::numeric end,
      nullif(payload->>'assessment_date','')::date,
      nullif(payload->>'plan_approval_date','')::date,
      nullif(payload->>'a_unit_name',''),
      nullif(payload->>'case_manager_name',''),
      nullif(payload->>'case_manager_phone',''),
      nullif(payload->>'assessor_name',''),
      nullif(v_plan->>'plan_date','')::date,
      v_service_usage_type,v_payment_method,
      v_supervisor,'active','html',now(),(select auth.uid())
    ) returning id into v_case_id;

    insert into public.case_supervisor_assignments(
      case_id,supervisor_id,assigned_from,is_current,created_by
    ) values(
      v_case_id,v_supervisor,current_date,true,(select auth.uid())
    );

    v_action:='created';
  end if;

  v_import_id:=gen_random_uuid();

  insert into public.case_imports(
    id,case_id,file_name,storage_path,source_ca110_id,source_hash,imported_by,
    detected_plan_date,import_type,status,warnings,parsed_data
  ) values(
    v_import_id,v_case_id,coalesce(nullif(payload->>'file_name',''),'import.html'),
    coalesce(nullif(payload->>'storage_path',''),''),
    nullif(payload->>'source_ca110_id',''),v_hash,(select auth.uid()),
    nullif(v_plan->>'plan_date','')::date,
    case when v_action='created' then 'new_case' else 'update_case' end,
    'success',coalesce(payload->'warnings','[]'::jsonb),
    payload - 'raw_html'
  );

  if jsonb_typeof(v_plan)='object'
     and (
       btrim(coalesce(v_plan->>'raw_plan_text',''))<>''
       or coalesce(v_plan->'sections','{}'::jsonb)<>'{}'::jsonb
       or nullif(v_plan->>'plan_date','') is not null
       or (jsonb_typeof(v_services)='array' and jsonb_array_length(v_services)>0)
       or (jsonb_typeof(v_budgets)='array' and jsonb_array_length(v_budgets)>0)
     ) then
    insert into public.care_plans(
      case_id,plan_date,phone_contact_date,home_visit_date,visit_with,sections,
      raw_plan_text,a_unit_name,case_manager_name,is_current,source_import_id,
      updated_at,updated_by
    ) values(
      v_case_id,
      nullif(v_plan->>'plan_date','')::date,
      nullif(v_plan->>'phone_contact_date','')::date,
      nullif(v_plan->>'home_visit_date','')::date,
      nullif(v_plan->>'visit_with',''),
      coalesce(v_plan->'sections','{}'::jsonb),
      nullif(v_plan->>'raw_plan_text',''),
      nullif(payload->>'a_unit_name',''),
      nullif(payload->>'case_manager_name',''),
      false,v_import_id,now(),(select auth.uid())
    ) returning id into v_plan_id;
  end if;

  if jsonb_typeof(v_services)='array' then
    for item in select value from jsonb_array_elements(v_services)
    loop
      if btrim(coalesce(item->>'service_code',''))<>'' then
        insert into public.case_approved_services(
          case_id,care_plan_id,service_group,service_code,service_name,unit_price,
          approved_quantity,subtotal,valid_from,valid_to,is_current,source_import_id
        ) values(
          v_case_id,v_plan_id,nullif(item->>'service_group',''),
          upper(btrim(item->>'service_code')),nullif(item->>'service_name',''),
          nullif(item->>'unit_price','')::numeric,
          nullif(item->>'approved_quantity','')::numeric,
          nullif(item->>'subtotal','')::numeric,
          nullif(item->>'valid_from','')::date,
          nullif(item->>'valid_to','')::date,
          false,v_import_id
        );
      end if;
    end loop;
  end if;

  if jsonb_typeof(v_budgets)='array' then
    for item in select value from jsonb_array_elements(v_budgets)
    loop
      if btrim(coalesce(item->>'category',''))<>'' then
        insert into public.service_budgets(
          case_id,care_plan_id,category,benefit_limit,planned_total,remaining_amount,
          valid_from,valid_to,is_current,source_import_id
        ) values(
          v_case_id,v_plan_id,item->>'category',
          nullif(item->>'benefit_limit','')::numeric,
          nullif(item->>'planned_total','')::numeric,
          nullif(item->>'remaining_amount','')::numeric,
          nullif(item->>'valid_from','')::date,
          nullif(item->>'valid_to','')::date,
          false,v_import_id
        );
      end if;
    end loop;
  end if;

  v_current_plan_id:=private.refresh_case_plan_current(v_case_id);
  v_import_is_current:=(v_plan_id is not null and v_current_plan_id=v_plan_id);

  if v_action='created' or v_import_is_current then
    update public.care_cases c set
      case_no=coalesce(nullif(c.case_no,''),v_case_no),
      case_name=coalesce(nullif(payload->>'case_name',''),c.case_name),
      national_id=case when v_national_id<>'' then v_national_id else c.national_id end,
      birth_date=coalesce(nullif(payload->>'birth_date','')::date,c.birth_date),
      gender=coalesce(nullif(payload->>'gender',''),c.gender),
      address=coalesce(nullif(payload->>'address',''),c.address),
      phone=coalesce(nullif(payload->>'phone',''),c.phone),
      lives_alone=case when payload ? 'lives_alone' then (payload->>'lives_alone')::boolean else c.lives_alone end,
      cms_level=coalesce(nullif(payload->>'cms_level',''),c.cms_level),
      identity_type=coalesce(nullif(payload->>'identity_type',''),c.identity_type),
      has_disability=case when payload ? 'has_disability' and nullif(payload->>'has_disability','') is not null then (payload->>'has_disability')::boolean else c.has_disability end,
      is_indigenous=case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null then (payload->>'is_indigenous')::boolean else c.is_indigenous end,
      indigenous_group=case when payload ? 'is_indigenous' and nullif(payload->>'is_indigenous','') is not null and (payload->>'is_indigenous')::boolean=false then null else coalesce(nullif(payload->>'indigenous_group',''),c.indigenous_group) end,
      welfare_identity=coalesce(nullif(payload->>'welfare_identity',''),c.welfare_identity),
      copay_rate=case nullif(payload->>'welfare_identity','') when '一般戶' then 16 when '中低收入戶' then 5 when '低收入戶' then 0 else coalesce(nullif(payload->>'copay_rate','')::numeric,c.copay_rate) end,
      assessment_date=coalesce(nullif(payload->>'assessment_date','')::date,c.assessment_date),
      plan_approval_date=coalesce(nullif(payload->>'plan_approval_date','')::date,c.plan_approval_date),
      a_unit_name=coalesce(nullif(payload->>'a_unit_name',''),c.a_unit_name),
      case_manager_name=coalesce(nullif(payload->>'case_manager_name',''),c.case_manager_name),
      case_manager_phone=coalesce(nullif(payload->>'case_manager_phone',''),c.case_manager_phone),
      assessor_name=coalesce(nullif(payload->>'assessor_name',''),c.assessor_name),
      updated_at=now()
    where c.id=v_case_id;

    delete from public.case_contacts
    where case_id=v_case_id and source='html_import';

    if jsonb_typeof(v_contacts)='array' then
      for item in select value from jsonb_array_elements(v_contacts)
      loop
        if btrim(coalesce(item->>'contact_name',''))<>'' then
          insert into public.case_contacts(
            case_id,contact_name,relationship,phone,is_primary_contact,
            is_primary_caregiver,is_secondary_caregiver,notes,source,source_import_id
          ) values(
            v_case_id,btrim(item->>'contact_name'),nullif(btrim(item->>'relationship'),''),
            nullif(btrim(item->>'phone'),''),
            coalesce(item->>'is_primary_contact','false')='true',
            coalesce(item->>'is_primary_caregiver','false')='true',
            coalesce(item->>'is_secondary_caregiver','false')='true',
            nullif(btrim(item->>'notes'),''),
            'html_import',v_import_id
          );
        end if;
      end loop;
    end if;
  end if;

  return jsonb_build_object(
    'action',v_action,
    'case_id',v_case_id,
    'case_no',v_case_no,
    'care_plan_id',v_plan_id,
    'import_id',v_import_id,
    'current_plan_id',v_current_plan_id,
    'plan_is_current',v_import_is_current
  );
end;
$function$
;

-- public.update_care_plan_version
CREATE OR REPLACE FUNCTION public.update_care_plan_version(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_plan_id uuid := nullif(payload->>'plan_id','')::uuid;
  v_case_id uuid;
  v_supervisor uuid;
  v_source_import_id uuid;
  v_is_voided boolean;
  v_current uuid;
  v_services jsonb := coalesce(payload->'services','[]'::jsonb);
  v_budgets jsonb := coalesce(payload->'budgets','[]'::jsonb);
  item jsonb;
begin
  select cp.case_id,c.supervisor_id,cp.source_import_id,cp.is_voided
    into v_case_id,v_supervisor,v_source_import_id,v_is_voided
  from public.care_plans cp
  join public.care_cases c on c.id=cp.case_id
  where cp.id=v_plan_id;

  if v_case_id is null then
    raise exception '找不到照管平台照顧計畫版本';
  end if;
  if not private.can_edit_case(v_supervisor) then
    raise exception '沒有修改此照管平台照顧計畫的權限';
  end if;
  if coalesce(v_is_voided,false) then
    raise exception '已作廢的照管平台照顧計畫不可編輯';
  end if;

  update public.care_plans
  set plan_date=nullif(payload->>'plan_date','')::date,
      phone_contact_date=nullif(payload->>'phone_contact_date','')::date,
      home_visit_date=nullif(payload->>'home_visit_date','')::date,
      visit_with=nullif(btrim(payload->>'visit_with'),''),
      sections=coalesce(payload->'sections','{}'::jsonb),
      raw_plan_text=nullif(payload->>'raw_plan_text',''),
      updated_at=now(),
      updated_by=(select auth.uid())
  where id=v_plan_id;

  if payload ? 'services' then
    delete from public.case_approved_services
    where care_plan_id=v_plan_id;

    if jsonb_typeof(v_services)='array' then
      for item in select value from jsonb_array_elements(v_services)
      loop
        if btrim(coalesce(item->>'service_code',''))<>'' then
          insert into public.case_approved_services(
            case_id,care_plan_id,service_group,service_code,service_name,unit_price,
            approved_quantity,subtotal,valid_from,valid_to,is_current,source_import_id
          ) values(
            v_case_id,v_plan_id,nullif(item->>'service_group',''),
            upper(btrim(item->>'service_code')),nullif(item->>'service_name',''),
            nullif(item->>'unit_price','')::numeric,
            nullif(item->>'approved_quantity','')::numeric,
            nullif(item->>'subtotal','')::numeric,
            nullif(item->>'valid_from','')::date,
            nullif(item->>'valid_to','')::date,
            false,v_source_import_id
          );
        end if;
      end loop;
    end if;
  end if;

  if payload ? 'budgets' then
    delete from public.service_budgets
    where care_plan_id=v_plan_id;

    if jsonb_typeof(v_budgets)='array' then
      for item in select value from jsonb_array_elements(v_budgets)
      loop
        if btrim(coalesce(item->>'category',''))<>'' then
          insert into public.service_budgets(
            case_id,care_plan_id,category,benefit_limit,planned_total,remaining_amount,
            valid_from,valid_to,is_current,source_import_id
          ) values(
            v_case_id,v_plan_id,upper(btrim(item->>'category')),
            nullif(item->>'benefit_limit','')::numeric,
            nullif(item->>'planned_total','')::numeric,
            nullif(item->>'remaining_amount','')::numeric,
            nullif(item->>'valid_from','')::date,
            nullif(item->>'valid_to','')::date,
            false,v_source_import_id
          );
        end if;
      end loop;
    end if;
  end if;

  v_current:=private.refresh_case_plan_current(v_case_id);

  return jsonb_build_object(
    'plan_id',v_plan_id,
    'case_id',v_case_id,
    'current_plan_id',v_current,
    'is_current',(v_current=v_plan_id)
  );
end;
$function$
;

-- public.void_care_plan_version
CREATE OR REPLACE FUNCTION public.void_care_plan_version(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_plan_id uuid := nullif(payload->>'plan_id','')::uuid;
  v_reason text := nullif(btrim(payload->>'reason'),'');
  v_case_id uuid;
  v_supervisor uuid;
  v_is_voided boolean;
  v_new_current uuid;
  v_staff_id uuid;
begin
  if v_plan_id is null then
    raise exception '缺少照管平台照顧計畫版本';
  end if;

  if v_reason is null then
    raise exception '請填寫作廢原因';
  end if;

  select cp.case_id,c.supervisor_id,cp.is_voided
    into v_case_id,v_supervisor,v_is_voided
  from public.care_plans cp
  join public.care_cases c on c.id=cp.case_id
  where cp.id=v_plan_id;

  if v_case_id is null then
    raise exception '找不到照管平台照顧計畫版本';
  end if;

  if not private.can_edit_case(v_supervisor) then
    raise exception '沒有作廢此照管平台照顧計畫的權限';
  end if;

  if coalesce(v_is_voided,false) then
    raise exception '此照管平台照顧計畫版本已作廢';
  end if;

  select s.id into v_staff_id
  from public.staff_users s
  where lower(s.email)=lower(coalesce((select auth.jwt())->>'email',''))
    and s.is_active=true
  limit 1;

  update public.care_plans
  set is_voided=true,
      voided_at=now(),
      voided_by=(select auth.uid()),
      voided_by_staff_id=v_staff_id,
      void_reason=v_reason,
      is_current=false,
      updated_at=now(),
      updated_by=(select auth.uid())
  where id=v_plan_id;

  update public.case_approved_services
  set is_current=false
  where care_plan_id=v_plan_id;

  update public.service_budgets
  set is_current=false
  where care_plan_id=v_plan_id;

  v_new_current:=private.refresh_case_plan_current(v_case_id);

  return jsonb_build_object(
    'plan_id',v_plan_id,
    'case_id',v_case_id,
    'voided',true,
    'new_current_plan_id',v_new_current
  );
end;
$function$
;

