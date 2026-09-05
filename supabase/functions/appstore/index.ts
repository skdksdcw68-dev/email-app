// What Apple says was bought, turned into an entitlement.
//
// 🔴 This function did not exist, and `Store.swift` has been posting to it
// since StoreKit was added. The post is a `try?`, so the 404 was swallowed
// and `transaction.finish()` ran regardless -- and a finished consumable is
// never redelivered by Apple. Every credit pack bought was money taken for
// nothing, unrecoverable, and `entitlements` had no writer of any kind, so
// every account's effective plan was `free` however much they paid.
//
// ## Two callers, one verification
//
//   * **The app**, right after a purchase, posting `{ signedTransaction }`.
//     Not because it is trusted -- it is not -- but because Apple's own
//     notification usually lands "within seconds", and "usually" is not what
//     somebody who has just paid should experience.
//   * **Apple**, posting `{ signedPayload }` for every renewal, lapse, grace
//     period, refund and revocation for the life of the subscription. This is
//     the one that matters: the app is not running when a renewal happens.
//
// Both are JWS signed by Apple. Nothing else is trusted, including the app's
// bearer token -- see `resolveUser`.
//
// ## ⚠️ Deployed with `--no-verify-jwt`, deliberately
//
// Apple cannot present a Supabase JWT. The authentication here is Apple's
// signature over the payload, checked against a pinned Apple Root CA - G3, and
// that is stronger than a platform JWT check would have been: a valid JWT only
// proves somebody is signed in, while a valid chain proves Apple itself said
// this purchase happened.
//
// 🔴 This exemption is for this function only. `ai` must never be deployed
// that way -- it spends money per call and its caller identity *is* the JWT.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BUNDLE_ID = "com.netro.maily";

// Apple Root CA - G3, DER, base64. The chain must end here.
//
// Pinned as whole bytes rather than a fingerprint on purpose: a fingerprint is
// 64 characters that have to be transcribed correctly and cannot be checked by
// reading them. These bytes came out of
// https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
const APPLE_ROOT_G3 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9v" +
  "dCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UE" +
  "CgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2" +
  "WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmlj" +
  "YXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqG" +
  "SM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxE" +
  "tX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNC" +
  "MEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0P" +
  "AQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3m" +
  "eoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkL" +
  "F1vLUagM6BgD56KyKA==";

// ---------------------------------------------------------------------------
// Products
// ---------------------------------------------------------------------------

function planFor(productID: string): "pro" | "max" | null {
  if (productID.includes(".max.")) return "max";
  if (productID.includes(".pro.")) return "pro";
  return null;
}

// How much *provider cost* a credit pack grants, in dollars.
//
// ⚠️ Not the price. Like `Plan.monthlyAllowanceUSD` on the client, these are
// what Maily is willing to spend at OpenAI on somebody's behalf, and they hold
// the same margin as Pro does: $14.99 -> $12.74 after Apple's 15% -> $6 of
// allowance, a shade over half.
//
//     small   assumes $4.99  ->  $4.24 net  ->  $2 granted
//     large   assumes $9.99  ->  $8.49 net  ->  $4 granted
//
// 🔴 If the App Store prices differ from those, these numbers are wrong and
// nothing will say so. They are the one figure here that is a decision rather
// than something Apple told us.
const CREDIT_PACKS: Record<string, number> = {
  "com.netro.maily.credits.small": 2,
  "com.netro.maily.credits.large": 4,
};

// ---------------------------------------------------------------------------
// DER, just enough of it
// ---------------------------------------------------------------------------
//
// An X.509 chain check needs four things out of a certificate: the bytes that
// were signed, the signature, the algorithm, and the public key. A full ASN.1
// library is not needed for that, and pulling one from npm into an edge
// function is a bundling risk taken for a hundred lines.

interface TLV {
  tag: number;
  start: number;
  contentStart: number;
  end: number;
}

function readTLV(buf: Uint8Array, off: number): TLV {
  const tag = buf[off];
  let i = off + 1;
  let len = buf[i++];
  if (len & 0x80) {
    const count = len & 0x7f;
    // Nothing in a certificate is four gigabytes long; a length claiming to be
    // is a malformed input, not something to allocate for.
    if (count === 0 || count > 4) throw new Error("bad DER length");
    len = 0;
    for (let k = 0; k < count; k++) len = len * 256 + buf[i++];
  }
  const end = i + len;
  if (end > buf.length) throw new Error("DER runs past the end");
  return { tag, start: off, contentStart: i, end };
}

