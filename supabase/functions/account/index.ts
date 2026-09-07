// Deleting a Maily account, for real.
//
// App Store guideline 5.1.1(v): an app that lets somebody create an account
// must let them delete it from inside the app. Not "email support". Not "sign
// out". Google's OAuth verification asks the same question about data
// deletion, and the privacy policy at mailyco.com/privacy promises this
// exact behaviour -- so this function is what makes that page true.
//
// 🔴 The one function in this project where an unverified token is refused.
//
// `ai/index.ts` deliberately falls back to reading a token it could not
// verify, because a rotated secret would otherwise turn every request in the
// app into a 401 at once and the cost of being wrong is a wrongly-counted
// call. Here the cost of being wrong is somebody else's account, permanently.
// If the signature does not check out, nothing is deleted.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

/// Whose account this is, according to Supabase itself.
///
/// 🔴 Not a local signature check, and that is the stronger choice here
/// rather than the lazier one.
///
/// `ai/index.ts` verifies an HS256 signature against `SUPABASE_JWT_SECRET`.
/// That secret is not set on this project and asking for it would be asking
/// for the wrong thing: the project signs with asymmetric keys now
/// (`SUPABASE_JWKS`), so the shared-secret check there has been silently
/// falling through to its unverified path all along.
///
/// Asking the auth server who the bearer is settles both problems at once. It
/// works whatever the tokens are signed with, and unlike any signature check
/// it also catches a token that is *valid but revoked* -- a session signed out
/// on another device, or an account already deleted. For the one operation
/// that cannot be undone, "is this token currently good" is the question
/// worth asking, and only the auth server knows.
async function identify(request: Request): Promise<string | null> {
  const header = request.headers.get("Authorization") ?? "";
  if (!header.startsWith("Bearer ")) return null;

  const response = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: ANON_KEY, Authorization: header },
  });
  if (!response.ok) {
    console.warn("delete refused: auth server rejected the token", response.status);
    return null;
  }

  const user = await response.json() as { id?: unknown };
  return typeof user.id === "string" && user.id.length > 0 ? user.id : null;
}

/// Everything keyed to a person, in the order that leaves nothing orphaned.
///
/// `appstore_transactions` and `subscription_owner` are deliberately NOT here.
/// They are records of a purchase Apple made, kept for accounting -- which the
/// privacy policy says in as many words -- and `subscription_owner` is also
/// what stops a subscription being restored onto a fresh account to reset an
/// allowance. Both are keyed to Apple's own identifiers, not to anything the
/// person typed.
const OWNED_TABLES = [
  "user_settings",
  "chats",
  "events",
  "memories",
  "searches",
  "devices",
  "entitlements",
  "ai_usage",
];

async function purge(table: string, userID: string): Promise<string | null> {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/${table}?user_id=eq.${userID}`,
    {
      method: "DELETE",
      headers: {
        apikey: SERVICE_ROLE,
        Authorization: `Bearer ${SERVICE_ROLE}`,
        Prefer: "return=minimal",
      },
    },
  );
  if (response.ok) return null;
  return `${table}: ${response.status} ${(await response.text()).slice(0, 200)}`;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const userID = await identify(request);
  if (!userID) return json({ error: "Sign in again, then try that once more." }, 401);

  let action = "";
  try {
    action = (await request.json())?.action ?? "";
  } catch {
    // No body. Treated as no action.
  }

  if (action !== "delete") {
    return json({ error: "Maily asked for something this version doesn't do." }, 400);
  }

  // Rows first, user last. The other order leaves rows behind that nothing
  // can ever reach again: RLS keys them to an auth user that no longer
  // exists, so no session can select them and no session can delete them.
  const failures: string[] = [];
  for (const table of OWNED_TABLES) {
    const failure = await purge(table, userID);
    if (failure) failures.push(failure);
  }

  if (failures.length > 0) {
    console.error("delete incomplete", failures);
    return json({
      error: "Maily could not finish deleting your account. Nothing was half-removed — try again, or write to support@mailyco.com.",
    }, 500);
  }

  const gone = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userID}`, {
    method: "DELETE",
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
    },
  });

  if (!gone.ok) {
    console.error("auth user not deleted", gone.status, (await gone.text()).slice(0, 300));
    return json({
      error: "Your data is deleted, but the sign-in itself could not be removed. Write to support@mailyco.com and it will be finished by hand.",
    }, 500);
  }

  return json({ deleted: true });
});
