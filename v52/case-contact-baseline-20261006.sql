-- V5.2 家、電訪 baseline
-- Source of truth: TEST Supabase live schema (2026-10-06)
-- Purpose: reproducible clean deployment to production.
-- NOTE: This script does not touch legacy public.case_visits.
-- Prerequisites already shared by TEST and production:
--   public.care_cases, public.staff_users, public.care_workers, public.case_contacts
--   private.can_manage_cases(), public.get_case_staff_directory()

begin;

-- Destructive only for the new 家、電訪 V1 tables. Current data is test-only.
drop table if exists public.case_followup_updates;
drop table if exists public.case_contact_record_history;
drop table if exists public.case_contact_satisfaction;
drop table if exists public.case_home_visit_details;
drop table if exists public.case_phone_details;
drop table if exists public.case_contact_formal_details;
drop table if exists public.case_contact_record_people;
drop table if exists public.case_record_links;
drop table if exists public.case_routine_plans;
drop table if exists public.case_followup_items;
drop table if exists public.case_contact_records;

create table public.case_contact_records (
  id uuid not null default gen_random_uuid(),
  case_id uuid not null,
  record_type text not null,
  record_date date not null,
  record_time time without time zone,
  performed_by_staff_id uuid not null,
  performed_by_name_snapshot text,
  supervisor_staff_id uuid,
  supervisor_name_snapshot text,
  reason_code text not null,
  reason_note text,
  summary text,
  status text not null default 'draft'::text,
  completed_at timestamp with time zone,
  completed_by_staff_id uuid,
  voided_at timestamp with time zone,
  voided_by_staff_id uuid,
  void_reason text,
  created_by uuid not null default auth.uid(),
  created_at timestamp with time zone not null default now(),
  updated_by_staff_id uuid,
  updated_at timestamp with time zone not null default now(),
  counts_for_cycle boolean not null default true,
  draft_payload jsonb not null default '{}'::jsonb,
  notes text,
  constraint case_contact_records_pkey primary key (id),
  constraint case_contact_records_case_id_fkey foreign key (case_id) references public.care_cases(id),
  constraint case_contact_records_performed_by_staff_id_fkey foreign key (performed_by_staff_id) references public.staff_users(id),
  constraint case_contact_records_supervisor_staff_id_fkey foreign key (supervisor_staff_id) references public.staff_users(id),
  constraint case_contact_records_completed_by_staff_id_fkey foreign key (completed_by_staff_id) references public.staff_users(id),
  constraint case_contact_records_voided_by_staff_id_fkey foreign key (voided_by_staff_id) references public.staff_users(id),
  constraint case_contact_records_updated_by_staff_id_fkey foreign key (updated_by_staff_id) references public.staff_users(id),
  constraint case_contact_records_record_type_check check (record_type = any (array['home_visit'::text,'formal_phone'::text,'general_phone'::text])),
  constraint case_contact_records_status_check check (status = any (array['draft'::text,'completed'::text,'voided'::text])),
  constraint case_contact_records_check check ((status <> 'completed'::text) or (completed_at is not null)),
  constraint case_contact_records_check1 check ((status <> 'voided'::text) or ((voided_at is not null) and (void_reason is not null) and (btrim(void_reason) <> ''::text)))
);

create table public.case_contact_record_people (
  id uuid not null default gen_random_uuid(),
  record_id uuid not null,
  person_type text not null,
  case_contact_id uuid,
  care_worker_id uuid,
  name_snapshot text not null,
  relationship_snapshot text,
  is_primary boolean not null default false,
  created_at timestamp with time zone not null default now(),
  constraint case_contact_record_people_pkey primary key (id),
  constraint case_contact_record_people_record_id_fkey foreign key (record_id) references public.case_contact_records(id) on delete cascade,
  constraint case_contact_record_people_case_contact_id_fkey foreign key (case_contact_id) references public.case_contacts(id),
  constraint case_contact_record_people_care_worker_id_fkey foreign key (care_worker_id) references public.care_workers(id),
  constraint case_contact_record_people_person_type_check check (person_type = any (array['client'::text,'primary_caregiver'::text,'family'::text,'care_worker'::text,'other'::text]))
);

