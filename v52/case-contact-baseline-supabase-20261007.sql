-- 家、電訪 baseline schema
-- Generated from verified TEST schema on 2026-10-07.
-- Intended for a database where these v2 tables do not yet exist.

begin;

create table public.case_contact_records (
  id uuid default gen_random_uuid() not null,
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
  status text default 'draft'::text not null,
  completed_at timestamp with time zone,
  completed_by_staff_id uuid,
  voided_at timestamp with time zone,
  voided_by_staff_id uuid,
  void_reason text,
  created_by uuid default auth.uid() not null,
  created_at timestamp with time zone default now() not null,
  updated_by_staff_id uuid,
  updated_at timestamp with time zone default now() not null,
  counts_for_cycle boolean default true not null,
  draft_payload jsonb default '{}'::jsonb not null,
  notes text
);

create table public.case_contact_record_people (
  id uuid default gen_random_uuid() not null,
  record_id uuid not null,
  person_type text not null,
  case_contact_id uuid,
  care_worker_id uuid,
  name_snapshot text not null,
  relationship_snapshot text,
  is_primary boolean default false not null,
  created_at timestamp with time zone default now() not null
);

create table public.case_contact_formal_details (
  record_id uuid not null,
  service_usage_status text,
  service_usage_note text,
  service_fit_status text,
  adjustment_directions text[] default '{}'::text[] not null,
  adjustment_note text,
  has_major_event boolean default false not null,
  major_event_types text[] default '{}'::text[] not null,
  major_event_note text,
  has_primary_concern boolean default false not null,
  primary_concern_note text,
  assessment_action text default 'none'::text not null,
  requires_action boolean default false not null,
  action_types text[] default '{}'::text[] not null,
  action_note text,
  satisfaction_note text,
  service_snapshot jsonb default '[]'::jsonb not null,
  updated_at timestamp with time zone default now() not null
);

create table public.case_home_visit_details (
  record_id uuid not null,
  visit_location text default 'home'::text not null,
  visit_location_note text,
  schedule_execution_status text,
  service_execution_status text,
  has_execution_difficulty boolean default false not null,
  execution_difficulty_note text,
  updated_at timestamp with time zone default now() not null
);

create table public.case_phone_details (
  record_id uuid not null,
  contact_success boolean default true not null,
  failure_reason text,
  failure_note text,
  needs_recontact boolean default false not null,
  recontact_date date,
  contact_content text,
  updated_at timestamp with time zone default now() not null
);

create table public.case_contact_satisfaction (
  id uuid default gen_random_uuid() not null,
  record_id uuid not null,
  item_code text not null,
  rating_code text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  note text
);

create table public.case_record_links (
  id uuid default gen_random_uuid() not null,
  case_id uuid not null,
  from_type text not null,
  from_id uuid not null,
  relation_type text not null,
  to_type text not null,
  to_id uuid not null,
  created_by_staff_id uuid not null,
  created_by uuid default auth.uid() not null,
  created_at timestamp with time zone default now() not null
);

