-- Predeployment production function definition, untouched.
CREATE OR REPLACE FUNCTION public.save_assessment_event_summary(p_event_id uuid, p_overall_status text, p_key_findings text, p_care_recommendations text, p_followup_required boolean, p_followup_plan text, p_service_adjustment_required boolean, p_service_adjustment_note text, p_external_coordination_required boolean, p_external_coordination_note text, p_previous_problem_status text, p_previous_problem_followup_note text, p_previous_recommendation_status text, p_previous_recommendation_followup_note text, p_finalize boolean DEFAULT false)
 RETURNS assessment_event_summaries
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_old public.assessment_event_summaries;
  v_record public.assessment_event_summaries;
  v_previous public.assessment_event_summaries;
  v_old_snapshot jsonb;
  v_new_snapshot jsonb;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;
  if v_event.status='voided' then raise exception 'ASSESSMENT_EVENT_VOIDED'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_assessment_case(v_case.id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id
      and f.status not in ('completed','unable','not_applicable')
  ) then
    raise exception 'ASSESSMENT_FORMS_NOT_COMPLETED';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id
  ) then
    raise exception 'ASSESSMENT_FORMS_NOT_FOUND';
  end if;

  if p_overall_status is not null
     and p_overall_status not in ('stable','attention','intervention') then
    raise exception 'INVALID_ASSESSMENT_OVERALL_STATUS';
  end if;

  if p_previous_problem_status is not null
     and p_previous_problem_status not in ('improved','persistent','worse','not_applicable') then
    raise exception 'INVALID_PREVIOUS_PROBLEM_STATUS';
  end if;

  if p_previous_recommendation_status is not null
     and p_previous_recommendation_status not in ('completed','partial','ongoing','not_done','not_applicable') then
    raise exception 'INVALID_PREVIOUS_RECOMMENDATION_STATUS';
  end if;

  select s.* into v_previous
  from public.assessment_event_summaries s
  join public.assessment_events pe on pe.id=s.assessment_event_id
  where s.case_id=v_event.case_id
    and s.assessment_event_id<>p_event_id
    and s.completed_at is not null
    and pe.planned_date<v_event.planned_date
  order by pe.planned_date desc,s.completed_at desc
  limit 1;

  select * into v_old
  from public.assessment_event_summaries
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is not null and v_old.previous_summary_id is not null then
    select * into v_previous
    from public.assessment_event_summaries
    where id=v_old.previous_summary_id;
  end if;

  if p_finalize then
    if p_overall_status is null then raise exception 'ASSESSMENT_OVERALL_STATUS_REQUIRED'; end if;
    if nullif(btrim(coalesce(p_key_findings,'')),'') is null then
      raise exception 'ASSESSMENT_KEY_FINDINGS_REQUIRED';
    end if;
    if nullif(btrim(coalesce(p_care_recommendations,'')),'') is null then
      raise exception 'ASSESSMENT_CARE_RECOMMENDATIONS_REQUIRED';
    end if;
    if p_followup_required is null then raise exception 'ASSESSMENT_FOLLOWUP_DECISION_REQUIRED'; end if;
    if p_service_adjustment_required is null then raise exception 'ASSESSMENT_SERVICE_ADJUSTMENT_DECISION_REQUIRED'; end if;
    if p_external_coordination_required is null then raise exception 'ASSESSMENT_EXTERNAL_COORDINATION_DECISION_REQUIRED'; end if;
    if p_followup_required and nullif(btrim(coalesce(p_followup_plan,'')),'') is null then
      raise exception 'ASSESSMENT_FOLLOWUP_PLAN_REQUIRED';
    end if;
    if p_service_adjustment_required and nullif(btrim(coalesce(p_service_adjustment_note,'')),'') is null then
      raise exception 'ASSESSMENT_SERVICE_ADJUSTMENT_NOTE_REQUIRED';
    end if;
    if p_external_coordination_required and nullif(btrim(coalesce(p_external_coordination_note,'')),'') is null then
      raise exception 'ASSESSMENT_EXTERNAL_COORDINATION_NOTE_REQUIRED';
    end if;

    if v_previous.id is not null then
      if p_previous_problem_status is null then
        raise exception 'PREVIOUS_PROBLEM_STATUS_REQUIRED';
      end if;
      if nullif(btrim(coalesce(p_previous_problem_followup_note,'')),'') is null then
        raise exception 'PREVIOUS_PROBLEM_FOLLOWUP_NOTE_REQUIRED';
      end if;
      if p_previous_recommendation_status is null then
        raise exception 'PREVIOUS_RECOMMENDATION_STATUS_REQUIRED';
      end if;
      if nullif(btrim(coalesce(p_previous_recommendation_followup_note,'')),'') is null then
        raise exception 'PREVIOUS_RECOMMENDATION_FOLLOWUP_NOTE_REQUIRED';
      end if;
    end if;
  end if;

  if v_old.id is null then
    insert into public.assessment_event_summaries(
      assessment_event_id,case_id,overall_status,key_findings,care_recommendations,
      followup_required,followup_plan,service_adjustment_required,service_adjustment_note,
      external_coordination_required,external_coordination_note,
      previous_summary_id,previous_key_findings_snapshot,previous_care_recommendations_snapshot,
      previous_problem_status,previous_problem_followup_note,
      previous_recommendation_status,previous_recommendation_followup_note,
      completed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_overall_status,p_key_findings,p_care_recommendations,
      p_followup_required,p_followup_plan,p_service_adjustment_required,p_service_adjustment_note,
      p_external_coordination_required,p_external_coordination_note,
      v_previous.id,v_previous.key_findings,v_previous.care_recommendations,
      p_previous_problem_status,p_previous_problem_followup_note,
      p_previous_recommendation_status,p_previous_recommendation_followup_note,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    ) returning * into v_record;
  else
    v_old_snapshot:=jsonb_build_object(
      'overall_status',v_old.overall_status,
      'key_findings',v_old.key_findings,
      'care_recommendations',v_old.care_recommendations,
      'followup_required',v_old.followup_required,
      'followup_plan',v_old.followup_plan,
      'service_adjustment_required',v_old.service_adjustment_required,
      'service_adjustment_note',v_old.service_adjustment_note,
      'external_coordination_required',v_old.external_coordination_required,
      'external_coordination_note',v_old.external_coordination_note,
      'previous_summary_id',v_old.previous_summary_id,
      'previous_key_findings_snapshot',v_old.previous_key_findings_snapshot,
      'previous_care_recommendations_snapshot',v_old.previous_care_recommendations_snapshot,
      'previous_problem_status',v_old.previous_problem_status,
      'previous_problem_followup_note',v_old.previous_problem_followup_note,
      'previous_recommendation_status',v_old.previous_recommendation_status,
      'previous_recommendation_followup_note',v_old.previous_recommendation_followup_note,
      'completed_at',v_old.completed_at
    );

    v_new_snapshot:=jsonb_build_object(
      'overall_status',p_overall_status,
      'key_findings',p_key_findings,
      'care_recommendations',p_care_recommendations,
      'followup_required',p_followup_required,
      'followup_plan',p_followup_plan,
      'service_adjustment_required',p_service_adjustment_required,
      'service_adjustment_note',p_service_adjustment_note,
      'external_coordination_required',p_external_coordination_required,
      'external_coordination_note',p_external_coordination_note,
      'previous_summary_id',coalesce(v_old.previous_summary_id,v_previous.id),
      'previous_key_findings_snapshot',coalesce(v_old.previous_key_findings_snapshot,v_previous.key_findings),
      'previous_care_recommendations_snapshot',coalesce(v_old.previous_care_recommendations_snapshot,v_previous.care_recommendations),
      'previous_problem_status',p_previous_problem_status,
      'previous_problem_followup_note',p_previous_problem_followup_note,
      'previous_recommendation_status',p_previous_recommendation_status,
      'previous_recommendation_followup_note',p_previous_recommendation_followup_note,
      'completed_at',case when p_finalize then coalesce(v_old.completed_at,now()) else v_old.completed_at end
    );

    if v_old_snapshot is distinct from v_new_snapshot then
      insert into public.assessment_event_summary_history(
        summary_id,assessment_event_id,case_id,old_snapshot,new_snapshot,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,v_old_snapshot,v_new_snapshot,(select auth.uid())
      );
    end if;

    update public.assessment_event_summaries
    set overall_status=p_overall_status,
        key_findings=p_key_findings,
        care_recommendations=p_care_recommendations,
        followup_required=p_followup_required,
        followup_plan=p_followup_plan,
        service_adjustment_required=p_service_adjustment_required,
        service_adjustment_note=p_service_adjustment_note,
        external_coordination_required=p_external_coordination_required,
        external_coordination_note=p_external_coordination_note,
        previous_summary_id=coalesce(previous_summary_id,v_previous.id),
        previous_key_findings_snapshot=coalesce(previous_key_findings_snapshot,v_previous.key_findings),
        previous_care_recommendations_snapshot=coalesce(previous_care_recommendations_snapshot,v_previous.care_recommendations),
        previous_problem_status=p_previous_problem_status,
        previous_problem_followup_note=p_previous_problem_followup_note,
        previous_recommendation_status=p_previous_recommendation_status,
        previous_recommendation_followup_note=p_previous_recommendation_followup_note,
        completed_at=case when p_finalize then coalesce(completed_at,now()) else completed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  if p_finalize then
    update public.assessment_events
    set status='completed',
        completed_at=coalesce(completed_at,now()),
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=p_event_id;
  end if;

  return v_record;
end;
$function$
