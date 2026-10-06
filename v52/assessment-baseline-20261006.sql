-- V5.2 評估管理 consolidated baseline
-- Source of truth: TEST production-candidate state on 2026-10-06.
-- Test data is disposable. This file rebuilds assessment-owned tables, but preserves care_cases rows.
-- Permission model intentionally preserved: supervisors may view and edit all cases.

begin;
set local search_path = public, private, extensions;

-- Live permission helpers required by assessment RLS.
CREATE OR REPLACE FUNCTION private.can_edit_assessment_case(p_case_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select
    exists (
      select 1
      from public.care_cases c
      where c.id = p_case_id
    )
    and exists (
      select 1
      from public.staff_users s
      where lower(s.email)=lower(coalesce((select auth.jwt())->>'email',''))
        and s.is_active=true
        and s.role in ('supervisor','business_manager','organization_manager','admin')
    );
$function$;
revoke all on function private.can_edit_assessment_case(uuid) from public, anon, authenticated;
grant execute on function private.can_edit_assessment_case(uuid) to authenticated;
grant execute on function private.can_edit_assessment_case(uuid) to service_role;

CREATE OR REPLACE FUNCTION private.can_view_assessment_history()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from public.staff_users s
    where lower(s.email)=lower(coalesce((select auth.jwt())->>'email',''))
      and s.is_active=true
      and s.role in ('business_manager','organization_manager','admin')
  );
$function$;
revoke all on function private.can_view_assessment_history() from public, anon, authenticated;
grant execute on function private.can_view_assessment_history() to authenticated;
grant execute on function private.can_view_assessment_history() to service_role;

-- Remove assessment-owned live objects. No other module has FK dependencies on these tables.
drop table if exists public.assessment_event_summary_history cascade;
drop table if exists public.assessment_event_summaries cascade;
drop table if exists public.assessment_caregiver_screen_history cascade;
drop table if exists public.assessment_caregiver_screen_records cascade;
drop table if exists public.assessment_support_history cascade;
drop table if exists public.assessment_support_records cascade;
drop table if exists public.assessment_home_safety_history cascade;
drop table if exists public.assessment_home_safety_records cascade;
drop table if exists public.assessment_health_history cascade;
drop table if exists public.assessment_health_records cascade;
drop table if exists public.assessment_gds15_history cascade;
drop table if exists public.assessment_gds15_records cascade;
drop table if exists public.assessment_spmsq_history cascade;
drop table if exists public.assessment_spmsq_records cascade;
drop table if exists public.assessment_iadl_history cascade;
drop table if exists public.assessment_iadl_records cascade;
drop table if exists public.assessment_adl_history cascade;
drop table if exists public.assessment_adl_records cascade;
drop table if exists public.assessment_event_forms cascade;
drop table if exists public.assessment_events cascade;
drop table if exists public.case_health_profile_history cascade;

alter table public.care_cases
  add column if not exists important_conditions text,
  add column if not exists ongoing_treatments text;

create table public.case_health_profile_history (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null check (field_name in ('important_conditions','ongoing_treatments')),
  old_value text,
  new_value text,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);
create index case_health_profile_history_case_idx
  on public.case_health_profile_history(case_id,changed_at desc);
alter table public.case_health_profile_history enable row level security;
create policy case_health_profile_history_read
  on public.case_health_profile_history for select to authenticated
  using (private.can_manage_cases());
create policy case_health_profile_history_insert
  on public.case_health_profile_history for insert to authenticated
  with check (
    changed_by=(select auth.uid())
    and exists (
      select 1 from public.care_cases c
      where c.id=case_health_profile_history.case_id
        and private.can_edit_assessment_case(c.id)
    )
  );
revoke all on public.case_health_profile_history from public, anon, authenticated;
grant select,insert on public.case_health_profile_history to authenticated;
grant all on public.case_health_profile_history to service_role;


-- ===== v52/assessment-shell-supabase-20261001.sql =====
-- V5.2 評估管理：評估事件外殼
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-01
-- 說明：建立正式評估事件與本次選用評估工具資料表；ADL 等量表內容另於後續階段建立。