create table public.case_followup_items (
  id uuid default gen_random_uuid() not null,
  case_id uuid not null,
  content text not null,
  responsible_staff_id uuid not null,
  due_date date,
  status text default 'pending'::text not null,
  result text,
  completed_at timestamp with time zone,
  source_type text,
  source_id uuid,
  created_by_staff_id uuid not null,
  created_by uuid default auth.uid() not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

create table public.case_followup_updates (
  id uuid default gen_random_uuid() not null,
  followup_item_id uuid not null,
  update_date date not null,
  result_code text not null,
  note text,
  next_due_date date,
  source_type text,
  source_id uuid,
  updated_by_staff_id uuid not null,
  created_by uuid default auth.uid() not null,
  created_at timestamp with time zone default now() not null
);

create table public.case_contact_record_history (
  id uuid default gen_random_uuid() not null,
  record_id uuid not null,
  version_no integer not null,
  snapshot jsonb not null,
  changed_by_staff_id uuid not null,
  created_by uuid default auth.uid() not null,
  changed_at timestamp with time zone default now() not null
);

create table public.case_routine_plans (
  id uuid default gen_random_uuid() not null,
  case_id uuid not null,
  plan_type text not null,
  planned_date date not null,
  note text,
  status text default 'planned'::text not null,
  created_by_staff_id uuid not null,
  created_by uuid default auth.uid() not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  fulfilled_at timestamp with time zone,
  cancelled_at timestamp with time zone
);

alter table public.case_contact_formal_details add constraint case_contact_formal_details_assessment_action_check CHECK ((assessment_action = ANY (ARRAY['none'::text, 'completed'::text, 'create_now'::text, 'schedule_later'::text])));
alter table public.case_contact_formal_details add constraint case_contact_formal_details_pkey PRIMARY KEY (record_id);
alter table public.case_contact_record_history add constraint case_contact_record_history_pkey PRIMARY KEY (id);
alter table public.case_contact_record_history add constraint case_contact_record_history_record_id_version_no_key UNIQUE (record_id, version_no);
alter table public.case_contact_record_history add constraint case_contact_record_history_version_no_check CHECK ((version_no >= 1));
alter table public.case_contact_record_people add constraint case_contact_record_people_person_type_check CHECK ((person_type = ANY (ARRAY['client'::text, 'primary_caregiver'::text, 'family'::text, 'care_worker'::text, 'other'::text])));
alter table public.case_contact_record_people add constraint case_contact_record_people_pkey PRIMARY KEY (id);
alter table public.case_contact_records add constraint case_contact_records_check CHECK (((status <> 'completed'::text) OR (completed_at IS NOT NULL)));
alter table public.case_contact_records add constraint case_contact_records_check1 CHECK (((status <> 'voided'::text) OR ((voided_at IS NOT NULL) AND (void_reason IS NOT NULL) AND (btrim(void_reason) <> ''::text))));
alter table public.case_contact_records add constraint case_contact_records_pkey PRIMARY KEY (id);
alter table public.case_contact_records add constraint case_contact_records_record_type_check CHECK ((record_type = ANY (ARRAY['home_visit'::text, 'formal_phone'::text, 'general_phone'::text])));
alter table public.case_contact_records add constraint case_contact_records_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'completed'::text, 'voided'::text])));
alter table public.case_contact_satisfaction add constraint case_contact_satisfaction_item_code_check CHECK ((item_code = ANY (ARRAY['service_time'::text, 'worker_attitude'::text, 'service_fit'::text, 'punctuality'::text, 'service_quality'::text, 'supervisor_support'::text])));
alter table public.case_contact_satisfaction add constraint case_contact_satisfaction_pkey PRIMARY KEY (id);
alter table public.case_contact_satisfaction add constraint case_contact_satisfaction_rating_code_check CHECK ((rating_code = ANY (ARRAY['very_satisfied'::text, 'satisfied'::text, 'neutral'::text, 'dissatisfied'::text, 'very_dissatisfied'::text, 'not_applicable'::text, 'not_asked'::text])));
alter table public.case_contact_satisfaction add constraint case_contact_satisfaction_record_id_item_code_key UNIQUE (record_id, item_code);
alter table public.case_followup_items add constraint case_followup_items_pkey PRIMARY KEY (id);
alter table public.case_followup_items add constraint case_followup_items_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'in_progress'::text, 'completed'::text, 'closed'::text])));
alter table public.case_followup_updates add constraint case_followup_updates_pkey PRIMARY KEY (id);
alter table public.case_followup_updates add constraint case_followup_updates_result_code_check CHECK ((result_code = ANY (ARRAY['completed'::text, 'improved'::text, 'partially_improved'::text, 'not_improved'::text, 'observe'::text, 'needs_action'::text, 'referred'::text, 'suspend_service'::text, 'close_report'::text, 'revise_care_plan'::text, 'not_followed'::text])));
alter table public.case_home_visit_details add constraint case_home_visit_details_pkey PRIMARY KEY (record_id);
alter table public.case_home_visit_details add constraint case_home_visit_details_visit_location_check CHECK ((visit_location = ANY (ARRAY['home'::text, 'hospital'::text, 'facility'::text, 'other'::text])));
alter table public.case_phone_details add constraint case_phone_details_pkey PRIMARY KEY (record_id);
alter table public.case_record_links add constraint case_record_links_from_type_from_id_relation_type_to_type_t_key UNIQUE (from_type, from_id, relation_type, to_type, to_id);
alter table public.case_record_links add constraint case_record_links_pkey PRIMARY KEY (id);
alter table public.case_record_links add constraint case_record_links_relation_type_check CHECK ((relation_type = ANY (ARRAY['source'::text, 'related'::text, 'followup'::text])));
alter table public.case_routine_plans add constraint case_routine_plans_pkey PRIMARY KEY (id);
alter table public.case_routine_plans add constraint case_routine_plans_plan_type_check CHECK ((plan_type = ANY (ARRAY['quarterly_bundle'::text, 'formal_phone'::text])));
alter table public.case_routine_plans add constraint case_routine_plans_status_check CHECK ((status = ANY (ARRAY['planned'::text, 'fulfilled'::text, 'cancelled'::text])));
alter table public.case_contact_formal_details add constraint case_contact_formal_details_record_id_fkey FOREIGN KEY (record_id) REFERENCES case_contact_records(id) ON DELETE CASCADE;
alter table public.case_contact_record_history add constraint case_contact_record_history_changed_by_staff_id_fkey FOREIGN KEY (changed_by_staff_id) REFERENCES staff_users(id);
alter table public.case_contact_record_history add constraint case_contact_record_history_record_id_fkey FOREIGN KEY (record_id) REFERENCES case_contact_records(id) ON DELETE CASCADE;
alter table public.case_contact_record_people add constraint case_contact_record_people_care_worker_id_fkey FOREIGN KEY (care_worker_id) REFERENCES care_workers(id);
alter table public.case_contact_record_people add constraint case_contact_record_people_case_contact_id_fkey FOREIGN KEY (case_contact_id) REFERENCES case_contacts(id);
alter table public.case_contact_record_people add constraint case_contact_record_people_record_id_fkey FOREIGN KEY (record_id) REFERENCES case_contact_records(id) ON DELETE CASCADE;
alter table public.case_contact_records add constraint case_contact_records_case_id_fkey FOREIGN KEY (case_id) REFERENCES care_cases(id);
alter table public.case_contact_records add constraint case_contact_records_completed_by_staff_id_fkey FOREIGN KEY (completed_by_staff_id) REFERENCES staff_users(id);
alter table public.case_contact_records add constraint case_contact_records_performed_by_staff_id_fkey FOREIGN KEY (performed_by_staff_id) REFERENCES staff_users(id);
alter table public.case_contact_records add constraint case_contact_records_supervisor_staff_id_fkey FOREIGN KEY (supervisor_staff_id) REFERENCES staff_users(id);
alter table public.case_contact_records add constraint case_contact_records_updated_by_staff_id_fkey FOREIGN KEY (updated_by_staff_id) REFERENCES staff_users(id);
alter table public.case_contact_records add constraint case_contact_records_voided_by_staff_id_fkey FOREIGN KEY (voided_by_staff_id) REFERENCES staff_users(id);
alter table public.case_contact_satisfaction add constraint case_contact_satisfaction_record_id_fkey FOREIGN KEY (record_id) REFERENCES case_contact_records(id) ON DELETE CASCADE;
alter table public.case_followup_items add constraint case_followup_items_case_id_fkey FOREIGN KEY (case_id) REFERENCES care_cases(id);
alter table public.case_followup_items add constraint case_followup_items_created_by_staff_id_fkey FOREIGN KEY (created_by_staff_id) REFERENCES staff_users(id);
alter table public.case_followup_items add constraint case_followup_items_responsible_staff_id_fkey FOREIGN KEY (responsible_staff_id) REFERENCES staff_users(id);
alter table public.case_followup_updates add constraint case_followup_updates_followup_item_id_fkey FOREIGN KEY (followup_item_id) REFERENCES case_followup_items(id) ON DELETE CASCADE;
alter table public.case_followup_updates add constraint case_followup_updates_updated_by_staff_id_fkey FOREIGN KEY (updated_by_staff_id) REFERENCES staff_users(id);
alter table public.case_home_visit_details add constraint case_home_visit_details_record_id_fkey FOREIGN KEY (record_id) REFERENCES case_contact_records(id) ON DELETE CASCADE;
alter table public.case_phone_details add constraint case_phone_details_record_id_fkey FOREIGN KEY (record_id) REFERENCES case_contact_records(id) ON DELETE CASCADE;
alter table public.case_record_links add constraint case_record_links_case_id_fkey FOREIGN KEY (case_id) REFERENCES care_cases(id);
alter table public.case_record_links add constraint case_record_links_created_by_staff_id_fkey FOREIGN KEY (created_by_staff_id) REFERENCES staff_users(id);
alter table public.case_routine_plans add constraint case_routine_plans_case_id_fkey FOREIGN KEY (case_id) REFERENCES care_cases(id);
alter table public.case_routine_plans add constraint case_routine_plans_created_by_staff_id_fkey FOREIGN KEY (created_by_staff_id) REFERENCES staff_users(id);

