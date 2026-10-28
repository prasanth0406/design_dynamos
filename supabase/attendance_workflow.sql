-- Attendance workflow upgrade for the existing Supabase Auth project.
-- Run this in the Supabase SQL Editor before testing the updated Flutter app.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  role text not null check (role in ('student', 'teacher')),
  created_at timestamptz not null default now()
);

create or replace function public.assign_role_from_college_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_email text := lower(coalesce(new.email, ''));
  assigned_role text;
begin
  if normalized_email ~ '^(23bcs|24bcs|25bcs)[0-9]{3}@iiitdwd[.]ac[.]in$' then
    assigned_role := 'student';
  elsif normalized_email ~ '^[a-z][a-z0-9._-]*@iiitdwd[.]ac[.]in$' then
    assigned_role := 'teacher';
  else
    raise exception 'Use a valid IIIT Dharwad student or teacher email address.';
  end if;

  new.raw_user_meta_data := jsonb_set(
    coalesce(new.raw_user_meta_data, '{}'::jsonb),
    '{role}',
    to_jsonb(assigned_role),
    true
  );
  return new;
end;
$$;

drop trigger if exists assign_role_from_college_email on auth.users;
create trigger assign_role_from_college_email
before insert or update of email on auth.users
for each row execute function public.assign_role_from_college_email();

create or replace function public.sync_profile_from_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (user_id, email, role)
  values (
    new.id,
    lower(new.email),
    new.raw_user_meta_data ->> 'role'
  )
  on conflict (user_id) do update
    set email = excluded.email,
        role = excluded.role;
  return new;
end;
$$;

drop trigger if exists sync_profile_from_auth_user on auth.users;
create trigger sync_profile_from_auth_user
after insert or update of email on auth.users
for each row execute function public.sync_profile_from_auth_user();

insert into public.profiles (user_id, email, role)
select
  id,
  lower(email),
  case
    when lower(email) ~ '^(23bcs|24bcs|25bcs)[0-9]{3}@iiitdwd[.]ac[.]in$'
      then 'student'
    else 'teacher'
  end
from auth.users
where lower(email) ~ '^(23bcs|24bcs|25bcs)[0-9]{3}@iiitdwd[.]ac[.]in$'
   or lower(email) ~ '^[a-z][a-z0-9._-]*@iiitdwd[.]ac[.]in$'
on conflict (user_id) do update
  set email = excluded.email,
      role = excluded.role;

create or replace function public.current_app_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select p.role
  from public.profiles as p
  where p.user_id = (select auth.uid())
  limit 1;
$$;

create table if not exists public.attendance_sessions (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.profiles(user_id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 120),
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at),
  check (ends_at <= starts_at + interval '1 minute')
);

alter table public.attendance_sessions
  add column if not exists session_code text,
  add column if not exists is_active boolean not null default false,
  add column if not exists current_qr_hash text,
  add column if not exists current_qr_expires_at timestamptz;

create unique index if not exists attendance_sessions_session_code_key
  on public.attendance_sessions (session_code);

create table if not exists public.attendance_records (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.attendance_sessions(id) on delete cascade,
  student_id uuid not null references public.profiles(user_id) on delete cascade,
  student_email text not null,
  marked_at timestamptz not null default now(),
  unique (session_id, student_id)
);

alter table public.attendance_records
  add column if not exists student_email text,
  add column if not exists status text not null default 'present'
  check (status in ('present', 'absent', 'leave'));

alter table public.attendance_records replica identity full;

create unique index if not exists attendance_records_session_student_key
  on public.attendance_records (session_id, student_id);

alter table public.profiles enable row level security;
alter table public.attendance_sessions enable row level security;
alter table public.attendance_records enable row level security;

drop policy if exists "Read own profile" on public.profiles;
drop policy if exists "Teachers read student profiles" on public.profiles;
create policy "Teachers read student profiles"
on public.profiles for select to authenticated
using (
  user_id = (select auth.uid())
  or (public.current_app_role() = 'teacher' and role = 'student')
);

drop policy if exists "Read own or active attendance sessions" on public.attendance_sessions;
drop policy if exists "Teachers create their own sessions" on public.attendance_sessions;
drop policy if exists "Teachers update their own sessions" on public.attendance_sessions;
drop policy if exists "Teachers read their own sessions" on public.attendance_sessions;
create policy "Teachers read their own sessions"
on public.attendance_sessions for select to authenticated
using (
  teacher_id = (select auth.uid())
  and public.current_app_role() = 'teacher'
);

drop policy if exists "Students view conducted attendance sessions" on public.attendance_sessions;
create policy "Students view conducted attendance sessions"
on public.attendance_sessions for select to authenticated
using (
  public.current_app_role() = 'student'
  and starts_at <= now()
);