create table if not exists public.assessment_events (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.care_cases(id) on delete cascade,
  assessment_type text not null
    check (assessment_type in ('opening','periodic','condition_change','specific_problem')),
  planned_date date not null,
  reason_code text,
  reason_note text,
  combined_with_home_visit boolean not null default false,
  responsible_staff_id uuid references public.staff_users(id) on delete set null,
  status text not null default 'pending'
    check (status in ('pending','in_progress','forms_completed','completed','voided')),
  started_at timestamptz,
  forms_completed_at timestamptz,
  completed_at timestamptz,
  voided_at timestamptz,
  void_reason text,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists assessment_events_case_id_idx
  on public.assessment_events(case_id);
create index if not exists assessment_events_planned_date_idx
  on public.assessment_events(planned_date);
create index if not exists assessment_events_status_idx
  on public.assessment_events(status);
create index if not exists assessment_events_responsible_staff_id_idx
  on public.assessment_events(responsible_staff_id);

create table if not exists public.assessment_event_forms (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  form_code text not null,
  form_name text not null,
  sort_order integer not null default 0,
  is_required boolean not null default false,
  status text not null default 'pending'
    check (status in ('pending','in_progress','completed','unable','not_applicable')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (assessment_event_id, form_code)
);

create index if not exists assessment_event_forms_event_id_idx
  on public.assessment_event_forms(assessment_event_id);

alter table public.assessment_events enable row level security;
alter table public.assessment_event_forms enable row level security;

drop policy if exists assessment_events_read on public.assessment_events;
create policy assessment_events_read
on public.assessment_events
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_events_insert on public.assessment_events;
create policy assessment_events_insert
on public.assessment_events
for insert
to authenticated
with check (
  created_by = (select auth.uid())
  and exists (
    select 1
    from public.care_cases c
    where c.id = assessment_events.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_events_update on public.assessment_events;
create policy assessment_events_update
on public.assessment_events
for update
to authenticated
using (
  exists (
    select 1
    from public.care_cases c
    where c.id = assessment_events.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1
    from public.care_cases c
    where c.id = assessment_events.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_event_forms_read on public.assessment_event_forms;
create policy assessment_event_forms_read
on public.assessment_event_forms
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_event_forms_insert on public.assessment_event_forms;
create policy assessment_event_forms_insert
on public.assessment_event_forms
for insert
to authenticated
with check (
  exists (
    select 1
    from public.assessment_events ae
    join public.care_cases c on c.id = ae.case_id
    where ae.id = assessment_event_forms.assessment_event_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_event_forms_update on public.assessment_event_forms;
create policy assessment_event_forms_update
on public.assessment_event_forms
for update
to authenticated
using (
  exists (
    select 1
    from public.assessment_events ae
    join public.care_cases c on c.id = ae.case_id
    where ae.id = assessment_event_forms.assessment_event_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1
    from public.assessment_events ae
    join public.care_cases c on c.id = ae.case_id
    where ae.id = assessment_event_forms.assessment_event_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_event_forms_delete on public.assessment_event_forms;
create policy assessment_event_forms_delete
on public.assessment_event_forms
for delete
to authenticated
using (
  exists (
    select 1
    from public.assessment_events ae
    join public.care_cases c on c.id = ae.case_id
    where ae.id = assessment_event_forms.assessment_event_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_events from public, anon, authenticated;
revoke all on public.assessment_event_forms from public, anon, authenticated;

grant select, insert, update on public.assessment_events to authenticated;
grant select, insert, update, delete on public.assessment_event_forms to authenticated;

grant all on public.assessment_events to service_role;
grant all on public.assessment_event_forms to service_role;

-- ===== v52/assessment-adl-supabase-20261001.sql =====
-- V5.2 評估管理：完整評估週期欄位＋Barthel ADL
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-01
-- 目的：
-- 1. 狀況變化／特定問題評估可有獨立問題追蹤日期，不直接改變完整評估週期。
-- 2. 保留「視同完整再評估」欄位，待評估總結階段依完整核心工具完成情形由督導確認。
-- 3. 建立 Barthel ADL 結構化資料、修改歷程及交易式儲存 RPC。


alter table public.assessment_events
  add column if not exists problem_followup_date date,
  add column if not exists counts_as_full_reassessment boolean not null default false,
  add column if not exists full_reassessment_decided_at timestamptz,
  add column if not exists full_reassessment_decided_by uuid;

create table if not exists public.assessment_adl_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  answers jsonb not null default '{}'::jsonb,
  notes jsonb not null default '{}'::jsonb,
  total_score integer check (total_score between 0 and 100),
  dependency_level text check (
    dependency_level is null or dependency_level in (
      'complete_dependence','severe_dependence','moderate_dependence',
      'mild_dependence','independent'
    )
  ),
  copied_from_id uuid references public.assessment_adl_records(id) on delete set null,
  copied_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists assessment_adl_records_case_id_idx
  on public.assessment_adl_records(case_id);
create index if not exists assessment_adl_records_event_id_idx
  on public.assessment_adl_records(assessment_event_id);
create index if not exists assessment_adl_records_confirmed_at_idx
  on public.assessment_adl_records(confirmed_at);
create index if not exists assessment_adl_records_copied_from_id_idx
  on public.assessment_adl_records(copied_from_id);

create table if not exists public.assessment_adl_history (
  id uuid primary key default gen_random_uuid(),
  adl_record_id uuid not null references public.assessment_adl_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_adl_history_record_idx
  on public.assessment_adl_history(adl_record_id, changed_at);
create index if not exists assessment_adl_history_case_idx
  on public.assessment_adl_history(case_id, changed_at);
create index if not exists assessment_adl_history_event_id_idx
  on public.assessment_adl_history(assessment_event_id);

alter table public.assessment_adl_records enable row level security;
alter table public.assessment_adl_history enable row level security;

drop policy if exists assessment_adl_read on public.assessment_adl_records;
create policy assessment_adl_read
on public.assessment_adl_records
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_adl_insert on public.assessment_adl_records;
create policy assessment_adl_insert
on public.assessment_adl_records
for insert
to authenticated
with check (
  created_by = (select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id = assessment_adl_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_adl_update on public.assessment_adl_records;
create policy assessment_adl_update
on public.assessment_adl_records
for update
to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id = assessment_adl_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id = assessment_adl_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_adl_history_read on public.assessment_adl_history;
create policy assessment_adl_history_read
on public.assessment_adl_history
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_adl_history_insert on public.assessment_adl_history;
create policy assessment_adl_history_insert
on public.assessment_adl_history
for insert
to authenticated
with check (
  changed_by = (select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id = assessment_adl_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_adl_records from public, anon, authenticated;
revoke all on public.assessment_adl_history from public, anon, authenticated;
grant select, insert, update on public.assessment_adl_records to authenticated;
grant select, insert on public.assessment_adl_history to authenticated;
grant all on public.assessment_adl_records to service_role;
grant all on public.assessment_adl_history to service_role;


create or replace function public.save_assessment_adl(
  p_event_id uuid,
  p_answers jsonb,
  p_notes jsonb,
  p_finalize boolean default false,
  p_copied_from_id uuid default null
)
returns public.assessment_adl_records
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_adl_records;
  v_old public.assessment_adl_records;
  v_total integer := 0;
  v_level text := null;
  v_key text;
  v_required text[] := array[
    'feeding','transfer','grooming','toileting','bathing',
    'walking','stairs','dressing','bowel','bladder'
  ];
  v_score integer;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id = p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id = v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id = p_event_id and f.form_code = 'adl'
  ) then raise exception 'ADL_FORM_NOT_SELECTED'; end if;

  p_answers := coalesce(p_answers, '{}'::jsonb);
  p_notes := coalesce(p_notes, '{}'::jsonb);

  foreach v_key in array v_required loop
    if p_answers ? v_key then
      begin v_score := (p_answers ->> v_key)::integer;
      exception when others then raise exception 'INVALID_ADL_SCORE:%', v_key; end;

      if
        (v_key = 'feeding' and v_score not in (0,5,10)) or
        (v_key = 'transfer' and v_score not in (0,5,10,15)) or
        (v_key = 'grooming' and v_score not in (0,5)) or
        (v_key = 'toileting' and v_score not in (0,5,10)) or
        (v_key = 'bathing' and v_score not in (0,5)) or
        (v_key = 'walking' and v_score not in (0,5,10,15)) or
        (v_key = 'stairs' and v_score not in (0,5,10)) or
        (v_key = 'dressing' and v_score not in (0,5,10)) or
        (v_key = 'bowel' and v_score not in (0,5,10)) or
        (v_key = 'bladder' and v_score not in (0,5,10))
      then raise exception 'INVALID_ADL_SCORE:%', v_key; end if;

      v_total := v_total + v_score;
    elsif p_finalize then
      raise exception 'ADL_INCOMPLETE:%', v_key;
    end if;
  end loop;

  if p_finalize then
    v_level := case
      when v_total <= 20 then 'complete_dependence'
      when v_total <= 60 then 'severe_dependence'
      when v_total <= 90 then 'moderate_dependence'
      when v_total <= 99 then 'mild_dependence'
      else 'independent'
    end;
  end if;

  select * into v_old
  from public.assessment_adl_records
  where assessment_event_id = p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_adl_records(
      assessment_event_id, case_id, answers, notes, total_score, dependency_level,
      copied_from_id, copied_at, confirmed_at, created_by, updated_by
    ) values (
      p_event_id, v_event.case_id, p_answers, p_notes,
      case when p_answers <> '{}'::jsonb then v_total else null end,
      v_level, p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()), (select auth.uid())
    ) returning * into v_record;
  else
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.answers,'{}'::jsonb) || p_answers) as t(key)
    loop
      if (v_old.answers -> v_key) is distinct from (p_answers -> v_key) then
        insert into public.assessment_adl_history(
          adl_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'answers.'||v_key,
          v_old.answers -> v_key, p_answers -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.notes,'{}'::jsonb) || p_notes) as t(key)
    loop
      if (v_old.notes -> v_key) is distinct from (p_notes -> v_key) then
        insert into public.assessment_adl_history(
          adl_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'notes.'||v_key,
          v_old.notes -> v_key, p_notes -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    update public.assessment_adl_records
    set
      answers = p_answers,
      notes = p_notes,
      total_score = case when p_answers <> '{}'::jsonb then v_total else null end,
      dependency_level = case when p_finalize then v_level else dependency_level end,
      copied_from_id = coalesce(copied_from_id, p_copied_from_id),
      copied_at = case
        when copied_at is not null then copied_at
        when p_copied_from_id is not null then now()
        else null
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
    and form_code = 'adl'
    and (p_finalize or status <> 'completed');

  update public.assessment_events
  set
    status = case
      when p_finalize and not exists (
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id = p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then 'forms_completed'
      when status = 'pending' then 'in_progress'
      else status
    end,
    started_at = coalesce(started_at, now()),
    forms_completed_at = case
      when p_finalize and not exists (
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id = p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then coalesce(forms_completed_at, now())
      else forms_completed_at
    end,
    updated_by = (select auth.uid()),
    updated_at = now()
  where id = p_event_id;

  return v_record;
end;
$$;

revoke all on function public.save_assessment_adl(uuid,jsonb,jsonb,boolean,uuid) from public, anon;
grant execute on function public.save_assessment_adl(uuid,jsonb,jsonb,boolean,uuid) to authenticated;

-- ===== v52/assessment-iadl-supabase-20261001.sql =====
-- V5.2 評估管理：Lawton IADL
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-01
-- 說明：建立 IADL 結構化紀錄、修改歷程、RLS 與儲存 RPC。
-- 前次紀錄的選擇由前端依本次評估日期動態判斷，不以建立順序判斷。


create table if not exists public.assessment_iadl_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  answers jsonb not null default '{}'::jsonb,
  notes jsonb not null default '{}'::jsonb,
  total_score integer check (total_score between 0 and 16),
  copied_from_id uuid references public.assessment_iadl_records(id) on delete set null,
  copied_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists assessment_iadl_records_case_id_idx
  on public.assessment_iadl_records(case_id);
create index if not exists assessment_iadl_records_event_id_idx
  on public.assessment_iadl_records(assessment_event_id);
create index if not exists assessment_iadl_records_confirmed_at_idx
  on public.assessment_iadl_records(confirmed_at);
create index if not exists assessment_iadl_records_copied_from_id_idx
  on public.assessment_iadl_records(copied_from_id);

create table if not exists public.assessment_iadl_history (
  id uuid primary key default gen_random_uuid(),
  iadl_record_id uuid not null references public.assessment_iadl_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_iadl_history_record_idx
  on public.assessment_iadl_history(iadl_record_id, changed_at);
create index if not exists assessment_iadl_history_case_idx
  on public.assessment_iadl_history(case_id, changed_at);
create index if not exists assessment_iadl_history_event_id_idx
  on public.assessment_iadl_history(assessment_event_id);

alter table public.assessment_iadl_records enable row level security;
alter table public.assessment_iadl_history enable row level security;

drop policy if exists assessment_iadl_read on public.assessment_iadl_records;
create policy assessment_iadl_read
on public.assessment_iadl_records
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_iadl_insert on public.assessment_iadl_records;
create policy assessment_iadl_insert
on public.assessment_iadl_records
for insert
to authenticated
with check (
  created_by = (select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id = assessment_iadl_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_iadl_update on public.assessment_iadl_records;
create policy assessment_iadl_update
on public.assessment_iadl_records
for update
to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id = assessment_iadl_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id = assessment_iadl_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_iadl_history_read on public.assessment_iadl_history;
create policy assessment_iadl_history_read
on public.assessment_iadl_history
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_iadl_history_insert on public.assessment_iadl_history;
create policy assessment_iadl_history_insert
on public.assessment_iadl_history
for insert
to authenticated
with check (
  changed_by = (select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id = assessment_iadl_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_iadl_records from public, anon, authenticated;
revoke all on public.assessment_iadl_history from public, anon, authenticated;
grant select, insert, update on public.assessment_iadl_records to authenticated;
grant select, insert on public.assessment_iadl_history to authenticated;
grant all on public.assessment_iadl_records to service_role;
grant all on public.assessment_iadl_history to service_role;


create or replace function public.save_assessment_iadl(
  p_event_id uuid,
  p_answers jsonb,
  p_notes jsonb,
  p_finalize boolean default false,
  p_copied_from_id uuid default null
)
returns public.assessment_iadl_records
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_iadl_records;
  v_old public.assessment_iadl_records;
  v_total integer := 0;
  v_key text;
  v_required text[] := array[
    'telephone','shopping','meal_prep','housekeeping',
    'laundry','transportation','medication','finances'
  ];
  v_score integer;
begin
  if (select auth.uid()) is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_event
  from public.assessment_events
  where id = p_event_id;

  if v_event.id is null then
    raise exception 'ASSESSMENT_EVENT_NOT_FOUND';
  end if;

  select * into v_case
  from public.care_cases
  where id = v_event.case_id;

  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1
    from public.assessment_event_forms f
    where f.assessment_event_id = p_event_id
      and f.form_code = 'iadl'
  ) then
    raise exception 'IADL_FORM_NOT_SELECTED';
  end if;

  p_answers := coalesce(p_answers, '{}'::jsonb);
  p_notes := coalesce(p_notes, '{}'::jsonb);

  foreach v_key in array v_required loop
    if (p_answers ->> v_key) is not null then
      begin
        v_score := (p_answers ->> v_key)::integer;
      exception when others then
        raise exception 'INVALID_IADL_SCORE:%', v_key;
      end;

      if v_score not in (0,1,2) then
        raise exception 'INVALID_IADL_SCORE:%', v_key;
      end if;

      v_total := v_total + v_score;
    elsif p_finalize then
      raise exception 'IADL_INCOMPLETE:%', v_key;
    end if;
  end loop;

  select * into v_old
  from public.assessment_iadl_records
  where assessment_event_id = p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_iadl_records(
      assessment_event_id, case_id, answers, notes, total_score,
      copied_from_id, copied_at, confirmed_at, created_by, updated_by
    ) values (
      p_event_id, v_event.case_id, p_answers, p_notes,
      case when p_answers <> '{}'::jsonb then v_total else null end,
      p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()), (select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.answers,'{}'::jsonb) || p_answers) as t(key)
    loop
      if (v_old.answers -> v_key) is distinct from (p_answers -> v_key) then
        insert into public.assessment_iadl_history(
          iadl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'answers.'||v_key,
          v_old.answers -> v_key, p_answers -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.notes,'{}'::jsonb) || p_notes) as t(key)
    loop
      if (v_old.notes -> v_key) is distinct from (p_notes -> v_key) then
        insert into public.assessment_iadl_history(
          iadl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'notes.'||v_key,
          v_old.notes -> v_key, p_notes -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    update public.assessment_iadl_records
    set
      answers = p_answers,
      notes = p_notes,
      total_score = case when p_answers <> '{}'::jsonb then v_total else null end,
      copied_from_id = coalesce(copied_from_id, p_copied_from_id),
      copied_at = case
        when copied_at is not null then copied_at
        when p_copied_from_id is not null then now()
        else null
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
    and form_code = 'iadl'
    and (p_finalize or status <> 'completed');

  update public.assessment_events
  set
    status = case
      when p_finalize and not exists (
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id = p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then 'forms_completed'
      when status = 'pending' then 'in_progress'
      else status
    end,
    started_at = coalesce(started_at, now()),
    forms_completed_at = case
      when p_finalize and not exists (
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id = p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then coalesce(forms_completed_at, now())
      else forms_completed_at
    end,
    updated_by = (select auth.uid()),
    updated_at = now()
  where id = p_event_id;

  return v_record;
end;
$$;

revoke all on function public.save_assessment_iadl(uuid,jsonb,jsonb,boolean,uuid) from public, anon;
grant execute on function public.save_assessment_iadl(uuid,jsonb,jsonb,boolean,uuid) to authenticated;

-- ===== v52/assessment-spmsq-supabase-20261001.sql =====
-- V5.2 評估管理：SPMSQ
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-01
-- 依機構現行表單：10題、受訪者回答、正確／錯誤判定、錯誤題數、無法評估原因。


create table if not exists public.assessment_spmsq_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  responses jsonb not null default '{}'::jsonb,
  judgments jsonb not null default '{}'::jsonb,
  error_count integer check (error_count between 0 and 10),
  is_unable boolean not null default false,
  unable_reason text,
  copied_from_id uuid references public.assessment_spmsq_records(id) on delete set null,
  copied_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((not is_unable) or (unable_reason is not null and btrim(unable_reason) <> ''))
);

create index if not exists assessment_spmsq_records_case_id_idx on public.assessment_spmsq_records(case_id);
create index if not exists assessment_spmsq_records_event_id_idx on public.assessment_spmsq_records(assessment_event_id);
create index if not exists assessment_spmsq_records_confirmed_at_idx on public.assessment_spmsq_records(confirmed_at);
create index if not exists assessment_spmsq_records_copied_from_id_idx on public.assessment_spmsq_records(copied_from_id);

create table if not exists public.assessment_spmsq_history (
  id uuid primary key default gen_random_uuid(),
  spmsq_record_id uuid not null references public.assessment_spmsq_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_spmsq_history_record_idx on public.assessment_spmsq_history(spmsq_record_id, changed_at);
create index if not exists assessment_spmsq_history_case_idx on public.assessment_spmsq_history(case_id, changed_at);
create index if not exists assessment_spmsq_history_event_id_idx on public.assessment_spmsq_history(assessment_event_id);

alter table public.assessment_spmsq_records enable row level security;
alter table public.assessment_spmsq_history enable row level security;

drop policy if exists assessment_spmsq_read on public.assessment_spmsq_records;
create policy assessment_spmsq_read on public.assessment_spmsq_records for select to authenticated using (private.can_manage_cases());

drop policy if exists assessment_spmsq_insert on public.assessment_spmsq_records;
create policy assessment_spmsq_insert on public.assessment_spmsq_records for insert to authenticated
with check (
  created_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_spmsq_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_spmsq_update on public.assessment_spmsq_records;
create policy assessment_spmsq_update on public.assessment_spmsq_records for update to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_spmsq_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_spmsq_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_spmsq_history_read on public.assessment_spmsq_history;
create policy assessment_spmsq_history_read on public.assessment_spmsq_history for select to authenticated using (private.can_manage_cases());

drop policy if exists assessment_spmsq_history_insert on public.assessment_spmsq_history;
create policy assessment_spmsq_history_insert on public.assessment_spmsq_history for insert to authenticated
with check (
  changed_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_spmsq_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_spmsq_records from public, anon, authenticated;
revoke all on public.assessment_spmsq_history from public, anon, authenticated;
grant select, insert, update on public.assessment_spmsq_records to authenticated;
grant select, insert on public.assessment_spmsq_history to authenticated;
grant all on public.assessment_spmsq_records to service_role;
grant all on public.assessment_spmsq_history to service_role;


create or replace function public.save_assessment_spmsq(
  p_event_id uuid,
  p_responses jsonb,
  p_judgments jsonb,
  p_finalize boolean default false,
  p_unable boolean default false,
  p_unable_reason text default null,
  p_copied_from_id uuid default null
)
returns public.assessment_spmsq_records
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_spmsq_records;
  v_old public.assessment_spmsq_records;
  v_key text;
  v_keys text[]:=array['q1','q2','q3','q4','q5','q6','q7','q8','q9','q10'];
  v_judgment text;
  v_error_count integer:=0;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id and f.form_code='spmsq'
  ) then raise exception 'SPMSQ_FORM_NOT_SELECTED'; end if;

  p_responses:=coalesce(p_responses,'{}'::jsonb);
  p_judgments:=coalesce(p_judgments,'{}'::jsonb);
  p_unable_reason:=nullif(btrim(p_unable_reason),'');

  if p_unable and p_unable_reason is null then
    raise exception 'SPMSQ_UNABLE_REASON_REQUIRED';
  end if;

  foreach v_key in array v_keys loop
    v_judgment:=p_judgments->>v_key;
    if v_judgment is not null and v_judgment not in ('correct','wrong') then
      raise exception 'INVALID_SPMSQ_JUDGMENT:%',v_key;
    end if;

    if not p_unable then
      if p_finalize and nullif(btrim(p_responses->>v_key),'') is null then
        raise exception 'SPMSQ_RESPONSE_INCOMPLETE:%',v_key;
      end if;
      if p_finalize and v_judgment is null then
        raise exception 'SPMSQ_JUDGMENT_INCOMPLETE:%',v_key;
      end if;
      if v_judgment='wrong' then v_error_count:=v_error_count+1; end if;
    end if;
  end loop;

  select * into v_old from public.assessment_spmsq_records
  where assessment_event_id=p_event_id for update;

  if v_old.id is null then
    insert into public.assessment_spmsq_records(
      assessment_event_id,case_id,responses,judgments,error_count,is_unable,unable_reason,
      copied_from_id,copied_at,confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_responses,p_judgments,
      case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
      p_unable,p_unable_reason,p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in select key from jsonb_object_keys(coalesce(v_old.responses,'{}'::jsonb)||p_responses) as t(key)
    loop
      if (v_old.responses->v_key) is distinct from (p_responses->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'responses.'||v_key,
          v_old.responses->v_key,p_responses->v_key,(select auth.uid())
        );
      end if;
    end loop;

    for v_key in select key from jsonb_object_keys(coalesce(v_old.judgments,'{}'::jsonb)||p_judgments) as t(key)
    loop
      if (v_old.judgments->v_key) is distinct from (p_judgments->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'judgments.'||v_key,
          v_old.judgments->v_key,p_judgments->v_key,(select auth.uid())
        );
      end if;
    end loop;

    if v_old.is_unable is distinct from p_unable then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'is_unable',
        to_jsonb(v_old.is_unable),to_jsonb(p_unable),(select auth.uid())
      );
    end if;

    if v_old.unable_reason is distinct from p_unable_reason then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'unable_reason',
        to_jsonb(v_old.unable_reason),to_jsonb(p_unable_reason),(select auth.uid())
      );
    end if;

    update public.assessment_spmsq_records
    set responses=p_responses,
        judgments=p_judgments,
        error_count=case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
        is_unable=p_unable,
        unable_reason=p_unable_reason,
        copied_from_id=coalesce(copied_from_id,p_copied_from_id),
        copied_at=case when copied_at is not null then copied_at when p_copied_from_id is not null then now() else null end,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case when p_finalize and p_unable then 'unable' when p_finalize then 'completed' else 'in_progress' end,
      updated_at=now()
  where assessment_event_id=p_event_id and form_code='spmsq';

  update public.assessment_events
  set status=case
      when p_finalize and not exists (
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id=p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then 'forms_completed'
      when status='pending' then 'in_progress'
      else status
    end,
    started_at=coalesce(started_at,now()),
    forms_completed_at=case
      when p_finalize and not exists (
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id=p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then coalesce(forms_completed_at,now())
      else forms_completed_at
    end,
    updated_by=(select auth.uid()),
    updated_at=now()
  where id=p_event_id;

  return v_record;
end;
$$;

revoke all on function public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid) from public, anon;
grant execute on function public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid) to authenticated;

-- ===== v52/assessment-gds15-supabase-20261001.sql =====
-- V5.2 評估管理：GDS-15 公版
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-01
-- 題目與計分邏輯採桃園市政府衛生局老人心理健康評估表(GDS-15)／衛福部公版。
-- 最近一週、15題、是／否。
-- 第1、5、7、11、13題答「否」計1分；其餘10題答「是」計1分；總分0–15。
-- 支援正常評估、無法評估、不適用；後兩者需填原因。


create table if not exists public.assessment_gds15_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  answers jsonb not null default '{}'::jsonb,
  total_score integer check (total_score between 0 and 15),
  completion_mode text not null default 'completed'
    check (completion_mode in ('completed','unable','not_applicable')),
  exception_reason text,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    completion_mode='completed'
    or (exception_reason is not null and btrim(exception_reason)<>'')
  )
);

create index if not exists assessment_gds15_records_case_id_idx on public.assessment_gds15_records(case_id);
create index if not exists assessment_gds15_records_event_id_idx on public.assessment_gds15_records(assessment_event_id);
create index if not exists assessment_gds15_records_confirmed_at_idx on public.assessment_gds15_records(confirmed_at);

create table if not exists public.assessment_gds15_history (
  id uuid primary key default gen_random_uuid(),
  gds15_record_id uuid not null references public.assessment_gds15_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_gds15_history_record_idx on public.assessment_gds15_history(gds15_record_id, changed_at);
create index if not exists assessment_gds15_history_case_idx on public.assessment_gds15_history(case_id, changed_at);
create index if not exists assessment_gds15_history_event_id_idx on public.assessment_gds15_history(assessment_event_id);

alter table public.assessment_gds15_records enable row level security;
alter table public.assessment_gds15_history enable row level security;

drop policy if exists assessment_gds15_read on public.assessment_gds15_records;
create policy assessment_gds15_read on public.assessment_gds15_records for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_gds15_insert on public.assessment_gds15_records;
create policy assessment_gds15_insert on public.assessment_gds15_records for insert to authenticated
with check (
  created_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_gds15_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_gds15_update on public.assessment_gds15_records;
create policy assessment_gds15_update on public.assessment_gds15_records for update to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_gds15_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_gds15_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_gds15_history_read on public.assessment_gds15_history;
create policy assessment_gds15_history_read on public.assessment_gds15_history for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_gds15_history_insert on public.assessment_gds15_history;
create policy assessment_gds15_history_insert on public.assessment_gds15_history for insert to authenticated
with check (
  changed_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_gds15_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_gds15_records from public, anon, authenticated;
revoke all on public.assessment_gds15_history from public, anon, authenticated;
grant select, insert, update on public.assessment_gds15_records to authenticated;
grant select, insert on public.assessment_gds15_history to authenticated;
grant all on public.assessment_gds15_records to service_role;
grant all on public.assessment_gds15_history to service_role;


create or replace function public.save_assessment_gds15(
  p_event_id uuid,
  p_answers jsonb,
  p_finalize boolean default false,
  p_completion_mode text default 'completed',
  p_exception_reason text default null
)
returns public.assessment_gds15_records
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_gds15_records;
  v_old public.assessment_gds15_records;
  v_key text;
  v_keys text[]:=array['q1','q2','q3','q4','q5','q6','q7','q8','q9','q10','q11','q12','q13','q14','q15'];
  v_reverse text[]:=array['q1','q5','q7','q11','q13'];
  v_value text;
  v_total integer:=0;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id and f.form_code='gds15'
  ) then raise exception 'GDS15_FORM_NOT_SELECTED'; end if;

  p_answers:=coalesce(p_answers,'{}'::jsonb);
  p_completion_mode:=coalesce(p_completion_mode,'completed');
  p_exception_reason:=nullif(btrim(p_exception_reason),'');

  if p_completion_mode not in ('completed','unable','not_applicable') then
    raise exception 'INVALID_GDS15_COMPLETION_MODE';
  end if;

  if p_completion_mode<>'completed' and p_exception_reason is null then
    raise exception 'GDS15_EXCEPTION_REASON_REQUIRED';
  end if;

  foreach v_key in array v_keys loop
    v_value:=p_answers->>v_key;

    if v_value is not null and v_value not in ('yes','no') then
      raise exception 'INVALID_GDS15_ANSWER:%',v_key;
    end if;

    if p_finalize and p_completion_mode='completed' and v_value is null then
      raise exception 'GDS15_INCOMPLETE:%',v_key;
    end if;

    if p_completion_mode='completed' and v_value is not null then
      if v_key=any(v_reverse) then
        if v_value='no' then v_total:=v_total+1; end if;
      else
        if v_value='yes' then v_total:=v_total+1; end if;
      end if;
    end if;
  end loop;

  select * into v_old
  from public.assessment_gds15_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_gds15_records(
      assessment_event_id,case_id,answers,total_score,completion_mode,exception_reason,
      confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_answers,
      case when p_completion_mode='completed' and p_answers<>'{}'::jsonb then v_total else null end,
      p_completion_mode,p_exception_reason,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.answers,'{}'::jsonb)||p_answers) as t(key)
    loop
      if (v_old.answers->v_key) is distinct from (p_answers->v_key) then
        insert into public.assessment_gds15_history(
          gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'answers.'||v_key,
          v_old.answers->v_key,p_answers->v_key,(select auth.uid())
        );
      end if;
    end loop;

    if v_old.completion_mode is distinct from p_completion_mode then
      insert into public.assessment_gds15_history(
        gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'completion_mode',
        to_jsonb(v_old.completion_mode),to_jsonb(p_completion_mode),(select auth.uid())
      );
    end if;

    if v_old.exception_reason is distinct from p_exception_reason then
      insert into public.assessment_gds15_history(
        gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'exception_reason',
        to_jsonb(v_old.exception_reason),to_jsonb(p_exception_reason),(select auth.uid())
      );
    end if;

    update public.assessment_gds15_records
    set answers=p_answers,
        total_score=case when p_completion_mode='completed' and p_answers<>'{}'::jsonb then v_total else null end,
        completion_mode=p_completion_mode,
        exception_reason=p_exception_reason,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case
      when p_finalize and p_completion_mode='unable' then 'unable'
      when p_finalize and p_completion_mode='not_applicable' then 'not_applicable'
      when p_finalize then 'completed'
      else 'in_progress'
    end,
    updated_at=now()
  where assessment_event_id=p_event_id and form_code='gds15';

  update public.assessment_events
  set status=case
      when p_finalize and not exists(
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id=p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then 'forms_completed'
      when status='pending' then 'in_progress'
      else status
    end,
    started_at=coalesce(started_at,now()),
    forms_completed_at=case
      when p_finalize and not exists(
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id=p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then coalesce(forms_completed_at,now())
      else forms_completed_at
    end,
    updated_by=(select auth.uid()),
    updated_at=now()
  where id=p_event_id;

  return v_record;
end;
$$;

revoke all on function public.save_assessment_gds15(uuid,jsonb,boolean,text,text) from public, anon;
grant execute on function public.save_assessment_gds15(uuid,jsonb,boolean,text,text) to authenticated;

-- ===== Health assessment live schema missing from historical files =====
create table public.assessment_health_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  medical_info jsonb not null default '{}'::jsonb,
  medication_checks jsonb not null default '{}'::jsonb,
  health_items jsonb not null default '{}'::jsonb,
  health_notes jsonb not null default '{}'::jsonb,
  total_score integer check (total_score>=0 and total_score<=20),
  copied_from_id uuid references public.assessment_health_records(id) on delete set null,
  copied_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  baseline_confirmed_at timestamptz,
  change_confirmed_at timestamptz,
  status_confirmed_at timestamptz
);
create index assessment_health_records_case_id_idx on public.assessment_health_records(case_id);
create index assessment_health_records_event_id_idx on public.assessment_health_records(assessment_event_id);
create index assessment_health_records_confirmed_at_idx on public.assessment_health_records(confirmed_at);
create index assessment_health_records_copied_from_id_idx on public.assessment_health_records(copied_from_id);

create table public.assessment_health_history (
  id uuid primary key default gen_random_uuid(),
  health_record_id uuid not null references public.assessment_health_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);
create index assessment_health_history_record_idx on public.assessment_health_history(health_record_id,changed_at);
create index assessment_health_history_case_idx on public.assessment_health_history(case_id,changed_at);
create index assessment_health_history_event_id_idx on public.assessment_health_history(assessment_event_id);

alter table public.assessment_health_records enable row level security;
alter table public.assessment_health_history enable row level security;

create policy assessment_health_read
  on public.assessment_health_records for select to authenticated
  using (private.can_manage_cases());
create policy assessment_health_insert
  on public.assessment_health_records for insert to authenticated
  with check (
    created_by=(select auth.uid())
    and exists (
      select 1 from public.care_cases c
      where c.id=assessment_health_records.case_id
        and private.can_edit_assessment_case(c.id)
    )
  );
create policy assessment_health_update
  on public.assessment_health_records for update to authenticated
  using (
    exists (
      select 1 from public.care_cases c
      where c.id=assessment_health_records.case_id
        and private.can_edit_assessment_case(c.id)
    )
  )
  with check (
    exists (
      select 1 from public.care_cases c
      where c.id=assessment_health_records.case_id
        and private.can_edit_assessment_case(c.id)
    )
  );

create policy assessment_health_history_read
  on public.assessment_health_history for select to authenticated
  using (private.can_view_assessment_history());
create policy assessment_health_history_insert
  on public.assessment_health_history for insert to authenticated
  with check (
    changed_by=(select auth.uid())
    and exists (
      select 1 from public.care_cases c
      where c.id=assessment_health_history.case_id
        and private.can_edit_assessment_case(c.id)
    )
  );

revoke all on public.assessment_health_records,public.assessment_health_history from public, anon, authenticated;
grant select,insert,update on public.assessment_health_records to authenticated;
grant select,insert on public.assessment_health_history to authenticated;
grant all on public.assessment_health_records,public.assessment_health_history to service_role;


-- ===== v52/assessment-health-current.sql =====
-- CURRENT RUNTIME DEFINITION — 評估管理／健康與用藥
-- 2026-10-02
-- 現行測試版定義；健康現況、身體健康10項與用藥均由單一 health_medication 工具管理。
-- 舊版歷史可由 Git 紀錄與備份分支追溯，主分支只保留此現行定義。

alter table public.assessment_health_records
  add column if not exists baseline_confirmed_at timestamptz,
  add column if not exists change_confirmed_at timestamptz,
  add column if not exists status_confirmed_at timestamptz;

-- 合併舊「身體與健康狀況評估」工具到 health_medication。
-- 只有舊兩張表都完成時，合併後才維持完成；只完成其中一張則回到進行中。
update public.assessment_event_forms hm
set status=case
      when hm.status='completed' and hs.status='completed' then 'completed'
      when hm.status in ('completed','in_progress') or hs.status in ('completed','in_progress') then 'in_progress'
      else hm.status
    end,
    updated_at=now()
from public.assessment_event_forms hs
where hm.assessment_event_id=hs.assessment_event_id
  and hm.form_code='health_medication'
  and hs.form_code='health_status';

delete from public.assessment_event_forms
where form_code='health_status';

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
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
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

  update public.assessment_events
  set status=case
      when p_finalize and p_section='all' and not exists(
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id=p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then 'forms_completed'
      when status='pending' then 'in_progress'
      else status
    end,
    started_at=coalesce(started_at,now()),
    forms_completed_at=case
      when p_finalize and p_section='all' and not exists(
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id=p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then coalesce(forms_completed_at,now())
      else forms_completed_at
    end,
    updated_by=(select auth.uid()),
    updated_at=now()
  where id=p_event_id;

  return v_record;
end;
$function$;


revoke all on function public.save_assessment_health(uuid,jsonb,jsonb,jsonb,jsonb,boolean,uuid,text) from public;
revoke all on function public.save_assessment_health(uuid,jsonb,jsonb,jsonb,jsonb,boolean,uuid,text) from anon;
grant execute on function public.save_assessment_health(uuid,jsonb,jsonb,jsonb,jsonb,boolean,uuid,text) to authenticated;

-- ===== v52/assessment-home-safety-supabase-20261002.sql =====
-- V5.2 評估管理：居家環境安全評估
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-02
-- 內容：21項居家安全評估、前次帶入、修改歷程與交易式儲存 RPC

create table if not exists public.assessment_home_safety_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  home_profile jsonb not null default '{}'::jsonb,
  answers jsonb not null default '{}'::jsonb,
  notes jsonb not null default '{}'::jsonb,
  summary jsonb not null default '{}'::jsonb,
  copied_from_id uuid references public.assessment_home_safety_records(id) on delete set null,
  copied_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists assessment_home_safety_records_case_id_idx
  on public.assessment_home_safety_records(case_id);
create index if not exists assessment_home_safety_records_event_id_idx
  on public.assessment_home_safety_records(assessment_event_id);
create index if not exists assessment_home_safety_records_confirmed_at_idx
  on public.assessment_home_safety_records(confirmed_at);
create index if not exists assessment_home_safety_records_copied_from_id_idx
  on public.assessment_home_safety_records(copied_from_id);

create table if not exists public.assessment_home_safety_history (
  id uuid primary key default gen_random_uuid(),
  home_safety_record_id uuid not null references public.assessment_home_safety_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_home_safety_history_record_idx
  on public.assessment_home_safety_history(home_safety_record_id, changed_at);
create index if not exists assessment_home_safety_history_case_idx
  on public.assessment_home_safety_history(case_id, changed_at);
create index if not exists assessment_home_safety_history_event_idx
  on public.assessment_home_safety_history(assessment_event_id);

alter table public.assessment_home_safety_records enable row level security;
alter table public.assessment_home_safety_history enable row level security;

drop policy if exists assessment_home_safety_read on public.assessment_home_safety_records;
create policy assessment_home_safety_read
on public.assessment_home_safety_records
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_home_safety_insert on public.assessment_home_safety_records;
create policy assessment_home_safety_insert
on public.assessment_home_safety_records
for insert
to authenticated
with check (
  created_by = (select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id = assessment_home_safety_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_home_safety_update on public.assessment_home_safety_records;
create policy assessment_home_safety_update
on public.assessment_home_safety_records
for update
to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id = assessment_home_safety_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id = assessment_home_safety_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_home_safety_history_read on public.assessment_home_safety_history;
create policy assessment_home_safety_history_read
on public.assessment_home_safety_history
for select
to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_home_safety_history_insert on public.assessment_home_safety_history;
create policy assessment_home_safety_history_insert
on public.assessment_home_safety_history
for insert
to authenticated
with check (
  changed_by = (select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id = assessment_home_safety_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_home_safety_records from public, anon, authenticated;
revoke all on public.assessment_home_safety_history from public, anon, authenticated;
grant select, insert, update on public.assessment_home_safety_records to authenticated;
grant select, insert on public.assessment_home_safety_history to authenticated;
grant all on public.assessment_home_safety_records to service_role;
grant all on public.assessment_home_safety_history to service_role;

create or replace function public.save_assessment_home_safety(
  p_event_id uuid,
  p_home_profile jsonb,
  p_answers jsonb,
  p_notes jsonb,
  p_summary jsonb,
  p_finalize boolean default false,
  p_copied_from_id uuid default null
)
returns public.assessment_home_safety_records
language plpgsql
security invoker
set search_path = ''
as $$
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
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
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
      ) values (v_old.id, p_event_id, v_event.case_id, 'home_profile', v_old.home_profile, p_home_profile, (select auth.uid()));
    end if;

    if v_old.answers is distinct from p_answers then
      insert into public.assessment_home_safety_history(
        home_safety_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
      ) values (v_old.id, p_event_id, v_event.case_id, 'answers', v_old.answers, p_answers, (select auth.uid()));
    end if;

    if v_old.notes is distinct from p_notes then
      insert into public.assessment_home_safety_history(
        home_safety_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
      ) values (v_old.id, p_event_id, v_event.case_id, 'notes', v_old.notes, p_notes, (select auth.uid()));
    end if;

    if v_old.summary is distinct from p_summary then
      insert into public.assessment_home_safety_history(
        home_safety_record_id, assessment_event_id, case_id, field_name, old_value, new_value, changed_by
      ) values (v_old.id, p_event_id, v_event.case_id, 'summary', v_old.summary, p_summary, (select auth.uid()));
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

  update public.assessment_events
  set
    status = case
      when p_finalize and not exists (
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id = p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then 'forms_completed'
      when status = 'pending' then 'in_progress'
      else status
    end,
    started_at = coalesce(started_at, now()),
    forms_completed_at = case
      when p_finalize and not exists (
        select 1 from public.assessment_event_forms f
        where f.assessment_event_id = p_event_id
          and f.status not in ('completed','unable','not_applicable')
      ) then coalesce(forms_completed_at, now())
      else forms_completed_at
    end,
    updated_by = (select auth.uid()),
    updated_at = now()
  where id = p_event_id;

  return v_record;
end;
$$;

revoke all on function public.save_assessment_home_safety(uuid,jsonb,jsonb,jsonb,jsonb,boolean,uuid) from public, anon;
grant execute on function public.save_assessment_home_safety(uuid,jsonb,jsonb,jsonb,jsonb,boolean,uuid) to authenticated;

-- ===== v52/assessment-support-supabase-20261002.sql =====
-- V5.2 評估管理：支持系統
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-02
-- 內容：家庭／照顧安排、7個支持面向、經濟與社會資源、前次帶入、歷程與儲存 RPC

create table if not exists public.assessment_support_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  household jsonb not null default '{}'::jsonb,
  family_members jsonb not null default '[]'::jsonb,
  support_domains jsonb not null default '{}'::jsonb,
  resources jsonb not null default '{}'::jsonb,
  summary jsonb not null default '{}'::jsonb,
  copied_from_id uuid references public.assessment_support_records(id) on delete set null,
  copied_at timestamptz,
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists assessment_support_records_case_id_idx on public.assessment_support_records(case_id);
create index if not exists assessment_support_records_event_id_idx on public.assessment_support_records(assessment_event_id);
create index if not exists assessment_support_records_confirmed_at_idx on public.assessment_support_records(confirmed_at);
create index if not exists assessment_support_records_copied_from_id_idx on public.assessment_support_records(copied_from_id);

create table if not exists public.assessment_support_history (
  id uuid primary key default gen_random_uuid(),
  support_record_id uuid not null references public.assessment_support_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_support_history_record_idx on public.assessment_support_history(support_record_id, changed_at);
create index if not exists assessment_support_history_case_idx on public.assessment_support_history(case_id, changed_at);
create index if not exists assessment_support_history_event_idx on public.assessment_support_history(assessment_event_id);

alter table public.assessment_support_records enable row level security;
alter table public.assessment_support_history enable row level security;

drop policy if exists assessment_support_read on public.assessment_support_records;
create policy assessment_support_read on public.assessment_support_records
for select to authenticated using (private.can_manage_cases());

drop policy if exists assessment_support_insert on public.assessment_support_records;
create policy assessment_support_insert on public.assessment_support_records
for insert to authenticated
with check (
  created_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_support_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_support_update on public.assessment_support_records;
create policy assessment_support_update on public.assessment_support_records
for update to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_support_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_support_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_support_history_read on public.assessment_support_history;
create policy assessment_support_history_read on public.assessment_support_history
for select to authenticated using (private.can_manage_cases());

drop policy if exists assessment_support_history_insert on public.assessment_support_history;
create policy assessment_support_history_insert on public.assessment_support_history
for insert to authenticated
with check (
  changed_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_support_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_support_records from public,anon,authenticated;
revoke all on public.assessment_support_history from public,anon,authenticated;
grant select,insert,update on public.assessment_support_records to authenticated;
grant select,insert on public.assessment_support_history to authenticated;
grant all on public.assessment_support_records to service_role;
grant all on public.assessment_support_history to service_role;

create or replace function public.save_assessment_support(
  p_event_id uuid,
  p_household jsonb,
  p_family_members jsonb,
  p_support_domains jsonb,
  p_resources jsonb,
  p_summary jsonb,
  p_finalize boolean default false,
  p_copied_from_id uuid default null
)
returns public.assessment_support_records
language plpgsql
security invoker
set search_path=''
as $$
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
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
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

  update public.assessment_events
  set status=case
        when p_finalize and not exists (
          select 1 from public.assessment_event_forms f
          where f.assessment_event_id=p_event_id and f.status not in ('completed','unable','not_applicable')
        ) then 'forms_completed'
        when status='pending' then 'in_progress'
        else status
      end,
      started_at=coalesce(started_at,now()),
      forms_completed_at=case
        when p_finalize and not exists (
          select 1 from public.assessment_event_forms f
          where f.assessment_event_id=p_event_id and f.status not in ('completed','unable','not_applicable')
        ) then coalesce(forms_completed_at,now())
        else forms_completed_at
      end,
      updated_by=(select auth.uid()),
      updated_at=now()
  where id=p_event_id;

  return v_record;
end;
$$;

revoke all on function public.save_assessment_support(uuid,jsonb,jsonb,jsonb,jsonb,jsonb,boolean,uuid) from public,anon;
grant execute on function public.save_assessment_support(uuid,jsonb,jsonb,jsonb,jsonb,jsonb,boolean,uuid) to authenticated;

-- ===== v52/assessment-caregiver-screen-supabase-20261002.sql =====
-- V5.2 評估管理：高負荷家庭照顧者初篩
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-02
-- form_code 沿用 caregiver_burden
-- 指標版本：衛福部高負荷家庭照顧者初篩指標（112-12-22 二修）

create table if not exists public.assessment_caregiver_screen_records (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  applicability text not null default 'applicable',
  caregiver_info jsonb not null default '{}'::jsonb,
  answers jsonb not null default '{}'::jsonb,
  notes jsonb not null default '{}'::jsonb,
  summary jsonb not null default '{}'::jsonb,
  indicator_version text not null default 'MOHW-112-12-22',
  confirmed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint assessment_caregiver_screen_applicability_chk
    check (applicability in ('applicable','no_family_caregiver','paid_caregiver','unable'))
);

create index if not exists assessment_caregiver_screen_case_idx
  on public.assessment_caregiver_screen_records(case_id);
create index if not exists assessment_caregiver_screen_event_idx
  on public.assessment_caregiver_screen_records(assessment_event_id);
create index if not exists assessment_caregiver_screen_confirmed_idx
  on public.assessment_caregiver_screen_records(confirmed_at);

create table if not exists public.assessment_caregiver_screen_history (
  id uuid primary key default gen_random_uuid(),
  caregiver_screen_record_id uuid not null references public.assessment_caregiver_screen_records(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  field_name text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_caregiver_screen_history_record_idx
  on public.assessment_caregiver_screen_history(caregiver_screen_record_id,changed_at);
create index if not exists assessment_caregiver_screen_history_case_idx
  on public.assessment_caregiver_screen_history(case_id,changed_at);

alter table public.assessment_caregiver_screen_records enable row level security;
alter table public.assessment_caregiver_screen_history enable row level security;

drop policy if exists assessment_caregiver_screen_read on public.assessment_caregiver_screen_records;
create policy assessment_caregiver_screen_read
on public.assessment_caregiver_screen_records
for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_caregiver_screen_insert on public.assessment_caregiver_screen_records;
create policy assessment_caregiver_screen_insert
on public.assessment_caregiver_screen_records
for insert to authenticated
with check (
  created_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_caregiver_screen_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_caregiver_screen_update on public.assessment_caregiver_screen_records;
create policy assessment_caregiver_screen_update
on public.assessment_caregiver_screen_records
for update to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_caregiver_screen_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_caregiver_screen_records.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_caregiver_screen_history_read on public.assessment_caregiver_screen_history;
create policy assessment_caregiver_screen_history_read
on public.assessment_caregiver_screen_history
for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_caregiver_screen_history_insert on public.assessment_caregiver_screen_history;
create policy assessment_caregiver_screen_history_insert
on public.assessment_caregiver_screen_history
for insert to authenticated
with check (
  changed_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_caregiver_screen_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_caregiver_screen_records from public,anon,authenticated;
revoke all on public.assessment_caregiver_screen_history from public,anon,authenticated;
grant select,insert,update on public.assessment_caregiver_screen_records to authenticated;
grant select,insert on public.assessment_caregiver_screen_history to authenticated;
grant all on public.assessment_caregiver_screen_records to service_role;
grant all on public.assessment_caregiver_screen_history to service_role;

create or replace function public.save_assessment_caregiver_screen(
  p_event_id uuid,
  p_applicability text,
  p_caregiver_info jsonb,
  p_answers jsonb,
  p_notes jsonb,
  p_summary jsonb,
  p_finalize boolean default false
)
returns public.assessment_caregiver_screen_records
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_old public.assessment_caregiver_screen_records;
  v_record public.assessment_caregiver_screen_records;
  v_key text;
  v_value text;
  v_positive_count int:=0;
  v_referral_required boolean:=false;
  v_form_status text;
  v_indicator_keys text[]:=array[
    'behavior_stress','older_caregiver','limited_experience','no_relief',
    'multiple_dependents','caregiver_health','resource_financial_crisis',
    'recent_care_change','violence_neglect_risk','suicide_risk'
  ];
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id and f.form_code='caregiver_burden'
  ) then raise exception 'CAREGIVER_SCREEN_FORM_NOT_SELECTED'; end if;

  p_applicability:=coalesce(nullif(p_applicability,''),'applicable');
  p_caregiver_info:=coalesce(p_caregiver_info,'{}'::jsonb);
  p_answers:=coalesce(p_answers,'{}'::jsonb);
  p_notes:=coalesce(p_notes,'{}'::jsonb);
  p_summary:=coalesce(p_summary,'{}'::jsonb);

  if p_applicability not in ('applicable','no_family_caregiver','paid_caregiver','unable') then
    raise exception 'INVALID_CAREGIVER_SCREEN_APPLICABILITY';
  end if;
  if jsonb_typeof(p_caregiver_info)<>'object' or jsonb_typeof(p_answers)<>'object'
     or jsonb_typeof(p_notes)<>'object' or jsonb_typeof(p_summary)<>'object' then
    raise exception 'INVALID_CAREGIVER_SCREEN_JSON';
  end if;

  if p_applicability='applicable' then
    foreach v_key in array v_indicator_keys loop
      v_value:=p_answers->>v_key;
      if v_value is not null and v_value not in ('yes','no') then
        raise exception 'INVALID_CAREGIVER_SCREEN_ANSWER:%',v_key;
      end if;
      if p_finalize and v_value is null then
        raise exception 'CAREGIVER_SCREEN_INCOMPLETE:%',v_key;
      end if;
      if v_value='yes' then
        v_positive_count:=v_positive_count+1;
        if p_finalize and nullif(btrim(coalesce(p_notes->>v_key,'')),'') is null then
          raise exception 'CAREGIVER_SCREEN_NOTE_REQUIRED:%',v_key;
        end if;
      end if;
    end loop;

    v_referral_required:=v_positive_count>=2
      or p_answers->>'violence_neglect_risk'='yes'
      or p_answers->>'suicide_risk'='yes'
      or coalesce((p_summary->>'professional_referral')::boolean,false);

    if p_finalize then
      if nullif(btrim(coalesce(p_caregiver_info->>'name','')),'') is null
         or nullif(btrim(coalesce(p_caregiver_info->>'relation','')),'') is null then
        raise exception 'CAREGIVER_SCREEN_CAREGIVER_INFO_REQUIRED';
      end if;
      if v_referral_required then
        if coalesce(p_summary->>'referral_action','') not in ('planned','referred','declined_followup','other') then
          raise exception 'CAREGIVER_SCREEN_REFERRAL_ACTION_REQUIRED';
        end if;
        if nullif(btrim(coalesce(p_summary->>'action_note','')),'') is null then
          raise exception 'CAREGIVER_SCREEN_ACTION_NOTE_REQUIRED';
        end if;
      end if;
      if coalesce((p_summary->>'professional_referral')::boolean,false)
         and nullif(btrim(coalesce(p_summary->>'professional_reason','')),'') is null then
        raise exception 'CAREGIVER_SCREEN_PROFESSIONAL_REASON_REQUIRED';
      end if;
    end if;
  elsif p_finalize then
    if p_applicability='unable'
       and nullif(btrim(coalesce(p_summary->>'unable_reason','')),'') is null then
      raise exception 'CAREGIVER_SCREEN_UNABLE_REASON_REQUIRED';
    end if;
  end if;

  p_summary:=p_summary||jsonb_build_object(
    'positive_count',v_positive_count,
    'referral_required',v_referral_required
  );

  select * into v_old
  from public.assessment_caregiver_screen_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_caregiver_screen_records(
      assessment_event_id,case_id,applicability,caregiver_info,answers,notes,summary,
      confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_applicability,p_caregiver_info,p_answers,p_notes,p_summary,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    ) returning * into v_record;
  else
    if to_jsonb(v_old.applicability) is distinct from to_jsonb(p_applicability) then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'applicability',to_jsonb(v_old.applicability),to_jsonb(p_applicability),(select auth.uid()));
    end if;
    if v_old.caregiver_info is distinct from p_caregiver_info then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'caregiver_info',v_old.caregiver_info,p_caregiver_info,(select auth.uid()));
    end if;
    if v_old.answers is distinct from p_answers then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'answers',v_old.answers,p_answers,(select auth.uid()));
    end if;
    if v_old.notes is distinct from p_notes then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'notes',v_old.notes,p_notes,(select auth.uid()));
    end if;
    if v_old.summary is distinct from p_summary then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'summary',v_old.summary,p_summary,(select auth.uid()));
    end if;

    update public.assessment_caregiver_screen_records
    set applicability=p_applicability,
        caregiver_info=p_caregiver_info,
        answers=p_answers,
        notes=p_notes,
        summary=p_summary,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  v_form_status:=case
    when not p_finalize then 'in_progress'
    when p_applicability in ('no_family_caregiver','paid_caregiver') then 'not_applicable'
    when p_applicability='unable' then 'unable'
    else 'completed'
  end;

  update public.assessment_event_forms
  set status=v_form_status,updated_at=now()
  where assessment_event_id=p_event_id and form_code='caregiver_burden';

  update public.assessment_events
  set status=case
        when p_finalize and not exists (
          select 1 from public.assessment_event_forms f
          where f.assessment_event_id=p_event_id
            and f.status not in ('completed','unable','not_applicable')
        ) then 'forms_completed'
        when status='pending' then 'in_progress'
        else status
      end,
      started_at=coalesce(started_at,now()),
      forms_completed_at=case
        when p_finalize and not exists (
          select 1 from public.assessment_event_forms f
          where f.assessment_event_id=p_event_id
            and f.status not in ('completed','unable','not_applicable')
        ) then coalesce(forms_completed_at,now())
        else forms_completed_at
      end,
      updated_by=(select auth.uid()),
      updated_at=now()
  where id=p_event_id;

  return v_record;
end;
$$;

revoke all on function public.save_assessment_caregiver_screen(uuid,text,jsonb,jsonb,jsonb,jsonb,boolean) from public,anon;
grant execute on function public.save_assessment_caregiver_screen(uuid,text,jsonb,jsonb,jsonb,jsonb,boolean) to authenticated;

-- Live-only index present in TEST and not created by the historical caregiver-screen SQL.
create index if not exists assessment_caregiver_screen_history_event_idx
  on public.assessment_caregiver_screen_history(assessment_event_id);

-- ===== v52/assessment-summary-supabase-20261002.sql =====
-- V5.2 評估管理：整體評估總結
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-02

create table if not exists public.assessment_event_summaries (
  id uuid primary key default gen_random_uuid(),
  assessment_event_id uuid not null unique references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  overall_status text,
  key_findings text,
  care_recommendations text,
  followup_required boolean,
  followup_plan text,
  service_adjustment_required boolean,
  service_adjustment_note text,
  external_coordination_required boolean,
  external_coordination_note text,
  completed_at timestamptz,
  created_by uuid not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint assessment_event_summary_overall_chk
    check (overall_status is null or overall_status in ('stable','attention','intervention'))
);

create index if not exists assessment_event_summaries_case_idx
  on public.assessment_event_summaries(case_id);
create index if not exists assessment_event_summaries_completed_idx
  on public.assessment_event_summaries(completed_at);

create table if not exists public.assessment_event_summary_history (
  id uuid primary key default gen_random_uuid(),
  summary_id uuid not null references public.assessment_event_summaries(id) on delete cascade,
  assessment_event_id uuid not null references public.assessment_events(id) on delete cascade,
  case_id uuid not null references public.care_cases(id) on delete cascade,
  old_snapshot jsonb not null,
  new_snapshot jsonb not null,
  changed_by uuid not null,
  changed_at timestamptz not null default now()
);

create index if not exists assessment_event_summary_history_summary_idx
  on public.assessment_event_summary_history(summary_id,changed_at);
create index if not exists assessment_event_summary_history_event_idx
  on public.assessment_event_summary_history(assessment_event_id);
create index if not exists assessment_event_summary_history_case_idx
  on public.assessment_event_summary_history(case_id);

alter table public.assessment_event_summaries enable row level security;
alter table public.assessment_event_summary_history enable row level security;

drop policy if exists assessment_event_summaries_read on public.assessment_event_summaries;
create policy assessment_event_summaries_read
on public.assessment_event_summaries
for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_event_summaries_insert on public.assessment_event_summaries;
create policy assessment_event_summaries_insert
on public.assessment_event_summaries
for insert to authenticated
with check (
  created_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_event_summaries.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_event_summaries_update on public.assessment_event_summaries;
create policy assessment_event_summaries_update
on public.assessment_event_summaries
for update to authenticated
using (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_event_summaries.case_id
      and private.can_edit_case(c.supervisor_id)
  )
)
with check (
  exists (
    select 1 from public.care_cases c
    where c.id=assessment_event_summaries.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

drop policy if exists assessment_event_summary_history_read on public.assessment_event_summary_history;
create policy assessment_event_summary_history_read
on public.assessment_event_summary_history
for select to authenticated
using (private.can_manage_cases());

drop policy if exists assessment_event_summary_history_insert on public.assessment_event_summary_history;
create policy assessment_event_summary_history_insert
on public.assessment_event_summary_history
for insert to authenticated
with check (
  changed_by=(select auth.uid())
  and exists (
    select 1 from public.care_cases c
    where c.id=assessment_event_summary_history.case_id
      and private.can_edit_case(c.supervisor_id)
  )
);

revoke all on public.assessment_event_summaries from public,anon,authenticated;
revoke all on public.assessment_event_summary_history from public,anon,authenticated;
grant select,insert,update on public.assessment_event_summaries to authenticated;
grant select,insert on public.assessment_event_summary_history to authenticated;
grant all on public.assessment_event_summaries to service_role;
grant all on public.assessment_event_summary_history to service_role;

create or replace function public.save_assessment_event_summary(
  p_event_id uuid,
  p_overall_status text,
  p_key_findings text,
  p_care_recommendations text,
  p_followup_required boolean,
  p_followup_plan text,
  p_service_adjustment_required boolean,
  p_service_adjustment_note text,
  p_external_coordination_required boolean,
  p_external_coordination_note text,
  p_finalize boolean default false
)
returns public.assessment_event_summaries
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_old public.assessment_event_summaries;
  v_record public.assessment_event_summaries;
  v_old_snapshot jsonb;
  v_new_snapshot jsonb;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;
  if v_event.status='voided' then raise exception 'ASSESSMENT_EVENT_VOIDED'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
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
  end if;

  select * into v_old
  from public.assessment_event_summaries
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_event_summaries(
      assessment_event_id,case_id,overall_status,key_findings,care_recommendations,
      followup_required,followup_plan,service_adjustment_required,service_adjustment_note,
      external_coordination_required,external_coordination_note,completed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_overall_status,p_key_findings,p_care_recommendations,
      p_followup_required,p_followup_plan,p_service_adjustment_required,p_service_adjustment_note,
      p_external_coordination_required,p_external_coordination_note,
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
$$;

revoke all on function public.save_assessment_event_summary(
  uuid,text,text,text,boolean,text,boolean,text,boolean,text,boolean
) from public,anon;
grant execute on function public.save_assessment_event_summary(
  uuid,text,text,text,boolean,text,boolean,text,boolean,text,boolean
) to authenticated;

-- ===== v52/assessment-summary-followup-supabase-20261002.sql =====
-- V5.2 評估管理：前次評估追蹤鏈
-- 測試環境：LiuXinZi-TEST
-- 日期：2026-10-02

alter table public.assessment_event_summaries
  add column if not exists previous_summary_id uuid references public.assessment_event_summaries(id) on delete set null,
  add column if not exists previous_key_findings_snapshot text,
  add column if not exists previous_care_recommendations_snapshot text,
  add column if not exists previous_problem_status text,
  add column if not exists previous_problem_followup_note text,
  add column if not exists previous_recommendation_status text,
  add column if not exists previous_recommendation_followup_note text;

create index if not exists assessment_event_summaries_previous_summary_idx
  on public.assessment_event_summaries(previous_summary_id);

alter table public.assessment_event_summaries
  drop constraint if exists assessment_event_summary_prev_problem_status_chk,
  add constraint assessment_event_summary_prev_problem_status_chk
    check (
      previous_problem_status is null
      or previous_problem_status in ('improved','persistent','worse','not_applicable')
    );

alter table public.assessment_event_summaries
  drop constraint if exists assessment_event_summary_prev_recommendation_status_chk,
  add constraint assessment_event_summary_prev_recommendation_status_chk
    check (
      previous_recommendation_status is null
      or previous_recommendation_status in ('completed','partial','ongoing','not_done','not_applicable')
    );

drop function if exists public.save_assessment_event_summary(
  uuid,text,text,text,boolean,text,boolean,text,boolean,text,boolean
);

create or replace function public.save_assessment_event_summary(
  p_event_id uuid,
  p_overall_status text,
  p_key_findings text,
  p_care_recommendations text,
  p_followup_required boolean,
  p_followup_plan text,
  p_service_adjustment_required boolean,
  p_service_adjustment_note text,
  p_external_coordination_required boolean,
  p_external_coordination_note text,
  p_previous_problem_status text,
  p_previous_problem_followup_note text,
  p_previous_recommendation_status text,
  p_previous_recommendation_followup_note text,
  p_finalize boolean default false
)
returns public.assessment_event_summaries
language plpgsql
security invoker
set search_path=''
as $$
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
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
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
$$;

revoke all on function public.save_assessment_event_summary(
  uuid,text,text,text,boolean,text,boolean,text,boolean,text,text,text,text,text,boolean
) from public,anon;
grant execute on function public.save_assessment_event_summary(
  uuid,text,text,text,boolean,text,boolean,text,boolean,text,text,text,text,text,boolean
) to authenticated;

-- ===== v52/assessment-history-manager-only-supabase-20261002.sql =====
-- V5.2 評估管理：修改歷程僅限管理者查閱
-- TEST migration mirror
-- 日期：2026-10-02

create or replace function private.can_view_assessment_history()
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select exists (
    select 1
    from public.staff_users s
    where lower(s.email)=lower(coalesce((select auth.jwt())->>'email',''))
      and s.is_active=true
      and s.role in ('business_manager','organization_manager','admin')
  );
$$;

revoke all on function private.can_view_assessment_history() from public,anon;
grant execute on function private.can_view_assessment_history() to authenticated;

drop policy if exists assessment_adl_history_read on public.assessment_adl_history;
create policy assessment_adl_history_read
on public.assessment_adl_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_iadl_history_read on public.assessment_iadl_history;
create policy assessment_iadl_history_read
on public.assessment_iadl_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_spmsq_history_read on public.assessment_spmsq_history;
create policy assessment_spmsq_history_read
on public.assessment_spmsq_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_gds15_history_read on public.assessment_gds15_history;
create policy assessment_gds15_history_read
on public.assessment_gds15_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_health_history_read on public.assessment_health_history;
create policy assessment_health_history_read
on public.assessment_health_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_home_safety_history_read on public.assessment_home_safety_history;
create policy assessment_home_safety_history_read
on public.assessment_home_safety_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_support_history_read on public.assessment_support_history;
create policy assessment_support_history_read
on public.assessment_support_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_caregiver_screen_history_read on public.assessment_caregiver_screen_history;
create policy assessment_caregiver_screen_history_read
on public.assessment_caregiver_screen_history
for select to authenticated
using (private.can_view_assessment_history());

drop policy if exists assessment_event_summary_history_read on public.assessment_event_summary_history;
create policy assessment_event_summary_history_read
on public.assessment_event_summary_history
for select to authenticated
using (private.can_view_assessment_history());

-- ===== Final shared progress implementation =====
-- LiuXinZi TEST assessment event progress refactor
-- 2026-10-03
-- Centralize assessment_events status synchronization while keeping each tool RPC responsible for its own validation/data/form status.

CREATE OR REPLACE FUNCTION private.sync_assessment_event_progress(p_event_id uuid)
 RETURNS assessment_events
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_all_terminal boolean := false;
begin
  if (select auth.uid()) is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_event
  from public.assessment_events
  where id = p_event_id
  for update;

  if v_event.id is null then
    raise exception 'ASSESSMENT_EVENT_NOT_FOUND';
  end if;

  select
    exists (
      select 1
      from public.assessment_event_forms f
      where f.assessment_event_id = p_event_id
    )
    and not exists (
      select 1
      from public.assessment_event_forms f
      where f.assessment_event_id = p_event_id
        and f.status not in ('completed','unable','not_applicable')
    )
  into v_all_terminal;

  update public.assessment_events
  set
    status = case
      when v_event.status in ('completed','voided') then v_event.status
      when v_all_terminal then 'forms_completed'
      else 'in_progress'
    end,
    started_at = coalesce(started_at, now()),
    forms_completed_at = case
      when v_event.status in ('completed','voided') then forms_completed_at
      when v_all_terminal then coalesce(forms_completed_at, now())
      else forms_completed_at
    end,
    updated_by = (select auth.uid()),
    updated_at = now()
  where id = p_event_id
  returning * into v_event;

  return v_event;
end;
$function$;

revoke all on function private.sync_assessment_event_progress(uuid) from public;
revoke all on function private.sync_assessment_event_progress(uuid) from anon;
grant execute on function private.sync_assessment_event_progress(uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.save_assessment_adl(p_event_id uuid, p_answers jsonb, p_notes jsonb, p_finalize boolean DEFAULT false, p_copied_from_id uuid DEFAULT NULL::uuid)
 RETURNS assessment_adl_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_adl_records;
  v_old public.assessment_adl_records;
  v_total integer := 0;
  v_level text := null;
  v_key text;
  v_required text[] := array[
    'feeding','transfer','grooming','toileting','bathing',
    'walking','stairs','dressing','bowel','bladder'
  ];
  v_score integer;
begin
  if (select auth.uid()) is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select *
  into v_event
  from public.assessment_events
  where id = p_event_id;

  if v_event.id is null then
    raise exception 'ASSESSMENT_EVENT_NOT_FOUND';
  end if;

  select *
  into v_case
  from public.care_cases
  where id = v_event.case_id;

  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1
    from public.assessment_event_forms f
    where f.assessment_event_id = p_event_id
      and f.form_code = 'adl'
  ) then
    raise exception 'ADL_FORM_NOT_SELECTED';
  end if;

  p_answers := coalesce(p_answers, '{}'::jsonb);
  p_notes := coalesce(p_notes, '{}'::jsonb);

  foreach v_key in array v_required loop
    if p_answers ? v_key then
      begin
        v_score := (p_answers ->> v_key)::integer;
      exception when others then
        raise exception 'INVALID_ADL_SCORE:%', v_key;
      end;

      if
        (v_key = 'feeding' and v_score not in (0,5,10)) or
        (v_key = 'transfer' and v_score not in (0,5,10,15)) or
        (v_key = 'grooming' and v_score not in (0,5)) or
        (v_key = 'toileting' and v_score not in (0,5,10)) or
        (v_key = 'bathing' and v_score not in (0,5)) or
        (v_key = 'walking' and v_score not in (0,5,10,15)) or
        (v_key = 'stairs' and v_score not in (0,5,10)) or
        (v_key = 'dressing' and v_score not in (0,5,10)) or
        (v_key = 'bowel' and v_score not in (0,5,10)) or
        (v_key = 'bladder' and v_score not in (0,5,10))
      then
        raise exception 'INVALID_ADL_SCORE:%', v_key;
      end if;
      v_total := v_total + v_score;
    elsif p_finalize then
      raise exception 'ADL_INCOMPLETE:%', v_key;
    end if;
  end loop;

  if p_finalize then
    v_level := case
      when v_total <= 20 then 'complete_dependence'
      when v_total <= 60 then 'severe_dependence'
      when v_total <= 90 then 'moderate_dependence'
      when v_total <= 99 then 'mild_dependence'
      else 'independent'
    end;
  end if;

  select *
  into v_old
  from public.assessment_adl_records
  where assessment_event_id = p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_adl_records(
      assessment_event_id,
      case_id,
      answers,
      notes,
      total_score,
      dependency_level,
      copied_from_id,
      copied_at,
      confirmed_at,
      created_by,
      updated_by
    ) values (
      p_event_id,
      v_event.case_id,
      p_answers,
      p_notes,
      case when p_answers <> '{}'::jsonb then v_total else null end,
      v_level,
      p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),
      (select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.answers,'{}'::jsonb) || p_answers) as t(key)
    loop
      if (v_old.answers -> v_key) is distinct from (p_answers -> v_key) then
        insert into public.assessment_adl_history(
          adl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'answers.'||v_key,
          v_old.answers -> v_key, p_answers -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.notes,'{}'::jsonb) || p_notes) as t(key)
    loop
      if (v_old.notes -> v_key) is distinct from (p_notes -> v_key) then
        insert into public.assessment_adl_history(
          adl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'notes.'||v_key,
          v_old.notes -> v_key, p_notes -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    update public.assessment_adl_records
    set
      answers = p_answers,
      notes = p_notes,
      total_score = case when p_answers <> '{}'::jsonb then v_total else null end,
      dependency_level = case when p_finalize then v_level else dependency_level end,
      copied_from_id = coalesce(copied_from_id, p_copied_from_id),
      copied_at = case
        when copied_at is not null then copied_at
        when p_copied_from_id is not null then now()
        else null
      end,
      confirmed_at = case when p_finalize then now() else confirmed_at end,
      updated_by = (select auth.uid()),
      updated_at = now()
    where id = v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set
    status = case when p_finalize then 'completed' else 'in_progress' end,
    updated_at = now()
  where assessment_event_id = p_event_id
    and form_code = 'adl'
    and (
      p_finalize
      or status <> 'completed'
    );

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;

CREATE OR REPLACE FUNCTION public.save_assessment_caregiver_screen(p_event_id uuid, p_applicability text, p_caregiver_info jsonb, p_answers jsonb, p_notes jsonb, p_summary jsonb, p_finalize boolean DEFAULT false)
 RETURNS assessment_caregiver_screen_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_old public.assessment_caregiver_screen_records;
  v_record public.assessment_caregiver_screen_records;
  v_key text;
  v_value text;
  v_positive_count int:=0;
  v_referral_required boolean:=false;
  v_form_status text;
  v_indicator_keys text[]:=array[
    'behavior_stress','older_caregiver','limited_experience','no_relief',
    'multiple_dependents','caregiver_health','resource_financial_crisis',
    'recent_care_change','violence_neglect_risk','suicide_risk'
  ];
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id and f.form_code='caregiver_burden'
  ) then raise exception 'CAREGIVER_SCREEN_FORM_NOT_SELECTED'; end if;

  p_applicability:=coalesce(nullif(p_applicability,''),'applicable');
  p_caregiver_info:=coalesce(p_caregiver_info,'{}'::jsonb);
  p_answers:=coalesce(p_answers,'{}'::jsonb);
  p_notes:=coalesce(p_notes,'{}'::jsonb);
  p_summary:=coalesce(p_summary,'{}'::jsonb);

  if p_applicability not in ('applicable','no_family_caregiver','paid_caregiver','unable') then
    raise exception 'INVALID_CAREGIVER_SCREEN_APPLICABILITY';
  end if;
  if jsonb_typeof(p_caregiver_info)<>'object' or jsonb_typeof(p_answers)<>'object'
     or jsonb_typeof(p_notes)<>'object' or jsonb_typeof(p_summary)<>'object' then
    raise exception 'INVALID_CAREGIVER_SCREEN_JSON';
  end if;

  if p_applicability='applicable' then
    foreach v_key in array v_indicator_keys loop
      v_value:=p_answers->>v_key;
      if v_value is not null and v_value not in ('yes','no') then
        raise exception 'INVALID_CAREGIVER_SCREEN_ANSWER:%',v_key;
      end if;
      if p_finalize and v_value is null then
        raise exception 'CAREGIVER_SCREEN_INCOMPLETE:%',v_key;
      end if;
      if v_value='yes' then
        v_positive_count:=v_positive_count+1;
        if p_finalize and nullif(btrim(coalesce(p_notes->>v_key,'')),'') is null then
          raise exception 'CAREGIVER_SCREEN_NOTE_REQUIRED:%',v_key;
        end if;
      end if;
    end loop;

    v_referral_required:=v_positive_count>=2
      or p_answers->>'violence_neglect_risk'='yes'
      or p_answers->>'suicide_risk'='yes'
      or coalesce((p_summary->>'professional_referral')::boolean,false);

    if p_finalize then
      if nullif(btrim(coalesce(p_caregiver_info->>'name','')),'') is null
         or nullif(btrim(coalesce(p_caregiver_info->>'relation','')),'') is null then
        raise exception 'CAREGIVER_SCREEN_CAREGIVER_INFO_REQUIRED';
      end if;
      if v_referral_required then
        if coalesce(p_summary->>'referral_action','') not in ('planned','referred','declined_followup','other') then
          raise exception 'CAREGIVER_SCREEN_REFERRAL_ACTION_REQUIRED';
        end if;
        if nullif(btrim(coalesce(p_summary->>'action_note','')),'') is null then
          raise exception 'CAREGIVER_SCREEN_ACTION_NOTE_REQUIRED';
        end if;
      end if;
      if coalesce((p_summary->>'professional_referral')::boolean,false)
         and nullif(btrim(coalesce(p_summary->>'professional_reason','')),'') is null then
        raise exception 'CAREGIVER_SCREEN_PROFESSIONAL_REASON_REQUIRED';
      end if;
    end if;
  elsif p_finalize then
    if p_applicability='unable'
       and nullif(btrim(coalesce(p_summary->>'unable_reason','')),'') is null then
      raise exception 'CAREGIVER_SCREEN_UNABLE_REASON_REQUIRED';
    end if;
  end if;

  p_summary:=p_summary
    || jsonb_build_object(
      'positive_count',v_positive_count,
      'referral_required',v_referral_required
    );

  select * into v_old
  from public.assessment_caregiver_screen_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_caregiver_screen_records(
      assessment_event_id,case_id,applicability,caregiver_info,answers,notes,summary,
      confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_applicability,p_caregiver_info,p_answers,p_notes,p_summary,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    ) returning * into v_record;
  else
    if to_jsonb(v_old.applicability) is distinct from to_jsonb(p_applicability) then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'applicability',to_jsonb(v_old.applicability),to_jsonb(p_applicability),(select auth.uid()));
    end if;
    if v_old.caregiver_info is distinct from p_caregiver_info then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'caregiver_info',v_old.caregiver_info,p_caregiver_info,(select auth.uid()));
    end if;
    if v_old.answers is distinct from p_answers then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'answers',v_old.answers,p_answers,(select auth.uid()));
    end if;
    if v_old.notes is distinct from p_notes then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'notes',v_old.notes,p_notes,(select auth.uid()));
    end if;
    if v_old.summary is distinct from p_summary then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'summary',v_old.summary,p_summary,(select auth.uid()));
    end if;

    update public.assessment_caregiver_screen_records
    set applicability=p_applicability,
        caregiver_info=p_caregiver_info,
        answers=p_answers,
        notes=p_notes,
        summary=p_summary,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  v_form_status:=case
    when not p_finalize then 'in_progress'
    when p_applicability in ('no_family_caregiver','paid_caregiver') then 'not_applicable'
    when p_applicability='unable' then 'unable'
    else 'completed'
  end;

  update public.assessment_event_forms
  set status=v_form_status,updated_at=now()
  where assessment_event_id=p_event_id and form_code='caregiver_burden';

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;

CREATE OR REPLACE FUNCTION public.save_assessment_gds15(p_event_id uuid, p_answers jsonb, p_finalize boolean DEFAULT false, p_completion_mode text DEFAULT 'completed'::text, p_exception_reason text DEFAULT NULL::text)
 RETURNS assessment_gds15_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_gds15_records;
  v_old public.assessment_gds15_records;
  v_key text;
  v_keys text[]:=array['q1','q2','q3','q4','q5','q6','q7','q8','q9','q10','q11','q12','q13','q14','q15'];
  v_reverse text[]:=array['q1','q5','q7','q11','q13'];
  v_value text;
  v_total integer:=0;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id and f.form_code='gds15'
  ) then raise exception 'GDS15_FORM_NOT_SELECTED'; end if;

  p_answers:=coalesce(p_answers,'{}'::jsonb);
  p_completion_mode:=coalesce(p_completion_mode,'completed');
  p_exception_reason:=nullif(btrim(p_exception_reason),'');

  if p_completion_mode not in ('completed','unable','not_applicable') then
    raise exception 'INVALID_GDS15_COMPLETION_MODE';
  end if;

  if p_completion_mode<>'completed' and p_exception_reason is null then
    raise exception 'GDS15_EXCEPTION_REASON_REQUIRED';
  end if;

  foreach v_key in array v_keys loop
    v_value:=p_answers->>v_key;

    if v_value is not null and v_value not in ('yes','no') then
      raise exception 'INVALID_GDS15_ANSWER:%',v_key;
    end if;

    if p_finalize and p_completion_mode='completed' and v_value is null then
      raise exception 'GDS15_INCOMPLETE:%',v_key;
    end if;

    if p_completion_mode='completed' and v_value is not null then
      if v_key = any(v_reverse) then
        if v_value='no' then v_total:=v_total+1; end if;
      else
        if v_value='yes' then v_total:=v_total+1; end if;
      end if;
    end if;
  end loop;

  select * into v_old
  from public.assessment_gds15_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_gds15_records(
      assessment_event_id,case_id,answers,total_score,completion_mode,exception_reason,
      confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_answers,
      case when p_completion_mode='completed' and p_answers<>'{}'::jsonb then v_total else null end,
      p_completion_mode,p_exception_reason,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.answers,'{}'::jsonb)||p_answers) as t(key)
    loop
      if (v_old.answers->v_key) is distinct from (p_answers->v_key) then
        insert into public.assessment_gds15_history(
          gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'answers.'||v_key,
          v_old.answers->v_key,p_answers->v_key,(select auth.uid())
        );
      end if;
    end loop;

    if v_old.completion_mode is distinct from p_completion_mode then
      insert into public.assessment_gds15_history(
        gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'completion_mode',
        to_jsonb(v_old.completion_mode),to_jsonb(p_completion_mode),(select auth.uid())
      );
    end if;

    if v_old.exception_reason is distinct from p_exception_reason then
      insert into public.assessment_gds15_history(
        gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'exception_reason',
        to_jsonb(v_old.exception_reason),to_jsonb(p_exception_reason),(select auth.uid())
      );
    end if;

    update public.assessment_gds15_records
    set answers=p_answers,
        total_score=case when p_completion_mode='completed' and p_answers<>'{}'::jsonb then v_total else null end,
        completion_mode=p_completion_mode,
        exception_reason=p_exception_reason,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case
      when p_finalize and p_completion_mode='unable' then 'unable'
      when p_finalize and p_completion_mode='not_applicable' then 'not_applicable'
      when p_finalize then 'completed'
      else 'in_progress'
    end,
    updated_at=now()
  where assessment_event_id=p_event_id and form_code='gds15';

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;

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
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
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
$function$;

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
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
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
$function$;

CREATE OR REPLACE FUNCTION public.save_assessment_iadl(p_event_id uuid, p_answers jsonb, p_notes jsonb, p_finalize boolean DEFAULT false, p_copied_from_id uuid DEFAULT NULL::uuid)
 RETURNS assessment_iadl_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_iadl_records;
  v_old public.assessment_iadl_records;
  v_total integer := 0;
  v_key text;
  v_required text[] := array[
    'telephone','shopping','meal_prep','housekeeping',
    'laundry','transportation','medication','finances'
  ];
  v_score integer;
begin
  if (select auth.uid()) is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_event
  from public.assessment_events
  where id = p_event_id;

  if v_event.id is null then
    raise exception 'ASSESSMENT_EVENT_NOT_FOUND';
  end if;

  select * into v_case
  from public.care_cases
  where id = v_event.case_id;

  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1
    from public.assessment_event_forms f
    where f.assessment_event_id = p_event_id
      and f.form_code = 'iadl'
  ) then
    raise exception 'IADL_FORM_NOT_SELECTED';
  end if;

  p_answers := coalesce(p_answers, '{}'::jsonb);
  p_notes := coalesce(p_notes, '{}'::jsonb);

  foreach v_key in array v_required loop
    if (p_answers ->> v_key) is not null then
      begin
        v_score := (p_answers ->> v_key)::integer;
      exception when others then
        raise exception 'INVALID_IADL_SCORE:%', v_key;
      end;

      if v_score not in (0,1,2) then
        raise exception 'INVALID_IADL_SCORE:%', v_key;
      end if;

      v_total := v_total + v_score;
    elsif p_finalize then
      raise exception 'IADL_INCOMPLETE:%', v_key;
    end if;
  end loop;

  select * into v_old
  from public.assessment_iadl_records
  where assessment_event_id = p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_iadl_records(
      assessment_event_id,
      case_id,
      answers,
      notes,
      total_score,
      copied_from_id,
      copied_at,
      confirmed_at,
      created_by,
      updated_by
    ) values (
      p_event_id,
      v_event.case_id,
      p_answers,
      p_notes,
      case when p_answers <> '{}'::jsonb then v_total else null end,
      p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),
      (select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.answers,'{}'::jsonb) || p_answers) as t(key)
    loop
      if (v_old.answers -> v_key) is distinct from (p_answers -> v_key) then
        insert into public.assessment_iadl_history(
          iadl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'answers.'||v_key,
          v_old.answers -> v_key, p_answers -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.notes,'{}'::jsonb) || p_notes) as t(key)
    loop
      if (v_old.notes -> v_key) is distinct from (p_notes -> v_key) then
        insert into public.assessment_iadl_history(
          iadl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'notes.'||v_key,
          v_old.notes -> v_key, p_notes -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    update public.assessment_iadl_records
    set
      answers = p_answers,
      notes = p_notes,
      total_score = case when p_answers <> '{}'::jsonb then v_total else null end,
      copied_from_id = coalesce(copied_from_id, p_copied_from_id),
      copied_at = case
        when copied_at is not null then copied_at
        when p_copied_from_id is not null then now()
        else null
      end,
      confirmed_at = case when p_finalize then now() else confirmed_at end,
      updated_by = (select auth.uid()),
      updated_at = now()
    where id = v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set
    status = case when p_finalize then 'completed' else 'in_progress' end,
    updated_at = now()
  where assessment_event_id = p_event_id
    and form_code = 'iadl'
    and (p_finalize or status <> 'completed');

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;

CREATE OR REPLACE FUNCTION public.save_assessment_spmsq(p_event_id uuid, p_responses jsonb, p_judgments jsonb, p_finalize boolean DEFAULT false, p_unable boolean DEFAULT false, p_unable_reason text DEFAULT NULL::text, p_copied_from_id uuid DEFAULT NULL::uuid)
 RETURNS assessment_spmsq_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_spmsq_records;
  v_old public.assessment_spmsq_records;
  v_key text;
  v_keys text[] := array['q1','q2','q3','q4','q5','q6','q7','q8','q9','q10'];
  v_judgment text;
  v_error_count integer := 0;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id and f.form_code='spmsq'
  ) then raise exception 'SPMSQ_FORM_NOT_SELECTED'; end if;

  p_responses := coalesce(p_responses,'{}'::jsonb);
  p_judgments := coalesce(p_judgments,'{}'::jsonb);
  p_unable_reason := nullif(btrim(p_unable_reason),'');

  if p_unable and p_unable_reason is null then
    raise exception 'SPMSQ_UNABLE_REASON_REQUIRED';
  end if;

  foreach v_key in array v_keys loop
    v_judgment := p_judgments ->> v_key;
    if v_judgment is not null and v_judgment not in ('correct','wrong') then
      raise exception 'INVALID_SPMSQ_JUDGMENT:%', v_key;
    end if;

    if not p_unable then
      if p_finalize and nullif(btrim(p_responses ->> v_key),'') is null then
        raise exception 'SPMSQ_RESPONSE_INCOMPLETE:%', v_key;
      end if;
      if p_finalize and v_judgment is null then
        raise exception 'SPMSQ_JUDGMENT_INCOMPLETE:%', v_key;
      end if;
      if v_judgment='wrong' then v_error_count := v_error_count + 1; end if;
    end if;
  end loop;

  select * into v_old
  from public.assessment_spmsq_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_spmsq_records(
      assessment_event_id,case_id,responses,judgments,error_count,is_unable,unable_reason,
      copied_from_id,copied_at,confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_responses,p_judgments,
      case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
      p_unable,p_unable_reason,p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in select key from jsonb_object_keys(coalesce(v_old.responses,'{}'::jsonb)||p_responses) as t(key)
    loop
      if (v_old.responses->v_key) is distinct from (p_responses->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'responses.'||v_key,
          v_old.responses->v_key,p_responses->v_key,(select auth.uid())
        );
      end if;
    end loop;

    for v_key in select key from jsonb_object_keys(coalesce(v_old.judgments,'{}'::jsonb)||p_judgments) as t(key)
    loop
      if (v_old.judgments->v_key) is distinct from (p_judgments->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'judgments.'||v_key,
          v_old.judgments->v_key,p_judgments->v_key,(select auth.uid())
        );
      end if;
    end loop;

    if v_old.is_unable is distinct from p_unable then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'is_unable',
        to_jsonb(v_old.is_unable),to_jsonb(p_unable),(select auth.uid())
      );
    end if;

    if v_old.unable_reason is distinct from p_unable_reason then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'unable_reason',
        to_jsonb(v_old.unable_reason),to_jsonb(p_unable_reason),(select auth.uid())
      );
    end if;

    update public.assessment_spmsq_records
    set responses=p_responses,
        judgments=p_judgments,
        error_count=case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
        is_unable=p_unable,
        unable_reason=p_unable_reason,
        copied_from_id=coalesce(copied_from_id,p_copied_from_id),
        copied_at=case when copied_at is not null then copied_at when p_copied_from_id is not null then now() else null end,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case
      when p_finalize and p_unable then 'unable'
      when p_finalize then 'completed'
      else 'in_progress'
    end,
    updated_at=now()
  where assessment_event_id=p_event_id
    and form_code='spmsq';

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;

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
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
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
$function$;

-- ===== Final SPMSQ judgment-only shape =====
-- LiuXinZi TEST / SPMSQ judgment-only refactor
-- 2026-10-03
-- Production use requires separate explicit approval.
-- Existing assessment data in TEST is disposable; raw SPMSQ responses are cleared.

alter table public.assessment_spmsq_records
  add column if not exists notes jsonb not null default '{}'::jsonb;

update public.assessment_spmsq_records
set responses='{}'::jsonb
where responses <> '{}'::jsonb;

delete from public.assessment_spmsq_history
where field_name like 'responses.%';

drop function if exists public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid);

CREATE OR REPLACE FUNCTION public.save_assessment_spmsq(p_event_id uuid, p_judgments jsonb, p_notes jsonb, p_finalize boolean DEFAULT false, p_unable boolean DEFAULT false, p_unable_reason text DEFAULT NULL::text, p_copied_from_id uuid DEFAULT NULL::uuid)
 RETURNS assessment_spmsq_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_spmsq_records;
  v_old public.assessment_spmsq_records;
  v_key text;
  v_keys text[] := array['q1','q2','q3','q4','q5','q6','q7','q8','q9','q10'];
  v_judgment text;
  v_error_count integer := 0;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id and f.form_code='spmsq'
  ) then raise exception 'SPMSQ_FORM_NOT_SELECTED'; end if;

  p_judgments := coalesce(p_judgments,'{}'::jsonb);
  p_notes := coalesce(p_notes,'{}'::jsonb);
  p_unable_reason := nullif(btrim(p_unable_reason),'');

  if p_unable and p_unable_reason is null then
    raise exception 'SPMSQ_UNABLE_REASON_REQUIRED';
  end if;

  foreach v_key in array v_keys loop
    v_judgment := p_judgments ->> v_key;

    if v_judgment is not null
       and v_judgment not in ('correct','wrong','unable_answer') then
      raise exception 'INVALID_SPMSQ_JUDGMENT:%', v_key;
    end if;

    if not p_unable then
      if p_finalize and v_judgment is null then
        raise exception 'SPMSQ_JUDGMENT_INCOMPLETE:%', v_key;
      end if;

      if v_judgment in ('wrong','unable_answer') then
        v_error_count := v_error_count + 1;
      end if;
    end if;
  end loop;

  select * into v_old
  from public.assessment_spmsq_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_spmsq_records(
      assessment_event_id,case_id,responses,judgments,notes,error_count,is_unable,unable_reason,
      copied_from_id,copied_at,confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,'{}'::jsonb,p_judgments,p_notes,
      case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
      p_unable,p_unable_reason,p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.judgments,'{}'::jsonb)||p_judgments) as t(key)
    loop
      if (v_old.judgments->v_key) is distinct from (p_judgments->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'judgments.'||v_key,
          v_old.judgments->v_key,p_judgments->v_key,(select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.notes,'{}'::jsonb)||p_notes) as t(key)
    loop
      if (v_old.notes->v_key) is distinct from (p_notes->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'notes.'||v_key,
          v_old.notes->v_key,p_notes->v_key,(select auth.uid())
        );
      end if;
    end loop;

    if v_old.is_unable is distinct from p_unable then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'is_unable',
        to_jsonb(v_old.is_unable),to_jsonb(p_unable),(select auth.uid())
      );
    end if;

    if v_old.unable_reason is distinct from p_unable_reason then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'unable_reason',
        to_jsonb(v_old.unable_reason),to_jsonb(p_unable_reason),(select auth.uid())
      );
    end if;

    update public.assessment_spmsq_records
    set responses='{}'::jsonb,
        judgments=p_judgments,
        notes=p_notes,
        error_count=case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
        is_unable=p_unable,
        unable_reason=p_unable_reason,
        copied_from_id=coalesce(copied_from_id,p_copied_from_id),
        copied_at=case when copied_at is not null then copied_at when p_copied_from_id is not null then now() else null end,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case
      when p_finalize and p_unable then 'unable'
      when p_finalize then 'completed'
      else 'in_progress'
    end,
    updated_at=now()
  where assessment_event_id=p_event_id
    and form_code='spmsq';

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;

revoke all on function public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid) from public;
revoke all on function public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid) from anon;
grant execute on function public.save_assessment_spmsq(uuid,jsonb,jsonb,boolean,boolean,text,uuid) to authenticated;

-- ===== Final SPMSQ unable-reason rule =====
-- LiuXinZi TEST / SPMSQ unable-answer reason requirement
-- 2026-10-03
-- Selecting unable_answer may be saved as draft without a reason.
-- Finalization requires a nonblank per-question note for every unable_answer.

CREATE OR REPLACE FUNCTION public.save_assessment_spmsq(p_event_id uuid, p_judgments jsonb, p_notes jsonb, p_finalize boolean DEFAULT false, p_unable boolean DEFAULT false, p_unable_reason text DEFAULT NULL::text, p_copied_from_id uuid DEFAULT NULL::uuid)
 RETURNS assessment_spmsq_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_spmsq_records;
  v_old public.assessment_spmsq_records;
  v_key text;
  v_keys text[] := array['q1','q2','q3','q4','q5','q6','q7','q8','q9','q10'];
  v_judgment text;
  v_error_count integer := 0;
begin
  if (select auth.uid()) is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_event from public.assessment_events where id=p_event_id;
  if v_event.id is null then raise exception 'ASSESSMENT_EVENT_NOT_FOUND'; end if;

  select * into v_case from public.care_cases where id=v_event.case_id;
  if v_case.id is null or not private.can_edit_case(v_case.supervisor_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1 from public.assessment_event_forms f
    where f.assessment_event_id=p_event_id and f.form_code='spmsq'
  ) then raise exception 'SPMSQ_FORM_NOT_SELECTED'; end if;

  p_judgments := coalesce(p_judgments,'{}'::jsonb);
  p_notes := coalesce(p_notes,'{}'::jsonb);
  p_unable_reason := nullif(btrim(p_unable_reason),'');

  if p_unable and p_unable_reason is null then
    raise exception 'SPMSQ_UNABLE_REASON_REQUIRED';
  end if;

  foreach v_key in array v_keys loop
    v_judgment := p_judgments ->> v_key;

    if v_judgment is not null
       and v_judgment not in ('correct','wrong','unable_answer') then
      raise exception 'INVALID_SPMSQ_JUDGMENT:%', v_key;
    end if;

    if not p_unable then
      if p_finalize and v_judgment is null then
        raise exception 'SPMSQ_JUDGMENT_INCOMPLETE:%', v_key;
      end if;

      if p_finalize
         and v_judgment='unable_answer'
         and nullif(btrim(p_notes ->> v_key),'') is null then
        raise exception 'SPMSQ_UNABLE_ANSWER_REASON_REQUIRED:%', v_key;
      end if;

      if v_judgment in ('wrong','unable_answer') then
        v_error_count := v_error_count + 1;
      end if;
    end if;
  end loop;

  select * into v_old
  from public.assessment_spmsq_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_spmsq_records(
      assessment_event_id,case_id,responses,judgments,notes,error_count,is_unable,unable_reason,
      copied_from_id,copied_at,confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,'{}'::jsonb,p_judgments,p_notes,
      case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
      p_unable,p_unable_reason,p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.judgments,'{}'::jsonb)||p_judgments) as t(key)
    loop
      if (v_old.judgments->v_key) is distinct from (p_judgments->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'judgments.'||v_key,
          v_old.judgments->v_key,p_judgments->v_key,(select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.notes,'{}'::jsonb)||p_notes) as t(key)
    loop
      if (v_old.notes->v_key) is distinct from (p_notes->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'notes.'||v_key,
          v_old.notes->v_key,p_notes->v_key,(select auth.uid())
        );
      end if;
    end loop;

    if v_old.is_unable is distinct from p_unable then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'is_unable',
        to_jsonb(v_old.is_unable),to_jsonb(p_unable),(select auth.uid())
      );
    end if;

    if v_old.unable_reason is distinct from p_unable_reason then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'unable_reason',
        to_jsonb(v_old.unable_reason),to_jsonb(p_unable_reason),(select auth.uid())
      );
    end if;

    update public.assessment_spmsq_records
    set responses='{}'::jsonb,
        judgments=p_judgments,
        notes=p_notes,
        error_count=case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
        is_unable=p_unable,
        unable_reason=p_unable_reason,
        copied_from_id=coalesce(copied_from_id,p_copied_from_id),
        copied_at=case when copied_at is not null then copied_at when p_copied_from_id is not null then now() else null end,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case
      when p_finalize and p_unable then 'unable'
      when p_finalize then 'completed'
      else 'in_progress'
    end,
    updated_at=now()
  where assessment_event_id=p_event_id
    and form_code='spmsq';

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;

-- ===== Live case-health helper and latest case profile updater =====
CREATE OR REPLACE FUNCTION private.update_case_health_from_assessment(p_case_id uuid, p_important_conditions text, p_ongoing_treatments text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if (select auth.uid()) is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not private.can_edit_assessment_case(p_case_id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  update public.care_cases
  set important_conditions = p_important_conditions,
      ongoing_treatments = p_ongoing_treatments,
      updated_at = now()
  where id = p_case_id;
end;
$function$;
revoke all on function private.update_case_health_from_assessment(uuid, text, text) from public, anon, authenticated;
grant execute on function private.update_case_health_from_assessment(uuid, text, text) to authenticated;
grant execute on function private.update_case_health_from_assessment(uuid, text, text) to service_role;

CREATE OR REPLACE FUNCTION public.update_case_profile(payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_case_id uuid := nullif(payload->>'case_id','')::uuid;
  v_old_supervisor uuid;
  v_old_conditions text;
  v_old_treatments text;
  v_new_conditions text;
  v_new_treatments text;
  v_new_supervisor uuid := nullif(payload->>'supervisor_id','')::uuid;
  v_case_no text := upper(regexp_replace(btrim(coalesce(payload->>'case_no','')),'\s+','','g'));
  v_case_name text := btrim(coalesce(payload->>'case_name',''));
  v_usage text := nullif(btrim(payload->>'service_usage_type'),'');
  v_payment text := nullif(btrim(payload->>'payment_method'),'');
  v_welfare text := nullif(btrim(payload->>'welfare_identity'),'');
  v_status text := coalesce(nullif(payload->>'service_status',''),'active');
  v_staff_id uuid;
  v_staff_role text;
  v_contacts jsonb := coalesce(payload->'contacts','[]'::jsonb);
  item jsonb;
begin
  if v_case_id is null then raise exception '缺少個案資料'; end if;

  select c.supervisor_id,c.important_conditions,c.ongoing_treatments
    into v_old_supervisor,v_old_conditions,v_old_treatments
  from public.care_cases c
  where c.id=v_case_id;

  if not found then raise exception '找不到個案'; end if;

  v_new_conditions:=case
    when payload ? 'important_conditions' then nullif(btrim(payload->>'important_conditions'),'')
    else v_old_conditions
  end;
  v_new_treatments:=case
    when payload ? 'ongoing_treatments' then nullif(btrim(payload->>'ongoing_treatments'),'')
    else v_old_treatments
  end;
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
  if v_welfare='低收入戶' then
    v_payment:='不收費';
  elsif v_welfare in ('中低收入戶','一般戶') and v_payment='不收費' then
    raise exception '第二類／第三類個案不可設定為不收費';
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

  if v_old_conditions is distinct from v_new_conditions then
    insert into public.case_health_profile_history(
      case_id,field_name,old_value,new_value,changed_by
    ) values(
      v_case_id,'important_conditions',v_old_conditions,v_new_conditions,(select auth.uid())
    );
  end if;

  if v_old_treatments is distinct from v_new_treatments then
    insert into public.case_health_profile_history(
      case_id,field_name,old_value,new_value,changed_by
    ) values(
      v_case_id,'ongoing_treatments',v_old_treatments,v_new_treatments,(select auth.uid())
    );
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
      lives_alone=case when payload ? 'lives_alone' and nullif(payload->>'lives_alone','') is not null then (payload->>'lives_alone')::boolean else lives_alone end,
      has_dementia=case when payload ? 'has_dementia' and nullif(payload->>'has_dementia','') is not null then (payload->>'has_dementia')::boolean else has_dementia end,
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
      important_conditions=v_new_conditions,
      ongoing_treatments=v_new_treatments,
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
$function$;
revoke all on function public.update_case_profile(jsonb) from public, anon, authenticated;
grant execute on function public.update_case_profile(jsonb) to authenticated;
grant execute on function public.update_case_profile(jsonb) to service_role;


-- ===== Final proxy-edit permission normalization (2026-10-06) =====
-- V5.2 評估代理編輯權限修正
-- 2026-10-06
-- User-approved policy: supervisors may edit assessments for other supervisors' cases.
-- Normalize assessment save RPCs to private.can_edit_assessment_case(case_id).


-- RLS normalization: keep the UI/DB permission model aligned.
-- Supervisors may edit assessments for any case; manager roles keep the same capability.
alter policy "assessment_adl_history_insert" on public.assessment_adl_history
  with check (((changed_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_adl_history.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_adl_insert" on public.assessment_adl_records
  with check (((created_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_adl_records.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_adl_update" on public.assessment_adl_records
  using ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_adl_records.case_id) AND private.can_edit_assessment_case(c.id)))))
  with check ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_adl_records.case_id) AND private.can_edit_assessment_case(c.id)))));

alter policy "assessment_caregiver_screen_history_insert" on public.assessment_caregiver_screen_history
  with check (((changed_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_caregiver_screen_history.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_caregiver_screen_insert" on public.assessment_caregiver_screen_records
  with check (((created_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_caregiver_screen_records.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_caregiver_screen_update" on public.assessment_caregiver_screen_records
  using ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_caregiver_screen_records.case_id) AND private.can_edit_assessment_case(c.id)))))
  with check ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_caregiver_screen_records.case_id) AND private.can_edit_assessment_case(c.id)))));

alter policy "assessment_event_forms_delete" on public.assessment_event_forms
  using ((EXISTS ( SELECT 1
   FROM (assessment_events ae
     JOIN care_cases c ON ((c.id = ae.case_id)))
  WHERE ((ae.id = assessment_event_forms.assessment_event_id) AND private.can_edit_assessment_case(c.id)))));

alter policy "assessment_event_forms_insert" on public.assessment_event_forms
  with check ((EXISTS ( SELECT 1
   FROM (assessment_events ae
     JOIN care_cases c ON ((c.id = ae.case_id)))
  WHERE ((ae.id = assessment_event_forms.assessment_event_id) AND private.can_edit_assessment_case(c.id)))));

alter policy "assessment_event_forms_update" on public.assessment_event_forms
  using ((EXISTS ( SELECT 1
   FROM (assessment_events ae
     JOIN care_cases c ON ((c.id = ae.case_id)))
  WHERE ((ae.id = assessment_event_forms.assessment_event_id) AND private.can_edit_assessment_case(c.id)))))
  with check ((EXISTS ( SELECT 1
   FROM (assessment_events ae
     JOIN care_cases c ON ((c.id = ae.case_id)))
  WHERE ((ae.id = assessment_event_forms.assessment_event_id) AND private.can_edit_assessment_case(c.id)))));

alter policy "assessment_event_summaries_insert" on public.assessment_event_summaries
  with check (((created_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_event_summaries.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_event_summaries_update" on public.assessment_event_summaries
  using ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_event_summaries.case_id) AND private.can_edit_assessment_case(c.id)))))
  with check ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_event_summaries.case_id) AND private.can_edit_assessment_case(c.id)))));