CREATE INDEX case_contact_record_history_changed_by_staff_idx ON public.case_contact_record_history USING btree (changed_by_staff_id);
CREATE INDEX case_contact_record_people_contact_idx ON public.case_contact_record_people USING btree (case_contact_id);
CREATE INDEX case_contact_record_people_record_idx ON public.case_contact_record_people USING btree (record_id);
CREATE INDEX case_contact_record_people_worker_idx ON public.case_contact_record_people USING btree (care_worker_id);
CREATE INDEX case_contact_records_case_date_idx ON public.case_contact_records USING btree (case_id, record_date DESC, created_at DESC);
CREATE INDEX case_contact_records_completed_by_idx ON public.case_contact_records USING btree (completed_by_staff_id);
CREATE INDEX case_contact_records_performed_by_idx ON public.case_contact_records USING btree (performed_by_staff_id);
CREATE INDEX case_contact_records_supervisor_idx ON public.case_contact_records USING btree (supervisor_staff_id);
CREATE INDEX case_contact_records_type_status_idx ON public.case_contact_records USING btree (record_type, status, record_date DESC);
CREATE INDEX case_contact_records_updated_by_idx ON public.case_contact_records USING btree (updated_by_staff_id);
CREATE INDEX case_contact_records_voided_by_idx ON public.case_contact_records USING btree (voided_by_staff_id);
CREATE INDEX case_followup_items_case_status_due_idx ON public.case_followup_items USING btree (case_id, status, due_date);
CREATE INDEX case_followup_items_created_by_staff_idx ON public.case_followup_items USING btree (created_by_staff_id);
CREATE INDEX case_followup_items_responsible_idx ON public.case_followup_items USING btree (responsible_staff_id, status, due_date);
CREATE INDEX case_followup_updates_item_date_idx ON public.case_followup_updates USING btree (followup_item_id, update_date DESC, created_at DESC);
CREATE INDEX case_followup_updates_updated_by_staff_idx ON public.case_followup_updates USING btree (updated_by_staff_id);
CREATE INDEX case_record_links_case_idx ON public.case_record_links USING btree (case_id, created_at DESC);
CREATE INDEX case_record_links_created_by_staff_idx ON public.case_record_links USING btree (created_by_staff_id);
CREATE INDEX case_routine_plans_case_type_status_idx ON public.case_routine_plans USING btree (case_id, plan_type, status, planned_date);
CREATE INDEX case_routine_plans_created_by_staff_idx ON public.case_routine_plans USING btree (created_by_staff_id);

