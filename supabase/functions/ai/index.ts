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
  "category": "meeting" | "finance" | "security" | "newsletter" | "promotion" | "other",
  "summary": "one sentence, under 20 words, what this asks of the reader"
}

priority
  urgent          a real deadline or consequence attached, today or tomorrow
  very_important  matters a lot but nothing is on fire
  important       worth reading today
  normal          everything else

Judge what the message ASKS OF THE READER, not how loudly it is written.
Marketing shouting "URGENT" is normal. A quiet note from a client asking for
a decision by Friday is not.

category is what the message IS, which is a separate question from how much
it matters. A payment reminder due tomorrow is urgent AND finance.
  meeting     an invitation, a scheduling request, a reschedule or cancellation
  finance     an invoice, receipt, payment, refund, renewal or statement
  security    a sign-in alert, verification code, password or account warning
  newsletter  a digest or subscription sent to a list, not written to anyone
  promotion   marketing: an offer, sale, discount or upsell
  other       anything else, including ordinary person-to-person mail

Pick "other" rather than forcing a fit.`;

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
- Sound like a person wrote it quickly and meant it, not like a press release.
- Never use dashes as punctuation. No em dashes, no en dashes, no " - ".
  Write two sentences, or use a comma. This is the clearest tell that a
  machine wrote something and it must not appear.
- No "I hope this finds you well", no "reaching out", no "circle back", no
  "at your earliest convenience". Nobody talks like that.`;

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

// ------------------------------------------------------------------ refine

// Rewrites what the user already typed. The hard part is restraint: the
// instinct of a model asked to "improve" an email is to inflate it into
// corporate filler, which is worse than what it was handed.
async function refine(body: Record<string, string>) {
  const tone = body.tone ?? "match how I already write";
  const formal = /formal|professional/i.test(tone);

  const system = `You improve a draft email that the user has written.

Tone: ${tone}.
${formal ? "No emoji." : "An emoji is fine where it adds warmth. At most one."}

What to do:
- Fix grammar, spelling and punctuation.
- Break a wall of text into short paragraphs. Use a list when the draft is
  genuinely listing things.
- Put the ask in the first two lines. A reader should know what is wanted
  without scrolling.
- Cut filler: "I hope this email finds you well", "just wanted to reach out",
  "at your earliest convenience".

What NOT to do:
- Do not add facts, names, dates, numbers or promises that are not already
  in the draft.
- Do not make it longer. Shorter is almost always the improvement.
- Do not change the meaning, the decision, or how warm or firm it is.
- No subject line, no signature block. Body text only.
- Never use dashes as punctuation. No em dashes, no en dashes, no " - ".
  Write two sentences, or use a comma. This is the clearest tell that a
  machine wrote something and it must not appear.
- No "I hope this finds you well", no "reaching out", no "circle back", no
  "at your earliest convenience". Nobody talks like that.

Return the improved email and nothing else. No preamble, no explanation, no
quotes around it.`;

  const context = body.body
    ? [
        "For context, the message being replied to:",
        `From: ${body.from ?? ""}`,
        `Subject: ${body.subject ?? ""}`,
        body.body.slice(0, BODY_LIMIT),
        "",
      ].join("\n")
    : "";

  const content = `${context}The user's draft to improve:\n${body.text ?? ""}`;

  const improved = await openai(
    DRAFT_MODEL,
    [
      { role: "system", content: system },
      { role: "user", content },
    ],
    false,
  );

  return json({ body: improved.trim(), model: DRAFT_MODEL });
}

// --------------------------------------------------------------------- ask

