-- Device-bound cryptographic authentication for SDTT BLE Attendance.
-- Run after supabase/attendance_workflow.sql in the Supabase SQL Editor.
--
-- Model:
--   * Each student has at most one ACTIVE device: an Android Keystore P-256
--     public key whose private key never leaves the phone and needs strong
--     biometric authentication for every signature.
--   * The first device a student registers becomes active automatically.
--     Any later key (new phone, reinstall, biometric enrollment change) is
--     stored as PENDING and must be approved by a device admin, which revokes
--     the previous key atomically.
--   * Challenges are random, single-use, short-lived and bound to the student,
--     device, purpose and attendance session. Signatures are verified by the
--     device-attendance Edge Function; only that function (service_role) can
--     call the sdtt_* functions below.
--   * Flutter clients can only READ their own device rows and events. They
--     cannot insert, update or delete any of these tables.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.device_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  note text,
  added_at timestamptz not null default now()
);

create table if not exists public.student_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  public_key_spki text not null,
  public_key_sha256 text not null unique,
  key_algorithm text not null default 'ES256' check (key_algorithm = 'ES256'),
  status text not null
    check (status in ('active', 'pending', 'revoked', 'rejected', 'superseded')),
  request_reason text,
  attestation_chain jsonb not null default '[]'::jsonb,
  attestation_summary jsonb not null default '{}'::jsonb,
  -- Device model, SDK level, StrongBox flag etc. Informational only: these are
  -- reported by the client and are never used for authorization.
  client_reported jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  activated_at timestamptz,
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null,
  decision_note text,
  revoked_at timestamptz,
  revoked_reason text,
  replaced_device_id uuid references public.student_devices(id) on delete set null
);

create unique index if not exists student_devices_one_active_per_user
  on public.student_devices (user_id) where status = 'active';
create unique index if not exists student_devices_one_pending_per_user
  on public.student_devices (user_id) where status = 'pending';
create index if not exists student_devices_user_idx
  on public.student_devices (user_id, created_at desc);

create table if not exists public.device_auth_challenges (
  id uuid primary key,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  device_id uuid references public.student_devices(id) on delete cascade,
  purpose text not null
    check (purpose in ('register_device', 'app_unlock', 'mark_attendance')),
  session_id uuid references public.attendance_sessions(id) on delete cascade,
  nonce text not null,
  signing_payload text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  outcome text,
  check (expires_at > created_at),
  check ((purpose = 'register_device') = (device_id is null)),
  check ((purpose = 'mark_attendance') = (session_id is not null))
);

create index if not exists device_auth_challenges_user_created_idx
  on public.device_auth_challenges (user_id, created_at desc);

create table if not exists public.device_auth_events (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles(user_id) on delete cascade,
  device_id uuid references public.student_devices(id) on delete set null,
  challenge_id uuid,
  session_id uuid references public.attendance_sessions(id) on delete set null,
  purpose text,
  outcome text not null,
  detail text,
  created_at timestamptz not null default now()
);

create index if not exists device_auth_events_user_idx
  on public.device_auth_events (user_id, created_at desc);