alter policy "assessment_event_summary_history_insert" on public.assessment_event_summary_history
  with check (((changed_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_event_summary_history.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_events_insert" on public.assessment_events
  with check (((created_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_events.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_events_update" on public.assessment_events
  using ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_events.case_id) AND private.can_edit_assessment_case(c.id)))))
  with check ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_events.case_id) AND private.can_edit_assessment_case(c.id)))));

alter policy "assessment_gds15_history_insert" on public.assessment_gds15_history
  with check (((changed_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_gds15_history.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_gds15_insert" on public.assessment_gds15_records
  with check (((created_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_gds15_records.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_gds15_update" on public.assessment_gds15_records
  using ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_gds15_records.case_id) AND private.can_edit_assessment_case(c.id)))))
  with check ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_gds15_records.case_id) AND private.can_edit_assessment_case(c.id)))));

alter policy "assessment_home_safety_history_insert" on public.assessment_home_safety_history
  with check (((changed_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_home_safety_history.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_home_safety_insert" on public.assessment_home_safety_records
  with check (((created_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_home_safety_records.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_home_safety_update" on public.assessment_home_safety_records
  using ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_home_safety_records.case_id) AND private.can_edit_assessment_case(c.id)))))
  with check ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_home_safety_records.case_id) AND private.can_edit_assessment_case(c.id)))));

