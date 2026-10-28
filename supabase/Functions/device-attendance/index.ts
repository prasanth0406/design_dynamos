import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function base64ToUint8Array(base64: string): Uint8Array {
  const binaryString = atob(base64.replace(/[\r\n\s]/g, ""));
  const len = binaryString.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return bytes;
}

/**
 * Converts standard ASN.1 DER ECDSA signature produced by Android Keystore
 * into the 64-byte IEEE P1363 format required by the WebCrypto API.
 */
function derToP1363(der: Uint8Array): Uint8Array {
  if (der.length === 64) return der;
  let offset = 0;
  if (der[offset++] !== 0x30) throw new Error("Invalid ASN.1 DER sequence header");

  let len = der[offset++];
  if (len & 0x80) {
    const numBytes = len & 0x7f;
    offset += numBytes;
  }

  if (der[offset++] !== 0x02) throw new Error("Invalid ASN.1 DER integer R header");
  const rLen = der[offset++];
  const r = der.slice(offset, offset + rLen);
  offset += rLen;

  if (der[offset++] !== 0x02) throw new Error("Invalid ASN.1 DER integer S header");
  const sLen = der[offset++];
  const s = der.slice(offset, offset + sLen);

  const raw = new Uint8Array(64);
  const rTrimmed = r.length > 32 ? r.slice(r.length - 32) : r;
  raw.set(rTrimmed, 32 - rTrimmed.length);

  const sTrimmed = s.length > 32 ? s.slice(s.length - 32) : s;
  raw.set(sTrimmed, 64 - sTrimmed.length);

  return raw;
}

async function verifyEcdsaSignature(
  publicKeySpkiBase64: string,
  signatureBase64: string,
  dataString: string,
): Promise<boolean> {
  try {
    const spkiBytes = base64ToUint8Array(publicKeySpkiBase64);
    const cryptoKey = await crypto.subtle.importKey(
      "spki",
      spkiBytes.buffer as ArrayBuffer,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );

    const sigBytes = base64ToUint8Array(signatureBase64);
    const p1363Sig = derToP1363(sigBytes);
    const dataBytes = new TextEncoder().encode(dataString);

    return await crypto.subtle.verify(
      { name: "ECDSA", hash: { name: "SHA-256" } },
      cryptoKey,
      p1363Sig.buffer as ArrayBuffer,
      dataBytes.buffer as ArrayBuffer,
    );
  } catch (err) {
    console.error("Signature verification error:", err);
    return false;
  }
}

