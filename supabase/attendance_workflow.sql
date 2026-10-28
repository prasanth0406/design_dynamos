-- Attendance workflow upgrade for the existing Supabase Auth project.
-- Run this in the Supabase SQL Editor, then run supabase/device_security.sql.

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
before insert or update of email, raw_user_meta_data on auth.users
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
  add column if not exists current_qr_expires_at timestamptz,
  add column if not exists current_ble_hash text,
  add column if not exists current_ble_expires_at timestamptz,
  add column if not exists previous_qr_hash text,
  add column if not exists previous_ble_hash text,
  add column if not exists previous_codes_expire_at timestamptz;

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
  add column if not exists student_email text;

create unique index if not exists attendance_records_session_student_key
  on public.attendance_records (session_id, student_id);

alter table public.profiles enable row level security;
alter table public.attendance_sessions enable row level security;
alter table public.attendance_records enable row level security;

drop policy if exists "Read own profile" on public.profiles;
create policy "Read own profile"
on public.profiles for select to authenticated
using (user_id = (select auth.uid()));

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

revoke all on public.profiles from anon, authenticated;
revoke all on public.attendance_sessions from anon, authenticated;
revoke all on public.attendance_records from anon, authenticated;
grant select on public.profiles to authenticated;
grant select on public.attendance_sessions to authenticated;
grant select on public.attendance_records to authenticated;

-- Teacher-generated rotating codes. The QR code (six digits) is shown on the
-- teacher's screen; the BLE token (12 hex chars = 6 random bytes) is broadcast
-- only in the teacher's BLE advertisement. Both rotate every 10 seconds and the
-- previous pair stays valid for a short grace period to absorb scan latency.
drop function if exists public.create_attendance_session(text, text);
create or replace function public.create_attendance_session(
  p_title text,
  p_initial_qr_code text,
  p_initial_ble_token text
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
  if p_initial_ble_token is null or p_initial_ble_token !~ '^[0-9a-f]{12}$' then
    raise exception 'The initial BLE token must contain 12 lowercase hex characters.';
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
      current_qr_expires_at,
      current_ble_hash,
      current_ble_expires_at,
      previous_qr_hash,
      previous_ble_hash,
      previous_codes_expire_at
    ) values (
      (select auth.uid()),
      trim(p_title),
      generated_code,
      now(),
      now() + interval '1 minute',
      true,
      encode(extensions.digest(p_initial_qr_code, 'sha256'), 'hex'),
      now() + interval '10 seconds',
      encode(extensions.digest(p_initial_ble_token, 'sha256'), 'hex'),
      now() + interval '10 seconds',
      null,
      null,
      null
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

drop function if exists public.rotate_attendance_qr(uuid, text);
create or replace function public.rotate_attendance_qr(
  p_session_id uuid,
  p_qr_code text,
  p_ble_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_end timestamptz;
  new_expiry timestamptz;
begin
  if (select auth.uid()) is null
     or public.current_app_role() is distinct from 'teacher' then
    raise exception 'Only an authenticated teacher can rotate a session QR code.';
  end if;
  if p_qr_code is null or p_qr_code !~ '^[0-9]{6}$' then
    raise exception 'A QR code must contain six digits.';
  end if;
  if p_ble_token is null or p_ble_token !~ '^[0-9a-f]{12}$' then
    raise exception 'A BLE token must contain 12 lowercase hex characters.';
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

  new_expiry := least(now() + interval '10 seconds', session_end);

  update public.attendance_sessions
  set previous_qr_hash = current_qr_hash,
      previous_ble_hash = current_ble_hash,
      previous_codes_expire_at = least(now() + interval '4 seconds', session_end),
      current_qr_hash = encode(extensions.digest(p_qr_code, 'sha256'), 'hex'),
      current_qr_expires_at = new_expiry,
      current_ble_hash = encode(extensions.digest(p_ble_token, 'sha256'), 'hex'),
      current_ble_expires_at = new_expiry
  where id = p_session_id;

  return jsonb_build_object('ok', true, 'expires_at', new_expiry);
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
      current_qr_expires_at = null,
      current_ble_hash = null,
      current_ble_expires_at = null,
      previous_qr_hash = null,
      previous_ble_hash = null,
      previous_codes_expire_at = null
  where id = p_session_id
    and teacher_id = (select auth.uid());
  stopped := found;

  return jsonb_build_object('ok', stopped);
end;
$$;

-- The old client-callable mark_attendance RPC let any signed-in student mark
-- attendance directly through PostgREST, bypassing BLE, biometrics and device
-- binding. Attendance is now recorded only by the device-attendance Edge
-- Function after server-side signature verification (see device_security.sql).
drop function if exists public.mark_attendance(uuid, text, text, text);

revoke all on function public.current_app_role() from public, anon;
revoke all on function public.create_attendance_session(text, text, text) from public, anon;
revoke all on function public.lookup_active_attendance_session(text) from public, anon;
revoke all on function public.rotate_attendance_qr(uuid, text, text) from public, anon;
revoke all on function public.stop_attendance_session(uuid) from public, anon;
grant execute on function public.current_app_role() to authenticated;
grant execute on function public.create_attendance_session(text, text, text) to authenticated;
grant execute on function public.lookup_active_attendance_session(text) to authenticated;
grant execute on function public.rotate_attendance_qr(uuid, text, text) to authenticated;
grant execute on function public.stop_attendance_session(uuid) to authenticated;

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