drop policy if exists "Read own attendance or records for own sessions" on public.attendance_records;
drop policy if exists "Teachers record attendance for their active sessions" on public.attendance_records;
drop policy if exists "Read own attendance or records for owned sessions" on public.attendance_records;
create policy "Read own attendance or records for owned sessions"
on public.attendance_records for select to authenticated
using (
  (student_id = (select auth.uid()) and public.current_app_role() = 'student')
  or exists (
    select 1
    from public.attendance_sessions as s
    where s.id = session_id
      and s.teacher_id = (select auth.uid())
      and public.current_app_role() = 'teacher'
  )
);

revoke insert, update, delete on public.attendance_sessions from anon, authenticated;
revoke insert, update, delete on public.attendance_records from anon, authenticated;
grant select on public.profiles to authenticated;
grant select on public.attendance_sessions to authenticated;
grant select on public.attendance_records to authenticated;

create or replace function public.create_attendance_session(
  p_title text,
  p_initial_qr_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  generated_code text;
  created_session public.attendance_sessions%rowtype;
  attempt integer;
begin
  if (select auth.uid()) is null
     or public.current_app_role() is distinct from 'teacher' then
    raise exception 'Only an authenticated teacher can create an attendance session.';
  end if;
  if p_title is null or char_length(trim(p_title)) not between 1 and 120 then
    raise exception 'Enter a session name between 1 and 120 characters.';
  end if;
  if p_initial_qr_code is null or p_initial_qr_code !~ '^[0-9]{6}$' then
    raise exception 'The initial QR code must contain six digits.';
  end if;

  for attempt in 1..25 loop
    generated_code := (100000 + floor(random() * 900000)::integer)::text;
    insert into public.attendance_sessions (
      teacher_id,
      title,
      session_code,
      starts_at,
      ends_at,
      is_active,
      current_qr_hash,
      current_qr_expires_at
    ) values (
      (select auth.uid()),
      trim(p_title),
      generated_code,
      now(),
      now() + interval '1 minute',
      true,
      encode(extensions.digest(p_initial_qr_code, 'sha256'), 'hex'),
      now() + interval '10 seconds'
    )
    on conflict (session_code) do nothing
    returning * into created_session;

    if found then
      return jsonb_build_object(
        'id', created_session.id,
        'session_code', created_session.session_code,
        'title', created_session.title,
        'starts_at', created_session.starts_at,
        'ends_at', created_session.ends_at
      );
    end if;
  end loop;

  raise exception 'Could not allocate a unique six-digit session ID. Please retry.';
end;
$$;

create or replace function public.lookup_active_attendance_session(
  p_session_code text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  session_info jsonb;
begin
  if (select auth.uid()) is null
     or public.current_app_role() is distinct from 'student' then
    raise exception 'Only an authenticated student can discover attendance sessions.';
  end if;

  select jsonb_build_object(
    'id', s.id,
    'session_code', s.session_code,
    'title', s.title,
    'teacher_id', s.teacher_id,
    'starts_at', s.starts_at,
    'ends_at', s.ends_at
  )
  into session_info
  from public.attendance_sessions as s
  where s.session_code = p_session_code
    and s.is_active
    and s.starts_at <= now()
    and s.ends_at > now()
  limit 1;

  return session_info;
end;
$$;

create or replace function public.rotate_attendance_qr(
  p_session_id uuid,
  p_qr_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_end timestamptz;
begin
  if (select auth.uid()) is null
     or public.current_app_role() is distinct from 'teacher' then
    raise exception 'Only an authenticated teacher can rotate a session QR code.';
  end if;
  if p_qr_code is null or p_qr_code !~ '^[0-9]{6}$' then
    raise exception 'A QR code must contain six digits.';
  end if;

  select s.ends_at into session_end
  from public.attendance_sessions as s
  where s.id = p_session_id
    and s.teacher_id = (select auth.uid())
    and s.is_active
  for update;

  if not found or session_end <= now() then
    raise exception 'This attendance session is no longer active.';
  end if;

  update public.attendance_sessions
  set current_qr_hash = encode(extensions.digest(p_qr_code, 'sha256'), 'hex'),
      current_qr_expires_at = least(now() + interval '10 seconds', session_end)
  where id = p_session_id;

  return jsonb_build_object(
    'ok', true,
    'expires_at', least(now() + interval '10 seconds', session_end)
  );
end;
$$;

create or replace function public.stop_attendance_session(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  stopped boolean;
begin
  if (select auth.uid()) is null
     or public.current_app_role() is distinct from 'teacher' then
    raise exception 'Only an authenticated teacher can stop an attendance session.';
  end if;

  update public.attendance_sessions
  set is_active = false,
      current_qr_hash = null,
      current_qr_expires_at = null
  where id = p_session_id
    and teacher_id = (select auth.uid());
  stopped := found;

  return jsonb_build_object('ok', stopped);
end;
$$;

create or replace function public.mark_attendance(
  p_session_id uuid,
  p_session_code text,
  p_method text,
  p_qr_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  active_session public.attendance_sessions%rowtype;
  student_email text;
  inserted_record uuid;
begin
  if (select auth.uid()) is null
     or public.current_app_role() is distinct from 'student' then
    return jsonb_build_object(
      'ok', false,
      'code', 'student_only',
      'message', 'Sign in with a student account to mark attendance.'
    );
  end if;

  if p_method is null or p_method not in ('qr', 'session_id') then
    return jsonb_build_object(
      'ok', false,
      'code', 'invalid_method',
      'message', 'Choose QR scanning or session ID entry.'
    );
  end if;

  select s.* into active_session
  from public.attendance_sessions as s
  where s.id = p_session_id
  for update;

  if not found
     or p_session_code is null
     or active_session.session_code <> p_session_code then
    return jsonb_build_object(
      'ok', false,
      'code', 'invalid_session_id',
      'message', 'The session ID does not match the selected BLE session.'
    );
  end if;

  if not active_session.is_active
     or active_session.starts_at > now()
     or active_session.ends_at <= now() then
    return jsonb_build_object(
      'ok', false,
      'code', 'session_ended',
      'message', 'This attendance session has ended.'
    );
  end if;

  if p_method = 'session_id' then
    if p_session_code !~ '^[0-9]{6}$' then
      return jsonb_build_object(
        'ok', false,
        'code', 'invalid_session_id',
        'message', 'Enter the six-digit ID for the selected session.'
      );
    end if;
  else
    if p_qr_code is null or p_qr_code !~ '^[0-9]{6}$' then
      return jsonb_build_object(
        'ok', false,
        'code', 'invalid_qr',
        'message', 'Scan the current six-digit QR code and try again.'
      );
    end if;
    if active_session.current_qr_expires_at is null
       or active_session.current_qr_expires_at <= now()
       or active_session.current_qr_hash is null
       or active_session.current_qr_hash <>
          encode(extensions.digest(p_qr_code, 'sha256'), 'hex') then
      return jsonb_build_object(
        'ok', false,
        'code', 'invalid_qr',
        'message', 'The QR code is incorrect or has expired. Scan the current code.'
      );
    end if;
  end if;

  select p.email into student_email
  from public.profiles as p
  where p.user_id = (select auth.uid())
    and p.role = 'student';

  if student_email is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'student_profile_missing',
      'message', 'The student profile could not be verified.'
    );
  end if;

  insert into public.attendance_records (
    session_id,
    student_id,
    student_email,
    marked_at
  ) values (
    active_session.id,
    (select auth.uid()),
    student_email,
    now()
  )
  on conflict (session_id, student_id) do nothing
  returning id into inserted_record;

  if inserted_record is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'already_marked',
      'message', 'Attendance is already marked for this session.'
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'present',
    'message', 'Attendance marked successfully.',
    'session_name', active_session.title,
    'student_email', student_email,
    'status', 'Present',
    'marked_at', now()
  );
end;
$$;

revoke all on function public.current_app_role() from public, anon;
revoke all on function public.create_attendance_session(text, text) from public, anon;
revoke all on function public.lookup_active_attendance_session(text) from public, anon;
revoke all on function public.rotate_attendance_qr(uuid, text) from public, anon;
revoke all on function public.stop_attendance_session(uuid) from public, anon;
revoke all on function public.mark_attendance(uuid, text, text, text) from public, anon;
grant execute on function public.current_app_role() to authenticated;
grant execute on function public.create_attendance_session(text, text) to authenticated;
grant execute on function public.lookup_active_attendance_session(text) to authenticated;
grant execute on function public.rotate_attendance_qr(uuid, text) to authenticated;
grant execute on function public.stop_attendance_session(uuid) to authenticated;
grant execute on function public.mark_attendance(uuid, text, text, text) to authenticated;

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

revoke all on function public.teacher_mark_attendance(uuid, uuid, text) from public, anon;
revoke all on function public.get_teacher_session_roster(uuid) from public, anon;
grant execute on function public.teacher_mark_attendance(uuid, uuid, text) to authenticated;
grant execute on function public.get_teacher_session_roster(uuid) to authenticated;

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

-- Refresh PostgREST's function and table metadata for RPC calls immediately.
notify pgrst, 'reload schema';
