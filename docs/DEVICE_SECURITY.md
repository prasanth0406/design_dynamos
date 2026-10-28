# Device-bound attendance security

This document covers setup, the threat model and testing for the device-bound
student authentication added to the SDTT BLE Attendance app.

## What it guarantees — and what it cannot

**Android's biometric APIs never tell an app which enrolled fingerprint or face
was used.** No amount of cryptography changes that. A successful signature
proves:

1. The request was signed by the private key that the server registered for
   this student, which only exists inside this phone's Android Keystore
   (TEE or StrongBox) and cannot be exported or copied to another phone.
2. A Class 3 (strong) biometric that was **enrolled on this phone when the key
   was created** was presented for *this specific* signature.
3. The signature covers a fresh, single-use, server-issued challenge bound to
   the student, device, operation and (for attendance) the session.

What this means in practice:

| Scenario | Result |
| --- | --- |
| Student's own phone, own fingerprint | Works. |
| Student logs in with email/password on a friend's phone | Friend's phone gets only a *pending* request; an admin must approve it, which revokes the old phone. |
| Friend's fingerprint enrolled **after** the key was created | Android permanently invalidates the key (`setInvalidatedByBiometricEnrollment(true)`); the student must re-register and an admin must approve. |
| Friend's fingerprint enrolled **before** the key was created | **The friend can sign.** The app cannot detect this. Mitigation is organisational (registration in front of staff, policy that only the student's biometrics are enrolled, teacher head-count). |
| Student hands the phone to a friend who uses the student's PIN | Not possible for signing: the key requires a *biometric*; PIN/pattern cannot authorize it. |
| Student hands an unlocked phone *and their finger* to a friend in class | Not preventable by software. |
| Remote student, friend in class relays QR + BLE token over chat | Possible within the ~10–14 s code window; the remote student still needs their own registered phone and biometric. BLE is not a proof of distance. |
| Rooted/compromised phone | Keystore hardware still protects the key, but a compromised OS can drive the prompt. Enable attestation enforcement (below) to reject software-only keys. |

This design makes proxy attendance substantially harder and auditable; it does
**not** make it impossible.

## Architecture

```
Flutter (lib/device_proof.dart)            Edge Function device-attendance       Postgres (service-role only RPCs)
  DeviceKey ── MethodChannel ──► DeviceKeyPlugin.kt (Keystore + BiometricPrompt)
  issue_challenge ───────────────────────► verifies JWT ───────────────────────► sdtt_issue_challenge
                                                                                  (role, device active, session,
                                                                                   QR hash, BLE hash, rate limit)
  sign(signing_payload) ◄─ biometric prompt
  verify_challenge / register_device ────► sdtt_get_challenge, ECDSA P-256
                                           verify vs registered SPKI ─────────► sdtt_complete_challenge
                                                                                  (lock, consume, record attendance)
```

* **Key**: EC P-256 (`secp256r1`), `SHA256withECDSA`, `PURPOSE_SIGN` only,
  `setUserAuthenticationRequired(true)`, per-use strong-biometric
  authentication (`setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`
  on API 30+, validity `-1` + `CryptoObject` on API 24–29),
  `setInvalidatedByBiometricEnrollment(true)`, StrongBox when available,
  attestation challenge = server nonce. Only the X.509 SPKI public key, the
  attestation chain and signatures leave the device.
* **Challenges** (`device_auth_challenges`): 32-byte random nonce, canonical
  payload (`sdtt-device-auth-v1`, purpose, challenge id, nonce, user, device,
  session, issued/expires), 60 s expiry (120 s for registration, capped at
  session end), consumed on the first verification attempt whatever the
  outcome, 12 per user per minute.
* **Devices** (`student_devices`): one `active` and at most one `pending` row
  per student (partial unique indexes), unique public-key hash, status
  `active | pending | revoked | rejected | superseded`, attestation summary,
  full audit trail (`device_audit_log`) and per-attempt events
  (`device_auth_events`).
* **Attendance**: only `sdtt_complete_challenge` (service role) inserts into
  `attendance_records`, storing `device_id` and `challenge_id`. The old
  client-callable `mark_attendance` RPC is dropped. QR codes (displayed) and BLE
  tokens (advertised, 6 random bytes) both rotate every 10 s; only their SHA-256
  hashes are stored, with a 4 s grace window for the previous pair.
* **RLS/privileges**: clients have `SELECT` only, restricted by RLS to their own
  devices/events/audit rows (device admins see all). No client `INSERT/UPDATE/
  DELETE` on any device table. Challenge rows are not readable by clients.

## Setup

### 1. Database

Run in the Supabase SQL Editor (or `psql`), in order:

1. `supabase/attendance_workflow.sql`
2. `supabase/device_security.sql`

Both are idempotent. Then designate device administrators:

```sql
insert into public.device_admins (user_id, note)
select id, 'Exam cell' from auth.users where email = 'admin@iiitdwd.ac.in';
```

### 2. Edge Function

