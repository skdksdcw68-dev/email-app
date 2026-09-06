// Sender logos, resolved on the server so the phone never has to.
//
// 🔴 This is the whole fix, and it is an architecture change rather than
// another source.
//
// Maily used to resolve a logo on the device, per row, while somebody was
// scrolling: a DNS lookup for BIMI, then an apple-touch-icon fetch, then a
// favicon fetch. Four round trips per newsletter, on every device, for every
// user, forever -- so rows filled in one at a time, out of order, and some
// never arrived. Gmail and Shortwave do none of that on the phone. They
// resolve on a server, once, for everybody, and ship a URL with the message
// list.
//
// So: one POST with the domains on screen, one answer with a URL each, and the
// phone's only remaining job is to download a picture.
//
// ## Two routes
//
//   POST /logos            { domains: [...] } -> { "tiktok.com": {...}, ... }
//   GET  /logos/img/<dom>  the rasterised PNG, for BIMI logos only
//
// The second exists because BIMI logos are **always** SVG -- the standard
// mandates SVG Tiny PS -- and no phone can draw one. It is rasterised here,
// once, and stored beside the row.
//
// ⚠️ Deployed with `--no-verify-jwt`: `GET /img/...` is a plain image URL that
// has to work in any image loader, and there is nothing to protect. A domain
// is the entire input and the entire output. No user id, no message, nothing
// about who asked -- see the note on the table.


const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

/// A found logo is good for three months; a miss is retried after two weeks,
/// because a company that had no logo last year may have published one since.
const FRESH_DAYS = 90;
const MISS_DAYS = 14;

/// Below this an icon is a blurry smear in an avatar circle and a letter is
/// the better answer.
const MIN_PIXELS = 32;
/// Good enough to stop climbing the ladder.
const GOOD_PIXELS = 120;

/// One request must not be able to make the server do unbounded work.
const MAX_DOMAINS = 60;

/// How long a request waits for cold domains before answering with what it
/// has. The rest keep resolving after the response and are in the table for
/// the phone's retry ten seconds later.
const ANSWER_WITHIN_MS = 12_000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

// ---------------------------------------------------------------------------
// Domains
// ---------------------------------------------------------------------------

/// Suffixes that are two labels long, so the organisation is third from the
/// end. Not the full Public Suffix List -- these are the ones that turn up in
/// mail, and anything missed keeps a subdomain, which is merely the old
/// behaviour rather than a new failure.
const TWO_LABEL = new Set([
  "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "co.jp", "or.jp", "ne.jp",
  "ac.jp", "co.kr", "com.au", "net.au", "org.au", "edu.au", "co.nz", "com.br",
  "com.mx", "com.ar", "com.tr", "com.cn", "com.hk", "com.sg", "com.tw",
  "co.in", "co.za", "com.et", "org.et", "edu.et",
]);

/// 🔴 The single most valuable line in this file.
///
/// Companies do not send newsletters from their homepage. They send from
/// `e.tiktok.com`, `notifications.github.com`, `mail.whatever.com` -- and
/// every icon service on earth answers 404 for those, which is why the most
/// common kind of message in an inbox had no logo at all.
function organisation(host: string): string {
  const labels = host.toLowerCase().split(".").filter(Boolean);
  if (labels.length <= 2) return labels.join(".");
  const lastTwo = labels.slice(-2).join(".");
  const keep = TWO_LABEL.has(lastTwo) ? 3 : 2;
  return labels.slice(-keep).join(".");
}

/// Rejected rather than looked up: anything that is not plausibly a hostname
/// is either a bug upstream or somebody probing.
function isSaneDomain(domain: string): boolean {
  return /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(domain) &&
    domain.length <= 253;
}

// ---------------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------------