/// An OID's content bytes as the usual dotted string.
function oid(buf: Uint8Array, tlv: TLV): string {
  const bytes = buf.subarray(tlv.contentStart, tlv.end);
  const parts: number[] = [Math.floor(bytes[0] / 40), bytes[0] % 40];
  let value = 0;
  for (let i = 1; i < bytes.length; i++) {
    value = value * 128 + (bytes[i] & 0x7f);
    if ((bytes[i] & 0x80) === 0) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

interface Cert {
  der: Uint8Array;
  tbs: Uint8Array;
  /// The signature *over* this certificate, made by its issuer.
  signature: Uint8Array;
  signatureAlgorithm: string;
  spki: Uint8Array;
  notBefore: Date;
  notAfter: Date;
}

function parseTime(buf: Uint8Array, tlv: TLV): Date {
  const text = new TextDecoder().decode(buf.subarray(tlv.contentStart, tlv.end));
  // UTCTime is YYMMDDHHMMSSZ with the century implied; GeneralizedTime spells
  // the year out. Apple's roots run to 2039, so the RFC 5280 pivot at 50 is
  // the right one and will not be reached by anything we see.
  if (tlv.tag === 0x17) {
    const yy = Number(text.slice(0, 2));
    const year = yy >= 50 ? 1900 + yy : 2000 + yy;
    return new Date(Date.UTC(
      year, Number(text.slice(2, 4)) - 1, Number(text.slice(4, 6)),
      Number(text.slice(6, 8)), Number(text.slice(8, 10)), Number(text.slice(10, 12)),
    ));
  }
  return new Date(Date.UTC(
    Number(text.slice(0, 4)), Number(text.slice(4, 6)) - 1, Number(text.slice(6, 8)),
    Number(text.slice(8, 10)), Number(text.slice(10, 12)), Number(text.slice(12, 14)),
  ));
}

function parseCert(der: Uint8Array): Cert {
  const outer = readTLV(der, 0);
  const tbs = readTLV(der, outer.contentStart);
  const algorithm = readTLV(der, tbs.end);
  const signature = readTLV(der, algorithm.end);

  // The BIT STRING's first content byte counts unused trailing bits, and is
  // always zero here. It is not part of the signature.
  const signatureBytes = der.subarray(signature.contentStart + 1, signature.end);

  // Walk the TBS to the two fields that are needed. Order is fixed by the
  // ASN.1 module, so this is positional rather than a search.
  let p = tbs.contentStart;
  const first = readTLV(der, p);
  if (first.tag === 0xa0) p = first.end; // [0] version, optional
  p = readTLV(der, p).end;               // serialNumber
  p = readTLV(der, p).end;               // signature algorithm
  p = readTLV(der, p).end;               // issuer
  const validity = readTLV(der, p);
  p = validity.end;
  p = readTLV(der, p).end;               // subject
  const spki = readTLV(der, p);

  const notBefore = readTLV(der, validity.contentStart);
  const notAfter = readTLV(der, notBefore.end);

  return {
    der,
    tbs: der.subarray(tbs.start, tbs.end),
    signature: signatureBytes,
    signatureAlgorithm: oid(der, readTLV(der, algorithm.contentStart)),
    spki: der.subarray(spki.start, spki.end),
    notBefore: parseTime(der, notBefore),
    notAfter: parseTime(der, notAfter),
  };
}

// ---------------------------------------------------------------------------
// Signatures
// ---------------------------------------------------------------------------

const ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const ECDSA_SHA384 = "1.2.840.10045.4.3.3";

/// X.509 wraps an ECDSA signature as `SEQUENCE { INTEGER r, INTEGER s }`.
/// WebCrypto wants the two halves raw and fixed-width, so the DER integers
/// have to be stripped of their sign padding and re-padded to the curve size.
function ecdsaDerToRaw(der: Uint8Array, size: number): Uint8Array {
  const seq = readTLV(der, 0);
  const r = readTLV(der, seq.contentStart);
  const s = readTLV(der, r.end);

  const out = new Uint8Array(size * 2);
  for (const [tlv, offset] of [[r, 0], [s, size]] as const) {
    let bytes = der.subarray(tlv.contentStart, tlv.end);
    // A leading zero is DER saying "this is positive, not negative".
    while (bytes.length > size && bytes[0] === 0) bytes = bytes.subarray(1);
    if (bytes.length > size) throw new Error("ECDSA component too long");
    out.set(bytes, offset + size - bytes.length);
  }
  return out;
}

async function importPublicKey(spki: Uint8Array): Promise<{ key: CryptoKey; size: number }> {
  // The curve is in the SPKI, but asking WebCrypto to tell us means parsing
  // more ASN.1 for an answer it already has. Two candidates, and Apple uses
  // both -- P-256 for leaves, P-384 for the roots.
  for (const [namedCurve, size] of [["P-256", 32], ["P-384", 48]] as const) {
    try {
      const key = await crypto.subtle.importKey(
        "spki",
        spki as BufferSource,
        { name: "ECDSA", namedCurve },
        false,
        ["verify"],
      );
      return { key, size };
    } catch {
      continue;
    }
  }
  throw new Error("unsupported public key");
}

async function verifySignature(
  issuerSPKI: Uint8Array,
  algorithm: string,
  signature: Uint8Array,
  signed: Uint8Array,
): Promise<boolean> {
  const hash = algorithm === ECDSA_SHA384
    ? "SHA-384"
    : algorithm === ECDSA_SHA256
    ? "SHA-256"
    : null;
  // 🔴 Anything else is refused rather than guessed at. An unrecognised
  // algorithm treated as a default is how a signature check becomes decorative.
  if (!hash) return false;

  const { key, size } = await importPublicKey(issuerSPKI);
  return await crypto.subtle.verify(
    { name: "ECDSA", hash },
    key,
    ecdsaDerToRaw(signature, size) as BufferSource,
    signed as BufferSource,
  );
}

function base64ToBytes(text: string): Uint8Array {
  const binary = atob(text);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function base64UrlToBytes(text: string): Uint8Array {
  return base64ToBytes(text.replace(/-/g, "+").replace(/_/g, "/"));
}

/// Verifies one of Apple's JWS payloads and returns what it says.
///
/// Three checks, and all three matter:
///
///   1. the chain ends at the pinned Apple root -- without this, anybody can
///      sign a payload with a certificate chain of their own making;
///   2. each certificate really was signed by the next one up -- without this,
///      the pinned root is decoration and the leaf can claim any issuer;
///   3. the JWS itself was signed by the leaf.
async function verifyJWS<T>(jws: string): Promise<T> {
  const parts = jws.split(".");
  if (parts.length !== 3) throw new Error("not a JWS");

  const header = JSON.parse(new TextDecoder().decode(base64UrlToBytes(parts[0])));
  const chain: string[] = header.x5c ?? [];
  if (chain.length < 2) throw new Error("no certificate chain");

  const certs = chain.map((c) => parseCert(base64ToBytes(c)));

  // 1. The root.
  const root = certs[certs.length - 1];
  const pinned = base64ToBytes(APPLE_ROOT_G3);
  if (root.der.length !== pinned.length || !root.der.every((b, i) => b === pinned[i])) {
    throw new Error("chain does not end at Apple Root CA - G3");
  }

  const now = Date.now();
  for (const cert of certs) {
    if (now < cert.notBefore.getTime() || now > cert.notAfter.getTime()) {
      throw new Error("certificate out of date");
    }
  }

  // 2. Each link.
  for (let i = 0; i < certs.length - 1; i++) {
    const ok = await verifySignature(
      certs[i + 1].spki,
      certs[i].signatureAlgorithm,
      certs[i].signature,
      certs[i].tbs,
    );
    if (!ok) throw new Error(`certificate ${i} is not signed by its issuer`);
  }

  // 3. The payload. ES256 is the only algorithm Apple uses here.
  if (header.alg !== "ES256") throw new Error(`unexpected alg ${header.alg}`);
  const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const { key } = await importPublicKey(certs[0].spki);
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    base64UrlToBytes(parts[2]) as BufferSource,
    signed as BufferSource,
  );
  if (!ok) throw new Error("payload signature does not verify");

  return JSON.parse(new TextDecoder().decode(base64UrlToBytes(parts[1]))) as T;
}

// ---------------------------------------------------------------------------
// Apple's payloads
// ---------------------------------------------------------------------------

interface TransactionInfo {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  type?: string;
  appAccountToken?: string;
  expiresDate?: number;
  revocationDate?: number;
  purchaseDate?: number;
}

interface RenewalInfo {
  autoRenewStatus?: number;
  gracePeriodExpiresDate?: number;
  isInBillingRetryPeriod?: boolean;
  expirationIntent?: number;
}

interface Notification {
  notificationType: string;
  subtype?: string;
  data?: {
    bundleId?: string;
    signedTransactionInfo?: string;
    signedRenewalInfo?: string;
  };
}

/// Whether money actually moved, which decides whether ownership may
/// re-anchor. A restore never lapses anything, so it never re-anchors.
function isPaidEvent(type: string | null, subtype: string | undefined): boolean {
  if (!type) return false;
  if (type === "DID_RENEW") return true;
  if (type === "SUBSCRIBED") return true; // INITIAL_BUY and RESUBSCRIBE
  if (type === "OFFER_REDEEMED") return true;
  if (type === "DID_CHANGE_RENEWAL_PREF" && subtype === "UPGRADE") return true;
  return false;
}

// ---------------------------------------------------------------------------
// Who it belongs to
// ---------------------------------------------------------------------------

async function postgrest(path: string, init: RequestInit): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
}

/// Which Maily account this purchase belongs to.
///
/// 🔴 In this order, and the order is the security.
///
///   1. `appAccountToken` -- set by the app at the moment of purchase, carried
///      by Apple through every renewal, and signed. It is the only one of the
///      three that works for a notification arriving at three in the morning
///      with no app running and no session to read.
///   2. An existing row with the same `original_transaction_id`. A renewal of
///      something already known.
///   3. The bearer token, and *only* for a receipt the app posted. Last
///      because it is the only one Apple did not sign -- anybody with an
///      account can present a token. On its own it proves who is asking, never
///      what they bought, which is why it decides nothing until the receipt
///      has already been verified.
async function resolveUser(
  info: TransactionInfo,
  bearer: string | null,
): Promise<string | null> {
  // Checked for shape before it is trusted as an id. It arrives signed, so it
  // is what the app sent -- and the app can be made to send anything.
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (info.appAccountToken && uuid.test(info.appAccountToken)) {
    return info.appAccountToken.toLowerCase();
  }

  if (info.originalTransactionId) {
    const response = await postgrest(
      `entitlements?original_transaction_id=eq.${encodeURIComponent(info.originalTransactionId)}&select=user_id`,
      { method: "GET" },
    );
    if (response.ok) {
      const rows = await response.json();
      if (Array.isArray(rows) && rows[0]?.user_id) return rows[0].user_id;
    }
  }

  if (bearer) {
    // The token's own claim about itself, checked against Supabase rather than
    // decoded here -- an unverified JWT body is a string somebody typed.
    const response = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SERVICE_ROLE, Authorization: `Bearer ${bearer}` },
    });
    if (response.ok) {
      const user = await response.json();
      if (user?.id) return user.id as string;
    }
  }

  return null;
}