const ASK_SYSTEM = `You are Maily, the assistant inside a person's email app. You are
given the conversation so far and a numbered list of their recent messages
that look relevant to what they just said, and nothing else.

Rules:
- If they are greeting you or making small talk, reply in one warm sentence
  and do not mention their email at all. Nobody who says "hi" wants a list.
- Otherwise answer only from the messages given. If they do not contain the
  answer, say so plainly. Never guess a name, a date, an amount or a
  commitment.
- Use the conversation so far to resolve "that one", "the second", "her".
- Do not number or cite the messages. No [1], no [2], no footnote markers.
  The app shows the reader which emails were used; markers in the prose only
  make it look like a report.
- Be brief. A list of three things beats a paragraph about them. Markdown
  headings, bullets and bold are fine; the app renders them.
- No preamble. Do not restate the question.
- If they asked about their mail and nothing is relevant, say "Nothing in
  your recent mail covers that."
- When they ask you to write, draft or send an email to anyone, including a
  company or a support address, do not put it in your prose. Say at most one
  short sentence, then give the email in a fenced block that starts with a
  line containing only \`\`\`email and ends with a line containing only \`\`\`.
  Inside the block: a "To:" line with the name and address if the messages
  show them (leave the address out rather than invent one), a "Subject:"
  line, a blank line, then the body only. No signature block. The app turns
  that block into a card the person can edit and send.
- You cannot send, archive, delete or file anything yourself. Never claim to
  have done any of those things.
- Never use dashes as punctuation. No em dashes, no en dashes, no " - ".`;


// Answers a question about the mailbox. The app has already picked which
// messages are relevant and sends only those, numbered -- retrieval happens
// on the device against mail it already holds, so this never sees a whole
// mailbox and never pays to.
// The same question, answered as a stream.
//
// Words appear as the model produces them instead of after it has finished,
// which on a ten second answer is the difference between the app looking fast
// and the app looking stuck. The provider's SSE body is passed straight
// through; the app parses the deltas.
async function askStream(body: Record<string, unknown>) {
  const question = String(body.question ?? "").slice(0, 500);
  if (!question) return json({ error: "No question was asked." }, 400);

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENAI_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: DRAFT_MODEL,
      messages: askMessages(question, body),
      stream: true,
    }),
  });

  if (!response.ok || !response.body) {
    const detail = await response.text();
    return json({ error: detail.slice(0, 300) || "The AI service failed." }, 502);
  }

  return new Response(response.body, {
    headers: {
      ...CORS,
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
    },
  });
}

/// Shared by the streaming and non-streaming paths so the two can never drift.
function askMessages(question: string, body: Record<string, unknown>) {
  const messages = Array.isArray(body.messages) ? body.messages : [];

  const digest = messages
    .slice(0, 25)
    .map((message: Record<string, string>, index: number) =>
      [
        `[${index + 1}]`,
        `From: ${message.from ?? ""}`,
        `Date: ${message.date ?? ""}`,
        `Subject: ${message.subject ?? ""}`,
        `${(message.body ?? "").slice(0, 400)}`,
      ].join("\n")
    )
    .join("\n\n");

  const content = digest
    ? `Question: ${question}\n\nTheir messages:\n\n${digest}`
    : `Question: ${question}\n\nThey have no matching messages.`;

  // The conversation so far, so follow-ups resolve. Only the two roles the
  // model expects, capped in count and length: the app sends what is on
  // screen, and a stray system-role turn from a client must never get in.
  const history = Array.isArray(body.history) ? body.history : [];
  const prior = history
    .slice(-10)
    .filter(
      (turn: Record<string, unknown>) =>
        (turn.role === "user" || turn.role === "assistant") &&
        typeof turn.content === "string" && turn.content.length > 0,
    )
    .map((turn: Record<string, string>) => ({
      role: turn.role,
      content: turn.content.slice(0, 1500),
    }));

  return [
    { role: "system", content: ASK_SYSTEM },
    ...prior,
    { role: "user", content },
  ];
}

async function ask(body: Record<string, unknown>) {
  const question = String(body.question ?? "").slice(0, 500);
  if (!question) return json({ error: "No question was asked." }, 400);

  const answer = await openai(DRAFT_MODEL, askMessages(question, body), false);
  return json({ answer: answer.trim(), model: DRAFT_MODEL });
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
      case "refine":
        return await refine(payload);
      case "ask":
        return await ask(payload);
      case "ask_stream":
        return await askStream(payload);
      default:
        return json({ error: `unknown action: ${payload.action}` }, 400);
    }
  } catch (error) {
    return json({ error: String(error instanceof Error ? error.message : error) }, 500);
  }
});
