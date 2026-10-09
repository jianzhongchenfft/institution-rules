-- One-time production initialization of team messages, based on tested V35+V36 state.
-- NO test data copied. Only five new public.team_message* tables are created.
-- Source: TEST Supabase schema, 2026-10-09. This script requires existing public.staff_users and private authorization helpers.
SET LOCAL search_path = public, pg_catalog;

CREATE TABLE public.team_messages (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  description text NOT NULL,
  created_by_staff_id uuid NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  closed_at timestamptz,
  CONSTRAINT team_messages_created_by_staff_id_fkey FOREIGN KEY (created_by_staff_id) REFERENCES public.staff_users(id),
  CONSTRAINT team_messages_description_check CHECK (((char_length(btrim(description)) >= 1) AND (char_length(btrim(description)) <= 5000))),
  CONSTRAINT team_messages_pkey PRIMARY KEY (id)
);

CREATE TABLE public.team_message_updates (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  message_id uuid NOT NULL,
  staff_id uuid NOT NULL,
  body text NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  is_system boolean DEFAULT false NOT NULL,
  voided_at timestamptz,
  voided_by_staff_id uuid,
  CONSTRAINT team_message_updates_body_check CHECK (((char_length(btrim(body)) >= 1) AND (char_length(btrim(body)) <=
CASE
    WHEN is_system THEN 11000
    ELSE 2000
END))),
  CONSTRAINT team_message_updates_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.team_messages(id) ON DELETE RESTRICT,
  CONSTRAINT team_message_updates_pkey PRIMARY KEY (id),
  CONSTRAINT team_message_updates_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_users(id),
  CONSTRAINT team_message_updates_voided_by_staff_id_fkey FOREIGN KEY (voided_by_staff_id) REFERENCES public.staff_users(id),
  CONSTRAINT team_update_void_consistency CHECK ((((voided_at IS NULL) AND (voided_by_staff_id IS NULL)) OR ((voided_at IS NOT NULL) AND (voided_by_staff_id IS NOT NULL) AND (NOT is_system))))
);

CREATE TABLE public.team_message_tasks (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  message_id uuid NOT NULL,
  description text NOT NULL,
  assignee_staff_id uuid NOT NULL,
  sort_order integer DEFAULT 0 NOT NULL,
  is_done boolean DEFAULT false NOT NULL,
  assistance_needed boolean DEFAULT false NOT NULL,
  instruction_pending boolean DEFAULT false NOT NULL,
  cancelled_at timestamptz,
  cancelled_by_staff_id uuid,
  cancel_reason text,
  help_note text,
  help_update_id uuid,
  CONSTRAINT team_message_help_note_pair CHECK (((help_note IS NULL) = (help_update_id IS NULL))),
  CONSTRAINT team_message_help_note_size CHECK (((help_note IS NULL) OR ((char_length(btrim(help_note)) >= 1) AND (char_length(btrim(help_note)) <= 1700)))),
  CONSTRAINT team_message_tasks_assignee_staff_id_fkey FOREIGN KEY (assignee_staff_id) REFERENCES public.staff_users(id),
  CONSTRAINT team_message_tasks_cancelled_by_staff_id_fkey FOREIGN KEY (cancelled_by_staff_id) REFERENCES public.staff_users(id),
  CONSTRAINT team_message_tasks_description_check CHECK (((char_length(btrim(description)) >= 1) AND (char_length(btrim(description)) <= 1000))),
  CONSTRAINT team_message_tasks_help_update_id_fkey FOREIGN KEY (help_update_id) REFERENCES public.team_message_updates(id),
  CONSTRAINT team_message_tasks_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.team_messages(id) ON DELETE RESTRICT,
  CONSTRAINT team_message_tasks_pkey PRIMARY KEY (id),
  CONSTRAINT team_task_action_state_check CHECK (((NOT (assistance_needed AND instruction_pending)) AND (NOT (is_done AND (assistance_needed OR instruction_pending))))),
  CONSTRAINT team_task_cancel_consistency CHECK ((((cancelled_at IS NULL) AND (cancelled_by_staff_id IS NULL) AND (cancel_reason IS NULL)) OR ((cancelled_at IS NOT NULL) AND (cancelled_by_staff_id IS NOT NULL) AND ((cancel_reason IS NULL) OR (char_length(btrim(cancel_reason)) <= 500)) AND (NOT is_done) AND (NOT assistance_needed) AND (NOT instruction_pending))))
);

CREATE TABLE public.team_message_recipients (
  message_id uuid NOT NULL,
  staff_id uuid NOT NULL,
  read_at timestamptz,
  CONSTRAINT team_message_recipients_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.team_messages(id) ON DELETE CASCADE,
  CONSTRAINT team_message_recipients_pkey PRIMARY KEY (message_id, staff_id),
  CONSTRAINT team_message_recipients_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_users(id)
);

CREATE TABLE public.team_message_favorites (
  message_id uuid NOT NULL,
  staff_id uuid NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  CONSTRAINT team_message_favorites_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.team_messages(id) ON DELETE CASCADE,
  CONSTRAINT team_message_favorites_pkey PRIMARY KEY (message_id, staff_id),
  CONSTRAINT team_message_favorites_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff_users(id)
);

