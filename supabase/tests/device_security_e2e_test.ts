// End-to-end security tests for the device-bound attendance flow.
//
// Runs against a Supabase project (local `supabase start` recommended) with
// supabase/attendance_workflow.sql and supabase/device_security.sql applied
// and the device-attendance function served. Software P-256 keys stand in for
// the Android Keystore key; the server cannot tell the difference, which is
// exactly why it must verify signatures rather than trust the client.
//
//   SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_SERVICE_ROLE_KEY=... \
//     deno test -A supabase/tests/device_security_e2e_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const fnUrl = `${url}/functions/v1/device-attendance`;
const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

type Json = Record<string, unknown>;

const toB64 = (bytes: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes)));

class SoftwareKey {
  private constructor(private pair: CryptoKeyPair, readonly spki: string) {}
  static async create() {
    const pair = await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"]);
    const spki = toB64(await crypto.subtle.exportKey("spki", pair.publicKey));
    return new SoftwareKey(pair, spki);
  }
  // DER-encoded like Android's SHA256withECDSA.
  async sign(payload: string): Promise<string> {
    const raw = new Uint8Array(await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" }, this.pair.privateKey,
      new TextEncoder().encode(payload)));
    const int = (v: Uint8Array) => {
      let i = 0;
      while (i < v.length - 1 && v[i] === 0) i++;
      let out = v.subarray(i);
      if (out[0] & 0x80) out = new Uint8Array([0, ...out]);
      return [0x02, out.length, ...out];
    };
    const body = [...int(raw.subarray(0, 32)), ...int(raw.subarray(32))];
    return toB64(new Uint8Array([0x30, body.length, ...body]));
  }
}

interface Actor { id: string; jwt: string; client: SupabaseClient }

async function makeUser(email: string): Promise<Actor> {
  const password = crypto.randomUUID();
  const { data, error } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
  });
  if (error) throw error;
  const client = createClient(url, anonKey, { auth: { persistSession: false } });
  const { data: session, error: signInError } = await client.auth.signInWithPassword({ email, password });
  if (signInError) throw signInError;
  return { id: data.user.id, jwt: session.session!.access_token, client };
}

async function call(actor: Actor | null, body: Json): Promise<Json & { httpStatus: number }> {
  const res = await fetch(fnUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: anonKey,
      ...(actor ? { Authorization: `Bearer ${actor.jwt}` } : {}),
    },
    body: JSON.stringify(body),
  });
  return { ...(await res.json()), httpStatus: res.status };
}

const challenge = (actor: Actor, body: Json) =>
  call(actor, { operation: "issue_challenge", ...body });

async function register(actor: Actor, key: SoftwareKey) {
  const ch = await challenge(actor, { purpose: "register_device" });
  assertEquals(ch.code, "challenge_issued");
  return await call(actor, {
    operation: "register_device",
    challenge_id: ch.challenge_id,
    public_key: key.spki,
    signature: await key.sign(String(ch.signing_payload)),
  });
}

async function unlock(actor: Actor, deviceId: string, key: SoftwareKey) {
  const ch = await challenge(actor, { purpose: "app_unlock", device_id: deviceId });
  if (ch.ok !== true) return ch;
  return await call(actor, {
    operation: "verify_challenge",
    challenge_id: ch.challenge_id,
    signature: await key.sign(String(ch.signing_payload)),
  });
}

const rand = () => String(100 + Math.floor(Math.random() * 900));
const sixDigits = () => String(100000 + Math.floor(Math.random() * 900000));
const bleToken = () => Array.from(crypto.getRandomValues(new Uint8Array(6)))
  .map((b) => b.toString(16).padStart(2, "0")).join("");

