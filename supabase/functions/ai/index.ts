// Maily's AI endpoint.
//
// The provider key lives here, in Supabase's secret store, and never reaches
// the iOS app -- anyone can pull strings out of an .ipa, so a key shipped in
// the binary is a published key.
//
// Two jobs, deliberately different models:
//   classify  runs on every message, so it is the cheap fast one
//   draft     runs only when a person asks for it, so it can afford quality
//
// Payload is kept deliberately small: headers plus the opening of the body,
// never the whole mailbox. That is a privacy position and a cost one, and it
// matters for Google's Limited Use rules on Gmail data.

const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");

const CLASSIFY_MODEL = "gpt-4.1-mini";
const DRAFT_MODEL = "gpt-5.4";

/// How much of a body the model sees. Enough to judge intent; far short of
/// shipping the message wholesale.
const BODY_LIMIT = 1200;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

async function openai(model: string, messages: unknown[], jsonMode: boolean) {
  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENAI_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      messages,
      ...(jsonMode ? { response_format: { type: "json_object" } } : {}),
    }),
  });

  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload?.error?.message ?? `provider returned ${response.status}`);
  }
  return payload.choices[0].message.content as string;
}

// ---------------------------------------------------------------- classify

const CLASSIFY_SYSTEM = `You triage email for a busy professional.

Return JSON only, no prose:
{
  "priority": "urgent" | "very_important" | "important" | "normal",
  "needs_reply": boolean,
  "summary": "one sentence, under 20 words, what this asks of the reader"
}

urgent          a real deadline or consequence attached, today or tomorrow
very_important  matters a lot but nothing is on fire
important       worth reading today
normal          everything else

Judge what the message ASKS OF THE READER, not how loudly it is written.
Marketing shouting "URGENT" is normal. A quiet note from a client asking for
a decision by Friday is not.`;

async function classify(body: Record<string, string>) {
  const content = [
    `From: ${body.from ?? ""}`,
    `Subject: ${body.subject ?? ""}`,
    "",
    (body.body ?? "").slice(0, BODY_LIMIT),
  ].join("\n");

  const raw = await openai(
    CLASSIFY_MODEL,
    [
      { role: "system", content: CLASSIFY_SYSTEM },
      { role: "user", content },
    ],
    true,
  );

  return json({ ...JSON.parse(raw), model: CLASSIFY_MODEL });
}

// ------------------------------------------------------------------- draft

async function draft(body: Record<string, string>) {
  const tone = body.tone ?? "match how I already write";

  // Emoji everywhere except the one tone that is actively hurt by them.
  // Gating on "casual or warm" was tried and reverted: the tone question is
  // optional and the direct/thorough answers are common, so most people would
  // have seen no emoji at all and assumed the setting did nothing.
  const formal = /formal|professional/i.test(tone);
  const emojiRule = formal
    ? "No emoji."
    : "Use an emoji where it genuinely adds warmth -- usually one, never more than two, and never in the opening words.";

  const system = `You write email replies on behalf of the user.

Tone: ${tone}.
${emojiRule}

Rules:
- Reply to the message shown. Do not invent facts, names, dates or commitments.
- If the instruction is vague, write the shortest reply that honours it.
- No subject line, no "Dear", no signature block. Body text only.
- Match the length of the original. A two-line email gets a two-line reply.
- Sound like a person wrote it quickly and meant it, not like a press release.`;

  const content = [
    `The message being replied to:`,
    `From: ${body.from ?? ""}`,
    `Subject: ${body.subject ?? ""}`,
    (body.body ?? "").slice(0, BODY_LIMIT),
    "",
    `What the user said to write, spoken aloud and transcribed:`,
    body.instruction ?? "",
  ].join("\n");

  const reply = await openai(
    DRAFT_MODEL,
    [
      { role: "system", content: system },
      { role: "user", content },
    ],
    false,
  );

  return json({ body: reply.trim(), model: DRAFT_MODEL });
}

// ------------------------------------------------------------------ router

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });

  if (!OPENAI_KEY) {
    return json({ error: "OPENAI_API_KEY is not set on this project." }, 500);
  }

  try {
    const payload = await request.json();
    switch (payload.action) {
      case "classify":
        return await classify(payload);
      case "draft":
        return await draft(payload);
      default:
        return json({ error: `unknown action: ${payload.action}` }, 400);
    }
  } catch (error) {
    return json({ error: String(error instanceof Error ? error.message : error) }, 500);
  }
});