async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(digest);
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const respond = (status: number, body: Record<string, unknown>) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  if (req.method !== "POST") {
    return respond(405, { ok: false, code: "method_not_allowed", message: "Use POST." });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = req.headers.get("Authorization");

  if (!supabaseUrl || !supabaseAnonKey || !authorization) {
    return respond(401, {
      ok: false,
      code: "missing_authentication",
      message: "Authorization header is required.",
    });
  }

  // 1. Verify caller session with anon client
  const userClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: { user }, error: userError } = await userClient.auth.getUser();
  if (userError || !user) {
    return respond(401, {
      ok: false,
      code: "invalid_session",
      message: "Your login session is invalid or expired.",
    });
  }

  // 2. Privileged admin client for atomic table operations
  const adminKey = supabaseServiceRoleKey || supabaseAnonKey;
  const adminClient = createClient(supabaseUrl, adminKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let body: Record<string, unknown>;
  try {
    const parsed = await req.json();
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return respond(400, { ok: false, code: "invalid_request", message: "A JSON object is required." });
    }
    body = parsed as Record<string, unknown>;
  } catch {
    return respond(400, { ok: false, code: "invalid_json", message: "Request body must contain valid JSON." });
  }

  const action = typeof body.action === "string" ? body.action.trim() : "";

  // --------------------------------------------------------------------------
  // Action: get_device_status
  // --------------------------------------------------------------------------
  if (action === "get_device_status") {
    const { data: activeDevice, error } = await adminClient
      .from("student_devices")
      .select("device_id, device_name, registered_at, status")
      .eq("student_id", user.id)
      .eq("status", "active")
      .maybeSingle();

    if (error) {
      return respond(500, { ok: false, code: "db_error", message: error.message });
    }

    return respond(200, {
      ok: true,
      registered: !!activeDevice,
      deviceId: activeDevice?.device_id ?? null,
      deviceName: activeDevice?.device_name ?? null,
      registeredAt: activeDevice?.registered_at ?? null,
    });
  }

  // --------------------------------------------------------------------------
  // Action: register_device
  // --------------------------------------------------------------------------
  if (action === "register_device") {
    const deviceId = typeof body.deviceId === "string" ? body.deviceId.trim() : "";
    const publicKeySpki = typeof body.publicKeySpki === "string" ? body.publicKeySpki.trim() : "";
    const deviceName = typeof body.deviceName === "string" ? body.deviceName.trim() : "Android Device";

    if (!deviceId || !publicKeySpki) {
      return respond(400, { ok: false, code: "missing_fields", message: "deviceId and publicKeySpki are required." });
    }

    // Validate SPKI format
    try {
      const spkiBytes = base64ToUint8Array(publicKeySpki);
      await crypto.subtle.importKey(
        "spki",
        spkiBytes.buffer as ArrayBuffer,
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["verify"],
      );
    } catch {
      return respond(400, { ok: false, code: "invalid_public_key", message: "Invalid EC P-256 public key." });
    }

    // Check if an active registered device already exists for this student
    const { data: existingDevice } = await adminClient
      .from("student_devices")
      .select("*")
      .eq("student_id", user.id)
      .eq("status", "active")
      .maybeSingle();

    if (existingDevice) {
      if (existingDevice.device_id === deviceId) {
        // Same physical device re-registering its key
        await adminClient
          .from("student_devices")
          .update({ public_key_spki: publicKeySpki, device_name: deviceName, last_authenticated_at: new Date().toISOString() })
          .eq("id", existingDevice.id);

        return respond(200, { ok: true, message: "Device registration key refreshed." });
      }

      return respond(409, {
        ok: false,
        code: "device_already_registered",
        message: "Another device is already registered for this student account. Use device recovery to replace it.",
      });
    }

    // Insert new registered device
    const { error: insertErr } = await adminClient.from("student_devices").insert({
      student_id: user.id,
      device_id: deviceId,
      device_name: deviceName,
      public_key_spki: publicKeySpki,
      algorithm: "ES256",
      status: "active",
      registered_at: new Date().toISOString(),
    });

    if (insertErr) {
      return respond(500, { ok: false, code: "registration_failed", message: insertErr.message });
    }

    await adminClient.from("auth_audit_logs").insert({
      event_type: "device_registered",
      student_id: user.id,
      device_id: deviceId,
      details: { device_name: deviceName },
    });

    return respond(200, { ok: true, message: "Device registered successfully." });
  }

  // --------------------------------------------------------------------------
  // Action: create_challenge
  // --------------------------------------------------------------------------
  if (action === "create_challenge") {
    const deviceId = typeof body.deviceId === "string" ? body.deviceId.trim() : "";
    const purpose = typeof body.purpose === "string" ? body.purpose.trim() : "";
    const sessionId = typeof body.sessionId === "string" ? body.sessionId.trim() : null;
    const sessionCode = typeof body.sessionCode === "string" ? body.sessionCode.trim() : null;
    const qrCode = typeof body.qrCode === "string" ? body.qrCode.trim() : null;

    if (!deviceId || (purpose !== "unlock" && purpose !== "attendance")) {
      return respond(400, { ok: false, code: "invalid_parameters", message: "deviceId and purpose (unlock|attendance) required." });
    }

    // Verify active device
    const { data: device } = await adminClient
      .from("student_devices")
      .select("id, status")
      .eq("student_id", user.id)
      .eq("device_id", deviceId)
      .eq("status", "active")
      .maybeSingle();

    if (!device) {
      return respond(403, { ok: false, code: "device_not_registered", message: "This device is not an active registered attendance device." });
    }

    let qrCodeHash: string | null = null;
    if (purpose === "attendance") {
      if (!sessionId || !sessionCode || !qrCode) {
        return respond(400, { ok: false, code: "missing_attendance_fields", message: "sessionId, sessionCode, and qrCode required for attendance." });
      }

      // Check session
      const { data: session } = await adminClient
        .from("attendance_sessions")
        .select("*")
        .eq("id", sessionId)
        .eq("session_code", sessionCode)
        .eq("is_active", true)
        .maybeSingle();

      if (!session || new Date(session.ends_at) <= new Date()) {
        return respond(400, { ok: false, code: "session_ended", message: "This attendance session has ended." });
      }

      // Verify QR code hash
      qrCodeHash = await sha256Hex(qrCode);
      if (session.current_qr_hash !== qrCodeHash || !session.current_qr_expires_at || new Date(session.current_qr_expires_at) <= new Date()) {
        return respond(400, { ok: false, code: "invalid_qr", message: "The QR code has expired or does not match." });
      }

      // Check if already marked
      const { data: existingRec } = await adminClient
        .from("attendance_records")
        .select("id")
        .eq("session_id", sessionId)
        .eq("student_id", user.id)
        .maybeSingle();

      if (existingRec) {
        return respond(400, { ok: false, code: "already_marked", message: "Attendance is already marked for this session." });
      }
    }

    // Generate random 32-byte nonce
    const nonceBytes = crypto.getRandomValues(new Uint8Array(32));
    const nonce = Array.from(nonceBytes).map((b) => b.toString(16).padStart(2, "0")).join("");
    const timestamp = Date.now();
    const expiresAt = new Date(Date.now() + 60 * 1000); // 60 seconds lifetime

    const payload = purpose === "unlock"
      ? `SDTT:unlock:${nonce}:${user.id}:${deviceId}:${timestamp}`
      : `SDTT:attendance:${nonce}:${user.id}:${deviceId}:${sessionId}:${qrCodeHash}:${timestamp}`;

    const { error: chalErr } = await adminClient.from("auth_challenges").insert({
      challenge_nonce: nonce,
      challenge_payload: payload,
      student_id: user.id,
      device_id: deviceId,
      purpose,
      session_id: sessionId,
      qr_code_hash: qrCodeHash,
      expires_at: expiresAt.toISOString(),
    });

    if (chalErr) {
      return respond(500, { ok: false, code: "challenge_generation_failed", message: chalErr.message });
    }

    return respond(200, {
      ok: true,
      challenge: payload,
      expiresAt: expiresAt.toISOString(),
    });
  }

  // --------------------------------------------------------------------------
  // Action: verify_unlock
  // --------------------------------------------------------------------------
  if (action === "verify_unlock") {
    const deviceId = typeof body.deviceId === "string" ? body.deviceId.trim() : "";
    const challenge = typeof body.challenge === "string" ? body.challenge.trim() : "";
    const signature = typeof body.signature === "string" ? body.signature.trim() : "";

    if (!deviceId || !challenge || !signature) {
      return respond(400, { ok: false, code: "missing_fields", message: "deviceId, challenge, and signature are required." });
    }

    const { data: chal } = await adminClient
      .from("auth_challenges")
      .select("*")
      .eq("challenge_payload", challenge)
      .eq("student_id", user.id)
      .eq("device_id", deviceId)
      .eq("purpose", "unlock")
      .is("consumed_at", null)
      .maybeSingle();

    if (!chal || new Date(chal.expires_at) <= new Date()) {
      return respond(400, { ok: false, code: "challenge_expired_or_invalid", message: "Challenge expired or already used." });
    }

    // Atomically consume challenge
    await adminClient.from("auth_challenges").update({ consumed_at: new Date().toISOString() }).eq("id", chal.id);

    // Fetch registered public key
    const { data: device } = await adminClient
      .from("student_devices")
      .select("public_key_spki")
      .eq("student_id", user.id)
      .eq("device_id", deviceId)
      .eq("status", "active")
      .maybeSingle();

    if (!device) {
      return respond(403, { ok: false, code: "device_not_active", message: "Device is not actively registered." });
    }

    const valid = await verifyEcdsaSignature(device.public_key_spki, signature, challenge);
    if (!valid) {
      await adminClient.from("auth_audit_logs").insert({
        event_type: "unlock_signature_failed",
        student_id: user.id,
        device_id: deviceId,
      });
      return respond(400, { ok: false, code: "invalid_signature", message: "Cryptographic signature verification failed." });
    }

    await adminClient
      .from("student_devices")
      .update({ last_authenticated_at: new Date().toISOString() })
      .eq("student_id", user.id)
      .eq("device_id", deviceId);

    await adminClient.from("auth_audit_logs").insert({
      event_type: "unlock_success",
      student_id: user.id,
      device_id: deviceId,
    });

    return respond(200, { ok: true, message: "Device unlocked successfully." });
  }

  // --------------------------------------------------------------------------
  // Action: verify_and_mark_attendance
  // --------------------------------------------------------------------------
  if (action === "verify_and_mark_attendance") {
    const deviceId = typeof body.deviceId === "string" ? body.deviceId.trim() : "";
    const challenge = typeof body.challenge === "string" ? body.challenge.trim() : "";
    const signature = typeof body.signature === "string" ? body.signature.trim() : "";
    const sessionId = typeof body.sessionId === "string" ? body.sessionId.trim() : "";
    const sessionCode = typeof body.sessionCode === "string" ? body.sessionCode.trim() : "";
    const qrCode = typeof body.qrCode === "string" ? body.qrCode.trim() : "";

    if (!deviceId || !challenge || !signature || !sessionId || !sessionCode || !qrCode) {
      return respond(400, { ok: false, code: "missing_fields", message: "All challenge, signature, and session parameters are required." });
    }

    const { data: chal } = await adminClient
      .from("auth_challenges")
      .select("*")
      .eq("challenge_payload", challenge)
      .eq("student_id", user.id)
      .eq("device_id", deviceId)
      .eq("purpose", "attendance")
      .eq("session_id", sessionId)
      .is("consumed_at", null)
      .maybeSingle();

    if (!chal || new Date(chal.expires_at) <= new Date()) {
      return respond(400, { ok: false, code: "challenge_expired_or_invalid", message: "Attendance challenge has expired or was already used." });
    }

    // Atomically consume challenge
    await adminClient.from("auth_challenges").update({ consumed_at: new Date().toISOString() }).eq("id", chal.id);

    // Verify session
    const { data: session } = await adminClient
      .from("attendance_sessions")
      .select("*")
      .eq("id", sessionId)
      .eq("session_code", sessionCode)
      .eq("is_active", true)
      .maybeSingle();

    if (!session || new Date(session.ends_at) <= new Date()) {
      return respond(400, { ok: false, code: "session_ended", message: "This attendance session has ended." });
    }

    // Verify QR hash
    const qrHash = await sha256Hex(qrCode);
    if (chal.qr_code_hash !== qrHash) {
      return respond(400, { ok: false, code: "challenge_qr_mismatch", message: "Scanned QR does not match the signed challenge." });
    }

    // Verify device signature
    const { data: device } = await adminClient
      .from("student_devices")
      .select("public_key_spki")
      .eq("student_id", user.id)
      .eq("device_id", deviceId)
      .eq("status", "active")
      .maybeSingle();

    if (!device) {
      return respond(403, { ok: false, code: "device_not_registered", message: "Device is not registered or was revoked." });
    }

    const valid = await verifyEcdsaSignature(device.public_key_spki, signature, challenge);
    if (!valid) {
      await adminClient.from("auth_audit_logs").insert({
        event_type: "attendance_signature_failed",
        student_id: user.id,
        device_id: deviceId,
        session_id: sessionId,
      });
      return respond(400, { ok: false, code: "invalid_signature", message: "Device signature verification failed." });
    }

    // Check duplicate
    const { data: existingRecord } = await adminClient
      .from("attendance_records")
      .select("id")
      .eq("session_id", sessionId)
      .eq("student_id", user.id)
      .maybeSingle();

    if (existingRecord) {
      return respond(400, { ok: false, code: "already_marked", message: "Attendance is already marked for this session." });
    }

    // Record attendance
    const nowIso = new Date().toISOString();
    const { error: insErr } = await adminClient.from("attendance_records").insert({
      session_id: sessionId,
      student_id: user.id,
      student_email: user.email ?? "",
      marked_at: nowIso,
    });

    if (insErr) {
      return respond(500, { ok: false, code: "attendance_insert_failed", message: insErr.message });
    }

    await adminClient.from("auth_audit_logs").insert({
      event_type: "attendance_verified_and_marked",
      student_id: user.id,
      device_id: deviceId,
      session_id: sessionId,
    });

    return respond(200, {
      ok: true,
      code: "present",
      message: "Attendance marked successfully.",
      session_name: session.title,
      student_email: user.email,
      status: "Present",
      marked_at: nowIso,
    });
  }

  // --------------------------------------------------------------------------
  // Action: request_device_recovery
  // --------------------------------------------------------------------------
  if (action === "request_device_recovery") {
    const newDeviceId = typeof body.newDeviceId === "string" ? body.newDeviceId.trim() : "";
    const newPublicKeySpki = typeof body.newPublicKeySpki === "string" ? body.newPublicKeySpki.trim() : "";
    const reason = typeof body.reason === "string" ? body.reason.trim() : "";

    if (!newDeviceId || !newPublicKeySpki || reason.length < 5) {
      return respond(400, { ok: false, code: "invalid_parameters", message: "newDeviceId, newPublicKeySpki, and reason (min 5 chars) required." });
    }

    const { data: oldDevice } = await adminClient
      .from("student_devices")
      .select("device_id")
      .eq("student_id", user.id)
      .eq("status", "active")
      .maybeSingle();

    const { error: reqErr } = await adminClient.from("device_recovery_requests").insert({
      student_id: user.id,
      old_device_id: oldDevice?.device_id ?? null,
      new_device_id: newDeviceId,
      new_public_key_spki: newPublicKeySpki,
      reason,
      status: "pending",
    });

    if (reqErr) {
      return respond(500, { ok: false, code: "recovery_request_failed", message: reqErr.message });
    }

    await adminClient.from("auth_audit_logs").insert({
      event_type: "device_recovery_requested",
      student_id: user.id,
      device_id: newDeviceId,
      details: { reason },
    });

    return respond(200, {
      ok: true,
      message: "Device recovery request submitted successfully. A teacher or administrator will review it.",
    });
  }

  return respond(400, {
    ok: false,
    code: "unknown_action",
    message: `Unknown action: ${action}`,
  });
});
