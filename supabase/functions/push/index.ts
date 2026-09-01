// Gmail told Pub/Sub something changed. Tell the phone to go and look.
//
// This function never sees an email. Gmail's notification carries an address
// and a history id and nothing else, and that is all that goes on to APNs.
// The phone fetches the message with its own credentials and writes its own
// notification, so the sender and the subject never leave the device even
// though they end up on its lock screen.
//
// That is a deliberate position, not an accident of the design: Maily holds
// Gmail restricted scopes, and every server that reads mail is a server a
// security assessment has to cover.

import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

const APNS_KEY = Deno.env.get("APNS_KEY");
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID");
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID");
const APNS_TOPIC = Deno.env.get("APNS_TOPIC");

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const HOSTS: Record<string, string> = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

interface Device {
  token: string;
  environment: string;
}

// APNs takes a signed token rather than a certificate, and the same one is
// good for an hour. Minting one per notification would be a needless ECDSA
// signature on every email that arrives.
let cachedToken: { value: string; expires: number } | null = null;

async function providerToken(): Promise<string> {
  const now = Date.now();
  if (cachedToken && cachedToken.expires > now) return cachedToken.value;

  if (!APNS_KEY || !APNS_KEY_ID || !APNS_TEAM_ID) {
    throw new Error("APNs is not configured on this project.");
  }

  // The .p8 is PEM. WebCrypto wants the DER inside it.
  const der = Uint8Array.from(
    atob(APNS_KEY.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "")),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const jwt = await create(
    { alg: "ES256", kid: APNS_KEY_ID },
    { iss: APNS_TEAM_ID, iat: getNumericDate(0) },
    key,
  );

  // Apple rejects a token older than an hour and refuses one minted more than
  // once every twenty minutes, so fifty minutes sits comfortably between.
  cachedToken = { value: jwt, expires: now + 50 * 60 * 1000 };
  return jwt;
}

async function devices(address: string): Promise<Device[]> {
  if (!SUPABASE_URL || !SERVICE_ROLE) return [];

  // Service role, because Pub/Sub is not a signed-in user and there is no
  // session to scope this by. The address is the only thing it may look up.
  const url = new URL(`${SUPABASE_URL}/rest/v1/devices`);
  url.searchParams.set("select", "token,environment");
  url.searchParams.set("gmail_address", `eq.${address.toLowerCase()}`);

  const response = await fetch(url, {
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
    },
  });
  if (!response.ok) return [];
  return await response.json();
}

async function forget(token: string) {
  if (!SUPABASE_URL || !SERVICE_ROLE) return;
  const url = new URL(`${SUPABASE_URL}/rest/v1/devices`);
  url.searchParams.set("token", `eq.${token}`);
  await fetch(url, {
    method: "DELETE",
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
    },
  });
}

/// One silent push. No alert, because the phone writes its own once it knows
/// what arrived.
async function notify(device: Device, historyId: string, jwt: string) {
  const host = HOSTS[device.environment] ?? HOSTS.production;

  const response = await fetch(`${host}/3/device/${device.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": APNS_TOPIC ?? "",
      "apns-push-type": "background",
      // Background pushes must be priority 5. Apple rejects 10 outright.
      "apns-priority": "5",
      "apns-expiration": "0",
    },
    body: JSON.stringify({
      aps: { "content-available": 1 },
      historyId,
    }),
  });

  if (response.ok) return;

  const reason = await response.text();
  // The app was deleted, or the token was reissued. Keeping it means
  // pushing into the void on every email from now on.
  if (response.status === 410 || reason.includes("BadDeviceToken")) {
    await forget(device.token);
  }
  console.error(`APNs ${response.status} for ${device.token.slice(0, 8)}…: ${reason}`);
}

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return new Response("ok", { status: 200 });
  }

  try {
    const body = await request.json();

    // Pub/Sub wraps the payload: { message: { data: <base64 json> } }.
    const encoded = body?.message?.data;
    if (!encoded) return new Response("no data", { status: 200 });

    const notice = JSON.parse(atob(encoded));
    const address = String(notice.emailAddress ?? "");
    const historyId = String(notice.historyId ?? "");
    if (!address) return new Response("no address", { status: 200 });

    const targets = await devices(address);
    if (targets.length === 0) return new Response("no devices", { status: 200 });

    const jwt = await providerToken();
    await Promise.all(targets.map((device) => notify(device, historyId, jwt)));

    return new Response("ok", { status: 200 });
  } catch (error) {
    // Always 200. A non-2xx tells Pub/Sub to redeliver, and a payload this
    // function cannot parse will fail again every time: that is a retry loop
    // costing money to achieve nothing.
    console.error("push failed:", error instanceof Error ? error.message : error);
    return new Response("ok", { status: 200 });
  }
});
