-- Predeployment production function definition, untouched.
CREATE OR REPLACE FUNCTION public.save_assessment_home_safety(p_event_id uuid, p_home_profile jsonb, p_answers jsonb, p_notes jsonb, p_summary jsonb, p_finalize boolean DEFAULT false, p_copied_from_id uuid DEFAULT NULL::uuid)
 RETURNS assessment_home_safety_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_home_safety_records;
  v_old public.assessment_home_safety_records;
  v_key text;
  v_status text;
  v_required text[] := array[
    'entrance_clear','floor_level','floor_nonslip','walkway_clear','lighting','furniture_safe',
    'bath_floor_nonslip','bath_seat','bath_grab','toilet_transfer','bath_threshold',
    'bed_transfer','night_lighting','night_toilet_route',
    'stairs_lighting','stairs_handrail','stairs_nonslip',
    'kitchen_reach','kitchen_floor_work',
    'emergency_contact','escape_route'
  ];
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id = p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id = v_event.case_id;
  if v_case.id is null or not private.can_edit_assessment_case(v_case.id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id = p_event_id and f.form_code = 'home_safety'
  ) then raise exception 'HOME_SAFETY_FORM_NOT_SELECTED'; end if;

  p_home_profile := coalesce(p_home_profile, '{}'::jsonb);
  p_answers := coalesce(p_answers, '{}'::jsonb);
  p_notes := coalesce(p_notes, '{}'::jsonb);
  p_summary := coalesce(p_summary, '{}'::jsonb);

  foreach v_key in array v_required loop
    if p_answers ? v_key then
      v_status := p_answers ->> v_key;
      if v_status not in ('safe','needs_improvement','not_applicable') then
        raise exception 'INVALID_HOME_SAFETY_STATUS:%', v_key;
      end if;
    elsif p_finalize then
      raise exception 'HOME_SAFETY_INCOMPLETE:%', v_key;
    end if;
  end loop;

  select * into v_old
  from public.assessment_home_safety_records
  where assessment_event_id = p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_home_safety_records(
      assessment_event_id, case_id, home_profile, answers, notes, summary,
      copied_from_id, copied_at, confirmed_at, created_by, updated_by
    ) values (
      p_event_id, v_event.case_id, p_home_profile, p_answers, p_notes, p_summary,
      p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()), (select auth.uid())
    ) returning * into v_record;
  else
    if v_old.home_profile is distinct from p_home_profile then
      insert into public.assessment_home_safety_history(
        home_safety_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
      ) values (
        v_old.id, p_event_id, v_event.case_id, 'home_profile',
        v_old.home_profile, p_home_profile, (select auth.uid())
      );
    end if;

    if v_old.answers is distinct from p_answers then
      insert into public.assessment_home_safety_history(
        home_safety_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
      ) values (
        v_old.id, p_event_id, v_event.case_id, 'answers',
        v_old.answers, p_answers, (select auth.uid())
      );
    end if;

    if v_old.notes is distinct from p_notes then
      insert into public.assessment_home_safety_history(
        home_safety_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
      ) values (
        v_old.id, p_event_id, v_event.case_id, 'notes',
        v_old.notes, p_notes, (select auth.uid())
      );
    end if;

    if v_old.summary is distinct from p_summary then
      insert into public.assessment_home_safety_history(
        home_safety_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
      ) values (
        v_old.id, p_event_id, v_event.case_id, 'summary',
        v_old.summary, p_summary, (select auth.uid())
      );
    end if;

    update public.assessment_home_safety_records
    set
      home_profile = p_home_profile,
      answers = p_answers,
      notes = p_notes,
      summary = p_summary,
      copied_from_id = coalesce(p_copied_from_id, copied_from_id),
      copied_at = case
        when p_copied_from_id is not null and p_copied_from_id is distinct from copied_from_id then now()
        else copied_at
      end,
      confirmed_at = case when p_finalize then now() else confirmed_at end,
      updated_by = (select auth.uid()),
      updated_at = now()
    where id = v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status = case when p_finalize then 'completed' else 'in_progress' end,
      updated_at = now()
  where assessment_event_id = p_event_id
    and form_code = 'home_safety'
    and (p_finalize or status <> 'completed');

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$
