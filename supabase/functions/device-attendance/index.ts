// device-attendance Edge Function
//
// Operations (POST JSON, user's Supabase access token in Authorization):
//   { operation: "issue_challenge", purpose: "register_device" }
//   { operation: "register_device", challenge_id, public_key, signature,
//     attestation_chain?, client_reported?, request_reason? }
//   { operation: "issue_challenge", purpose: "app_unlock", device_id }
//   { operation: "issue_challenge", purpose: "mark_attendance", device_id,
//     session_id, session_code, qr_code, ble_token }
//   { operation: "verify_challenge", challenge_id, signature }
//
// The service-role key never leaves this function. Every identity, device and
// session value comes from the verified JWT or the database, never from the
// client's say-so.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { summarizeAttestation, verifyDeviceSignature } from "./crypto.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const B64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

const respond = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const fail = (status: number, code: string, message: string) =>
  respond(status, { ok: false, code, message });

const optionalString = (value: unknown, max: number): string | null =>
  typeof value === "string" && value.length > 0 && value.length <= max
    ? value
    : null;

const uuidOrNull = (value: unknown): string | null =>
  typeof value === "string" && UUID_RE.test(value) ? value.toLowerCase() : null;

const sanitizeClientReported = (value: unknown): Record<string, unknown> => {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return {};
  const out: Record<string, unknown> = {};
  for (const [key, entry] of Object.entries(value).slice(0, 16)) {
    if (key.length > 40) continue;
    if (typeof entry === "string") out[key] = entry.slice(0, 120);
    else if (typeof entry === "number" || typeof entry === "boolean") out[key] = entry;
  }
  return out;
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "method_not_allowed", "Use POST.");

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY is not configured");
    return fail(500, "server_misconfigured", "The attendance server is not configured.");
  }

  const authorization = req.headers.get("Authorization") ?? "";
  const jwt = authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
  if (!jwt) return fail(401, "missing_authentication", "Authentication is required.");

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } = await admin.auth.getUser(jwt);
  const user = userData?.user;
  if (userError || !user) {
    return fail(401, "invalid_session", "Your session is invalid or expired. Please sign in again.");
  }

  let body: Record<string, unknown>;
  try {
    const parsed: unknown = await req.json();
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return fail(400, "invalid_request", "A JSON object is required.");
    }
    body = parsed as Record<string, unknown>;
  } catch {
    return fail(400, "invalid_json", "The request body must contain valid JSON.");
  }

  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await admin.rpc(fn, args);
    if (error) {
      console.error(`${fn} failed`, error.message);
      return null;
    }
    return data as Record<string, unknown>;
  };
  const rpcResponse = (data: Record<string, unknown> | null) =>
    data ? respond(200, data) : fail(500, "server_error", "The attendance server could not complete the request.");

  switch (body.operation) {
    case "issue_challenge": {
      const purpose = body.purpose;
      if (purpose !== "register_device" && purpose !== "app_unlock" && purpose !== "mark_attendance") {
        return fail(400, "invalid_purpose", "Unknown authentication purpose.");
      }
      return rpcResponse(await rpc("sdtt_issue_challenge", {
        p_user_id: user.id,
        p_purpose: purpose,
        p_device_id: purpose === "register_device" ? null : uuidOrNull(body.device_id),
        p_session_id: purpose === "mark_attendance" ? uuidOrNull(body.session_id) : null,
        p_session_code: purpose === "mark_attendance" ? optionalString(body.session_code, 6) : null,
        p_qr_code: purpose === "mark_attendance" ? optionalString(body.qr_code, 6) : null,
        p_ble_token: purpose === "mark_attendance" ? optionalString(body.ble_token, 12) : null,
      }));
    }

    case "register_device":
    case "verify_challenge": {
      const challengeId = uuidOrNull(body.challenge_id);
      const signature = optionalString(body.signature, 200);
      if (!challengeId || !signature || !B64_RE.test(signature)) {
        return fail(400, "invalid_request", "challenge_id and a base64 signature are required.");
      }

      const challenge = await rpc("sdtt_get_challenge", {
        p_user_id: user.id,
        p_challenge_id: challengeId,
      });
      if (!challenge) return fail(500, "server_error", "The attendance server could not complete the request.");
      if (challenge.ok !== true) return respond(200, challenge);

      const isRegistration = challenge.purpose === "register_device";
      if (isRegistration !== (body.operation === "register_device")) {
        return fail(400, "wrong_operation", "This challenge belongs to a different operation.");
      }

      let publicKey: string | null;
      let registration: Record<string, unknown> | null = null;
      if (isRegistration) {
        publicKey = optionalString(body.public_key, 400);
        if (!publicKey || !B64_RE.test(publicKey)) {
          return fail(400, "invalid_public_key", "A base64 X.509 public key is required.");
        }
        const roots = (Deno.env.get("ANDROID_ATTESTATION_ROOT_SPKI_SHA256") ?? "")
          .split(",").filter((v) => v.trim().length > 0);
        const attestation = await summarizeAttestation(
          body.attestation_chain, publicKey, String(challenge.nonce), roots);
        if (Deno.env.get("REQUIRE_KEY_ATTESTATION") === "true" && !attestation.trusted) {
          const result = await rpc("sdtt_complete_challenge", {
            p_user_id: user.id,
            p_challenge_id: challengeId,
            p_signature_valid: false,
            p_failure_detail: "untrusted attestation: " + attestation.errors.join("; "),
          });
          if (!result) return fail(500, "server_error", "The attendance server could not complete the request.");
          return fail(200, "attestation_failed",
            "This phone could not prove its key is protected by secure hardware.");
        }
        registration = {
          public_key_spki: publicKey,
          attestation_chain: Array.isArray(body.attestation_chain)
            ? body.attestation_chain.slice(0, 10) : [],
          attestation_summary: attestation,
          client_reported: sanitizeClientReported(body.client_reported),
          request_reason: optionalString(body.request_reason, 200) ?? "new_device",
        };
      } else {
        publicKey = typeof challenge.public_key_spki === "string" ? challenge.public_key_spki : null;
      }

      const verification = publicKey
        ? await verifyDeviceSignature(publicKey, signature, String(challenge.signing_payload))
        : { valid: false, detail: "no registered public key" };

      return rpcResponse(await rpc("sdtt_complete_challenge", {
        p_user_id: user.id,
        p_challenge_id: challengeId,
        p_signature_valid: verification.valid,
        p_failure_detail: verification.detail ?? null,
        p_registration: registration,
      }));
    }

    default:
      return fail(400, "invalid_operation", "Unknown operation.");
  }
});