alter policy "assessment_iadl_history_insert" on public.assessment_iadl_history
  with check (((changed_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_iadl_history.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_iadl_insert" on public.assessment_iadl_records
  with check (((created_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_iadl_records.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_iadl_update" on public.assessment_iadl_records
  using ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_iadl_records.case_id) AND private.can_edit_assessment_case(c.id)))))
  with check ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_iadl_records.case_id) AND private.can_edit_assessment_case(c.id)))));

alter policy "assessment_spmsq_history_insert" on public.assessment_spmsq_history
  with check (((changed_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_spmsq_history.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_spmsq_insert" on public.assessment_spmsq_records
  with check (((created_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_spmsq_records.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_spmsq_update" on public.assessment_spmsq_records
  using ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_spmsq_records.case_id) AND private.can_edit_assessment_case(c.id)))))
  with check ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_spmsq_records.case_id) AND private.can_edit_assessment_case(c.id)))));

alter policy "assessment_support_history_insert" on public.assessment_support_history
  with check (((changed_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_support_history.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_support_insert" on public.assessment_support_records
  with check (((created_by = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_support_records.case_id) AND private.can_edit_assessment_case(c.id))))));

alter policy "assessment_support_update" on public.assessment_support_records
  using ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_support_records.case_id) AND private.can_edit_assessment_case(c.id)))))
  with check ((EXISTS ( SELECT 1
   FROM care_cases c
  WHERE ((c.id = assessment_support_records.case_id) AND private.can_edit_assessment_case(c.id)))));