alter table public.case_contact_records enable row level security;
alter table public.case_contact_record_people enable row level security;
alter table public.case_contact_formal_details enable row level security;
alter table public.case_home_visit_details enable row level security;
alter table public.case_phone_details enable row level security;
alter table public.case_contact_satisfaction enable row level security;
alter table public.case_record_links enable row level security;
alter table public.case_followup_items enable row level security;
alter table public.case_followup_updates enable row level security;
alter table public.case_contact_record_history enable row level security;
alter table public.case_routine_plans enable row level security;

create policy case_contact_formal_details_delete on public.case_contact_formal_details as permissive for delete to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_formal_details.record_id)))));
create policy case_contact_formal_details_insert on public.case_contact_formal_details as permissive for insert to authenticated with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_formal_details.record_id)))));
create policy case_contact_formal_details_select on public.case_contact_formal_details as permissive for select to authenticated using (private.can_manage_cases());
create policy case_contact_formal_details_update on public.case_contact_formal_details as permissive for update to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_formal_details.record_id))))) with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_formal_details.record_id)))));
create policy case_contact_record_history_insert on public.case_contact_record_history as permissive for insert to authenticated with check (((created_by = ( SELECT auth.uid() AS uid)) AND private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_record_history.record_id)))));
create policy case_contact_record_history_select on public.case_contact_record_history as permissive for select to authenticated using (private.can_manage_cases());
create policy case_contact_record_people_delete on public.case_contact_record_people as permissive for delete to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_record_people.record_id)))));
create policy case_contact_record_people_insert on public.case_contact_record_people as permissive for insert to authenticated with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_record_people.record_id)))));
create policy case_contact_record_people_select on public.case_contact_record_people as permissive for select to authenticated using (private.can_manage_cases());
create policy case_contact_record_people_update on public.case_contact_record_people as permissive for update to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_record_people.record_id))))) with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_record_people.record_id)))));
create policy case_contact_records_insert on public.case_contact_records as permissive for insert to authenticated with check (((created_by = ( SELECT auth.uid() AS uid)) AND private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE (c.id = case_contact_records.case_id)))));
create policy case_contact_records_select on public.case_contact_records as permissive for select to authenticated using (private.can_manage_cases());
create policy case_contact_records_update on public.case_contact_records as permissive for update to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE (c.id = case_contact_records.case_id))))) with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE (c.id = case_contact_records.case_id)))));
create policy case_contact_satisfaction_delete on public.case_contact_satisfaction as permissive for delete to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_satisfaction.record_id)))));
create policy case_contact_satisfaction_insert on public.case_contact_satisfaction as permissive for insert to authenticated with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_satisfaction.record_id)))));
create policy case_contact_satisfaction_select on public.case_contact_satisfaction as permissive for select to authenticated using (private.can_manage_cases());
create policy case_contact_satisfaction_update on public.case_contact_satisfaction as permissive for update to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_satisfaction.record_id))))) with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_contact_satisfaction.record_id)))));
create policy case_followup_items_insert on public.case_followup_items as permissive for insert to authenticated with check (((created_by = ( SELECT auth.uid() AS uid)) AND private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE (c.id = case_followup_items.case_id)))));
create policy case_followup_items_select on public.case_followup_items as permissive for select to authenticated using (private.can_manage_cases());
create policy case_followup_items_update on public.case_followup_items as permissive for update to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE (c.id = case_followup_items.case_id))))) with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE (c.id = case_followup_items.case_id)))));
create policy case_followup_updates_insert on public.case_followup_updates as permissive for insert to authenticated with check (((created_by = ( SELECT auth.uid() AS uid)) AND private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_followup_items f
  WHERE (f.id = case_followup_updates.followup_item_id)))));