async function postgrest(path: string, init: RequestInit = {}): Promise<Response> {
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

interface Stored {
  domain: string;
  url: string | null;
  source: string | null;
  width: number | null;
  missing: boolean;
  resolved_at: string;
}

async function read(domains: string[]): Promise<Map<string, Stored>> {
  const list = domains.map((d) => `"${d}"`).join(",");
  const response = await postgrest(
    `brand_logos?domain=in.(${list})&select=domain,url,source,width,missing,resolved_at`,
  );
  if (!response.ok) return new Map();
  const rows: Stored[] = await response.json();
  return new Map(rows.map((r) => [r.domain, r]));
}

function isStale(row: Stored): boolean {
  const age = Date.now() - new Date(row.resolved_at).getTime();
  const days = row.missing ? MISS_DAYS : FRESH_DAYS;
  return age > days * 24 * 60 * 60 * 1000;
}

async function write(
  domain: string,
  found: { url: string; source: string; width: number; png?: Uint8Array } | null,
) {
  const body: Record<string, unknown> = {
    domain,
    url: found?.url ?? null,
    source: found?.source ?? "none",
    width: found?.width ?? null,
    missing: found === null,
    resolved_at: new Date().toISOString(),
    // PostgREST takes bytea as a hex string with a \x prefix.
    png: found?.png ? `\\x${[...found.png].map((b) => b.toString(16).padStart(2, "0")).join("")}` : null,
  };

  await postgrest("brand_logos?on_conflict=domain", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates" },
    body: JSON.stringify(body),
  });
}

// ---------------------------------------------------------------------------
// Resolving
// ---------------------------------------------------------------------------

/// Reads a PNG/JPEG/ICO header far enough to learn the width.
///
/// ⚠️ Needed because "the server returned 200" says nothing about what it
/// returned. Asking a site for `apple-touch-icon.png` it does not have very
/// often returns the homepage -- instagram.com answers with 618KB of HTML and
/// a cheerful 200 -- and the icon services answer a miss with a valid 16px
/// placeholder PNG. Width is the only honest test.
function imageWidth(bytes: Uint8Array): number | null {
  // PNG: 8-byte signature, then IHDR with width at offset 16.
  if (
    bytes.length > 24 && bytes[0] === 0x89 && bytes[1] === 0x50 &&
    bytes[2] === 0x4e && bytes[3] === 0x47
  ) {
    return new DataView(bytes.buffer, bytes.byteOffset).getUint32(16);
  }
  // ICO: reserved 0, type 1, then count; first entry's width at offset 6.
  if (bytes.length > 8 && bytes[0] === 0 && bytes[1] === 0 && bytes[2] === 1) {
    // 0 in an ICO directory means 256.
    return bytes[6] === 0 ? 256 : bytes[6];
  }
  // JPEG: walk the segments to a start-of-frame.
  if (bytes.length > 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    let offset = 2;
    const view = new DataView(bytes.buffer, bytes.byteOffset);
    while (offset + 9 < bytes.length) {
      if (bytes[offset] !== 0xff) return null;
      const marker = bytes[offset + 1];
      const length = view.getUint16(offset + 2);
      // SOF0..SOF3 and SOF5..SOF15 carry the dimensions.
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8) {
        return view.getUint16(offset + 7);
      }
      offset += 2 + length;
    }
  }
  return null;
}

async function fetchImage(
  url: string,
): Promise<{ bytes: Uint8Array; width: number } | null> {
  try {
    const response = await fetch(url, {
      signal: AbortSignal.timeout(6000),
      redirect: "follow",
      // Some sites serve nothing useful to an unrecognised client.
      headers: { "User-Agent": "Mozilla/5.0 (compatible; MailyLogoBot/1.0)" },
    });
    if (!response.ok) return null;

    const bytes = new Uint8Array(await response.arrayBuffer());
    // A logo is kilobytes. Anything enormous is a web page.
    if (bytes.length === 0 || bytes.length > 2 * 1024 * 1024) return null;

    const width = imageWidth(bytes);
    if (width === null || width < MIN_PIXELS) return null;
    return { bytes, width };
  } catch {
    return null;
  }
}