-- save_assessment_adl
CREATE OR REPLACE FUNCTION public.save_assessment_adl(p_event_id uuid, p_answers jsonb, p_notes jsonb, p_finalize boolean DEFAULT false, p_copied_from_id uuid DEFAULT NULL::uuid)
 RETURNS assessment_adl_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_adl_records;
  v_old public.assessment_adl_records;
  v_total integer := 0;
  v_level text := null;
  v_key text;
  v_required text[] := array[
    'feeding','transfer','grooming','toileting','bathing',
    'walking','stairs','dressing','bowel','bladder'
  ];
  v_score integer;
begin
  if (select auth.uid()) is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select *
  into v_event
  from public.assessment_events
  where id = p_event_id;

  if v_event.id is null then
    raise exception 'ASSESSMENT_EVENT_NOT_FOUND';
  end if;

  select *
  into v_case
  from public.care_cases
  where id = v_event.case_id;

  if v_case.id is null or not private.can_edit_assessment_case(v_case.id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1
    from public.assessment_event_forms f
    where f.assessment_event_id = p_event_id
      and f.form_code = 'adl'
  ) then
    raise exception 'ADL_FORM_NOT_SELECTED';
  end if;

  p_answers := coalesce(p_answers, '{}'::jsonb);
  p_notes := coalesce(p_notes, '{}'::jsonb);

  foreach v_key in array v_required loop
    if p_answers ? v_key then
      begin
        v_score := (p_answers ->> v_key)::integer;
      exception when others then
        raise exception 'INVALID_ADL_SCORE:%', v_key;
      end;

      if
        (v_key = 'feeding' and v_score not in (0,5,10)) or
        (v_key = 'transfer' and v_score not in (0,5,10,15)) or
        (v_key = 'grooming' and v_score not in (0,5)) or
        (v_key = 'toileting' and v_score not in (0,5,10)) or
        (v_key = 'bathing' and v_score not in (0,5)) or
        (v_key = 'walking' and v_score not in (0,5,10,15)) or
        (v_key = 'stairs' and v_score not in (0,5,10)) or
        (v_key = 'dressing' and v_score not in (0,5,10)) or
        (v_key = 'bowel' and v_score not in (0,5,10)) or
        (v_key = 'bladder' and v_score not in (0,5,10))
      then
        raise exception 'INVALID_ADL_SCORE:%', v_key;
      end if;
      v_total := v_total + v_score;
    elsif p_finalize then
      raise exception 'ADL_INCOMPLETE:%', v_key;
    end if;
  end loop;

  if p_finalize then
    v_level := case
      when v_total <= 20 then 'complete_dependence'
      when v_total <= 60 then 'severe_dependence'
      when v_total <= 90 then 'moderate_dependence'
      when v_total <= 99 then 'mild_dependence'
      else 'independent'
    end;
  end if;

  select *
  into v_old
  from public.assessment_adl_records
  where assessment_event_id = p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_adl_records(
      assessment_event_id,
      case_id,
      answers,
      notes,
      total_score,
      dependency_level,
      copied_from_id,
      copied_at,
      confirmed_at,
      created_by,
      updated_by
    ) values (
      p_event_id,
      v_event.case_id,
      p_answers,
      p_notes,
      case when p_answers <> '{}'::jsonb then v_total else null end,
      v_level,
      p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),
      (select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.answers,'{}'::jsonb) || p_answers) as t(key)
    loop
      if (v_old.answers -> v_key) is distinct from (p_answers -> v_key) then
        insert into public.assessment_adl_history(
          adl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'answers.'||v_key,
          v_old.answers -> v_key, p_answers -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.notes,'{}'::jsonb) || p_notes) as t(key)
    loop
      if (v_old.notes -> v_key) is distinct from (p_notes -> v_key) then
        insert into public.assessment_adl_history(
          adl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'notes.'||v_key,
          v_old.notes -> v_key, p_notes -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    update public.assessment_adl_records
    set
      answers = p_answers,
      notes = p_notes,
      total_score = case when p_answers <> '{}'::jsonb then v_total else null end,
      dependency_level = case when p_finalize then v_level else dependency_level end,
      copied_from_id = coalesce(copied_from_id, p_copied_from_id),
      copied_at = case
        when copied_at is not null then copied_at
        when p_copied_from_id is not null then now()
        else null
      end,
      confirmed_at = case when p_finalize then now() else confirmed_at end,
      updated_by = (select auth.uid()),
      updated_at = now()
    where id = v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set
    status = case when p_finalize then 'completed' else 'in_progress' end,
    updated_at = now()
  where assessment_event_id = p_event_id
    and form_code = 'adl'
    and (
      p_finalize
      or status <> 'completed'
    );

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;
revoke all on function public.save_assessment_adl(uuid, jsonb, jsonb, boolean, uuid) from public, anon, authenticated;
grant execute on function public.save_assessment_adl(uuid, jsonb, jsonb, boolean, uuid) to authenticated;
grant execute on function public.save_assessment_adl(uuid, jsonb, jsonb, boolean, uuid) to service_role;

-- save_assessment_iadl
CREATE OR REPLACE FUNCTION public.save_assessment_iadl(p_event_id uuid, p_answers jsonb, p_notes jsonb, p_finalize boolean DEFAULT false, p_copied_from_id uuid DEFAULT NULL::uuid)
 RETURNS assessment_iadl_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_iadl_records;
  v_old public.assessment_iadl_records;
  v_total integer := 0;
  v_key text;
  v_required text[] := array[
    'telephone','shopping','meal_prep','housekeeping',
    'laundry','transportation','medication','finances'
  ];
  v_score integer;
begin
  if (select auth.uid()) is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_event
  from public.assessment_events
  where id = p_event_id;

  if v_event.id is null then
    raise exception 'ASSESSMENT_EVENT_NOT_FOUND';
  end if;

  select * into v_case
  from public.care_cases
  where id = v_event.case_id;

  if v_case.id is null or not private.can_edit_assessment_case(v_case.id) then
    raise exception 'ASSESSMENT_EDIT_FORBIDDEN';
  end if;

  if not exists (
    select 1
    from public.assessment_event_forms f
    where f.assessment_event_id = p_event_id
      and f.form_code = 'iadl'
  ) then
    raise exception 'IADL_FORM_NOT_SELECTED';
  end if;

  p_answers := coalesce(p_answers, '{}'::jsonb);
  p_notes := coalesce(p_notes, '{}'::jsonb);

  foreach v_key in array v_required loop
    if (p_answers ->> v_key) is not null then
      begin
        v_score := (p_answers ->> v_key)::integer;
      exception when others then
        raise exception 'INVALID_IADL_SCORE:%', v_key;
      end;

      if v_score not in (0,1,2) then
        raise exception 'INVALID_IADL_SCORE:%', v_key;
      end if;

      v_total := v_total + v_score;
    elsif p_finalize then
      raise exception 'IADL_INCOMPLETE:%', v_key;
    end if;
  end loop;

  select * into v_old
  from public.assessment_iadl_records
  where assessment_event_id = p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_iadl_records(
      assessment_event_id,
      case_id,
      answers,
      notes,
      total_score,
      copied_from_id,
      copied_at,
      confirmed_at,
      created_by,
      updated_by
    ) values (
      p_event_id,
      v_event.case_id,
      p_answers,
      p_notes,
      case when p_answers <> '{}'::jsonb then v_total else null end,
      p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),
      (select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.answers,'{}'::jsonb) || p_answers) as t(key)
    loop
      if (v_old.answers -> v_key) is distinct from (p_answers -> v_key) then
        insert into public.assessment_iadl_history(
          iadl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'answers.'||v_key,
          v_old.answers -> v_key, p_answers -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key
      from jsonb_object_keys(coalesce(v_old.notes,'{}'::jsonb) || p_notes) as t(key)
    loop
      if (v_old.notes -> v_key) is distinct from (p_notes -> v_key) then
        insert into public.assessment_iadl_history(
          iadl_record_id, assessment_event_id, case_id, field_name,
          old_value, new_value, changed_by
        ) values (
          v_old.id, p_event_id, v_event.case_id, 'notes.'||v_key,
          v_old.notes -> v_key, p_notes -> v_key, (select auth.uid())
        );
      end if;
    end loop;

    update public.assessment_iadl_records
    set
      answers = p_answers,
      notes = p_notes,
      total_score = case when p_answers <> '{}'::jsonb then v_total else null end,
      copied_from_id = coalesce(copied_from_id, p_copied_from_id),
      copied_at = case
        when copied_at is not null then copied_at
        when p_copied_from_id is not null then now()
        else null
      end,
      confirmed_at = case when p_finalize then now() else confirmed_at end,
      updated_by = (select auth.uid()),
      updated_at = now()
    where id = v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set
    status = case when p_finalize then 'completed' else 'in_progress' end,
    updated_at = now()
  where assessment_event_id = p_event_id
    and form_code = 'iadl'
    and (p_finalize or status <> 'completed');

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;
revoke all on function public.save_assessment_iadl(uuid, jsonb, jsonb, boolean, uuid) from public, anon, authenticated;
grant execute on function public.save_assessment_iadl(uuid, jsonb, jsonb, boolean, uuid) to authenticated;
grant execute on function public.save_assessment_iadl(uuid, jsonb, jsonb, boolean, uuid) to service_role;

-- save_assessment_spmsq
CREATE OR REPLACE FUNCTION public.save_assessment_spmsq(p_event_id uuid, p_judgments jsonb, p_notes jsonb, p_finalize boolean DEFAULT false, p_unable boolean DEFAULT false, p_unable_reason text DEFAULT NULL::text, p_copied_from_id uuid DEFAULT NULL::uuid)
 RETURNS assessment_spmsq_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_spmsq_records;
  v_old public.assessment_spmsq_records;
  v_key text;
  v_keys text[] := array['q1','q2','q3','q4','q5','q6','q7','q8','q9','q10'];
  v_judgment text;
  v_error_count integer := 0;
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
    where f.assessment_event_id=p_event_id and f.form_code='spmsq'
  ) then raise exception 'SPMSQ_FORM_NOT_SELECTED'; end if;

  p_judgments := coalesce(p_judgments,'{}'::jsonb);
  p_notes := coalesce(p_notes,'{}'::jsonb);
  p_unable_reason := nullif(btrim(p_unable_reason),'');

  if p_unable and p_unable_reason is null then
    raise exception 'SPMSQ_UNABLE_REASON_REQUIRED';
  end if;

  foreach v_key in array v_keys loop
    v_judgment := p_judgments ->> v_key;

    if v_judgment is not null
       and v_judgment not in ('correct','wrong','unable_answer') then
      raise exception 'INVALID_SPMSQ_JUDGMENT:%', v_key;
    end if;

    if not p_unable then
      if p_finalize and v_judgment is null then
        raise exception 'SPMSQ_JUDGMENT_INCOMPLETE:%', v_key;
      end if;

      if p_finalize
         and v_judgment='unable_answer'
         and nullif(btrim(p_notes ->> v_key),'') is null then
        raise exception 'SPMSQ_UNABLE_ANSWER_REASON_REQUIRED:%', v_key;
      end if;

      if v_judgment in ('wrong','unable_answer') then
        v_error_count := v_error_count + 1;
      end if;
    end if;
  end loop;

  select * into v_old
  from public.assessment_spmsq_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_spmsq_records(
      assessment_event_id,case_id,responses,judgments,notes,error_count,is_unable,unable_reason,
      copied_from_id,copied_at,confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,'{}'::jsonb,p_judgments,p_notes,
      case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
      p_unable,p_unable_reason,p_copied_from_id,
      case when p_copied_from_id is not null then now() else null end,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.judgments,'{}'::jsonb)||p_judgments) as t(key)
    loop
      if (v_old.judgments->v_key) is distinct from (p_judgments->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'judgments.'||v_key,
          v_old.judgments->v_key,p_judgments->v_key,(select auth.uid())
        );
      end if;
    end loop;

    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.notes,'{}'::jsonb)||p_notes) as t(key)
    loop
      if (v_old.notes->v_key) is distinct from (p_notes->v_key) then
        insert into public.assessment_spmsq_history(
          spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'notes.'||v_key,
          v_old.notes->v_key,p_notes->v_key,(select auth.uid())
        );
      end if;
    end loop;

    if v_old.is_unable is distinct from p_unable then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'is_unable',
        to_jsonb(v_old.is_unable),to_jsonb(p_unable),(select auth.uid())
      );
    end if;

    if v_old.unable_reason is distinct from p_unable_reason then
      insert into public.assessment_spmsq_history(
        spmsq_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'unable_reason',
        to_jsonb(v_old.unable_reason),to_jsonb(p_unable_reason),(select auth.uid())
      );
    end if;

    update public.assessment_spmsq_records
    set responses='{}'::jsonb,
        judgments=p_judgments,
        notes=p_notes,
        error_count=case when p_unable then null when p_judgments<>'{}'::jsonb then v_error_count else null end,
        is_unable=p_unable,
        unable_reason=p_unable_reason,
        copied_from_id=coalesce(copied_from_id,p_copied_from_id),
        copied_at=case when copied_at is not null then copied_at when p_copied_from_id is not null then now() else null end,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case
      when p_finalize and p_unable then 'unable'
      when p_finalize then 'completed'
      else 'in_progress'
    end,
    updated_at=now()
  where assessment_event_id=p_event_id
    and form_code='spmsq';

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;
revoke all on function public.save_assessment_spmsq(uuid, jsonb, jsonb, boolean, boolean, text, uuid) from public, anon, authenticated;
grant execute on function public.save_assessment_spmsq(uuid, jsonb, jsonb, boolean, boolean, text, uuid) to authenticated;
grant execute on function public.save_assessment_spmsq(uuid, jsonb, jsonb, boolean, boolean, text, uuid) to service_role;