create table public.case_contact_formal_details (
  record_id uuid not null,
  service_usage_status text,
  service_usage_note text,
  service_fit_status text,
  adjustment_directions text[] not null default '{}'::text[],
  adjustment_note text,
  has_major_event boolean not null default false,
  major_event_types text[] not null default '{}'::text[],
  major_event_note text,
  has_primary_concern boolean not null default false,
  primary_concern_note text,
  assessment_action text not null default 'none'::text,
  requires_action boolean not null default false,
  action_types text[] not null default '{}'::text[],
  action_note text,
  satisfaction_note text,
  service_snapshot jsonb not null default '[]'::jsonb,
  updated_at timestamp with time zone not null default now(),
  constraint case_contact_formal_details_pkey primary key (record_id),
  constraint case_contact_formal_details_record_id_fkey foreign key (record_id) references public.case_contact_records(id) on delete cascade,
  constraint case_contact_formal_details_assessment_action_check check (assessment_action = any (array['none'::text,'completed'::text,'create_now'::text,'schedule_later'::text]))
);

create table public.case_home_visit_details (
  record_id uuid not null,
  visit_location text not null default 'home'::text,
  visit_location_note text,
  schedule_execution_status text,
  service_execution_status text,
  has_execution_difficulty boolean not null default false,
  execution_difficulty_note text,
  updated_at timestamp with time zone not null default now(),
  constraint case_home_visit_details_pkey primary key (record_id),
  constraint case_home_visit_details_record_id_fkey foreign key (record_id) references public.case_contact_records(id) on delete cascade,
  constraint case_home_visit_details_visit_location_check check (visit_location = any (array['home'::text,'hospital'::text,'facility'::text,'other'::text]))
);

create table public.case_phone_details (
  record_id uuid not null,
  contact_success boolean not null default true,
  failure_reason text,
  failure_note text,
  needs_recontact boolean not null default false,
  recontact_date date,
  contact_content text,
  updated_at timestamp with time zone not null default now(),
  constraint case_phone_details_pkey primary key (record_id),
  constraint case_phone_details_record_id_fkey foreign key (record_id) references public.case_contact_records(id) on delete cascade
);

create table public.case_contact_satisfaction (
  id uuid not null default gen_random_uuid(),
  record_id uuid not null,
  item_code text not null,
  rating_code text not null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  note text,
  constraint case_contact_satisfaction_pkey primary key (id),
  constraint case_contact_satisfaction_record_id_fkey foreign key (record_id) references public.case_contact_records(id) on delete cascade,
  constraint case_contact_satisfaction_record_id_item_code_key unique (record_id,item_code),
  constraint case_contact_satisfaction_item_code_check check (item_code = any (array['service_time'::text,'worker_attitude'::text,'service_fit'::text,'punctuality'::text,'service_quality'::text,'supervisor_support'::text])),
  constraint case_contact_satisfaction_rating_code_check check (rating_code = any (array['very_satisfied'::text,'satisfied'::text,'neutral'::text,'dissatisfied'::text,'very_dissatisfied'::text,'not_applicable'::text,'not_asked'::text]))
);

create table public.case_followup_items (
  id uuid not null default gen_random_uuid(),
  case_id uuid not null,
  content text not null,
  responsible_staff_id uuid not null,
  due_date date,
  status text not null default 'pending'::text,
  result text,
  completed_at timestamp with time zone,
  source_type text,
  source_id uuid,
  created_by_staff_id uuid not null,
  created_by uuid not null default auth.uid(),
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint case_followup_items_pkey primary key (id),
  constraint case_followup_items_case_id_fkey foreign key (case_id) references public.care_cases(id),
  constraint case_followup_items_responsible_staff_id_fkey foreign key (responsible_staff_id) references public.staff_users(id),
  constraint case_followup_items_created_by_staff_id_fkey foreign key (created_by_staff_id) references public.staff_users(id),
  constraint case_followup_items_status_check check (status = any (array['pending'::text,'in_progress'::text,'completed'::text,'closed'::text]))
);

