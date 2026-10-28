
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

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
    return respond(405, {
      ok: false,
      code: "method_not_allowed",
      message: "Use POST.",
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const authorization = req.headers.get("Authorization");

  if (!supabaseUrl || !supabaseAnonKey || !authorization) {
    return respond(401, {
      ok: false,
      code: "missing_authentication",
      message: "Authentication is required.",
    });
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } },
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });

  const { data: { user }, error } = await supabase.auth.getUser();

  if (error || !user) {
    return respond(401, {
      ok: false,
      code: "invalid_session",
      message: "Your session is invalid or expired. Please sign in again.",
    });
  }

  let body: Record<string, unknown>;

  try {
    const parsed: unknown = await req.json();

    if (
      typeof parsed !== "object" ||
      parsed === null ||
      Array.isArray(parsed)
    ) {
      return respond(400, {
        ok: false,
        code: "invalid_request",
        message: "A JSON object is required.",
      });
    }

    body = parsed as Record<string, unknown>;
  } catch {
    return respond(400, {
      ok: false,
      code: "invalid_json",
      message: "The request body must contain valid JSON.",
    });
  }

  // Intentionally do not mark attendance here.
  // Device enrollment and signed-challenge verification must be
  // implemented before this endpoint can authorize attendance.

  return respond(501, {
    ok: false,
    code: "device_verification_not_implemented",
    message:
      "Authentication succeeded, but device verification is not implemented yet.",
    user_id: user.id,
    received_operation:
      typeof body.operation === "string" ? body.operation : null,
  });
});