/// The logo a company publishes for its own mail.
///
/// A DNS TXT record at `default._bimi.<domain>`, read through Google's
/// DNS-over-HTTPS resolver. This is the source Gmail itself draws: the company
/// published it, against a DMARC-authenticated domain, and for a Verified Mark
/// Certificate a trademark office checked it.
///
/// It also rescues exactly the domains a favicon handles worst -- TikTok's
/// favicon is 32px and eBay's is 16, and both publish a proper BIMI logo.
async function bimiURL(domain: string): Promise<string | null> {
  try {
    const response = await fetch(
      `https://dns.google/resolve?name=default._bimi.${domain}&type=TXT`,
      { signal: AbortSignal.timeout(5000) },
    );
    if (!response.ok) return null;
    const payload = await response.json();
    const record: string | undefined = (payload.Answer ?? [])
      .map((a: { data?: string }) => a.data ?? "")
      .find((d: string) => d.includes("v=BIMI1"));
    if (!record) return null;

    // Join before unquoting: a TXT record over 255 bytes arrives as several
    // quoted strings, and stripping the quotes first leaves a space in the
    // middle of the URL.
    const flat = record.replace(/" "/g, "").replace(/"/g, "");
    for (const field of flat.split(";")) {
      const trimmed = field.trim();
      if (!trimmed.toLowerCase().startsWith("l=")) continue;
      const value = trimmed.slice(2).trim();
      // An empty `l=` is legal and means "we deliberately have no logo".
      if (!value.startsWith("https://")) return null;
      return value;
    }
    return null;
  } catch {
    return null;
  }
}

/// Turns a BIMI SVG into a PNG the phone can draw.
///
/// 🔴 Done here rather than on the device on purpose. The previous attempt
/// rendered SVG through an offscreen WebKit view on the phone -- untested on a
/// device, and offscreen snapshots commonly come back blank, so that tier may
/// have been silently contributing nothing at all. On the server it either
/// works or it throws, once, for everybody.
///
/// Degrades rather than fails: if the rasteriser cannot be loaded the caller
/// simply moves down the ladder to an icon service, which is the behaviour
/// without BIMI at all.
type Renderer = { render: (svg: string, width: number) => Uint8Array } | null;

/// 🔴 The **promise** is cached, not a "have we tried yet" flag.
///
/// Caught by the first live test: TikTok got its BIMI logo and LinkedIn and
/// PayPal fell back to favicons, though all three publish one. Every domain in
/// a request resolves inside one `Promise.all`, so several reach here at once.
/// With a boolean, the first caller set `tried = true` and then *awaited* the
/// WebAssembly download -- and every other caller saw "tried, and no renderer"
/// and gave up, for the whole cold-start window.
///
/// Awaiting one shared promise means the others wait for the same init instead
/// of concluding it failed. The failure was invisible: nothing errored, the
/// logos were simply worse.
let resvgReady: Promise<Renderer> | null = null;

async function loadResvg(): Promise<Renderer> {
  try {
    const mod = await import("npm:@resvg/resvg-wasm@2.6.2");
    const wasm = await fetch(
      "https://unpkg.com/@resvg/resvg-wasm@2.6.2/index_bg.wasm",
    );
    await mod.initWasm(await wasm.arrayBuffer());
    return {
      render: (source: string, width: number) => {
        const instance = new mod.Resvg(source, {
          fitTo: { mode: "width", value: width },
          background: "rgba(0,0,0,0)",
        });
        return instance.render().asPng();
      },
    };
  } catch (error) {
    console.error("resvg unavailable", String(error));
    return null;
  }
}

async function rasterise(svg: string): Promise<Uint8Array | null> {
  resvgReady ??= loadResvg();
  const renderer = await resvgReady;
  if (!renderer) return null;

  try {
    return renderer.render(svg, 256);
  } catch (error) {
    console.error("rasterise failed", String(error));
    return null;
  }
}

async function resolve(
  domain: string,
): Promise<{ url: string; source: string; width: number; png?: Uint8Array } | null> {
  // 1. BIMI -- authoritative, and what Gmail draws.
  const bimi = await bimiURL(domain);
  if (bimi) {
    try {
      const response = await fetch(bimi, { signal: AbortSignal.timeout(6000) });
      if (response.ok) {
        const svg = await response.text();
        if (svg.length < 512 * 1024 && svg.includes("<svg")) {
          const png = await rasterise(svg);
          if (png) {
            return {
              url: `${SUPABASE_URL}/functions/v1/logos/img/${domain}`,
              source: "bimi",
              width: 256,
              png,
            };
          }
        }
      }
    } catch {
      // Fall through to the icon services.
    }
  }

  // 2. Whatever the site publishes for a home screen, then the icon services.
  const candidates: Array<[string, string]> = [
    ["apple-touch-icon", `https://${domain}/apple-touch-icon.png`],
    ["apple-touch-icon", `https://${domain}/apple-touch-icon-precomposed.png`],
    ["favicon", `https://www.google.com/s2/favicons?sz=256&domain=${domain}`],
    ["favicon", `https://icons.duckduckgo.com/ip3/${domain}.ico`],
  ];

  let best: { url: string; source: string; width: number } | null = null;
  for (const [source, url] of candidates) {
    const image = await fetchImage(url);
    if (!image) continue;
    if (!best || image.width > best.width) best = { url, source, width: image.width };
    if (best.width >= GOOD_PIXELS) return best;
  }
  return best;
}

// ---------------------------------------------------------------------------

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const path = new URL(request.url).pathname;

  // The rasterised BIMI logo, as a plain image URL.
  const image = path.match(/\/img\/([^/]+)$/);
  if (image) {
    const domain = decodeURIComponent(image[1]).toLowerCase();
    if (!isSaneDomain(domain)) return json({ error: "bad domain" }, 400);

    const response = await postgrest(
      `brand_logos?domain=eq.${encodeURIComponent(domain)}&select=png`,
    );
    if (!response.ok) return json({ error: "not found" }, 404);
    const rows = await response.json();
    const hex: string | null = rows?.[0]?.png ?? null;
    if (!hex || !hex.startsWith("\\x")) return json({ error: "not found" }, 404);

    const bytes = new Uint8Array(
      (hex.slice(2).match(/.{2}/g) ?? []).map((h: string) => parseInt(h, 16)),
    );
    return new Response(bytes, {
      headers: {
        "Content-Type": "image/png",
        // It is a logo. It is not going to change this month.
        "Cache-Control": "public, max-age=2592000, immutable",
        ...CORS,
      },
    });
  }

  if (request.method !== "POST") return json({ error: "POST only" }, 405);
  if (!SUPABASE_URL || !SERVICE_ROLE) return json({ error: "not configured" }, 500);

  let body: { domains?: string[] };
  try {
    body = await request.json();
  } catch {
    return json({ error: "bad body" }, 400);
  }

  // Normalise, deduplicate and bound before doing any work.
  const asked = new Map<string, string>();
  for (const raw of body.domains ?? []) {
    if (typeof raw !== "string") continue;
    const host = raw.includes("@") ? raw.split("@").pop()! : raw;
    const domain = organisation(host.trim().toLowerCase());
    if (!isSaneDomain(domain)) continue;
    asked.set(domain, domain);
    if (asked.size >= MAX_DOMAINS) break;
  }
  const domains = [...asked.keys()];
  if (domains.length === 0) return json({});

  const stored = await read(domains);
  const answer: Record<string, { url: string | null; source: string | null }> = {};
  const toResolve: string[] = [];

  for (const domain of domains) {
    const row = stored.get(domain);
    if (row && !isStale(row)) {
      answer[domain] = { url: row.missing ? null : row.url, source: row.source };
    } else {
      toResolve.push(domain);
    }
  }

  // Resolved together rather than one after another: a cold inbox is thirty
  // unknown domains, and doing those in sequence would take a minute.
  //
  // 🔴 And answered within a deadline. The slowest company in a cold batch
  // used to set the latency of the whole answer -- a site that hangs on
  // apple-touch-icon.png costs two 6s timeouts before an icon service is
  // even tried -- and the phone gave up at 20s and, in build 189, remembered
  // the entire batch as "no logo" for a week. Now whatever has resolved by
  // the deadline goes out; a domain missing from the answer is simply not
  // answered yet, and the phone asks again.
  const work = toResolve.map(async (domain) => {
    try {
      const found = await resolve(domain);
      await write(domain, found);
      answer[domain] = {
        url: found?.url ?? null,
        source: found?.source ?? "none",
      };
    } catch (error) {
      // One company's failure must not 500 the batch for the other thirty.
      console.error("resolve failed", domain, String(error));
    }
  });
  const everything = Promise.all(work);
  await Promise.race([
    everything,
    new Promise<void>((done) => setTimeout(done, ANSWER_WITHIN_MS)),
  ]);
  // Keep the isolate alive for the stragglers after the response has gone,
  // where the runtime offers it. Where it does not, they still usually
  // finish before the isolate is torn down.
  (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } })
    .EdgeRuntime?.waitUntil(everything);

  return json(answer);
});