CREATE INDEX team_message_favorites_staff_idx ON public.team_message_favorites USING btree (staff_id, created_at DESC);
CREATE INDEX team_message_recipients_staff_idx ON public.team_message_recipients USING btree (staff_id, read_at);
CREATE INDEX team_message_tasks_assignee_idx ON public.team_message_tasks USING btree (assignee_staff_id, is_done);
CREATE INDEX team_message_tasks_message_idx ON public.team_message_tasks USING btree (message_id, sort_order);
CREATE INDEX team_message_updates_message_idx ON public.team_message_updates USING btree (message_id, created_at, id);
CREATE INDEX team_message_updates_staff_idx ON public.team_message_updates USING btree (staff_id);
CREATE INDEX team_messages_created_idx ON public.team_messages USING btree (created_at DESC);
CREATE INDEX team_messages_creator_idx ON public.team_messages USING btree (created_by_staff_id);

ALTER TABLE public.team_messages, public.team_message_updates, public.team_message_tasks, public.team_message_recipients, public.team_message_favorites ENABLE ROW LEVEL SECURITY;

CREATE POLICY team_favorites_delete ON public.team_message_favorites AS PERMISSIVE FOR DELETE TO authenticated USING (private.can_manage_cases() AND (staff_id = private.current_staff_user_id())) ;
CREATE POLICY team_favorites_insert ON public.team_message_favorites AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (private.can_manage_cases() AND (staff_id = private.current_staff_user_id()));
CREATE POLICY team_favorites_select ON public.team_message_favorites AS PERMISSIVE FOR SELECT TO authenticated USING (private.can_manage_cases() AND (staff_id = private.current_staff_user_id())) ;
CREATE POLICY team_recipients_insert ON public.team_message_recipients AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (private.can_manage_cases() AND (EXISTS ( SELECT 1
   FROM team_messages m
  WHERE ((m.id = team_message_recipients.message_id) AND (m.created_by_staff_id = private.current_staff_user_id()) AND (m.closed_at IS NULL)))) AND (EXISTS ( SELECT 1
   FROM staff_users s
  WHERE ((s.id = team_message_recipients.staff_id) AND s.is_active AND (s.role = ANY (ARRAY['admin'::text, 'organization_manager'::text, 'business_manager'::text, 'supervisor'::text]))))));
CREATE POLICY team_recipients_manage_own_read ON public.team_message_recipients AS PERMISSIVE FOR UPDATE TO authenticated USING (private.can_manage_cases() AND (staff_id = private.current_staff_user_id())) WITH CHECK (private.can_manage_cases() AND (staff_id = private.current_staff_user_id()));
CREATE POLICY team_recipients_select ON public.team_message_recipients AS PERMISSIVE FOR SELECT TO authenticated USING private.can_manage_cases() ;
CREATE POLICY team_tasks_insert ON public.team_message_tasks AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (private.can_manage_cases() AND (NOT is_done) AND (EXISTS ( SELECT 1
   FROM team_messages m
  WHERE ((m.id = team_message_tasks.message_id) AND (m.created_by_staff_id = private.current_staff_user_id()) AND (m.closed_at IS NULL)))) AND (EXISTS ( SELECT 1
   FROM staff_users s
  WHERE ((s.id = team_message_tasks.assignee_staff_id) AND s.is_active AND (s.role = ANY (ARRAY['admin'::text, 'organization_manager'::text, 'business_manager'::text, 'supervisor'::text]))))));
CREATE POLICY team_tasks_select ON public.team_message_tasks AS PERMISSIVE FOR SELECT TO authenticated USING private.can_manage_cases() ;
CREATE POLICY team_updates_author_edit ON public.team_message_updates AS PERMISSIVE FOR UPDATE TO authenticated USING (private.can_manage_cases() AND (staff_id = private.current_staff_user_id()) AND (NOT is_system) AND (voided_at IS NULL)) WITH CHECK (private.can_manage_cases() AND (staff_id = private.current_staff_user_id()) AND (NOT is_system) AND (voided_at IS NULL) AND (voided_by_staff_id IS NULL));
CREATE POLICY team_updates_insert ON public.team_message_updates AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (private.can_manage_cases() AND (staff_id = private.current_staff_user_id()) AND (is_system = false) AND (voided_at IS NULL) AND (voided_by_staff_id IS NULL) AND (EXISTS ( SELECT 1
   FROM team_messages m
  WHERE ((m.id = team_message_updates.message_id) AND (m.closed_at IS NULL)))));
CREATE POLICY team_updates_select ON public.team_message_updates AS PERMISSIVE FOR SELECT TO authenticated USING private.can_manage_cases() ;
CREATE POLICY team_messages_close ON public.team_messages AS PERMISSIVE FOR UPDATE TO authenticated USING (private.can_manage_cases() AND (created_by_staff_id = private.current_staff_user_id()) AND (closed_at IS NULL)) WITH CHECK (private.can_manage_cases() AND (created_by_staff_id = private.current_staff_user_id()) AND (closed_at IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM team_message_tasks t
  WHERE (t.message_id = team_messages.id))));
CREATE POLICY team_messages_insert ON public.team_messages AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (private.can_manage_cases() AND (created_by_staff_id = private.current_staff_user_id()) AND (closed_at IS NULL));
CREATE POLICY team_messages_select ON public.team_messages AS PERMISSIVE FOR SELECT TO authenticated USING private.can_manage_cases() ;

-- Least privilege: three business tables have NO direct INSERT rights.
REVOKE ALL ON public.team_messages, public.team_message_updates, public.team_message_tasks, public.team_message_recipients, public.team_message_favorites FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.team_messages, public.team_message_updates, public.team_message_tasks, public.team_message_recipients, public.team_message_favorites TO authenticated;
GRANT INSERT, DELETE ON public.team_message_favorites TO authenticated;
GRANT UPDATE (read_at) ON public.team_message_recipients TO authenticated;
GRANT UPDATE (closed_at) ON public.team_messages TO authenticated;
GRANT INSERT (message_id,staff_id,body), UPDATE (body) ON public.team_message_updates TO authenticated;
