-- V5.2 固定例假日設定與加班提醒
alter table public.staff_users
  add column if not exists regular_day_weekday smallint default 0;

update public.staff_users
set regular_day_weekday = 0
where regular_day_weekday is null;

alter table public.staff_users
  alter column regular_day_weekday set default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.staff_users'::regclass
      and conname='staff_users_regular_day_weekday_check'
  ) then
    alter table public.staff_users
      add constraint staff_users_regular_day_weekday_check
      check (regular_day_weekday between 0 and 6);
  end if;
end $$;

alter table public.overtime_requests
  add column if not exists regular_day_weekday_snapshot smallint,
  add column if not exists regular_day_warning boolean not null default false;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.overtime_requests'::regclass
      and conname='overtime_requests_regular_day_weekday_snapshot_check'
  ) then
    alter table public.overtime_requests
      add constraint overtime_requests_regular_day_weekday_snapshot_check
      check (regular_day_weekday_snapshot is null or regular_day_weekday_snapshot between 0 and 6);
  end if;
end $$;

create or replace function private.set_overtime_regular_day_snapshot()
returns trigger
language plpgsql
security invoker
set search_path = public, private, pg_temp
as $$
declare
  v_weekday smallint;
begin
  select s.regular_day_weekday
    into v_weekday
  from public.staff_users s
  where s.id = new.applicant_staff_id;

  new.regular_day_weekday_snapshot := v_weekday;
  new.regular_day_warning :=
    coalesce(v_weekday is not null
      and new.work_date is not null
      and extract(dow from new.work_date)::smallint = v_weekday, false);

  return new;
end;
$$;

drop trigger if exists trg_set_overtime_regular_day_snapshot on public.overtime_requests;
create trigger trg_set_overtime_regular_day_snapshot
before insert or update of applicant_staff_id, work_date
on public.overtime_requests
for each row
execute function private.set_overtime_regular_day_snapshot();

comment on column public.staff_users.regular_day_weekday is
  '固定例假星期：0=週日,1=週一,...,6=週六';
comment on column public.overtime_requests.regular_day_weekday_snapshot is
  '申請儲存時之固定例假星期快照';
comment on column public.overtime_requests.regular_day_warning is
  '申請日是否與儲存當下固定例假星期相同';