create table public.case_followup_updates (
  id uuid not null default gen_random_uuid(),
  followup_item_id uuid not null,
  update_date date not null,
  result_code text not null,
  note text,
  next_due_date date,
  source_type text,
  source_id uuid,
  updated_by_staff_id uuid not null,
  created_by uuid not null default auth.uid(),
  created_at timestamp with time zone not null default now(),
  constraint case_followup_updates_pkey primary key (id),
  constraint case_followup_updates_followup_item_id_fkey foreign key (followup_item_id) references public.case_followup_items(id) on delete cascade,
  constraint case_followup_updates_updated_by_staff_id_fkey foreign key (updated_by_staff_id) references public.staff_users(id),
  constraint case_followup_updates_result_code_check check (result_code = any (array['completed'::text,'improved'::text,'partially_improved'::text,'not_improved'::text,'observe'::text,'needs_action'::text,'referred'::text,'suspend_service'::text,'close_report'::text,'revise_care_plan'::text,'not_followed'::text]))
);

create table public.case_contact_record_history (
  id uuid not null default gen_random_uuid(),
  record_id uuid not null,
  version_no integer not null,
  snapshot jsonb not null,
  changed_by_staff_id uuid not null,
  created_by uuid not null default auth.uid(),
  changed_at timestamp with time zone not null default now(),
  constraint case_contact_record_history_pkey primary key (id),
  constraint case_contact_record_history_record_id_fkey foreign key (record_id) references public.case_contact_records(id) on delete cascade,
  constraint case_contact_record_history_changed_by_staff_id_fkey foreign key (changed_by_staff_id) references public.staff_users(id),
  constraint case_contact_record_history_record_id_version_no_key unique (record_id,version_no),
  constraint case_contact_record_history_version_no_check check (version_no >= 1)
);

create table public.case_record_links (
  id uuid not null default gen_random_uuid(),
  case_id uuid not null,
  from_type text not null,
  from_id uuid not null,
  relation_type text not null,
  to_type text not null,
  to_id uuid not null,
  created_by_staff_id uuid not null,
  created_by uuid not null default auth.uid(),
  created_at timestamp with time zone not null default now(),
  constraint case_record_links_pkey primary key (id),
  constraint case_record_links_case_id_fkey foreign key (case_id) references public.care_cases(id),
  constraint case_record_links_created_by_staff_id_fkey foreign key (created_by_staff_id) references public.staff_users(id),
  constraint case_record_links_from_type_from_id_relation_type_to_type_t_key unique (from_type,from_id,relation_type,to_type,to_id),
  constraint case_record_links_relation_type_check check (relation_type = any (array['source'::text,'related'::text,'followup'::text]))
);

create table public.case_routine_plans (
  id uuid not null default gen_random_uuid(),
  case_id uuid not null,
  plan_type text not null,
  planned_date date not null,
  note text,
  status text not null default 'planned'::text,
  created_by_staff_id uuid not null,
  created_by uuid not null default auth.uid(),
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  fulfilled_at timestamp with time zone,
  cancelled_at timestamp with time zone,
  constraint case_routine_plans_pkey primary key (id),
  constraint case_routine_plans_case_id_fkey foreign key (case_id) references public.care_cases(id),
  constraint case_routine_plans_created_by_staff_id_fkey foreign key (created_by_staff_id) references public.staff_users(id),
  constraint case_routine_plans_plan_type_check check (plan_type = any (array['quarterly_bundle'::text,'formal_phone'::text])),
  constraint case_routine_plans_status_check check (status = any (array['planned'::text,'fulfilled'::text,'cancelled'::text]))
);

-- Indexes (excluding indexes automatically created for PK/UNIQUE constraints)
create index case_contact_records_case_date_idx on public.case_contact_records (case_id,record_date desc,created_at desc);
create index case_contact_records_completed_by_idx on public.case_contact_records (completed_by_staff_id);
create index case_contact_records_performed_by_idx on public.case_contact_records (performed_by_staff_id);
create index case_contact_records_supervisor_idx on public.case_contact_records (supervisor_staff_id);
create index case_contact_records_type_status_idx on public.case_contact_records (record_type,status,record_date desc);
create index case_contact_records_updated_by_idx on public.case_contact_records (updated_by_staff_id);
create index case_contact_records_voided_by_idx on public.case_contact_records (voided_by_staff_id);

create index case_contact_record_people_contact_idx on public.case_contact_record_people (case_contact_id);
create index case_contact_record_people_record_idx on public.case_contact_record_people (record_id);
create index case_contact_record_people_worker_idx on public.case_contact_record_people (care_worker_id);

create index case_contact_record_history_changed_by_staff_idx on public.case_contact_record_history (changed_by_staff_id);

