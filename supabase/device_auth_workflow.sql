-- ==============================================================================
-- Device-Bound Cryptographic Authentication Schema & Policies
-- Run this in the Supabase SQL Editor to support Android Keystore device binding.
-- ==============================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------------------------
-- 1. Student Devices: Tracks registered hardware keys per student
-- ------------------------------------------------------------------------------
create table if not exists public.student_devices (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(user_id) on delete cascade,
  device_id text not null,
  device_name text,
  public_key_spki text not null,
  algorithm text not null default 'ES256',
  status text not null check (status in ('active', 'revoked', 'pending_recovery')) default 'active',
  registered_at timestamptz not null default now(),
  revoked_at timestamptz,
  last_authenticated_at timestamptz,
  created_at timestamptz not null default now()
);

-- Exactly ONE active device per student at any given time (enforced atomically)
create unique index if not exists student_devices_single_active_idx
  on public.student_devices (student_id)
  where (status = 'active');

create unique index if not exists student_devices_student_device_unique_idx
  on public.student_devices (student_id, device_id);

-- ------------------------------------------------------------------------------
-- 2. Auth Challenges: Short-lived, unpredictable, single-use challenges
-- ------------------------------------------------------------------------------
create table if not exists public.auth_challenges (
  id uuid primary key default gen_random_uuid(),
  challenge_nonce text not null unique,
  challenge_payload text not null,
  student_id uuid not null references public.profiles(user_id) on delete cascade,
  device_id text not null,
  purpose text not null check (purpose in ('unlock', 'attendance')),
  session_id uuid references public.attendance_sessions(id) on delete cascade,
  qr_code_hash text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz
);

create index if not exists auth_challenges_lookup_idx
  on public.auth_challenges (challenge_payload, student_id, device_id);

-- ------------------------------------------------------------------------------
-- 3. Device Recovery Requests: Audited device replacement workflow
-- ------------------------------------------------------------------------------
create table if not exists public.device_recovery_requests (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(user_id) on delete cascade,
  old_device_id text,
  new_device_id text not null,
  new_public_key_spki text not null,
  reason text not null check (char_length(trim(reason)) between 5 and 500),
  status text not null check (status in ('pending', 'approved', 'rejected')) default 'pending',
  requested_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.profiles(user_id)
);

-- ------------------------------------------------------------------------------
-- 4. Audit Auth Logs: Comprehensive forensic records of auth attempts
-- ------------------------------------------------------------------------------
create table if not exists public.auth_audit_logs (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  student_id uuid references public.profiles(user_id) on delete set null,
  device_id text,
  session_id uuid references public.attendance_sessions(id) on delete set null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------------------------
-- 5. Row Level Security (RLS) Policies
-- ------------------------------------------------------------------------------
alter table public.student_devices enable row level security;
alter table public.auth_challenges enable row level security;
alter table public.device_recovery_requests enable row level security;
alter table public.auth_audit_logs enable row level security;

-- Student Devices Policies
drop policy if exists "Students read own device registrations" on public.student_devices;
create policy "Students read own device registrations"
  on public.student_devices for select to authenticated
  using (student_id = (select auth.uid()));

-- Teachers can view registered student devices for attendance verification
drop policy if exists "Teachers view student devices" on public.student_devices;
create policy "Teachers view student devices"
  on public.student_devices for select to authenticated
  using (public.current_app_role() = 'teacher');

-- Revoke direct mutation permissions on student_devices from client roles
revoke insert, update, delete on public.student_devices from anon, authenticated;
grant select on public.student_devices to authenticated;

-- Auth Challenges Policies: Revoke all client direct access
revoke all on public.auth_challenges from anon, authenticated;

-- Device Recovery Policies
drop policy if exists "Students read own recovery requests" on public.device_recovery_requests;
create policy "Students read own recovery requests"
  on public.device_recovery_requests for select to authenticated
  using (student_id = (select auth.uid()));

drop policy if exists "Students insert recovery requests" on public.device_recovery_requests;
create policy "Students insert recovery requests"
  on public.device_recovery_requests for insert to authenticated
  with check (
    student_id = (select auth.uid())
    and public.current_app_role() = 'student'
  );

drop policy if exists "Teachers read and review recovery requests" on public.device_recovery_requests;
create policy "Teachers read and review recovery requests"
  on public.device_recovery_requests for select to authenticated
  using (public.current_app_role() = 'teacher');

revoke update, delete on public.device_recovery_requests from anon, authenticated;
grant select, insert on public.device_recovery_requests to authenticated;

-- Audit Logs Policies
drop policy if exists "Students read own audit logs" on public.auth_audit_logs;
create policy "Students read own audit logs"
  on public.auth_audit_logs for select to authenticated
  using (student_id = (select auth.uid()));

drop policy if exists "Teachers read audit logs" on public.auth_audit_logs;
create policy "Teachers read audit logs"
  on public.auth_audit_logs for select to authenticated
  using (public.current_app_role() = 'teacher');

revoke insert, update, delete on public.auth_audit_logs from anon, authenticated;
grant select on public.auth_audit_logs to authenticated;

-- ------------------------------------------------------------------------------
-- 6. Helper RPC Functions
-- ------------------------------------------------------------------------------

-- Approves a device recovery request (Teachers only)
create or replace function public.approve_device_recovery(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  req public.device_recovery_requests%rowtype;
begin
  if (select auth.uid()) is null or public.current_app_role() is distinct from 'teacher' then
    raise exception 'Only an authenticated teacher can approve device recovery requests.';
  end if;

  select * into req
  from public.device_recovery_requests
  where id = p_request_id and status = 'pending'
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'Pending recovery request not found.');
  end if;

  -- 1. Revoke existing active devices for this student
  update public.student_devices
  set status = 'revoked', revoked_at = now()
  where student_id = req.student_id and status = 'active';

  -- 2. Insert new device as active
  insert into public.student_devices (
    student_id,
    device_id,
    public_key_spki,
    status,
    registered_at
  ) values (
    req.student_id,
    req.new_device_id,
    req.new_public_key_spki,
    'active',
    now()
  );

  -- 3. Mark request as approved
  update public.device_recovery_requests
  set status = 'approved',
      resolved_at = now(),
      resolved_by = (select auth.uid())
  where id = p_request_id;

  -- 4. Audit log
  insert into public.auth_audit_logs (event_type, student_id, device_id, details)
  values (
    'device_recovery_approved',
    req.student_id,
    req.new_device_id,
    jsonb_build_object('request_id', req.id, 'approved_by', (select auth.uid()))
  );

  return jsonb_build_object('ok', true, 'message', 'Device recovery approved successfully.');
end;
$$;

revoke all on function public.approve_device_recovery(uuid) from public, anon;
grant execute on function public.approve_device_recovery(uuid) to authenticated;

notify pgrst, 'reload schema';
