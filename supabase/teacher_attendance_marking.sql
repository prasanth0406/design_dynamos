-- Migration: Teacher Attendance Marking & Roster Access
-- Run on Supabase project otfazpvwsxintyzcytvx

-- 1. Add status column to attendance_records (non-destructive, defaults to 'present')
alter table public.attendance_records
  add column if not exists status text not null default 'present'
  check (status in ('present', 'absent', 'leave'));

-- 2. Configure replica identity full so Realtime provides complete row data on updates
alter table public.attendance_records replica identity full;

-- 3. Update profiles RLS: Allow teachers to view student profiles for roster display
drop policy if exists "Teachers read student profiles" on public.profiles;
create policy "Teachers read student profiles"
on public.profiles for select to authenticated
using (
  (user_id = (select auth.uid()))
  or (public.current_app_role() = 'teacher' and role = 'student')
);

-- 4. Secure RPC: Teacher marks or updates student attendance (Present or Absent)
create or replace function public.teacher_mark_attendance(
  p_session_id uuid,
  p_student_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_session public.attendance_sessions%rowtype;
  student_profile public.profiles%rowtype;
  normalized_status text := lower(trim(p_status));
begin
  if (select auth.uid()) is null or public.current_app_role() is distinct from 'teacher' then
    return jsonb_build_object('ok', false, 'code', 'unauthorized', 'message', 'Only teachers can mark attendance.');
  end if;

  if normalized_status not in ('present', 'absent', 'leave') then
    return jsonb_build_object('ok', false, 'code', 'invalid_status', 'message', 'Status must be present, absent, or leave.');
  end if;

  select * into target_session
  from public.attendance_sessions
  where id = p_session_id
    and teacher_id = (select auth.uid());

  if not found then
    return jsonb_build_object('ok', false, 'code', 'session_not_found', 'message', 'Session not found or you are not the session teacher.');
  end if;

  select * into student_profile
  from public.profiles
  where user_id = p_student_id
    and role = 'student';

  if not found then
    return jsonb_build_object('ok', false, 'code', 'student_not_found', 'message', 'Student profile not found.');
  end if;

  insert into public.attendance_records (
    session_id,
    student_id,
    student_email,
    status,
    marked_at
  ) values (
    target_session.id,
    student_profile.user_id,
    student_profile.email,
    normalized_status,
    now()
  )
  on conflict (session_id, student_id) do update
  set status = excluded.status,
      marked_at = now();

  return jsonb_build_object(
    'ok', true,
    'code', 'success',
    'message', 'Attendance saved as ' || normalized_status,
    'session_id', target_session.id,
    'student_id', student_profile.user_id,
    'student_email', student_profile.email,
    'status', normalized_status
  );
end;
$$;

revoke all on function public.teacher_mark_attendance(uuid, uuid, text) from public, anon;
grant execute on function public.teacher_mark_attendance(uuid, uuid, text) to authenticated;

-- 5. Secure RPC: Teacher retrieves student roster with marked attendance status
create or replace function public.get_teacher_session_roster(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  roster jsonb;
begin
  if (select auth.uid()) is null or public.current_app_role() is distinct from 'teacher' then
    raise exception 'Only teachers can access the session roster.';
  end if;

  if not exists (
    select 1 from public.attendance_sessions
    where id = p_session_id and teacher_id = (select auth.uid())
  ) then
    raise exception 'Session not found or permission denied.';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'student_id', p.user_id,
        'email', p.email,
        'full_name', coalesce(d.full_name, split_part(p.email, '@', 1)),
        'register_number', coalesce(d.register_number, upper(split_part(p.email, '@', 1))),
        'status', coalesce(ar.status, 'unmarked'),
        'marked_at', ar.marked_at
      ) order by coalesce(d.register_number, p.email)
    ),
    '[]'::jsonb
  ) into roster
  from public.profiles p
  left join public.student_directory d on lower(d.email) = lower(p.email)
  left join public.attendance_records ar on ar.session_id = p_session_id and ar.student_id = p.user_id
  where p.role = 'student';

  return roster;
end;
$$;

revoke all on function public.get_teacher_session_roster(uuid) from public, anon;
grant execute on function public.get_teacher_session_roster(uuid) to authenticated;

-- Ensure Realtime publication includes attendance_records
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1
       from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'attendance_records'
     ) then
    execute 'alter publication supabase_realtime add table public.attendance_records';
  end if;
end;
$$;

notify pgrst, 'reload schema';
