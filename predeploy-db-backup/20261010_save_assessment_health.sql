-- Predeployment production function definition, untouched.
CREATE OR REPLACE FUNCTION public.save_assessment_health(p_event_id uuid, p_medical_info jsonb, p_medication_checks jsonb, p_health_items jsonb, p_health_notes jsonb, p_finalize boolean DEFAULT false, p_copied_from_id uuid DEFAULT NULL::uuid, p_section text DEFAULT 'all'::text)
 RETURNS assessment_health_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_health_records;
  v_old public.assessment_health_records;
  v_key text;
  v_status text;
  v_change jsonb;
  v_entry jsonb;
  v_total integer:=0;
  v_health_keys text[]:=array[
    'consciousness','eating','elimination','mobility','upper_limb',
    'lower_limb','daily_activity','sleep','appetite_weight','mood'
  ];
  v_med_keys text[]:=array[
    'storage_safety','expired_medicine','medicine_recognition',
    'follow_prescription','medication_management_support'
  ];
  v_sync_master boolean:=false;
  v_new_conditions text;
  v_new_treatments text;
  v_form_code text;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_assessment_case(v_case.id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if p_section not in ('baseline','change','status','all') then
    raise exception 'INVALID_HEALTH_SECTION';
  end if;

  v_form_code:='health_medication';

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id and f.form_code='health_medication'
  ) then raise exception 'HEALTH_FORM_NOT_SELECTED:health_medication'; end if;

  p_medical_info:=coalesce(p_medical_info,'{}'::jsonb);
  p_medication_checks:=coalesce(p_medication_checks,'{}'::jsonb);
  p_health_items:=coalesce(p_health_items,'{}'::jsonb);
  p_health_notes:=coalesce(p_health_notes,'{}'::jsonb);

  if p_medical_info ? 'opening_no_fixed_medications'
     and jsonb_typeof(p_medical_info->'opening_no_fixed_medications')<>'boolean' then
    raise exception 'INVALID_OPENING_NO_FIXED_MEDICATIONS';
  end if;

  if p_medical_info ? 'opening_no_temporary_medications'
     and jsonb_typeof(p_medical_info->'opening_no_temporary_medications')<>'boolean' then
    raise exception 'INVALID_OPENING_NO_TEMPORARY_MEDICATIONS';
  end if;

  if p_medical_info ? 'opening_temporary_medications'
     and jsonb_typeof(p_medical_info->'opening_temporary_medications')<>'array' then
    raise exception 'INVALID_OPENING_TEMPORARY_MEDICATIONS';
  end if;

  for v_entry in
    select value
    from jsonb_array_elements(coalesce(p_medical_info->'opening_temporary_medications','[]'::jsonb))
  loop
    if jsonb_typeof(v_entry)<>'object' then
      raise exception 'INVALID_OPENING_TEMPORARY_MEDICATION_ITEM';
    end if;
    if p_finalize and p_section in ('baseline','all')
       and v_event.assessment_type='opening'
       and nullif(btrim(v_entry->>'medication'),'') is null then
      raise exception 'OPENING_TEMPORARY_MEDICATION_INCOMPLETE';
    end if;
  end loop;

  if p_finalize and p_section in ('baseline','all') and v_event.assessment_type='opening' then
    if coalesce((p_medical_info->>'opening_no_fixed_medications')::boolean,false)=false
       and jsonb_array_length(coalesce(p_medical_info->'fixed_medication_base_entries','[]'::jsonb))=0 then
      raise exception 'OPENING_MEDICATION_BASELINE_UNCONFIRMED';
    end if;

    if coalesce((p_medical_info->>'opening_no_temporary_medications')::boolean,false)=false
       and jsonb_array_length(coalesce(p_medical_info->'opening_temporary_medications','[]'::jsonb))=0 then
      raise exception 'OPENING_TEMPORARY_MEDICATIONS_UNCONFIRMED';
    end if;
  end if;

  if p_medical_info ? 'healthcare_events'
     and jsonb_typeof(p_medical_info->'healthcare_events')<>'array' then
    raise exception 'INVALID_HEALTHCARE_EVENTS';
  end if;

  if p_medical_info ? 'no_healthcare_events'
     and jsonb_typeof(p_medical_info->'no_healthcare_events')<>'boolean' then
    raise exception 'INVALID_NO_HEALTHCARE_EVENTS';
  end if;

  if p_medical_info ? 'no_fixed_medications'
     and jsonb_typeof(p_medical_info->'no_fixed_medications')<>'boolean' then
    raise exception 'INVALID_NO_FIXED_MEDICATIONS';
  end if;

  if p_medical_info ? 'no_medication_changes'
     and jsonb_typeof(p_medical_info->'no_medication_changes')<>'boolean' then
    raise exception 'INVALID_NO_MEDICATION_CHANGES';
  end if;

  if p_medical_info ? 'fixed_medication_base_entries'
     and jsonb_typeof(p_medical_info->'fixed_medication_base_entries')<>'array' then
    raise exception 'INVALID_FIXED_MEDICATION_BASE_ENTRIES';
  end if;

  if p_medical_info ? 'fixed_medication_entries'
     and jsonb_typeof(p_medical_info->'fixed_medication_entries')<>'array' then
    raise exception 'INVALID_FIXED_MEDICATION_ENTRIES';
  end if;

  for v_entry in
    select value
    from jsonb_array_elements(coalesce(p_medical_info->'fixed_medication_base_entries','[]'::jsonb))
  loop
    if jsonb_typeof(v_entry)<>'object'
       or nullif(btrim(v_entry->>'id'),'') is null
       or nullif(btrim(v_entry->>'medication'),'') is null then
      raise exception 'INVALID_FIXED_MEDICATION_BASE_ENTRY';
    end if;
    if nullif(btrim(v_entry->>'origin_type'),'') is not null
       and v_entry->>'origin_type' not in ('opening_baseline','service_change','correction_add','legacy') then
      raise exception 'INVALID_FIXED_MEDICATION_BASE_ORIGIN';
    end if;
  end loop;

  for v_entry in
    select value
    from jsonb_array_elements(coalesce(p_medical_info->'fixed_medication_entries','[]'::jsonb))
  loop
    if jsonb_typeof(v_entry)<>'object'
       or nullif(btrim(v_entry->>'id'),'') is null
       or nullif(btrim(v_entry->>'medication'),'') is null then
      raise exception 'INVALID_FIXED_MEDICATION_ENTRY';
    end if;
    if nullif(btrim(v_entry->>'origin_type'),'') is not null
       and v_entry->>'origin_type' not in ('opening_baseline','service_change','correction_add','legacy') then
      raise exception 'INVALID_FIXED_MEDICATION_ORIGIN';
    end if;
  end loop;

  if p_medical_info ? 'medication_corrections'
     and jsonb_typeof(p_medical_info->'medication_corrections')<>'array' then
    raise exception 'INVALID_MEDICATION_CORRECTIONS';
  end if;

  if p_medical_info ? 'medication_corrections' then
    for v_change in
      select value from jsonb_array_elements(p_medical_info->'medication_corrections')
    loop
      if jsonb_typeof(v_change)<>'object' then
        raise exception 'INVALID_MEDICATION_CORRECTION_ITEM';
      end if;

      if nullif(btrim(v_change->>'action'),'') is not null
         and v_change->>'action' not in ('add','edit','remove') then
        raise exception 'INVALID_MEDICATION_CORRECTION_ACTION';
      end if;

      if nullif(btrim(v_change->>'reason'),'') is not null
         and v_change->>'reason' not in ('opening_omission','previous_record_error','other') then
        raise exception 'INVALID_MEDICATION_CORRECTION_REASON';
      end if;

      if p_finalize and p_section in ('change','all') then
        if nullif(btrim(v_change->>'action'),'') is null
           or nullif(btrim(v_change->>'reason'),'') is null then
          raise exception 'MEDICATION_CORRECTION_INCOMPLETE';
        end if;

        if v_change->>'action'='add'
           and nullif(btrim(v_change->>'medication_after'),'') is null then
          raise exception 'MEDICATION_CORRECTION_ADD_INCOMPLETE';
        elsif v_change->>'action' in ('edit','remove')
           and nullif(btrim(v_change->>'target_entry_id'),'') is null then
          raise exception 'MEDICATION_CORRECTION_TARGET_INCOMPLETE';
        elsif v_change->>'action'='edit'
           and nullif(btrim(v_change->>'medication_after'),'') is null then
          raise exception 'MEDICATION_CORRECTION_EDIT_INCOMPLETE';
        end if;

        if v_change->>'reason'='other'
           and nullif(btrim(v_change->>'note'),'') is null then
          raise exception 'MEDICATION_CORRECTION_OTHER_NOTE_REQUIRED';
        end if;
      end if;
    end loop;
  end if;

  if p_medical_info ? 'medication_changes'
     and jsonb_typeof(p_medical_info->'medication_changes')<>'array' then
    raise exception 'INVALID_MEDICATION_CHANGES';
  end if;

  if p_medical_info ? 'medication_changes' then
    for v_change in
      select value from jsonb_array_elements(p_medical_info->'medication_changes')
    loop
      if jsonb_typeof(v_change)<>'object' then
        raise exception 'INVALID_MEDICATION_CHANGE_ITEM';
      end if;

      if nullif(btrim(v_change->>'action'),'') is not null
         and v_change->>'action' not in ('add','stop','adjust') then
        raise exception 'INVALID_MEDICATION_CHANGE_ACTION';
      end if;

      if nullif(btrim(v_change->>'duration_type'),'') is not null
         and v_change->>'duration_type' not in ('long_term','short_term') then
        raise exception 'INVALID_MEDICATION_CHANGE_DURATION';
      end if;

      if p_finalize and p_section in ('change','all') then
        if nullif(btrim(v_change->>'action'),'') is null
           or nullif(btrim(v_change->>'duration_type'),'') is null then
          raise exception 'MEDICATION_CHANGE_INCOMPLETE';
        end if;

        if v_change->>'action'='add'
           and nullif(btrim(v_change->>'medication_after'),'') is null then
          raise exception 'MEDICATION_CHANGE_ADD_INCOMPLETE';
        elsif v_change->>'action'='stop'
           and (
             (v_change->>'duration_type'='long_term'
              and nullif(btrim(v_change->>'medication_before_entry_id'),'') is null)
             or
             (v_change->>'duration_type'='short_term'
              and nullif(btrim(v_change->>'medication_before'),'') is null)
           ) then
          raise exception 'MEDICATION_CHANGE_STOP_INCOMPLETE';
        elsif v_change->>'action'='adjust'
           and (
             nullif(btrim(v_change->>'medication_after'),'') is null
             or
             (v_change->>'duration_type'='long_term'
              and nullif(btrim(v_change->>'medication_before_entry_id'),'') is null)
             or
             (v_change->>'duration_type'='short_term'
              and nullif(btrim(v_change->>'medication_before'),'') is null)
           ) then
          raise exception 'MEDICATION_CHANGE_ADJUST_INCOMPLETE';
        end if;
      end if;
    end loop;
  end if;

  if nullif(btrim(p_medical_info->>'unvisited_health_change'),'') is not null
     and p_medical_info->>'unvisited_health_change' not in ('no','yes') then
    raise exception 'INVALID_UNVISITED_HEALTH_CHANGE';
  end if;

  if nullif(btrim(p_medical_info->>'medication_change'),'') is not null
     and p_medical_info->>'medication_change' not in ('none','changed') then
    raise exception 'INVALID_MEDICATION_CHANGE';
  end if;

  if nullif(btrim(p_medical_info->>'medication_method'),'') is not null
     and p_medical_info->>'medication_method' not in ('self','assisted') then
    raise exception 'INVALID_MEDICATION_METHOD';
  end if;

  if nullif(btrim(p_medical_info->>'regular_followup'),'') is not null
     and p_medical_info->>'regular_followup' not in ('yes','no') then
    raise exception 'INVALID_REGULAR_FOLLOWUP';
  end if;

  if nullif(btrim(p_medical_info->>'medication_regular'),'') is not null
     and p_medical_info->>'medication_regular' not in ('yes','no') then
    raise exception 'INVALID_MEDICATION_REGULAR';
  end if;

  if nullif(btrim(p_medical_info->>'side_effect'),'') is not null
     and p_medical_info->>'side_effect' not in ('none','present') then
    raise exception 'INVALID_SIDE_EFFECT';
  end if;

  if nullif(btrim(p_medical_info->>'care_impact'),'') is not null
     and p_medical_info->>'care_impact' not in ('no_impact','observe','adjust_plan','contact_external') then
    raise exception 'INVALID_CARE_IMPACT';
  end if;

  foreach v_key in array v_med_keys loop
    if p_medication_checks ? v_key then
      v_status:=p_medication_checks->v_key->>'status';
      if v_status is not null and v_status not in ('good','improve','not_applicable') then
        raise exception 'INVALID_MEDICATION_CHECK:%',v_key;
      end if;
    end if;
  end loop;

  foreach v_key in array v_health_keys loop
    v_status:=p_health_items->>v_key;

    if v_status is not null and v_status not in ('good','observe','refer') then
      raise exception 'INVALID_HEALTH_STATUS:%',v_key;
    end if;

    if p_finalize and p_section in ('status','all') and v_status is null then
      raise exception 'HEALTH_INCOMPLETE:%',v_key;
    end if;

    if v_status='good' then v_total:=v_total+2;
    elsif v_status='observe' then v_total:=v_total+1;
    end if;
  end loop;

  select * into v_old
  from public.assessment_health_records
  where assessment_event_id=p_event_id
  for update;

  v_new_conditions:=nullif(btrim(p_medical_info->>'baseline_important_conditions'),'');
  v_new_treatments:=nullif(btrim(p_medical_info->>'baseline_ongoing_treatments'),'');

  if p_section in ('baseline','change','all') and v_old.id is null then
    v_sync_master:=
      (
        p_medical_info ? 'baseline_important_conditions'
        and v_case.important_conditions is distinct from v_new_conditions
      )
      or
      (
        p_medical_info ? 'baseline_ongoing_treatments'
        and v_case.ongoing_treatments is distinct from v_new_treatments
      );
  elsif p_section in ('baseline','change','all') then
    v_sync_master:=
      (
        p_medical_info ? 'baseline_important_conditions'
        and nullif(btrim(v_old.medical_info->>'baseline_important_conditions'),'')
            is distinct from v_new_conditions
      )
      or
      (
        p_medical_info ? 'baseline_ongoing_treatments'
        and nullif(btrim(v_old.medical_info->>'baseline_ongoing_treatments'),'')
            is distinct from v_new_treatments
      );
  else
    v_sync_master:=false;
  end if;

  if v_sync_master then
    if v_case.important_conditions is distinct from v_new_conditions then
      insert into public.case_health_profile_history(
        case_id,field_name,old_value,new_value,changed_by
      ) values(
        v_case.id,'important_conditions',v_case.important_conditions,v_new_conditions,(select auth.uid())
      );
    end if;

    if v_case.ongoing_treatments is distinct from v_new_treatments then
      insert into public.case_health_profile_history(
        case_id,field_name,old_value,new_value,changed_by
      ) values(
        v_case.id,'ongoing_treatments',v_case.ongoing_treatments,v_new_treatments,(select auth.uid())
      );
    end if;

    update public.care_cases
    set important_conditions=v_new_conditions,
        ongoing_treatments=v_new_treatments,
        updated_at=now()
    where id=v_case.id;
  end if;

  if v_old.id is null then
    insert into public.assessment_health_records(
      assessment_event_id,case_id,medical_info,medication_checks,
      health_items,health_notes,total_score,copied_from_id,copied_at,
      confirmed_at,baseline_confirmed_at,change_confirmed_at,status_confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,
      case when p_section in ('baseline','change','all') then p_medical_info else '{}'::jsonb end,
      case when p_section in ('baseline','change','all') then p_medication_checks else '{}'::jsonb end,
      case when p_section in ('status','all') then p_health_items else '{}'::jsonb end,
      case when p_section in ('status','all') then p_health_notes else '{}'::jsonb end,
      case when p_section in ('status','all') and p_health_items<>'{}'::jsonb then v_total else null end,
      case when p_section in ('status','all') then p_copied_from_id else null end,
      case when p_section in ('status','all') and p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      case when p_finalize and p_section in ('baseline','all') then now() else null end,
      case when p_finalize and p_section in ('change','all') then now() else null end,
      case when p_finalize and p_section in ('status','all') then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    if p_section in ('baseline','change','all') then
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.medical_info,'{}'::jsonb)||p_medical_info) as t(key)
    loop
      if (v_old.medical_info->v_key) is distinct from (p_medical_info->v_key) then
        insert into public.assessment_health_history(
          health_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'medical_info.'||v_key,
          v_old.medical_info->v_key,p_medical_info->v_key,(select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.medication_checks,'{}'::jsonb)||p_medication_checks) as t(key)
    loop
      if (v_old.medication_checks->v_key) is distinct from (p_medication_checks->v_key) then
        insert into public.assessment_health_history(
          health_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'medication_checks.'||v_key,
          v_old.medication_checks->v_key,p_medication_checks->v_key,(select auth.uid())
        );
      end if;
    end loop;

    end if;

    if p_section in ('status','all') then
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.health_items,'{}'::jsonb)||p_health_items) as t(key)
    loop
      if (v_old.health_items->v_key) is distinct from (p_health_items->v_key) then
        insert into public.assessment_health_history(
          health_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'health_items.'||v_key,
          v_old.health_items->v_key,p_health_items->v_key,(select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.health_notes,'{}'::jsonb)||p_health_notes) as t(key)
    loop
      if (v_old.health_notes->v_key) is distinct from (p_health_notes->v_key) then
        insert into public.assessment_health_history(
          health_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'health_notes.'||v_key,
          v_old.health_notes->v_key,p_health_notes->v_key,(select auth.uid())
        );
      end if;
    end loop;

    end if;

    update public.assessment_health_records
    set medical_info=case
          when p_section in ('baseline','change','all') then p_medical_info
          else medical_info
        end,
        medication_checks=case
          when p_section in ('baseline','change','all') then p_medication_checks
          else medication_checks
        end,
        health_items=case
          when p_section in ('status','all') then p_health_items
          else health_items
        end,
        health_notes=case
          when p_section in ('status','all') then p_health_notes
          else health_notes
        end,
        total_score=case
          when p_section in ('status','all') then
            case when p_health_items<>'{}'::jsonb then v_total else null end
          else total_score
        end,
        copied_from_id=case
          when p_section in ('status','all') then coalesce(copied_from_id,p_copied_from_id)
          else copied_from_id
        end,
        copied_at=case
          when p_section not in ('status','all') then copied_at
          when copied_at is not null then copied_at
          when p_copied_from_id is not null then now()
          else null
        end,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        baseline_confirmed_at=case when p_finalize and p_section in ('baseline','all') then now() else baseline_confirmed_at end,
        change_confirmed_at=case when p_finalize and p_section in ('change','all') then now() else change_confirmed_at end,
        status_confirmed_at=case when p_finalize and p_section in ('status','all') then now() else status_confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case
        when p_finalize and p_section='all' then 'completed'
        when status='completed' then status
        else 'in_progress'
      end,
      updated_at=now()
  where assessment_event_id=p_event_id
    and form_code='health_medication';

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$