```bash
supabase functions deploy device-attendance
# Optional hardening, once you have collected the Google root fingerprints:
supabase secrets set REQUIRE_KEY_ATTESTATION=true \
  ANDROID_ATTESTATION_ROOT_SPKI_SHA256=<sha256-hex-of-root-spki>[,<another>]
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically by
Supabase. The service-role key must never be placed in the Flutter app.

The function always stores an attestation summary
(`student_devices.attestation_summary`: chain validity, challenge match,
TEE/StrongBox level, root fingerprint). With `REQUIRE_KEY_ATTESTATION=true` a
registration is rejected unless the chain is valid, certifies the submitted key,
contains the server nonce, is hardware-backed and ends in a configured root.
The root fingerprints are listed in Google's
[key attestation documentation](https://developer.android.com/privacy-and-security/security-key-attestation#root_certificate).
Revocation-list checking is not implemented.

### 3. Android app

No new pub packages. `android/app/build.gradle.kts` adds
`androidx.biometric:biometric:1.1.0`; `MainActivity` (already a
`FlutterFragmentActivity`) registers `DeviceKeyPlugin` on the
`com.example.att/device_key` channel. `USE_BIOMETRIC` was already declared.

```bash
flutter pub get
flutter build apk --release   # configure a real release signing key first
```

Students need a Class 3 (strong) fingerprint or face unlock. Phones that only
offer Class 2 face unlock or no biometrics cannot register.

## Device replacement / recovery

1. Student signs in on the new phone and taps **Enable device unlock**. A new
   key is generated and registered as `pending` (`replacement_pending`).
2. Admin verifies the student's identity in person, then:

   ```sql
   select public.list_device_requests();
   select public.approve_device_request('<pending device id>', 'ID card checked');
   -- or
   select public.reject_device_request('<pending device id>', 'Not the student');
   ```

   Approval atomically revokes the previous active device and activates the new
   one. Every step is written to `device_audit_log`.
3. Student taps the button again; the app sees `active` and opens.

Lost/stolen phone: `select public.revoke_student_device('<device id>', 'reported stolen');`
— outstanding challenges for it are invalidated immediately.

Biometric change on the same phone: the key is destroyed by Android; the unlock
screen offers **Register this phone again**, which creates a pending request.

These admin RPCs work from the SQL Editor or for signed-in users listed in
`device_admins`; nobody else can call them successfully.

## Error codes (returned as `{ ok:false, code, message }`)

`student_only`, `rate_limited`, `device_not_registered`,
`device_pending_approval`, `device_revoked`, `device_rejected`, `key_in_use`,
`key_retired`, `attestation_failed`, `challenge_not_found`,
`challenge_already_used`, `challenge_expired`, `invalid_signature`,
`invalid_session_id`, `session_ended`, `invalid_qr`, `invalid_ble`,
`already_marked`. On-device errors: `cancelled`, `locked_out`,
`biometric_unavailable`, `key_invalidated`, `no_key`, `unsupported_platform`.

## Testing

### Automated (server)

```bash
supabase start
psql "$DB_URL" -f supabase/attendance_workflow.sql -f supabase/device_security.sql
supabase functions serve --no-verify-jwt   # separate terminal
deno test -A supabase/functions/device-attendance/crypto_test.ts
SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... SUPABASE_SERVICE_ROLE_KEY=... \
  deno test -A supabase/tests/device_security_e2e_test.ts
```

The end-to-end test uses software keys in place of the Keystore and covers:
missing/forged JWT, teacher accounts, first registration, valid unlock,
replayed challenge, forged signature (wrong key), modified payload, expired
challenge, unregistered device, cross-student device and challenge use, a key
registered to two accounts, second phone → pending, students approving or
mutating device rows, client calls to service-role RPCs and the removed
`mark_attendance`, direct attendance inserts, QR-only, BLE-only, wrong BLE
token, wrong session code, pending device attendance, a valid attendance,
duplicate attendance (including two concurrent challenges), rotated codes and
the grace window, admin approval revoking the old device, revoked device
rejection and retired-key reuse, and rate limiting.

### Manual (physical Android phones — required for Keystore/biometrics)

| # | Steps | Expected |
| --- | --- | --- |
| 1 | Student signs in on phone A, taps Enable device unlock, uses fingerprint | Dashboard opens; `student_devices` row `active` with `attestation_summary.hardware_backed = true` |
| 2 | Close/reopen app, Unlock | Biometric prompt (no PIN option); dashboard opens |
| 3 | Teacher starts a session; student scans QR (or types code) near teacher | Fingerprint prompt, then "Attendance marked"; teacher list updates live |
| 4 | Submit again | `already_marked` |
| 5 | Same student signs in on phone B | "waiting for administrator approval"; phone B cannot unlock or mark attendance |
| 6 | Admin approves phone B | Phone A unlock → "revoked"; phone B works |
| 7 | On the active phone, add a new fingerprint in Settings, open app | "fingerprint or face was added…key was destroyed" + Register again button → pending |
| 8 | Cancel the biometric prompt | "Verification was cancelled"; nothing recorded |
| 9 | Scan a QR older than ~14 s | `invalid_qr` |
| 10 | Mark attendance far from the teacher (no BLE) with a valid QR photo | `invalid_ble` |
| 11 | Turn off network, unlock | Connection error; dashboard stays locked |
| 12 | A phone with no strong biometric | Registration refused with a setup message |

## Notes / behaviour changes

* "Enter Session ID" is now **Enter Code**: the student types the rotating code
  printed under the teacher's QR. A static session ID is broadcast over BLE
  and can no longer be used as proof of presence.
* The teacher's BLE advertisement now restarts every 10 s with a new token.
* Teachers keep the previous `local_auth` unlock (the device binding is
  student-only); teacher actions are authorised by Supabase Auth + RLS.