create policy case_followup_updates_select on public.case_followup_updates as permissive for select to authenticated using (private.can_manage_cases());
create policy case_home_visit_details_insert on public.case_home_visit_details as permissive for insert to authenticated with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_home_visit_details.record_id)))));
create policy case_home_visit_details_select on public.case_home_visit_details as permissive for select to authenticated using (private.can_manage_cases());
create policy case_home_visit_details_update on public.case_home_visit_details as permissive for update to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_home_visit_details.record_id))))) with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_home_visit_details.record_id)))));
create policy case_phone_details_insert on public.case_phone_details as permissive for insert to authenticated with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_phone_details.record_id)))));
create policy case_phone_details_select on public.case_phone_details as permissive for select to authenticated using (private.can_manage_cases());
create policy case_phone_details_update on public.case_phone_details as permissive for update to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_phone_details.record_id))))) with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM case_contact_records r
  WHERE (r.id = case_phone_details.record_id)))));
create policy case_record_links_delete on public.case_record_links as permissive for delete to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE (c.id = case_record_links.case_id)))));
create policy case_record_links_insert on public.case_record_links as permissive for insert to authenticated with check (((created_by = ( SELECT auth.uid() AS uid)) AND private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE (c.id = case_record_links.case_id)))));
create policy case_record_links_select on public.case_record_links as permissive for select to authenticated using (private.can_manage_cases());
create policy case_routine_plans_insert on public.case_routine_plans as permissive for insert to authenticated with check (((created_by = ( SELECT auth.uid() AS uid)) AND private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE (c.id = case_routine_plans.case_id)))));
create policy case_routine_plans_select on public.case_routine_plans as permissive for select to authenticated using (private.can_manage_cases());
create policy case_routine_plans_update on public.case_routine_plans as permissive for update to authenticated using ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE (c.id = case_routine_plans.case_id))))) with check ((private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM care_cases c
  WHERE (c.id = case_routine_plans.case_id)))));