-- save_assessment_gds15
CREATE OR REPLACE FUNCTION public.save_assessment_gds15(p_event_id uuid, p_answers jsonb, p_finalize boolean DEFAULT false, p_completion_mode text DEFAULT 'completed'::text, p_exception_reason text DEFAULT NULL::text)
 RETURNS assessment_gds15_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_record public.assessment_gds15_records;
  v_old public.assessment_gds15_records;
  v_key text;
  v_keys text[]:=array['q1','q2','q3','q4','q5','q6','q7','q8','q9','q10','q11','q12','q13','q14','q15'];
  v_reverse text[]:=array['q1','q5','q7','q11','q13'];
  v_value text;
  v_total integer:=0;
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
    where f.assessment_event_id=p_event_id and f.form_code='gds15'
  ) then raise exception 'GDS15_FORM_NOT_SELECTED'; end if;

  p_answers:=coalesce(p_answers,'{}'::jsonb);
  p_completion_mode:=coalesce(p_completion_mode,'completed');
  p_exception_reason:=nullif(btrim(p_exception_reason),'');

  if p_completion_mode not in ('completed','unable','not_applicable') then
    raise exception 'INVALID_GDS15_COMPLETION_MODE';
  end if;

  if p_completion_mode<>'completed' and p_exception_reason is null then
    raise exception 'GDS15_EXCEPTION_REASON_REQUIRED';
  end if;

  foreach v_key in array v_keys loop
    v_value:=p_answers->>v_key;

    if v_value is not null and v_value not in ('yes','no') then
      raise exception 'INVALID_GDS15_ANSWER:%',v_key;
    end if;

    if p_finalize and p_completion_mode='completed' and v_value is null then
      raise exception 'GDS15_INCOMPLETE:%',v_key;
    end if;

    if p_completion_mode='completed' and v_value is not null then
      if v_key = any(v_reverse) then
        if v_value='no' then v_total:=v_total+1; end if;
      else
        if v_value='yes' then v_total:=v_total+1; end if;
      end if;
    end if;
  end loop;

  select * into v_old
  from public.assessment_gds15_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_gds15_records(
      assessment_event_id,case_id,answers,total_score,completion_mode,exception_reason,
      confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_answers,
      case when p_completion_mode='completed' and p_answers<>'{}'::jsonb then v_total else null end,
      p_completion_mode,p_exception_reason,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    )
    returning * into v_record;
  else
    for v_key in
      select key from jsonb_object_keys(coalesce(v_old.answers,'{}'::jsonb)||p_answers) as t(key)
    loop
      if (v_old.answers->v_key) is distinct from (p_answers->v_key) then
        insert into public.assessment_gds15_history(
          gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
        ) values (
          v_old.id,p_event_id,v_event.case_id,'answers.'||v_key,
          v_old.answers->v_key,p_answers->v_key,(select auth.uid())
        );
      end if;
    end loop;

    if v_old.completion_mode is distinct from p_completion_mode then
      insert into public.assessment_gds15_history(
        gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'completion_mode',
        to_jsonb(v_old.completion_mode),to_jsonb(p_completion_mode),(select auth.uid())
      );
    end if;

    if v_old.exception_reason is distinct from p_exception_reason then
      insert into public.assessment_gds15_history(
        gds15_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values (
        v_old.id,p_event_id,v_event.case_id,'exception_reason',
        to_jsonb(v_old.exception_reason),to_jsonb(p_exception_reason),(select auth.uid())
      );
    end if;

    update public.assessment_gds15_records
    set answers=p_answers,
        total_score=case when p_completion_mode='completed' and p_answers<>'{}'::jsonb then v_total else null end,
        completion_mode=p_completion_mode,
        exception_reason=p_exception_reason,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  update public.assessment_event_forms
  set status=case
      when p_finalize and p_completion_mode='unable' then 'unable'
      when p_finalize and p_completion_mode='not_applicable' then 'not_applicable'
      when p_finalize then 'completed'
      else 'in_progress'
    end,
    updated_at=now()
  where assessment_event_id=p_event_id and form_code='gds15';

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;
revoke all on function public.save_assessment_gds15(uuid, jsonb, boolean, text, text) from public, anon, authenticated;
grant execute on function public.save_assessment_gds15(uuid, jsonb, boolean, text, text) to authenticated;
grant execute on function public.save_assessment_gds15(uuid, jsonb, boolean, text, text) to service_role;

-- save_assessment_health
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
$function$;
revoke all on function public.save_assessment_health(uuid, jsonb, jsonb, jsonb, jsonb, boolean, uuid, text) from public, anon, authenticated;
grant execute on function public.save_assessment_health(uuid, jsonb, jsonb, jsonb, jsonb, boolean, uuid, text) to authenticated;
grant execute on function public.save_assessment_health(uuid, jsonb, jsonb, jsonb, jsonb, boolean, uuid, text) to service_role;

-- save_assessment_home_safety
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
$function$;
revoke all on function public.save_assessment_home_safety(uuid, jsonb, jsonb, jsonb, jsonb, boolean, uuid) from public, anon, authenticated;
grant execute on function public.save_assessment_home_safety(uuid, jsonb, jsonb, jsonb, jsonb, boolean, uuid) to authenticated;
grant execute on function public.save_assessment_home_safety(uuid, jsonb, jsonb, jsonb, jsonb, boolean, uuid) to service_role;

-- save_assessment_support
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
$function$;
revoke all on function public.save_assessment_support(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, boolean, uuid) from public, anon, authenticated;
grant execute on function public.save_assessment_support(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, boolean, uuid) to authenticated;
grant execute on function public.save_assessment_support(uuid, jsonb, jsonb, jsonb, jsonb, jsonb, boolean, uuid) to service_role;

-- save_assessment_caregiver_screen
CREATE OR REPLACE FUNCTION public.save_assessment_caregiver_screen(p_event_id uuid, p_applicability text, p_caregiver_info jsonb, p_answers jsonb, p_notes jsonb, p_summary jsonb, p_finalize boolean DEFAULT false)
 RETURNS assessment_caregiver_screen_records
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_event public.assessment_events;
  v_case public.care_cases;
  v_old public.assessment_caregiver_screen_records;
  v_record public.assessment_caregiver_screen_records;
  v_key text;
  v_value text;
  v_positive_count int:=0;
  v_referral_required boolean:=false;
  v_form_status text;
  v_indicator_keys text[]:=array[
    'behavior_stress','older_caregiver','limited_experience','no_relief',
    'multiple_dependents','caregiver_health','resource_financial_crisis',
    'recent_care_change','violence_neglect_risk','suicide_risk'
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
    where f.assessment_event_id=p_event_id and f.form_code='caregiver_burden'
  ) then raise exception 'CAREGIVER_SCREEN_FORM_NOT_SELECTED'; end if;

  p_applicability:=coalesce(nullif(p_applicability,''),'applicable');
  p_caregiver_info:=coalesce(p_caregiver_info,'{}'::jsonb);
  p_answers:=coalesce(p_answers,'{}'::jsonb);
  p_notes:=coalesce(p_notes,'{}'::jsonb);
  p_summary:=coalesce(p_summary,'{}'::jsonb);

  if p_applicability not in ('applicable','no_family_caregiver','paid_caregiver','unable') then
    raise exception 'INVALID_CAREGIVER_SCREEN_APPLICABILITY';
  end if;
  if jsonb_typeof(p_caregiver_info)<>'object' or jsonb_typeof(p_answers)<>'object'
     or jsonb_typeof(p_notes)<>'object' or jsonb_typeof(p_summary)<>'object' then
    raise exception 'INVALID_CAREGIVER_SCREEN_JSON';
  end if;

  if p_applicability='applicable' then
    foreach v_key in array v_indicator_keys loop
      v_value:=p_answers->>v_key;
      if v_value is not null and v_value not in ('yes','no') then
        raise exception 'INVALID_CAREGIVER_SCREEN_ANSWER:%',v_key;
      end if;
      if p_finalize and v_value is null then
        raise exception 'CAREGIVER_SCREEN_INCOMPLETE:%',v_key;
      end if;
      if v_value='yes' then
        v_positive_count:=v_positive_count+1;
        if p_finalize and nullif(btrim(coalesce(p_notes->>v_key,'')),'') is null then
          raise exception 'CAREGIVER_SCREEN_NOTE_REQUIRED:%',v_key;
        end if;
      end if;
    end loop;

    v_referral_required:=v_positive_count>=2
      or p_answers->>'violence_neglect_risk'='yes'
      or p_answers->>'suicide_risk'='yes'
      or coalesce((p_summary->>'professional_referral')::boolean,false);

    if p_finalize then
      if nullif(btrim(coalesce(p_caregiver_info->>'name','')),'') is null
         or nullif(btrim(coalesce(p_caregiver_info->>'relation','')),'') is null then
        raise exception 'CAREGIVER_SCREEN_CAREGIVER_INFO_REQUIRED';
      end if;
      if v_referral_required then
        if coalesce(p_summary->>'referral_action','') not in ('planned','referred','declined_followup','other') then
          raise exception 'CAREGIVER_SCREEN_REFERRAL_ACTION_REQUIRED';
        end if;
        if nullif(btrim(coalesce(p_summary->>'action_note','')),'') is null then
          raise exception 'CAREGIVER_SCREEN_ACTION_NOTE_REQUIRED';
        end if;
      end if;
      if coalesce((p_summary->>'professional_referral')::boolean,false)
         and nullif(btrim(coalesce(p_summary->>'professional_reason','')),'') is null then
        raise exception 'CAREGIVER_SCREEN_PROFESSIONAL_REASON_REQUIRED';
      end if;
    end if;
  elsif p_finalize then
    if p_applicability='unable'
       and nullif(btrim(coalesce(p_summary->>'unable_reason','')),'') is null then
      raise exception 'CAREGIVER_SCREEN_UNABLE_REASON_REQUIRED';
    end if;
  end if;

  p_summary:=p_summary
    || jsonb_build_object(
      'positive_count',v_positive_count,
      'referral_required',v_referral_required
    );

  select * into v_old
  from public.assessment_caregiver_screen_records
  where assessment_event_id=p_event_id
  for update;

  if v_old.id is null then
    insert into public.assessment_caregiver_screen_records(
      assessment_event_id,case_id,applicability,caregiver_info,answers,notes,summary,
      confirmed_at,created_by,updated_by
    ) values (
      p_event_id,v_event.case_id,p_applicability,p_caregiver_info,p_answers,p_notes,p_summary,
      case when p_finalize then now() else null end,
      (select auth.uid()),(select auth.uid())
    ) returning * into v_record;
  else
    if to_jsonb(v_old.applicability) is distinct from to_jsonb(p_applicability) then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'applicability',to_jsonb(v_old.applicability),to_jsonb(p_applicability),(select auth.uid()));
    end if;
    if v_old.caregiver_info is distinct from p_caregiver_info then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'caregiver_info',v_old.caregiver_info,p_caregiver_info,(select auth.uid()));
    end if;
    if v_old.answers is distinct from p_answers then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'answers',v_old.answers,p_answers,(select auth.uid()));
    end if;
    if v_old.notes is distinct from p_notes then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'notes',v_old.notes,p_notes,(select auth.uid()));
    end if;
    if v_old.summary is distinct from p_summary then
      insert into public.assessment_caregiver_screen_history(
        caregiver_screen_record_id,assessment_event_id,case_id,field_name,old_value,new_value,changed_by
      ) values(v_old.id,p_event_id,v_event.case_id,'summary',v_old.summary,p_summary,(select auth.uid()));
    end if;

    update public.assessment_caregiver_screen_records
    set applicability=p_applicability,
        caregiver_info=p_caregiver_info,
        answers=p_answers,
        notes=p_notes,
        summary=p_summary,
        confirmed_at=case when p_finalize then now() else confirmed_at end,
        updated_by=(select auth.uid()),
        updated_at=now()
    where id=v_old.id
    returning * into v_record;
  end if;

  v_form_status:=case
    when not p_finalize then 'in_progress'
    when p_applicability in ('no_family_caregiver','paid_caregiver') then 'not_applicable'
    when p_applicability='unable' then 'unable'
    else 'completed'
  end;

  update public.assessment_event_forms
  set status=v_form_status,updated_at=now()
  where assessment_event_id=p_event_id and form_code='caregiver_burden';

  perform private.sync_assessment_event_progress(p_event_id);

  return v_record;
end;
$function$;
revoke all on function public.save_assessment_caregiver_screen(uuid, text, jsonb, jsonb, jsonb, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.save_assessment_caregiver_screen(uuid, text, jsonb, jsonb, jsonb, jsonb, boolean) to authenticated;
grant execute on function public.save_assessment_caregiver_screen(uuid, text, jsonb, jsonb, jsonb, jsonb, boolean) to service_role;

-- save_assessment_event_summary
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
$function$;
revoke all on function public.save_assessment_event_summary(uuid, text, text, text, boolean, text, boolean, text, boolean, text, text, text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.save_assessment_event_summary(uuid, text, text, text, boolean, text, boolean, text, boolean, text, text, text, text, text, boolean) to authenticated;
grant execute on function public.save_assessment_event_summary(uuid, text, text, text, boolean, text, boolean, text, boolean, text, text, text, text, text, boolean) to service_role;

commit;