create table if not exists public.device_audit_log (
  id bigint generated always as identity primary key,
  device_id uuid references public.student_devices(id) on delete set null,
  user_id uuid references public.profiles(user_id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  actor_label text not null,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.attendance_records
  add column if not exists device_id uuid
    references public.student_devices(id) on delete set null,
  add column if not exists challenge_id uuid;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function public.is_device_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.device_admins as a
    where a.user_id = (select auth.uid())
  );
$$;

-- Returns the acting admin's user id, or null when called from the Supabase
-- SQL Editor (session user postgres, no JWT). Raises for everyone else.
create or replace function public.sdtt_require_device_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is not null then
    if public.is_device_admin() then
      return (select auth.uid());
    end if;
  elsif session_user in ('postgres', 'supabase_admin') then
    return null;
  end if;
  raise exception 'Only a device administrator can manage student devices.'
    using errcode = '42501';
end;
$$;

create or replace function public.sdtt_iso(ts timestamptz)
returns text
language sql
immutable
set search_path = ''
as $$
  select to_char(ts at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
$$;

create or replace function public.sdtt_log_event(
  p_user_id uuid,
  p_device_id uuid,
  p_challenge_id uuid,
  p_session_id uuid,
  p_purpose text,
  p_outcome text,
  p_detail text default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.device_auth_events (
    user_id, device_id, challenge_id, session_id, purpose, outcome, detail
  ) values (
    p_user_id, p_device_id, p_challenge_id, p_session_id, p_purpose, p_outcome,
    left(p_detail, 500)
  );
$$;

create or replace function public.sdtt_error(p_code text, p_message text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('ok', false, 'code', p_code, 'message', p_message);
$$;

-- Maps a device row status to the error a client should see.
create or replace function public.sdtt_device_error(p_status text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case p_status
    when 'pending' then public.sdtt_error(
      'device_pending_approval',
      'This phone is waiting for administrator approval before it can be used.')
    when 'revoked' then public.sdtt_error(
      'device_revoked',
      'This phone''s attendance key has been revoked. Request device re-registration.')
    when 'rejected' then public.sdtt_error(
      'device_rejected',
      'The registration request for this phone was rejected. Contact your administrator.')
    else public.sdtt_error(
      'device_not_registered',
      'This phone is not the registered attendance device for your account.')
  end;
$$;

-- ---------------------------------------------------------------------------
-- Service-role API used by the device-attendance Edge Function
-- ---------------------------------------------------------------------------

create or replace function public.sdtt_issue_challenge(
  p_user_id uuid,
  p_purpose text,
  p_device_id uuid default null,
  p_session_id uuid default null,
  p_session_code text default null,
  p_qr_code text default null,
  p_ble_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_id uuid := gen_random_uuid();
  v_nonce text := encode(extensions.gen_random_bytes(32), 'base64');
  v_expires timestamptz;
  v_role text;
  v_device public.student_devices%rowtype;
  v_session public.attendance_sessions%rowtype;
  v_qr_hash text;
  v_ble_hash text;
  v_recent integer;
  v_payload text;
begin
  select p.role into v_role from public.profiles as p where p.user_id = p_user_id;
  if v_role is distinct from 'student' then
    return public.sdtt_error('student_only',
      'Only student accounts use device-bound attendance keys.');
  end if;

  if p_purpose is null
     or p_purpose not in ('register_device', 'app_unlock', 'mark_attendance') then
    return public.sdtt_error('invalid_purpose', 'Unknown authentication purpose.');
  end if;

  select count(*) into v_recent
  from public.device_auth_challenges as c
  where c.user_id = p_user_id
    and c.created_at > v_now - interval '1 minute';
  if v_recent >= 12 then
    perform public.sdtt_log_event(p_user_id, p_device_id, null, p_session_id,
      p_purpose, 'rate_limited');
    return public.sdtt_error('rate_limited',
      'Too many authentication attempts. Wait a minute and try again.');
  end if;

  if p_purpose = 'register_device' then
    if p_device_id is not null or p_session_id is not null then
      return public.sdtt_error('invalid_request',
        'Registration challenges are not bound to a device or session.');
    end if;
    v_expires := v_now + interval '2 minutes';
  else
    if p_device_id is null then
      return public.sdtt_device_error(null);
    end if;
    select d.* into v_device
    from public.student_devices as d
    where d.id = p_device_id and d.user_id = p_user_id;
    if not found or v_device.status <> 'active' then
      perform public.sdtt_log_event(p_user_id,
        case when found then p_device_id end, null, p_session_id, p_purpose,
        'device_not_active', coalesce(v_device.status, 'unknown_device'));
      return public.sdtt_device_error(v_device.status);
    end if;
    v_expires := v_now + interval '60 seconds';
  end if;

  if p_purpose = 'mark_attendance' then
    select s.* into v_session
    from public.attendance_sessions as s
    where s.id = p_session_id;

    if not found or p_session_code is null
       or v_session.session_code is distinct from p_session_code then
      perform public.sdtt_log_event(p_user_id, p_device_id, null, null,
        p_purpose, 'invalid_session');
      return public.sdtt_error('invalid_session_id',
        'The session does not match the BLE session you selected.');
    end if;

    if not v_session.is_active
       or v_session.starts_at > v_now
       or v_session.ends_at <= v_now then
      return public.sdtt_error('session_ended', 'This attendance session has ended.');
    end if;

    if exists (
      select 1 from public.attendance_records as r
      where r.session_id = v_session.id and r.student_id = p_user_id
    ) then
      return public.sdtt_error('already_marked',
        'Attendance is already marked for this session.');
    end if;

    if p_qr_code is null or p_qr_code !~ '^[0-9]{6}$' then
      return public.sdtt_error('invalid_qr',
        'Scan the current six-digit QR code and try again.');
    end if;
    v_qr_hash := encode(extensions.digest(p_qr_code, 'sha256'), 'hex');
    -- coalesce: NULL previous-code columns must count as "no match".
    if not coalesce(
      (v_session.current_qr_hash = v_qr_hash
        and v_session.current_qr_expires_at > v_now)
      or (v_session.previous_qr_hash = v_qr_hash
        and v_session.previous_codes_expire_at > v_now),
      false
    ) then
      perform public.sdtt_log_event(p_user_id, p_device_id, null, v_session.id,
        p_purpose, 'invalid_qr');
      return public.sdtt_error('invalid_qr',
        'The QR code is incorrect or has expired. Scan the current code.');
    end if;

    if p_ble_token is null or p_ble_token !~ '^[0-9a-f]{12}$' then
      perform public.sdtt_log_event(p_user_id, p_device_id, null, v_session.id,
        p_purpose, 'invalid_ble');
      return public.sdtt_error('invalid_ble',
        'No current BLE signal from the teacher''s phone. Stay near the teacher and keep Bluetooth on.');
    end if;
    v_ble_hash := encode(extensions.digest(p_ble_token, 'sha256'), 'hex');
    -- coalesce: NULL previous-code columns must count as "no match".
    if not coalesce(
      (v_session.current_ble_hash = v_ble_hash
        and v_session.current_ble_expires_at > v_now)
      or (v_session.previous_ble_hash = v_ble_hash
        and v_session.previous_codes_expire_at > v_now),
      false
    ) then
      perform public.sdtt_log_event(p_user_id, p_device_id, null, v_session.id,
        p_purpose, 'invalid_ble');
      return public.sdtt_error('invalid_ble',
        'The BLE signal is out of date. Stay near the teacher''s phone and try again.');
    end if;

    v_expires := least(v_expires, v_session.ends_at);
  elsif p_session_id is not null then
    return public.sdtt_error('invalid_request',
      'Only attendance challenges are bound to a session.');
  end if;

  v_payload := concat_ws(E'\n',
    'sdtt-device-auth-v1',
    'purpose=' || p_purpose,
    'challenge_id=' || v_id::text,
    'nonce=' || v_nonce,
    'user_id=' || p_user_id::text,
    'device_id=' || coalesce(p_device_id::text, '-'),
    'session_id=' || coalesce(v_session.id::text, '-'),
    'issued_at=' || public.sdtt_iso(v_now),
    'expires_at=' || public.sdtt_iso(v_expires)
  );

  insert into public.device_auth_challenges (
    id, user_id, device_id, purpose, session_id, nonce, signing_payload,
    created_at, expires_at
  ) values (
    v_id, p_user_id, p_device_id, p_purpose, v_session.id, v_nonce, v_payload,
    v_now, v_expires
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'challenge_issued',
    'challenge_id', v_id,
    'nonce', v_nonce,
    'signing_payload', v_payload,
    'expires_at', v_expires
  );
end;
$$;

-- Returns what the Edge Function needs to verify a signature. Never consumes.
create or replace function public.sdtt_get_challenge(
  p_user_id uuid,
  p_challenge_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_challenge public.device_auth_challenges%rowtype;
  v_key text;
begin
  select c.* into v_challenge
  from public.device_auth_challenges as c
  where c.id = p_challenge_id and c.user_id = p_user_id;
  if not found then
    return public.sdtt_error('challenge_not_found',
      'The authentication challenge was not found. Request a new one.');
  end if;

  if v_challenge.device_id is not null then
    select d.public_key_spki into v_key
    from public.student_devices as d
    where d.id = v_challenge.device_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'purpose', v_challenge.purpose,
    'nonce', v_challenge.nonce,
    'signing_payload', v_challenge.signing_payload,
    'device_id', v_challenge.device_id,
    'public_key_spki', v_key
  );
end;
$$;

-- Atomically consumes a challenge and performs its operation. The Edge
-- Function reports whether the ECDSA signature verified; everything else
-- (expiry, single use, device status, session state, duplicates) is enforced
-- here under a row lock so concurrent submissions cannot double-spend.
create or replace function public.sdtt_complete_challenge(
  p_user_id uuid,
  p_challenge_id uuid,
  p_signature_valid boolean,
  p_failure_detail text default null,
  p_registration jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_challenge public.device_auth_challenges%rowtype;
  v_device public.student_devices%rowtype;
  v_existing public.student_devices%rowtype;
  v_active public.student_devices%rowtype;
  v_session public.attendance_sessions%rowtype;
  v_email text;
  v_record uuid;
  v_spki text;
  v_key_hash text;
  v_new_id uuid;
begin
  select c.* into v_challenge
  from public.device_auth_challenges as c
  where c.id = p_challenge_id and c.user_id = p_user_id
  for update;

  if not found then
    perform public.sdtt_log_event(p_user_id, null, p_challenge_id, null, null,
      'challenge_not_found');
    return public.sdtt_error('challenge_not_found',
      'The authentication challenge was not found. Request a new one.');
  end if;

  if v_challenge.consumed_at is not null then
    perform public.sdtt_log_event(p_user_id, v_challenge.device_id, v_challenge.id,
      v_challenge.session_id, v_challenge.purpose, 'challenge_replayed');
    return public.sdtt_error('challenge_already_used',
      'This authentication challenge was already used. Request a new one.');
  end if;

  if v_challenge.expires_at <= v_now then
    update public.device_auth_challenges
    set consumed_at = v_now, outcome = 'expired'
    where id = v_challenge.id;
    perform public.sdtt_log_event(p_user_id, v_challenge.device_id, v_challenge.id,
      v_challenge.session_id, v_challenge.purpose, 'challenge_expired');
    return public.sdtt_error('challenge_expired',
      'The authentication challenge expired. Try again.');
  end if;

  -- Single attempt per challenge, whatever the outcome.
  update public.device_auth_challenges
  set consumed_at = v_now, outcome = 'processing'
  where id = v_challenge.id;

  if p_signature_valid is distinct from true then
    update public.device_auth_challenges set outcome = 'invalid_signature'
    where id = v_challenge.id;
    perform public.sdtt_log_event(p_user_id, v_challenge.device_id, v_challenge.id,
      v_challenge.session_id, v_challenge.purpose, 'invalid_signature',
      p_failure_detail);
    return public.sdtt_error('invalid_signature',
      'The device signature could not be verified.');
  end if;

  -- ----- Device registration ---------------------------------------------
  if v_challenge.purpose = 'register_device' then
    v_spki := p_registration ->> 'public_key_spki';
    if v_spki is null or v_spki !~ '^[A-Za-z0-9+/]+={0,2}$'
       or char_length(v_spki) > 400 then
      update public.device_auth_challenges set outcome = 'invalid_key'
      where id = v_challenge.id;
      return public.sdtt_error('invalid_public_key', 'The public key is malformed.');
    end if;
    v_key_hash := encode(extensions.digest(decode(v_spki, 'base64'), 'sha256'), 'hex');

    -- Serialize all registrations for this student.
    perform 1 from public.profiles as p where p.user_id = p_user_id for update;

    select d.* into v_existing
    from public.student_devices as d
    where d.public_key_sha256 = v_key_hash;

    if found then
      if v_existing.user_id <> p_user_id then
        update public.device_auth_challenges set outcome = 'key_in_use'
        where id = v_challenge.id;
        perform public.sdtt_log_event(p_user_id, null, v_challenge.id, null,
          v_challenge.purpose, 'key_in_use');
        return public.sdtt_error('key_in_use',
          'This key is already registered to another account.');
      end if;
      update public.device_auth_challenges set outcome = 'already_registered'
      where id = v_challenge.id;
      if v_existing.status in ('active', 'pending') then
        return jsonb_build_object(
          'ok', true,
          'code', case v_existing.status
                    when 'active' then 'device_registered'
                    else 'replacement_pending' end,
          'device_id', v_existing.id,
          'status', v_existing.status,
          'message', case v_existing.status
                    when 'active' then 'This phone is your registered attendance device.'
                    else 'This phone is waiting for administrator approval.' end
        );
      end if;
      return public.sdtt_error('key_retired',
        'This key was revoked or rejected. Generate a new key and request approval.');
    end if;

    select d.* into v_active
    from public.student_devices as d
    where d.user_id = p_user_id and d.status = 'active';

    if found then
      update public.student_devices
      set status = 'superseded', decided_at = v_now,
          decision_note = 'Superseded by a newer registration request'
      where user_id = p_user_id and status = 'pending';

      insert into public.student_devices (
        user_id, public_key_spki, public_key_sha256, status, request_reason,
        attestation_chain, attestation_summary, client_reported,
        replaced_device_id
      ) values (
        p_user_id, v_spki, v_key_hash, 'pending',
        left(coalesce(p_registration ->> 'request_reason', 'new_device'), 200),
        coalesce(p_registration -> 'attestation_chain', '[]'::jsonb),
        coalesce(p_registration -> 'attestation_summary', '{}'::jsonb),
        coalesce(p_registration -> 'client_reported', '{}'::jsonb),
        v_active.id
      ) returning id into v_new_id;

      insert into public.device_audit_log (device_id, user_id, actor_id, actor_label, action, details)
      values (v_new_id, p_user_id, p_user_id, 'student', 'replacement_requested',
        jsonb_build_object('current_device_id', v_active.id,
          'reason', p_registration ->> 'request_reason'));
      update public.device_auth_challenges set outcome = 'replacement_pending'
      where id = v_challenge.id;
      perform public.sdtt_log_event(p_user_id, v_new_id, v_challenge.id, null,
        v_challenge.purpose, 'replacement_pending');

      return jsonb_build_object(
        'ok', true,
        'code', 'replacement_pending',
        'device_id', v_new_id,
        'status', 'pending',
        'message', 'Another phone is registered to this account. Your request was sent for administrator approval.'
      );
    end if;

    insert into public.student_devices (
      user_id, public_key_spki, public_key_sha256, status, request_reason,
      attestation_chain, attestation_summary, client_reported, activated_at
    ) values (
      p_user_id, v_spki, v_key_hash, 'active', 'first_device',
      coalesce(p_registration -> 'attestation_chain', '[]'::jsonb),
      coalesce(p_registration -> 'attestation_summary', '{}'::jsonb),
      coalesce(p_registration -> 'client_reported', '{}'::jsonb),
      v_now
    ) returning id into v_new_id;

    insert into public.device_audit_log (device_id, user_id, actor_id, actor_label, action)
    values (v_new_id, p_user_id, p_user_id, 'student', 'first_device_registered');
    update public.device_auth_challenges set outcome = 'device_registered'
    where id = v_challenge.id;
    perform public.sdtt_log_event(p_user_id, v_new_id, v_challenge.id, null,
      v_challenge.purpose, 'device_registered');

    return jsonb_build_object(
      'ok', true,
      'code', 'device_registered',
      'device_id', v_new_id,
      'status', 'active',
      'message', 'This phone is now your registered attendance device.'
    );
  end if;

  -- ----- Operations that require the active registered device -------------
  select d.* into v_device
  from public.student_devices as d
  where d.id = v_challenge.device_id and d.user_id = p_user_id
  for share;

  if not found or v_device.status <> 'active' then
    update public.device_auth_challenges set outcome = 'device_not_active'
    where id = v_challenge.id;
    perform public.sdtt_log_event(p_user_id, v_challenge.device_id, v_challenge.id,
      v_challenge.session_id, v_challenge.purpose, 'device_not_active',
      v_device.status);
    return public.sdtt_device_error(v_device.status);
  end if;

  if v_challenge.purpose = 'app_unlock' then
    update public.device_auth_challenges set outcome = 'ok' where id = v_challenge.id;
    perform public.sdtt_log_event(p_user_id, v_device.id, v_challenge.id, null,
      v_challenge.purpose, 'ok');
    return jsonb_build_object(
      'ok', true, 'code', 'unlocked', 'device_id', v_device.id,
      'message', 'Device verified.');
  end if;

  -- mark_attendance
  select s.* into v_session
  from public.attendance_sessions as s
  where s.id = v_challenge.session_id
  for share;

  if not found or not v_session.is_active
     or v_session.starts_at > v_now or v_session.ends_at <= v_now then
    update public.device_auth_challenges set outcome = 'session_ended'
    where id = v_challenge.id;
    return public.sdtt_error('session_ended', 'This attendance session has ended.');
  end if;

  select p.email into v_email
  from public.profiles as p
  where p.user_id = p_user_id and p.role = 'student';
  if v_email is null then
    update public.device_auth_challenges set outcome = 'student_profile_missing'
    where id = v_challenge.id;
    return public.sdtt_error('student_profile_missing',
      'The student profile could not be verified.');
  end if;

  insert into public.attendance_records (
    session_id, student_id, student_email, marked_at, device_id, challenge_id
  ) values (
    v_session.id, p_user_id, v_email, v_now, v_device.id, v_challenge.id
  )
  on conflict (session_id, student_id) do nothing
  returning id into v_record;

  if v_record is null then
    update public.device_auth_challenges set outcome = 'already_marked'
    where id = v_challenge.id;
    return public.sdtt_error('already_marked',
      'Attendance is already marked for this session.');
  end if;

  update public.device_auth_challenges set outcome = 'ok' where id = v_challenge.id;
  perform public.sdtt_log_event(p_user_id, v_device.id, v_challenge.id, v_session.id,
    v_challenge.purpose, 'ok');

  return jsonb_build_object(
    'ok', true,
    'code', 'present',
    'message', 'Attendance marked successfully.',
    'session_name', v_session.title,
    'student_email', v_email,
    'status', 'Present',
    'marked_at', v_now
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin API (device admins via RPC, or the SQL Editor)
-- ---------------------------------------------------------------------------

create or replace function public.list_device_requests()
returns table (
  device_id uuid,
  student_email text,
  status text,
  request_reason text,
  requested_at timestamptz,
  current_device_id uuid,
  current_device_since timestamptz,
  attestation_summary jsonb,
  client_reported jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.sdtt_require_device_admin();
  return query
  select d.id, p.email, d.status, d.request_reason, d.created_at,
         a.id, a.activated_at, d.attestation_summary, d.client_reported
  from public.student_devices as d
  join public.profiles as p on p.user_id = d.user_id
  left join public.student_devices as a
    on a.user_id = d.user_id and a.status = 'active'
  where d.status = 'pending'
  order by d.created_at;
end;
$$;

create or replace function public.approve_device_request(
  p_device_id uuid,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := public.sdtt_require_device_admin();
  v_now timestamptz := clock_timestamp();
  v_request public.student_devices%rowtype;
  v_old uuid;
begin
  select d.* into v_request from public.student_devices as d
  where d.id = p_device_id for update;
  if not found or v_request.status <> 'pending' then
    raise exception 'Device request % is not pending.', p_device_id;
  end if;

  perform 1 from public.profiles as p where p.user_id = v_request.user_id for update;

  update public.student_devices
  set status = 'revoked', revoked_at = v_now,
      revoked_reason = 'Replaced by approved device ' || p_device_id::text
  where user_id = v_request.user_id and status = 'active'
  returning id into v_old;

  if v_old is not null then
    update public.device_auth_challenges
    set consumed_at = v_now, outcome = 'device_revoked'
    where device_id = v_old and consumed_at is null;
    insert into public.device_audit_log (device_id, user_id, actor_id, actor_label, action, details)
    values (v_old, v_request.user_id, v_actor, coalesce(v_actor::text, session_user::text),
      'revoked', jsonb_build_object('replaced_by', p_device_id));
  end if;

  update public.student_devices
  set status = 'active', activated_at = v_now, decided_at = v_now,
      decided_by = v_actor, decision_note = left(p_note, 500),
      replaced_device_id = coalesce(v_old, replaced_device_id)
  where id = p_device_id;

  insert into public.device_audit_log (device_id, user_id, actor_id, actor_label, action, details)
  values (p_device_id, v_request.user_id, v_actor, coalesce(v_actor::text, session_user::text),
    'approved', jsonb_build_object('note', p_note, 'previous_device_id', v_old));

  return jsonb_build_object('ok', true, 'device_id', p_device_id,
    'revoked_device_id', v_old);
end;
$$;

create or replace function public.reject_device_request(
  p_device_id uuid,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := public.sdtt_require_device_admin();
  v_user uuid;
begin
  update public.student_devices
  set status = 'rejected', decided_at = clock_timestamp(), decided_by = v_actor,
      decision_note = left(p_note, 500)
  where id = p_device_id and status = 'pending'
  returning user_id into v_user;
  if v_user is null then
    raise exception 'Device request % is not pending.', p_device_id;
  end if;
  insert into public.device_audit_log (device_id, user_id, actor_id, actor_label, action, details)
  values (p_device_id, v_user, v_actor, coalesce(v_actor::text, session_user::text),
    'rejected', jsonb_build_object('note', p_note));
  return jsonb_build_object('ok', true, 'device_id', p_device_id);
end;
$$;

create or replace function public.revoke_student_device(
  p_device_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := public.sdtt_require_device_admin();
  v_now timestamptz := clock_timestamp();
  v_user uuid;
begin
  if p_reason is null or char_length(trim(p_reason)) = 0 then
    raise exception 'A revocation reason is required.';
  end if;
  update public.student_devices
  set status = 'revoked', revoked_at = v_now, revoked_reason = left(p_reason, 500)
  where id = p_device_id and status in ('active', 'pending')
  returning user_id into v_user;
  if v_user is null then
    raise exception 'Device % is not active or pending.', p_device_id;
  end if;
  update public.device_auth_challenges
  set consumed_at = v_now, outcome = 'device_revoked'
  where device_id = p_device_id and consumed_at is null;
  insert into public.device_audit_log (device_id, user_id, actor_id, actor_label, action, details)
  values (p_device_id, v_user, v_actor, coalesce(v_actor::text, session_user::text),
    'revoked', jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true, 'device_id', p_device_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security and privileges
-- ---------------------------------------------------------------------------

alter table public.device_admins enable row level security;
alter table public.student_devices enable row level security;
alter table public.device_auth_challenges enable row level security;
alter table public.device_auth_events enable row level security;
alter table public.device_audit_log enable row level security;

-- Supabase grants table privileges to anon/authenticated by default; remove
-- them so RLS is not the only line of defence.
revoke all on public.device_admins from anon, authenticated;
revoke all on public.student_devices from anon, authenticated;
revoke all on public.device_auth_challenges from anon, authenticated;
revoke all on public.device_auth_events from anon, authenticated;
revoke all on public.device_audit_log from anon, authenticated;

grant select on public.device_admins to authenticated;
grant select on public.student_devices to authenticated;
grant select on public.device_auth_events to authenticated;
grant select on public.device_audit_log to authenticated;
-- device_auth_challenges: no client access at all (nonces live here).

drop policy if exists "Read own admin membership" on public.device_admins;
create policy "Read own admin membership"
on public.device_admins for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "Read own devices or all as device admin" on public.student_devices;
create policy "Read own devices or all as device admin"
on public.student_devices for select to authenticated
using (user_id = (select auth.uid()) or public.is_device_admin());

drop policy if exists "Read own auth events or all as device admin" on public.device_auth_events;
create policy "Read own auth events or all as device admin"
on public.device_auth_events for select to authenticated
using (user_id = (select auth.uid()) or public.is_device_admin());

drop policy if exists "Read own device audit or all as device admin" on public.device_audit_log;
create policy "Read own device audit or all as device admin"
on public.device_audit_log for select to authenticated
using (user_id = (select auth.uid()) or public.is_device_admin());

-- Function privileges: sdtt_* are for the Edge Function (service_role) only.
revoke all on function public.sdtt_require_device_admin() from public, anon, authenticated;
revoke all on function public.sdtt_iso(timestamptz) from public, anon, authenticated;
revoke all on function public.sdtt_log_event(uuid, uuid, uuid, uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.sdtt_error(text, text) from public, anon, authenticated;
revoke all on function public.sdtt_device_error(text) from public, anon, authenticated;
revoke all on function public.sdtt_issue_challenge(uuid, text, uuid, uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.sdtt_get_challenge(uuid, uuid) from public, anon, authenticated;
revoke all on function public.sdtt_complete_challenge(uuid, uuid, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.sdtt_issue_challenge(uuid, text, uuid, uuid, text, text, text) to service_role;
grant execute on function public.sdtt_get_challenge(uuid, uuid) to service_role;
grant execute on function public.sdtt_complete_challenge(uuid, uuid, boolean, text, jsonb) to service_role;

revoke all on function public.is_device_admin() from public, anon;
revoke all on function public.list_device_requests() from public, anon;
revoke all on function public.approve_device_request(uuid, text) from public, anon;
revoke all on function public.reject_device_request(uuid, text) from public, anon;
revoke all on function public.revoke_student_device(uuid, text) from public, anon;
grant execute on function public.is_device_admin() to authenticated;
grant execute on function public.list_device_requests() to authenticated;
grant execute on function public.approve_device_request(uuid, text) to authenticated;
grant execute on function public.reject_device_request(uuid, text) to authenticated;
grant execute on function public.revoke_student_device(uuid, text) to authenticated;

notify pgrst, 'reload schema';