// ---------------------------------------------------------------------------
// Applying it
// ---------------------------------------------------------------------------

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function apply(
  info: TransactionInfo,
  renewal: RenewalInfo | null,
  paid: boolean,
  bearer: string | null,
  revoked: boolean,
): Promise<Response> {
  // ⚠️ Checked, not assumed. A perfectly valid Apple receipt for a different
  // app is still a valid Apple receipt.
  if (info.bundleId && info.bundleId !== BUNDLE_ID) {
    return json({ error: "wrong app" }, 400);
  }

  const userId = await resolveUser(info, bearer);
  if (!userId) {
    // Nothing to write it against. Apple retries notifications for days, and
    // a 500 is what asks it to -- by then the purchase will usually have been
    // posted by the app, which knows who is signed in.
    return json({ error: "no account for this purchase" }, 500);
  }

  const credit = CREDIT_PACKS[info.productId];
  const plan = planFor(info.productId);
  const kind = credit !== undefined ? "credit" : "subscription";

  if (kind === "subscription" && !plan) {
    return json({ error: "unknown product" }, 400);
  }

  // Grace is still paid access: somebody whose card failed this morning has
  // not stopped being a customer, and Apple keeps trying for days.
  const inGrace = Boolean(renewal?.isInBillingRetryPeriod) ||
    (renewal?.gracePeriodExpiresDate ?? 0) > Date.now();

  // A refunded credit pack takes the credit back, and needs its own row in the
  // ledger to do it: the purchase already claimed `transactionId`, so a refund
  // reusing that key would be read as a duplicate and silently ignored. One
  // suffix, and the deduction lands exactly once however many times Apple
  // resends the refund.
  const refundingCredit = kind === "credit" && revoked;
  const transactionKey = refundingCredit
    ? `${info.transactionId}:refund`
    : info.transactionId;

  const response = await postgrest("rpc/apply_appstore_transaction", {
    method: "POST",
    body: JSON.stringify({
      p_user_id: userId,
      p_transaction_id: transactionKey,
      p_original_transaction_id: info.originalTransactionId ?? null,
      p_product_id: info.productId,
      p_kind: kind,
      p_plan: plan,
      p_expires_at: info.expiresDate ? new Date(info.expiresDate).toISOString() : null,
      p_is_in_grace: inGrace,
      p_revoked: revoked,
      p_credit_usd: refundingCredit ? -(credit ?? 0) : (credit ?? 0),
      p_paid: paid,
    }),
  });

  if (!response.ok) {
    const detail = await response.text();
    console.error("apply_appstore_transaction failed", response.status, detail);
    // 5xx so Apple retries. A dropped notification is a subscription that
    // silently stops working at the next renewal.
    return json({ error: "could not record" }, 500);
  }

  const verdict = await response.json();
  console.log("appstore", info.productId, kind, JSON.stringify(verdict));

  // `other_account` is a definite answer, not a failure -- somebody else owns
  // this subscription. Retrying will not change it, so it is a 200 with the
  // verdict rather than a 5xx that makes Apple try for three days.
  return json(verdict);
}