Deno.test("device-bound attendance security", async (t) => {
  const suffix = rand();
  const studentA = await makeUser(`25bcs${suffix}@iiitdwd.ac.in`);
  const studentB = await makeUser(`24bcs${suffix}@iiitdwd.ac.in`);
  const studentC = await makeUser(`23bcs${suffix}@iiitdwd.ac.in`);
  const teacher = await makeUser(`teacher${suffix}${Date.now()}@iiitdwd.ac.in`);

  const keyA1 = await SoftwareKey.create();
  const keyA2 = await SoftwareKey.create();
  const keyB = await SoftwareKey.create();
  let deviceA1 = "";
  let deviceA2 = "";

  await t.step("requests without a valid JWT are rejected", async () => {
    assertEquals((await call(null, { operation: "issue_challenge", purpose: "app_unlock" })).httpStatus, 401);
    const forged = { ...studentA, jwt: studentA.jwt.slice(0, -4) + "AAAA" };
    assertEquals((await call(forged, { operation: "issue_challenge", purpose: "app_unlock" })).httpStatus, 401);
  });

  await t.step("teachers cannot obtain student device challenges", async () => {
    assertEquals((await challenge(teacher, { purpose: "register_device" })).code, "student_only");
  });

  await t.step("first device registers as active", async () => {
    const res = await register(studentA, keyA1);
    assertEquals(res.code, "device_registered");
    assertEquals(res.status, "active");
    deviceA1 = String(res.device_id);
  });

  await t.step("registered device unlocks with a valid signature", async () => {
    assertEquals((await unlock(studentA, deviceA1, keyA1)).code, "unlocked");
  });

  await t.step("replayed challenge is rejected", async () => {
    const ch = await challenge(studentA, { purpose: "app_unlock", device_id: deviceA1 });
    const signature = await keyA1.sign(String(ch.signing_payload));
    const first = await call(studentA, { operation: "verify_challenge", challenge_id: ch.challenge_id, signature });
    assertEquals(first.code, "unlocked");
    const replay = await call(studentA, { operation: "verify_challenge", challenge_id: ch.challenge_id, signature });
    assertEquals(replay.code, "challenge_already_used");
  });

  await t.step("forged signature (wrong key) is rejected and burns the challenge", async () => {
    const ch = await challenge(studentA, { purpose: "app_unlock", device_id: deviceA1 });
    const forged = await call(studentA, {
      operation: "verify_challenge", challenge_id: ch.challenge_id,
      signature: await keyB.sign(String(ch.signing_payload)),
    });
    assertEquals(forged.code, "invalid_signature");
    const retry = await call(studentA, {
      operation: "verify_challenge", challenge_id: ch.challenge_id,
      signature: await keyA1.sign(String(ch.signing_payload)),
    });
    assertEquals(retry.code, "challenge_already_used");
  });

  await t.step("signature over a modified payload is rejected", async () => {
    const ch = await challenge(studentA, { purpose: "app_unlock", device_id: deviceA1 });
    const tampered = String(ch.signing_payload).replace("purpose=app_unlock", "purpose=mark_attendance");
    const res = await call(studentA, {
      operation: "verify_challenge", challenge_id: ch.challenge_id,
      signature: await keyA1.sign(tampered),
    });
    assertEquals(res.code, "invalid_signature");
  });

  await t.step("expired challenge is rejected", async () => {
    const ch = await challenge(studentA, { purpose: "app_unlock", device_id: deviceA1 });
    const { error } = await admin.from("device_auth_challenges")
      .update({
        created_at: new Date(Date.now() - 120_000).toISOString(),
        expires_at: new Date(Date.now() - 1000).toISOString(),
      })
      .eq("id", ch.challenge_id);
    if (error) throw error;
    const res = await call(studentA, {
      operation: "verify_challenge", challenge_id: ch.challenge_id,
      signature: await keyA1.sign(String(ch.signing_payload)),
    });
    assertEquals(res.code, "challenge_expired");
  });

  await t.step("unregistered device id is rejected", async () => {
    const res = await challenge(studentB, { purpose: "app_unlock", device_id: crypto.randomUUID() });
    assertEquals(res.code, "device_not_registered");
  });

  await t.step("cross-student: B cannot use A's device or A's challenge", async () => {
    assertEquals((await challenge(studentB, { purpose: "app_unlock", device_id: deviceA1 })).code,
      "device_not_registered");
    const ch = await challenge(studentA, { purpose: "app_unlock", device_id: deviceA1 });
    const res = await call(studentB, {
      operation: "verify_challenge", challenge_id: ch.challenge_id,
      signature: await keyA1.sign(String(ch.signing_payload)),
    });
    assertEquals(res.code, "challenge_not_found");
  });

  await t.step("a public key cannot be registered to a second account", async () => {
    const res = await register(studentB, keyA1);
    assertEquals(res.code, "key_in_use");
  });

  await t.step("second phone (password login alone) only creates a pending request", async () => {
    const res = await register(studentA, keyA2);
    assertEquals(res.code, "replacement_pending");
    deviceA2 = String(res.device_id);
    assertEquals((await unlock(studentA, deviceA2, keyA2)).code, "device_pending_approval");
    assertEquals((await unlock(studentA, deviceA1, keyA1)).code, "unlocked");
  });

  await t.step("students cannot approve, mutate or read others' device records", async () => {
    const approve = await studentA.client.rpc("approve_device_request", { p_device_id: deviceA2 });
    assert(approve.error, "student approval must fail");
    const insert = await studentA.client.from("student_devices").insert({
      user_id: studentA.id, public_key_spki: keyA2.spki, public_key_sha256: "x", status: "active",
    });
    assert(insert.error, "direct insert must fail");
    const update = await studentA.client.from("student_devices").update({ status: "active" }).eq("id", deviceA2).select();
    assert(update.error || (update.data ?? []).length === 0, "direct update must fail");
    const others = await studentB.client.from("student_devices").select("id");
    assertEquals(others.data ?? [], []);
    const own = await studentA.client.from("student_devices").select("id,status");
    assertEquals((own.data ?? []).length, 2);
    const challenges = await studentA.client.from("device_auth_challenges").select("id");
    assert(challenges.error || (challenges.data ?? []).length === 0);
  });

  await t.step("service-role RPCs and the old mark_attendance are not client-callable", async () => {
    const complete = await studentA.client.rpc("sdtt_complete_challenge", {
      p_user_id: studentA.id, p_challenge_id: crypto.randomUUID(), p_signature_valid: true,
    });
    assert(complete.error, "sdtt_complete_challenge must not be callable");
    const legacy = await studentA.client.rpc("mark_attendance", {
      p_session_id: crypto.randomUUID(), p_session_code: "123456", p_method: "qr", p_qr_code: "123456",
    });
    assert(legacy.error, "mark_attendance must be gone");
    const direct = await studentA.client.from("attendance_records").insert({
      session_id: crypto.randomUUID(), student_id: studentA.id, student_email: "x",
    });
    assert(direct.error, "direct attendance insert must fail");
  });

  // ---------------------------------------------------------------- attendance
  const qr = sixDigits();
  const ble = bleToken();
  const { data: session, error: sessionError } = await teacher.client.rpc("create_attendance_session", {
    p_title: "Security test", p_initial_qr_code: qr, p_initial_ble_token: ble,
  });
  if (sessionError) throw sessionError;
  const base = { purpose: "mark_attendance", device_id: deviceA1, session_id: session.id, session_code: session.session_code };

  await t.step("QR-only submission (no BLE token) is rejected", async () => {
    assertEquals((await challenge(studentA, { ...base, qr_code: qr })).code, "invalid_ble");
  });

  await t.step("BLE-only submission (no / wrong QR) is rejected", async () => {
    assertEquals((await challenge(studentA, { ...base, ble_token: ble })).code, "invalid_qr");
    const wrongQr = qr === "111111" ? "222222" : "111111";
    assertEquals((await challenge(studentA, { ...base, ble_token: ble, qr_code: wrongQr })).code, "invalid_qr");
  });

  await t.step("wrong BLE token and wrong session code are rejected", async () => {
    assertEquals((await challenge(studentA, { ...base, qr_code: qr, ble_token: "000000000000" })).code, "invalid_ble");
    assertEquals((await challenge(studentA, { ...base, session_code: "000000", qr_code: qr, ble_token: ble })).code,
      "invalid_session_id");
  });

  await t.step("pending device cannot mark attendance", async () => {
    assertEquals((await challenge(studentA, { ...base, device_id: deviceA2, qr_code: qr, ble_token: ble })).code,
      "device_pending_approval");
  });

  await t.step("valid device + signature + QR + BLE marks attendance once", async () => {
    const ch = await challenge(studentA, { ...base, qr_code: qr, ble_token: ble });
    assertEquals(ch.code, "challenge_issued");
    assert(String(ch.signing_payload).includes(`session_id=${session.id}`));
    const signature = await keyA1.sign(String(ch.signing_payload));
    const res = await call(studentA, { operation: "verify_challenge", challenge_id: ch.challenge_id, signature });
    assertEquals(res.code, "present");
    const replay = await call(studentA, { operation: "verify_challenge", challenge_id: ch.challenge_id, signature });
    assertEquals(replay.code, "challenge_already_used");
    assertEquals((await challenge(studentA, { ...base, qr_code: qr, ble_token: ble })).code, "already_marked");
    const { data: rows } = await teacher.client.from("attendance_records").select("student_id,device_id").eq("session_id", session.id);
    assertEquals(rows, [{ student_id: studentA.id, device_id: deviceA1 }]);
  });

  await t.step("duplicate submission racing on two challenges records once", async () => {
    // B registers, then issues two attendance challenges before completing either.
    const reg = await register(studentB, keyB);
    const deviceB = String(reg.device_id);
    const b = { ...base, device_id: deviceB, qr_code: qr, ble_token: ble };
    const [c1, c2] = [await challenge(studentB, b), await challenge(studentB, b)];
    const results = await Promise.all([c1, c2].map(async (c) =>
      call(studentB, { operation: "verify_challenge", challenge_id: c.challenge_id,
        signature: await keyB.sign(String(c.signing_payload)) })));
    assertEquals(results.map((r) => r.code).sort(), ["already_marked", "present"]);
  });

  await t.step("rotated codes: previous pair valid briefly, then rejected", async () => {
    const qr2 = sixDigits();
    const ble2 = bleToken();
    const { error } = await teacher.client.rpc("rotate_attendance_qr", {
      p_session_id: session.id, p_qr_code: qr2, p_ble_token: ble2,
    });
    if (error) throw error;
    await admin.from("attendance_sessions").update({ previous_codes_expire_at: new Date(Date.now() - 1000).toISOString() }).eq("id", session.id);
    const regC = await register(studentC, await SoftwareKey.create());
    const cBase = { ...base, device_id: String(regC.device_id) };
    assertEquals((await challenge(studentC, { ...cBase, qr_code: qr, ble_token: ble })).code, "invalid_qr");
    assertEquals((await challenge(studentC, { ...cBase, qr_code: qr2, ble_token: ble })).code, "invalid_ble");
    assertEquals((await challenge(studentC, { ...cBase, qr_code: qr2, ble_token: ble2 })).code, "challenge_issued");
  });

  await t.step("admin approval atomically revokes the old device", async () => {
    const { error } = await admin.from("device_admins").insert({ user_id: teacher.id });
    if (error) throw error;
    const list = await teacher.client.rpc("list_device_requests");
    if (list.error) throw list.error;
    assert(JSON.stringify(list.data).includes(deviceA2));
    const approved = await teacher.client.rpc("approve_device_request", { p_device_id: deviceA2, p_note: "lost phone, ID checked" });
    if (approved.error) throw approved.error;
    assertEquals((await unlock(studentA, deviceA1, keyA1)).code, "device_revoked");
    assertEquals((await unlock(studentA, deviceA2, keyA2)).code, "unlocked");
    const { data: audit } = await admin.from("device_audit_log").select("action").eq("user_id", studentA.id);
    const actions = (audit ?? []).map((r) => r.action);
    assert(actions.includes("approved") && actions.includes("revoked"), JSON.stringify(actions));
  });

  await t.step("revoked device is rejected", async () => {
    const revoked = await teacher.client.rpc("revoke_student_device", { p_device_id: deviceA2, p_reason: "test" });
    if (revoked.error) throw revoked.error;
    assertEquals((await unlock(studentA, deviceA2, keyA2)).code, "device_revoked");
    const reuse = await register(studentA, keyA2);
    assertEquals(reuse.code, "key_retired");
  });

  await t.step("challenge issuance is rate limited", async () => {
    let last: Json = {};
    for (let i = 0; i < 14; i++) last = await challenge(studentC, { purpose: "register_device" });
    assertEquals(last.code, "rate_limited");
  });
});