create index case_followup_items_case_status_due_idx on public.case_followup_items (case_id,status,due_date);
create index case_followup_items_created_by_staff_idx on public.case_followup_items (created_by_staff_id);
create index case_followup_items_responsible_idx on public.case_followup_items (responsible_staff_id,status,due_date);

create index case_followup_updates_item_date_idx on public.case_followup_updates (followup_item_id,update_date desc,created_at desc);
create index case_followup_updates_updated_by_staff_idx on public.case_followup_updates (updated_by_staff_id);

create index case_record_links_case_idx on public.case_record_links (case_id,created_at desc);
create index case_record_links_created_by_staff_idx on public.case_record_links (created_by_staff_id);

create index case_routine_plans_case_type_status_idx on public.case_routine_plans (case_id,plan_type,status,planned_date);
create index case_routine_plans_created_by_staff_idx on public.case_routine_plans (created_by_staff_id);

-- RLS
alter table public.case_contact_records enable row level security;
alter table public.case_contact_record_people enable row level security;
alter table public.case_contact_formal_details enable row level security;
alter table public.case_home_visit_details enable row level security;
alter table public.case_phone_details enable row level security;
alter table public.case_contact_satisfaction enable row level security;
alter table public.case_followup_items enable row level security;
alter table public.case_followup_updates enable row level security;
alter table public.case_contact_record_history enable row level security;
alter table public.case_record_links enable row level security;
alter table public.case_routine_plans enable row level security;

create policy case_contact_records_select on public.case_contact_records for select to authenticated using (private.can_manage_cases());
create policy case_contact_records_insert on public.case_contact_records for insert to authenticated
with check (
  created_by=(select auth.uid())
  and private.can_manage_cases()
  and exists(select 1 from public.care_cases c where c.id=case_contact_records.case_id)
);
create policy case_contact_records_update on public.case_contact_records for update to authenticated
using (
  private.can_manage_cases()
  and exists(select 1 from public.care_cases c where c.id=case_contact_records.case_id)
)
with check (
  private.can_manage_cases()
  and exists(select 1 from public.care_cases c where c.id=case_contact_records.case_id)
);

create policy case_contact_record_people_select on public.case_contact_record_people for select to authenticated using (private.can_manage_cases());
create policy case_contact_record_people_insert on public.case_contact_record_people for insert to authenticated
with check (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_record_people.record_id));
create policy case_contact_record_people_update on public.case_contact_record_people for update to authenticated
using (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_record_people.record_id))
with check (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_record_people.record_id));
create policy case_contact_record_people_delete on public.case_contact_record_people for delete to authenticated
using (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_record_people.record_id));

create policy case_contact_formal_details_select on public.case_contact_formal_details for select to authenticated using (private.can_manage_cases());
create policy case_contact_formal_details_insert on public.case_contact_formal_details for insert to authenticated
with check (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_formal_details.record_id));
create policy case_contact_formal_details_update on public.case_contact_formal_details for update to authenticated
using (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_formal_details.record_id))
with check (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_formal_details.record_id));
create policy case_contact_formal_details_delete on public.case_contact_formal_details for delete to authenticated
using (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_formal_details.record_id));

create policy case_home_visit_details_select on public.case_home_visit_details for select to authenticated using (private.can_manage_cases());
create policy case_home_visit_details_insert on public.case_home_visit_details for insert to authenticated
with check (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_home_visit_details.record_id));
create policy case_home_visit_details_update on public.case_home_visit_details for update to authenticated
using (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_home_visit_details.record_id))
with check (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_home_visit_details.record_id));

create policy case_phone_details_select on public.case_phone_details for select to authenticated using (private.can_manage_cases());
create policy case_phone_details_insert on public.case_phone_details for insert to authenticated
with check (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_phone_details.record_id));
create policy case_phone_details_update on public.case_phone_details for update to authenticated
using (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_phone_details.record_id))
with check (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_phone_details.record_id));

create policy case_contact_satisfaction_select on public.case_contact_satisfaction for select to authenticated using (private.can_manage_cases());
create policy case_contact_satisfaction_insert on public.case_contact_satisfaction for insert to authenticated
with check (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_satisfaction.record_id));
create policy case_contact_satisfaction_update on public.case_contact_satisfaction for update to authenticated
using (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_satisfaction.record_id))
with check (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_satisfaction.record_id));
create policy case_contact_satisfaction_delete on public.case_contact_satisfaction for delete to authenticated
using (private.can_manage_cases() and exists(select 1 from public.case_contact_records r where r.id=case_contact_satisfaction.record_id));