// ---------------------------------------------------------------------------

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  if (!SUPABASE_URL || !SERVICE_ROLE) {
    console.error("appstore is missing its service role configuration");
    return json({ error: "not configured" }, 500);
  }

  let body: { signedPayload?: string; signedTransaction?: string };
  try {
    body = await request.json();
  } catch {
    return json({ error: "bad body" }, 400);
  }

  const authorization = request.headers.get("Authorization") ?? "";
  const bearer = authorization.startsWith("Bearer ")
    ? authorization.slice(7)
    : null;

  try {
    // Apple's server notification.
    if (body.signedPayload) {
      const notification = await verifyJWS<Notification>(body.signedPayload);
      const signedTransaction = notification.data?.signedTransactionInfo;
      if (!signedTransaction) {
        // Notifications with no transaction -- a test ping, a consumption
        // request -- are acknowledged rather than retried forever.
        console.log("appstore notification with no transaction", notification.notificationType);
        return json({ ok: true, ignored: notification.notificationType });
      }

      const info = await verifyJWS<TransactionInfo>(signedTransaction);
      const renewal = notification.data?.signedRenewalInfo
        ? await verifyJWS<RenewalInfo>(notification.data.signedRenewalInfo)
        : null;

      const revoked = notification.notificationType === "REFUND" ||
        notification.notificationType === "REVOKE" ||
        (notification.notificationType === "EXPIRED");

      return await apply(
        info,
        renewal,
        isPaidEvent(notification.notificationType, notification.subtype),
        // 🔴 Apple's own POST carries no session. Passing a bearer here would
        // mean a stranger's notification could be attributed to whoever last
        // called this function.
        null,
        revoked,
      );
    }

    // The app, immediately after a purchase or a restore.
    if (body.signedTransaction) {
      const info = await verifyJWS<TransactionInfo>(body.signedTransaction);

      // ⚠️ `paid` is decided here rather than taken from the app. A purchase
      // made in the last ten minutes is a purchase; anything older is a
      // receipt being re-presented, which is a restore however it is labelled.
      // Ownership can only re-anchor on the first kind, and only when the
      // current owner has genuinely lapsed -- so the worst a wrong answer here
      // can do is hand somebody an entitlement that has already expired.
      const age = Date.now() - (info.purchaseDate ?? 0);
      const paid = age >= 0 && age < 10 * 60 * 1000;

      const revoked = Boolean(info.revocationDate);
      return await apply(info, null, paid, bearer, revoked);
    }

    return json({ error: "nothing to verify" }, 400);
  } catch (error) {
    // 🔴 A signature that does not verify is refused, and refused with a 400
    // so Apple does not retry it. There is no path here that writes an
    // entitlement from a payload that failed this check.
    console.error("appstore verification failed", String(error));
    return json({ error: "could not verify" }, 400);
  }
});
