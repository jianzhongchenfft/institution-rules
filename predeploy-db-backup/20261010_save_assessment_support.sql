-- Predeployment production function definition, untouched.
CREATE OR REPLACE FUNCTION public.save_assessment_support(p_event_id uuid, p_household jsonb, p_family_members jsonb, p_support_domains jsonb, p_resources jsonb, p_summary jsonb, p_finalize boolean DEFAULT false, p_copied_from_id uuid DEFAULT NULL::uuid)
 RETURNS assessment_support_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_support_records;
  v_old public.assessment_support_records;
  v_key text;
  v_status text;
  v_item jsonb;
  v_expected_nature text;
  v_domain_keys text[]:=array[
    'daily_care','meal_housework','medical_transport','medication_health',
    'financial','emotional','decision_contact'
  ];
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_assessment_case(v_case.id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id and f.form_code='support'
  ) then raise exception 'SUPPORT_FORM_NOT_SELECTED'; end if;

  p_household:=coalesce(p_household,'{}'::jsonb);
  p_family_members:=coalesce(p_family_members,'[]'::jsonb);
  p_support_domains:=coalesce(p_support_domains,'{}'::jsonb);
  p_resources:=coalesce(p_resources,'{}'::jsonb);
  p_summary:=coalesce(p_summary,'{}'::jsonb);

  if jsonb_typeof(p_household)<>'object' then raise exception 'INVALID_SUPPORT_HOUSEHOLD'; end if;
  if jsonb_typeof(p_family_members)<>'array' then raise exception 'INVALID_SUPPORT_FAMILY_MEMBERS'; end if;
  if jsonb_typeof(p_support_domains)<>'object' then raise exception 'INVALID_SUPPORT_DOMAINS'; end if;
  if jsonb_typeof(p_resources)<>'object' then raise exception 'INVALID_SUPPORT_RESOURCES'; end if;
  if jsonb_typeof(p_summary)<>'object' then raise exception 'INVALID_SUPPORT_SUMMARY'; end if;

  if p_resources ? 'social_resources' and jsonb_typeof(p_resources->'social_resources')<>'array' then
    raise exception 'INVALID_SUPPORT_SOCIAL_RESOURCES';
  end if;
  if p_resources ? 'unmet_needs' and jsonb_typeof(p_resources->'unmet_needs')<>'array' then
    raise exception 'INVALID_SUPPORT_UNMET_NEEDS';
  end if;

  foreach v_key in array v_domain_keys loop
    if p_support_domains ? v_key then
      v_status:=p_support_domains->v_key->>'status';
      if v_status is not null and v_status not in ('adequate','partial','insufficient','not_applicable') then
        raise exception 'INVALID_SUPPORT_DOMAIN:%',v_key;
      end if;
      if p_finalize and v_status is null then
        raise exception 'SUPPORT_DOMAIN_INCOMPLETE:%',v_key;
      end if;
      if p_finalize
         and v_status in ('partial','insufficient','not_applicable')
         and nullif(btrim(coalesce(p_support_domains->v_key->>'note','')),'') is null then
        raise exception 'SUPPORT_DOMAIN_NOTE_REQUIRED:%',v_key;
      end if;
    elsif p_finalize then
      raise exception 'SUPPORT_DOMAIN_INCOMPLETE:%',v_key;
    end if;
  end loop;

  if p_finalize then
    if coalesce(p_household->>'living_arrangement','') not in (
      'alone','spouse','parents','children','grandchildren','relatives','nonrelative','other'
    ) then raise exception 'SUPPORT_LIVING_ARRANGEMENT_REQUIRED'; end if;

    if coalesce(p_household->>'family_change_status','') not in ('no','yes') then
      raise exception 'SUPPORT_FAMILY_CHANGE_REQUIRED';
    end if;
    if p_household->>'family_change_status'='yes'
       and nullif(btrim(coalesce(p_household->>'family_change_note','')),'') is null then
      raise exception 'SUPPORT_FAMILY_CHANGE_NOTE_REQUIRED';
    end if;

    if coalesce(p_household->>'primary_caregiver_status','') not in ('present','none') then
      raise exception 'SUPPORT_PRIMARY_CAREGIVER_STATUS_REQUIRED';
    end if;
    if p_household->>'primary_caregiver_status'='present' then
      if nullif(btrim(coalesce(p_household->>'primary_caregiver_name','')),'') is null
         or nullif(btrim(coalesce(p_household->>'primary_caregiver_relation','')),'') is null then
        raise exception 'SUPPORT_PRIMARY_CAREGIVER_INFO_REQUIRED';
      end if;
    end if;

    if coalesce(p_household->>'backup_available','') not in ('yes','no') then
      raise exception 'SUPPORT_BACKUP_STATUS_REQUIRED';
    end if;
    if p_household->>'backup_available'='yes' and jsonb_array_length(p_family_members)=0 then
      raise exception 'SUPPORT_BACKUP_MEMBER_REQUIRED';
    end if;
    if p_household->>'backup_available'='no' and jsonb_array_length(p_family_members)>0 then
      raise exception 'SUPPORT_BACKUP_MEMBER_CONFLICT';
    end if;

    for v_item in select value from jsonb_array_elements(p_family_members) loop
      if jsonb_typeof(v_item)<>'object' then raise exception 'INVALID_SUPPORT_FAMILY_MEMBER_ITEM'; end if;
      if nullif(btrim(coalesce(v_item->>'name','')),'') is null
         or nullif(btrim(coalesce(v_item->>'relation','')),'') is null
         or nullif(btrim(coalesce(v_item->>'support_role','')),'') is null then
        raise exception 'SUPPORT_FAMILY_MEMBER_INCOMPLETE';
      end if;
      if nullif(btrim(coalesce(v_item->>'co_resident','')),'') is not null
         and v_item->>'co_resident' not in ('yes','no') then
        raise exception 'INVALID_SUPPORT_FAMILY_MEMBER_COHABIT';
      end if;
    end loop;

    if coalesce(p_resources->>'economic_status','') not in ('stable','watch','difficulty') then
      raise exception 'SUPPORT_ECONOMIC_STATUS_REQUIRED';
    end if;
    if p_resources->>'economic_status' in ('watch','difficulty')
       and nullif(btrim(coalesce(p_resources->>'economic_note','')),'') is null then
      raise exception 'SUPPORT_ECONOMIC_NOTE_REQUIRED';
    end if;

    if coalesce(p_resources->>'economic_care_impact','') not in ('yes','no') then
      raise exception 'SUPPORT_ECONOMIC_IMPACT_REQUIRED';
    end if;
    if p_resources->>'economic_care_impact'='yes'
       and nullif(btrim(coalesce(p_resources->>'economic_care_impact_note','')),'') is null then
      raise exception 'SUPPORT_ECONOMIC_IMPACT_NOTE_REQUIRED';
    end if;

    for v_item in select value from jsonb_array_elements(coalesce(p_resources->'social_resources','[]'::jsonb)) loop
      if jsonb_typeof(v_item)<>'object' then raise exception 'INVALID_SUPPORT_RESOURCE_ITEM'; end if;
      if v_item->>'type' not in (
        'long_term_care','medical','welfare','disability','assistive_device','community',
        'social_work','transport','meal','charity_religion','neighbor_friend','volunteer',
        'other_formal','other_informal'
      ) then raise exception 'INVALID_SUPPORT_RESOURCE_TYPE'; end if;

      v_expected_nature:=case
        when v_item->>'type' in (
          'long_term_care','medical','welfare','disability','assistive_device','community',
          'social_work','transport','meal','charity_religion','other_formal'
        ) then 'formal'
        when v_item->>'type' in ('neighbor_friend','volunteer','other_informal') then 'informal'
        else null
      end;

      if v_item->>'nature' is distinct from v_expected_nature then
        raise exception 'INVALID_SUPPORT_RESOURCE_NATURE';
      end if;

      if nullif(btrim(coalesce(v_item->>'name','')),'') is null
         or nullif(btrim(coalesce(v_item->>'assistance','')),'') is null then
        raise exception 'SUPPORT_RESOURCE_INFO_REQUIRED';
      end if;
      if v_item->>'usage_status' not in ('stable','occasional','waiting','stopped') then
        raise exception 'INVALID_SUPPORT_RESOURCE_USAGE';
      end if;
      if v_item->>'sufficiency' not in ('adequate','partial','insufficient') then
        raise exception 'INVALID_SUPPORT_RESOURCE_SUFFICIENCY';
      end if;
      if v_item->>'sufficiency' in ('partial','insufficient')
         and nullif(btrim(coalesce(v_item->>'insufficiency_note','')),'') is null then
        raise exception 'SUPPORT_RESOURCE_GAP_NOTE_REQUIRED';
      end if;
    end loop;

    if coalesce(p_resources->>'social_interaction_status','') not in ('regular','limited','isolated','unable') then
      raise exception 'SUPPORT_SOCIAL_INTERACTION_REQUIRED';
    end if;
    if p_resources->>'social_interaction_status' in ('limited','isolated','unable')
       and nullif(btrim(coalesce(p_resources->>'social_interaction_note','')),'') is null then
      raise exception 'SUPPORT_SOCIAL_INTERACTION_NOTE_REQUIRED';
    end if;

    if coalesce(p_resources->>'community_participation_status','') not in (
      'participates','none','unwilling','health_limited','not_applicable'
    ) then raise exception 'SUPPORT_COMMUNITY_PARTICIPATION_REQUIRED'; end if;

    if coalesce(p_resources->>'unmet_needs_status','') not in ('yes','no') then
      raise exception 'SUPPORT_UNMET_NEEDS_STATUS_REQUIRED';
    end if;
    if p_resources->>'unmet_needs_status'='yes'
       and jsonb_array_length(coalesce(p_resources->'unmet_needs','[]'::jsonb))=0 then
      raise exception 'SUPPORT_UNMET_NEEDS_REQUIRED';
    end if;
    if p_resources->>'unmet_needs_status'='no'
       and jsonb_array_length(coalesce(p_resources->'unmet_needs','[]'::jsonb))>0 then
      raise exception 'SUPPORT_UNMET_NEEDS_CONFLICT';
    end if;

    for v_item in select value from jsonb_array_elements(coalesce(p_resources->'unmet_needs','[]'::jsonb)) loop
      if jsonb_typeof(v_item)<>'object' then raise exception 'INVALID_SUPPORT_UNMET_NEED_ITEM'; end if;
      if v_item->>'type' not in (
        'long_term_care','medical','welfare','disability','assistive_device','community',
        'social_work','transport','meal','charity_religion','neighbor_friend','volunteer',
        'other_formal','other_informal'
      ) then raise exception 'INVALID_SUPPORT_UNMET_NEED_TYPE'; end if;
      if nullif(btrim(coalesce(v_item->>'need','')),'') is null
         or nullif(btrim(coalesce(v_item->>'action','')),'') is null then
        raise exception 'SUPPORT_UNMET_NEED_INFO_REQUIRED';
      end if;
      if v_item->>'status' not in ('pending','referred','in_progress','completed','declined') then
        raise exception 'INVALID_SUPPORT_UNMET_NEED_STATUS';
      end if;
    end loop;

    if coalesce(p_summary->>'overall_support','') not in ('adequate','needs_attention','weak') then
      raise exception 'SUPPORT_OVERALL_REQUIRED';
    end if;
    if p_summary->>'overall_support' in ('needs_attention','weak')
       and nullif(btrim(coalesce(p_summary->>'key_issues','')),'') is null then
      raise exception 'SUPPORT_KEY_ISSUES_REQUIRED';
    end if;
    if coalesce(p_summary->>'followup_required','') not in ('yes','no') then
      raise exception 'SUPPORT_FOLLOWUP_REQUIRED';
    end if;
    if p_summary->>'followup_required'='yes'
       and nullif(btrim(coalesce(p_summary->>'followup_note','')),'') is null then
      raise exception 'SUPPORT_FOLLOWUP_NOTE_REQUIRED';
    end if;
  end if;

  select * into v_old from public.assessment_support_records where assessment_event_id=p_event_id for update;

  if v_old.id is null then
    insert into public.assessment_support_records(
      assessment_event_id,case_id,household,family_members,support_domains,resources,summary,
      copied_from_id,copied_at,confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_household,p_family_members,p_support_domains,p_resources,p_summary,
      p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    ) returning * into v_record;
  else
    if v_old.household is distinct from p_household then
      insert into public.assessment_support_history(support_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by)
      values(v_old.id,p_event_id,v_event.case_id,'household',v_old.household,p_household,(select auth.uid()));
    end if;
    if v_old.family_members is distinct from p_family_members then
      insert into public.assessment_support_history(support_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by)
      values(v_old.id,p_event_id,v_event.case_id,'family_members',v_old.family_members,p_family_members,(select auth.uid()));
    end if;
    if v_old.support_domains is distinct from p_support_domains then
      insert into public.assessment_support_history(support_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by)
      values(v_old.id,p_event_id,v_event.case_id,'support_domains',v_old.support_domains,p_support_domains,(select auth.uid()));
    end if;
    if v_old.resources is distinct from p_resources then
      insert into public.assessment_support_history(support_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by)
      values(v_old.id,p_event_id,v_event.case_id,'resources',v_old.resources,p_resources,(select auth.uid()));
    end if;
    if v_old.summary is distinct from p_summary then
      insert into public.assessment_support_history(support_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by)
      values(v_old.id,p_event_id,v_event.case_id,'summary',v_old.summary,p_summary,(select auth.uid()));
    end if;

    update public.assessment_support_records
    set household=p_household,
        family_members=p_family_members,
        support_domains=p_support_domains,
        resources=p_resources,
        summary=p_summary,
        copied_from_id=coalesce(p_copied_from_id,copied_from_id),
        copied_at=case when p_copied_from_id is not null and p_copied_from_id is distinct from copied_from_id then now() else copied_at end,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case when p_finalize then 'completed' else 'in_progress' end,updated_at=now()
  where assessment_event_id=p_event_id and form_code='support' and (p_finalize or status<>'completed');

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$