create policy case_followup_items_select on public.case_followup_items for select to authenticated using (private.can_manage_cases());
create policy case_followup_items_insert on public.case_followup_items for insert to authenticated
with check (
  created_by=(select auth.uid())
  and private.can_manage_cases()
  and exists(select 1 from public.care_cases c where c.id=case_followup_items.case_id)
);
create policy case_followup_items_update on public.case_followup_items for update to authenticated
using (private.can_manage_cases() and exists(select 1 from public.care_cases c where c.id=case_followup_items.case_id))
with check (private.can_manage_cases() and exists(select 1 from public.care_cases c where c.id=case_followup_items.case_id));

create policy case_followup_updates_select on public.case_followup_updates for select to authenticated using (private.can_manage_cases());
create policy case_followup_updates_insert on public.case_followup_updates for insert to authenticated
with check (
  created_by=(select auth.uid())
  and private.can_manage_cases()
  and exists(select 1 from public.case_followup_items f where f.id=case_followup_updates.followup_item_id)
);

create policy case_contact_record_history_select on public.case_contact_record_history for select to authenticated using (private.can_manage_cases());
create policy case_contact_record_history_insert on public.case_contact_record_history for insert to authenticated
with check (
  created_by=(select auth.uid())
  and private.can_manage_cases()
  and exists(select 1 from public.case_contact_records r where r.id=case_contact_record_history.record_id)
);

create policy case_record_links_select on public.case_record_links for select to authenticated using (private.can_manage_cases());
create policy case_record_links_insert on public.case_record_links for insert to authenticated
with check (
  created_by=(select auth.uid())
  and private.can_manage_cases()
  and exists(select 1 from public.care_cases c where c.id=case_record_links.case_id)
);
create policy case_record_links_delete on public.case_record_links for delete to authenticated
using (private.can_manage_cases() and exists(select 1 from public.care_cases c where c.id=case_record_links.case_id));

create policy case_routine_plans_select on public.case_routine_plans for select to authenticated using (private.can_manage_cases());
create policy case_routine_plans_insert on public.case_routine_plans for insert to authenticated
with check (
  created_by=(select auth.uid())
  and private.can_manage_cases()
  and exists(select 1 from public.care_cases c where c.id=case_routine_plans.case_id)
);
create policy case_routine_plans_update on public.case_routine_plans for update to authenticated
using (private.can_manage_cases() and exists(select 1 from public.care_cases c where c.id=case_routine_plans.case_id))
with check (private.can_manage_cases() and exists(select 1 from public.care_cases c where c.id=case_routine_plans.case_id));

-- Grants: reproduce TEST privileges exactly.
revoke all on
  public.case_contact_records,
  public.case_contact_record_people,
  public.case_contact_formal_details,
  public.case_home_visit_details,
  public.case_phone_details,
  public.case_contact_satisfaction,
  public.case_followup_items,
  public.case_followup_updates,
  public.case_contact_record_history,
  public.case_record_links,
  public.case_routine_plans
from public, anon, authenticated;

grant select,insert,update on public.case_contact_records to authenticated;
grant select,insert,update,delete on public.case_contact_record_people to authenticated;
grant select,insert,update,delete on public.case_contact_formal_details to authenticated;
grant select,insert,update on public.case_home_visit_details to authenticated;
grant select,insert,update on public.case_phone_details to authenticated;
grant select,insert,update,delete on public.case_contact_satisfaction to authenticated;
grant select,insert,update on public.case_followup_items to authenticated;
grant select,insert on public.case_followup_updates to authenticated;
grant select,insert on public.case_contact_record_history to authenticated;
grant select,insert,delete on public.case_record_links to authenticated;
grant select,insert,update on public.case_routine_plans to authenticated;

grant all on
  public.case_contact_records,
  public.case_contact_record_people,
  public.case_contact_formal_details,
  public.case_home_visit_details,
  public.case_phone_details,
  public.case_contact_satisfaction,
  public.case_followup_items,
  public.case_followup_updates,
  public.case_contact_record_history,
  public.case_record_links,
  public.case_routine_plans
to service_role;

commit;