revoke all on public.case_contact_records from public, anon, authenticated;
revoke all on public.case_contact_record_people from public, anon, authenticated;
revoke all on public.case_contact_formal_details from public, anon, authenticated;
revoke all on public.case_home_visit_details from public, anon, authenticated;
revoke all on public.case_phone_details from public, anon, authenticated;
revoke all on public.case_contact_satisfaction from public, anon, authenticated;
revoke all on public.case_record_links from public, anon, authenticated;
revoke all on public.case_followup_items from public, anon, authenticated;
revoke all on public.case_followup_updates from public, anon, authenticated;
revoke all on public.case_contact_record_history from public, anon, authenticated;
revoke all on public.case_routine_plans from public, anon, authenticated;
grant insert, select, update on public.case_contact_records to authenticated;
grant all on public.case_contact_records to service_role;
grant delete, insert, select, update on public.case_contact_record_people to authenticated;
grant all on public.case_contact_record_people to service_role;
grant delete, insert, select, update on public.case_contact_formal_details to authenticated;
grant all on public.case_contact_formal_details to service_role;
grant insert, select, update on public.case_home_visit_details to authenticated;
grant all on public.case_home_visit_details to service_role;
grant insert, select, update on public.case_phone_details to authenticated;
grant all on public.case_phone_details to service_role;
grant delete, insert, select, update on public.case_contact_satisfaction to authenticated;
grant all on public.case_contact_satisfaction to service_role;
grant delete, insert, select on public.case_record_links to authenticated;
grant all on public.case_record_links to service_role;
grant insert, select, update on public.case_followup_items to authenticated;
grant all on public.case_followup_items to service_role;
grant insert, select on public.case_followup_updates to authenticated;
grant all on public.case_followup_updates to service_role;
grant insert, select on public.case_contact_record_history to authenticated;
grant all on public.case_contact_record_history to service_role;
grant insert, select, update on public.case_routine_plans to authenticated;
grant all on public.case_routine_plans to service_role;

commit;
