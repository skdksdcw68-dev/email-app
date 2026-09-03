// Maily's AI endpoint.
//
// The provider key lives here, in Supabase's secret store, and never reaches
// the iOS app -- anyone can pull strings out of an .ipa, so a key shipped in
// the binary is a published key.
//
// Five jobs, two models:
//   classify  runs on every message, so it is the cheap fast one
//   extract   runs only where classify said there was something to find; the
//             same cheap model, reading more of the message for less often
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
  "summary": "one sentence, under 20 words, what this asks of the reader",
  "extract": boolean
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

Pick "other" rather than forcing a fit.

extract is whether a closer read would find something worth remembering:
a person asking the reader for something, promising something, putting a
question to them, or naming a date that matters. True for mail written to
the reader by a person, or by someone acting for one, that carries any of
those. False for newsletters, promotions, receipts, alerts, notifications
and anything that wants nothing from the reader. Most mail is false.`;

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

// ----------------------------------------------------------------- extract
//
// The second tier. Classify runs on everything and is deliberately shallow;
// this runs only where classify said there was something to find, and reads
// the whole thing for what a person would want to be reminded of later.
//
// Written from the email's point of view -- writer and reader -- rather than
// the app's. The same email is a request when it arrives and a promise when
// it is the one you sent, and the app knows which of those it is looking at.
// The model does not need to.

/// More than classify sees. An ask is often in the last paragraph, after
/// the context that explains it, and cutting there would keep the context
/// and lose the ask.
const EXTRACT_BODY_LIMIT = 2400;

const EXTRACT_SYSTEM = `You read one email and write down what a person would want
to be reminded of from it.

Return JSON only, no prose:
{
  "requests":    [{ "what": "...", "due": "YYYY-MM-DD" | null }],
  "commitments": [{ "what": "...", "due": "YYYY-MM-DD" | null }],
  "questions":   ["..."],
  "dates":       [{ "what": "...", "on": "YYYY-MM-DD" }]
}

requests     things the WRITER asks the READER to do or send
commitments  things the WRITER says they themselves will do
questions    open questions the writer puts to the reader that are not a
             request to do something: "does Thursday work", "which plan"
dates        anything with a date attached that is not already the due date
             of a request or commitment: a meeting, a call, a renewal, a
             trip, a launch, a deadline set by somebody else

Rules:
- Only what the email says. Never infer, never complete a thought for them.
- "what" is a short phrase, under twelve words, opening with a verb for
  requests and commitments: "Send the revised quote", "Book the venue for
  the 14th". Name the thing, not the sentence it came in.
- Dates are resolved against the email's own date, which you are given.
  "By Friday" in an email written on Wednesday 2 September 2026 is
  2026-09-04. "Next week" with no day is null. Never invent a date.
- Most email has nothing in it. Empty lists are the right answer for a
  receipt, a newsletter, a notification, a thank-you, a "sounds good".
- Leave out pleasantries, sign-offs, "let me know if you have questions",
  unsubscribe lines, legal footers and anything quoted from an earlier
  message in the thread.
- At most four items in each list. If there are more, keep the ones with
  dates and the ones that sound like they matter.`;

async function extract(body: Record<string, string>) {
  const content = [
    `From: ${body.from ?? ""}`,
    `To: ${body.to ?? ""}`,
    `Written on: ${body.date ?? ""}`,
    `Subject: ${body.subject ?? ""}`,
    "",
    (body.body ?? "").slice(0, EXTRACT_BODY_LIMIT),
  ].join("\n");

  const raw = await openai(
    CLASSIFY_MODEL,
    [
      { role: "system", content: EXTRACT_SYSTEM },
      { role: "user", content },
    ],
    true,
  );

  const parsed = JSON.parse(raw);
  // Whatever shape came back, the app gets the four lists, each a list.
  const list = (value: unknown) => (Array.isArray(value) ? value : []);
  return json({
    requests: list(parsed.requests),
    commitments: list(parsed.commitments),
    questions: list(parsed.questions),
    dates: list(parsed.dates),
    model: CLASSIFY_MODEL,
  });
}

// -------------------------------------------------------------- auto-reply
//
// Two jobs, both about the person's own setup rather than their mail. Nothing
// here ever sees an email: the input is what they chose and typed in the
// Auto-Reply wizard, which is theirs and which they are about to read back.
//
// The point of both is that a person can check them. A summary the app
// assembled from its own fields could never be wrong, and an example reply
// built from a template would prove nothing about what the real thing will
// do. Both are written by the model from the actual state, so getting one
// wrong is a signal rather than a bug in a mockup.

const UNDERSTANDING_SYSTEM = `You are being shown what somebody told an email
assistant about their work, so it can answer routine mail for them. Write back
what you understood, for them to check.

Return JSON only, no prose:
{
  "role": "one sentence: who they are and what they do",
  "work": "one or two sentences on the work itself",
  "audience": "one sentence on who writes to them",
  "commonRequests": ["short phrases, what people ask them for"],
  "canHandle": ["short phrases, what they said you may answer"],
  "alwaysAsks": ["short phrases, what must go back to them"],
  "whenUnsure": "one sentence on what you do when you are not sure",
  "style": "one sentence on how they want you to sound",
  "rules": ["their own rules, in their words, unchanged"]
}

Rules:
- Only what they actually told you. Never fill a gap with a guess, and never
  flatter them. If they said little, say little.
- Write it to them, as "you". Plain, warm, no marketing language.
- Under twenty words a sentence. Under eight words a list item.
- Keep their own words for the rules. They wrote those deliberately.
- An empty list is the right answer when they chose nothing.`;

async function autoReplyUnderstanding(body: Record<string, string>) {
  const raw = await openai(
    DRAFT_MODEL,
    [
      { role: "system", content: UNDERSTANDING_SYSTEM },
      { role: "user", content: setupLines(body) },
    ],
    true,
  );

  const parsed = JSON.parse(raw);
  const list = (value: unknown) =>
    Array.isArray(value) ? value.filter((item) => typeof item === "string") : [];
  const line = (value: unknown) => (typeof value === "string" ? value : "");

  return json({
    role: line(parsed.role),
    work: line(parsed.work),
    audience: line(parsed.audience),
    commonRequests: list(parsed.commonRequests),
    canHandle: list(parsed.canHandle),
    alwaysAsks: list(parsed.alwaysAsks),
    whenUnsure: line(parsed.whenUnsure),
    style: line(parsed.style),
    rules: list(parsed.rules),
    model: DRAFT_MODEL,
  });
}

const EXAMPLE_SYSTEM = `Write one realistic example of the email assistant at
work, from the setup you are given.

First invent a plausible incoming email: something this person would actually
receive, given who writes to them and what those people ask about. Ordinary
and specific. No placeholders, no "Lorem", no [brackets].

Then write the reply the assistant would send, obeying the setup exactly.

Return JSON only, no prose:
{
  "incoming": "the email, as it would arrive",
  "reply": "the reply, ready to send",
  "evidenceUsed": ["which approved facts the reply leans on"],
  "rulesFollowed": ["which of their own rules you obeyed, and how"],
  "blockedFacts": ["what you deliberately did not answer, and why"],
  "safety": "one or two sentences: what you answered, what you left for them"
}

Rules that decide the reply:
- You may state ONLY the facts given to you under "What they may state". If
  an answer needs anything else -- a price, a date, a policy, a promise --
  you do not have it. Say you will come back to them, or ask, according to
  what they chose for when you are unsure. Never invent one to make a
  better example.
- Anything on the "must come back to them" list is not yours to answer, even
  if you were given a fact that would cover it. Say so in blockedFacts.
- Their own rules shape how you write. They never let you state something
  you were not given, and they never override the list above.
- Write in the style described. Sign off as an assistant writing on their
  behalf would.
- Make the example one where something is deliberately left for them, where
  the setup allows it. That is the honest picture, and it is the half that
  shows the thing works.`;

async function autoReplyExample(body: Record<string, string>) {
  const raw = await openai(
    DRAFT_MODEL,
    [
      { role: "system", content: EXAMPLE_SYSTEM },
      { role: "user", content: setupLines(body) },
    ],
    true,
  );

  const parsed = JSON.parse(raw);
  const list = (value: unknown) =>
    Array.isArray(value) ? value.filter((item) => typeof item === "string") : [];

  return json({
    incoming: typeof parsed.incoming === "string" ? parsed.incoming : "",
    reply: typeof parsed.reply === "string" ? parsed.reply : "",
    evidenceUsed: list(parsed.evidenceUsed),
    rulesFollowed: list(parsed.rulesFollowed),
    blockedFacts: list(parsed.blockedFacts),
    safety: typeof parsed.safety === "string" ? parsed.safety : "",
    model: DRAFT_MODEL,
  });
}

/// The setup as labelled lines. Both jobs read the same picture, so the
/// summary can never describe a setup the example did not use.
function setupLines(body: Record<string, string>) {
  const fields: [string, string][] = [
    ["They are", body.persona],
    ["Their work is about", body.work],
    ["People who write to them", body.audience],
    ["What those people usually ask about", body.inbound],
    ["What they may state as fact", body.facts],
    ["Their written policies", body.policies],
    ["How to handle pricing questions", body.pricing],
    ["How to handle availability questions", body.availability],
    ["You may answer these without asking", body.allowed],
    ["These must always come back to them", body.boundaries],
    ["When you are not sure", body.unsure],
    ["How they want you to sound", body.style],
    ["Their own rules for you", body.rules],
  ];
  return fields
    .filter(([, value]) => value && value.trim().length > 0)
    .map(([label, value]) => `${label}:\n${value}`)
    .join("\n\n");
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
- You may be told where things stand with the person being written to: what
  is outstanding either way, what was promised, when you last spoke. Use it
  so the reply does not contradict what was said last week, ask for
  something already sent, or thank somebody for something they never did.
  Do not recite it back at them.
- You may be told facts about the user's own work that they approved. Those
  you may state. Anything a reply needs that is not in them, and not in the
  message or the thread, you do not have -- say you will confirm it rather
  than producing a number, a date or a policy that nobody gave you. A wrong
  price in a reply is worse than a slower reply.
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
    body.standing ? `Where things stand with them:\n${body.standing.slice(0, 1200)}\n` : "",
    body.knowledge ? `Facts about the user's work they approved:\n${body.knowledge.slice(0, 1200)}\n` : "",
    body.thread ? `Earlier in this conversation:\n${body.thread.slice(0, 1600)}\n` : "",
    `The message being replied to:`,
    `From: ${body.from ?? ""}`,
    `Subject: ${body.subject ?? ""}`,
    (body.body ?? "").slice(0, BODY_LIMIT),
    "",
    `What the user said to write, spoken aloud and transcribed:`,
    body.instruction ?? "",
  ].filter(Boolean).join("\n");

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

// ------------------------------------------------------------------ revise

// One requested change to a draft the assistant wrote, and nothing else.
// The failure mode to guard against is the model "helpfully" rewriting the
// whole thing when asked to warm up one line.
async function revise(body: Record<string, string>) {
  const tone = body.tone ?? "match how I already write";

  const system = `You revise an email draft. Apply exactly the change asked for and
nothing else.

Tone: ${tone}.

The facts are locked. The style is yours.

Every number, date, name, price, commitment and decision in the draft is a
fact somebody has already checked. "Make it warmer" is an instruction about
tone; it is not permission to round a figure, move a date, soften a refusal
into a maybe, or add a promise to make the warmth land. If a change cannot
be made without altering one of those, make the part that can be and leave
the fact exactly as it was written.

The one exception is a change that is explicitly about a fact -- "change the
date to Friday", "make it two thousand". Then that fact changes, and only
that one.

Rules:
- Keep the meaning, the facts, the names and the decision exactly as they
  are, unless the change asked for is about one of them.
- Keep the length, unless the change asked for is about length.
- Do not add facts, names, dates, numbers or promises that are not already in
  the draft.
- No subject line, no signature block. Body text only.
- Never use dashes as punctuation. No em dashes, no en dashes, no " - ".
- No "I hope this finds you well", no "reaching out", no "circle back", no
  "at your earliest convenience". Nobody talks like that.

Return the revised email and nothing else. No preamble, no explanation, no
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

  const content = `${context}The draft:\n${body.text ?? ""}\n\nThe change asked for:\n${body.instruction ?? ""}`;

  const revised = await openai(
    DRAFT_MODEL,
    [
      { role: "system", content: system },
      { role: "user", content },
    ],
    false,
  );

  return json({ body: revised.trim(), model: DRAFT_MODEL });
}

// ------------------------------------------------------------------ search

// Turns what somebody remembers about an email into a Gmail query.
//
// The model never sees the mailbox here. It sees the question, writes a
// query, and Gmail answers it from its own index -- which reaches the whole
// account rather than the three months on the phone, and costs one small
// call rather than shipping mail anywhere.
const SEARCH_SYSTEM = `You turn a description of an email into a Gmail search query.

Return JSON only, no prose:
{
  "query": "the Gmail search query",
  "terms": ["words", "to", "mark"],
  "explanation": "one short sentence: what you searched for"
}

Operators available: from: to: cc: subject: has:attachment filename:
after: before: older_than: newer_than: is:unread is:starred label:
in:anywhere OR AND -  and parentheses. Dates are YYYY/MM/DD.

Rules:
- You are told today's date. Resolve "last spring", "in March", "a couple of
  weeks back", "before the summer" against it. Never guess the year.
- Prefer fewer operators. A query returning the right email and ten others
  beats a precise one returning nothing. When in doubt, drop the date.
- Bare words are joined with AND, so each one you add makes the search
  stricter. Two or three at most, and only words likely to be in the email
  itself. If you want alternatives, write them with OR.
- The query must name something: a word, a sender, a subject. A query built
  only from date operators, like "older_than:1d", matches every email ever
  received and is the same as no search at all. If they gave you nothing to
  go on, use the plainest noun in what they said.
- You may be given more than one line, because a short follow-up like
  "search for it, it is older" carries no subject of its own. The earlier
  lines are what they are looking for; the last line is usually only telling
  you where to look. Search for the subject, not for the instruction.
- Never invent an email address. If they name a person, write from:thatname
  and let Gmail match it.
- Put quotes around a phrase only when the words must appear together.
- "terms" are the plain words worth marking in the results: no operators, no
  dates, no quotes. Two to five, and only ones likely to appear in the text.
- "explanation" is for a person. "Mail from Sara about invoices since March."
  Not a restatement of the query.
- Never use dashes as punctuation in the explanation.`;

async function search(body: Record<string, unknown>) {
  const question = String(body.question ?? "").slice(0, 300);
  if (!question) return json({ error: "Nothing to search for." }, 400);

  const today = body.today ? `Today is ${String(body.today).slice(0, 60)}.\n` : "";

  const raw = await openai(
    CLASSIFY_MODEL,
    [
      { role: "system", content: SEARCH_SYSTEM },
      { role: "user", content: `${today}They are looking for: ${question}` },
    ],
    true,
  );

  return json({ ...JSON.parse(raw), model: CLASSIFY_MODEL });
}

// --------------------------------------------------------------------- ask

const ASK_SYSTEM = `You are Maily, the assistant inside a person's email app. You are
given the conversation so far and a numbered list of their recent messages
that look relevant to what they just said, and nothing else.

Rules:
- If they are greeting you or making small talk, reply in one warm sentence
  and do not mention their email at all. Nobody who says "hi" wants a list.
  Where you are given the shape of their inbox you may add one short offer
  after the greeting -- "3 urgent are sitting there, want them?" -- and if
  they say yes, do the thing you offered.
- Otherwise answer only from the messages given. If they do not contain the
  answer, say so plainly. Never guess a name, a date, an amount or a
  commitment.
- The messages are listed newest first. The first one is the most recent
  thing they received, so "what was the last email I got" is answered from
  the top of the list and not from whichever one looks most important.
- Use the conversation so far to resolve "that one", "the second", "her".
- Do not number or cite the messages in your prose. No [1], no [2], no
  footnote markers. The one place a number belongs is a show block.
- When the answer is an email, show it rather than describing it. Say one
  short sentence, then a fenced block that opens with a line of \`\`\`show
  and closes with \`\`\`, with the number of each message to show on its own
  line, in the order they should appear. The app draws each one as a card
  the reader can open. "What was the last email I got" is one sentence and
  a show block containing 1. "Anything from Sara" is one sentence and the
  numbers of her messages. "Show me the invoice" is the invoice's number.
- Never write out a message's sender, subject, date or read status in your
  prose. The card already says all of that; a paragraph repeating it makes
  the reader read the same email twice. The sentence beside a show block
  carries what the card cannot: the answer to what they actually asked. For
  "when did I register" it is the date. For "what did she want" it is what
  she wanted. For "show me the last one" it can be four words.
- Show as many as they asked for. "My last ten emails" is ten, if ten were
  given to you. When they did not say how many, show the ones that answer
  and no padding; if more match than you show, say how many there were.
  Show nothing when the answer is a count, a yes or no, or a summary across
  many messages; then it is prose, or stats. A date read off an email is not
  a count: say it in a plain sentence, "You joined LinkedIn on 14 March
  2019", and show the email it came from, so they can check you.
- Be brief. A list of three things beats a paragraph about them. Markdown
  headings, bullets and bold are fine; the app renders them.
- When the answer turns on two or three numbers, draw them instead of
  describing them. Put them in a fenced block that opens with a line of
  \`\`\`stats and closes with \`\`\`, one "Label: value" per line, at most
  three. Say the sentence that gives them meaning outside the block, and do
  not repeat the numbers in it.
- When you are comparing more than three things, or showing a spread, use a
  block that opens with \`\`\`chart and closes with \`\`\`: a title on the
  first line, then "Label: number" per line. Values must be plain numbers.
- Counts of two or three piles are stats. A breakdown of their whole inbox
  by tag is a chart. "How is my inbox looking" is stats: pick the three that
  matter, not all of them.
- Always write one short sentence outside the block, saying what it means or
  what to do about it. A block on its own is not an answer, it is a table.
  Do not repeat the numbers in that sentence.
- Use neither when the answer is a sentence. A tile with one number in it is
  worse than the sentence it replaced.
- No preamble. Do not restate the question.
- If they asked about their mail and nothing is relevant, say "Nothing in
  your recent mail covers that." Only when you have been told you cannot
  search. When you can, ask to search instead. Saying you cannot find
  something you have not looked for is the worst answer available to you.
- You are told today's date. Use it for "today", "this week", "overdue",
  "before Friday". Never guess what day it is.
- You may be given the shape of their inbox as tag counts. Those counts
  cover the whole inbox, including mail you were not shown, so you can
  answer "how many are in Important" straight from them.
- Every message says whether they have read it. Do not chase somebody about
  mail they have already read: if it is read, offer once, gently, as a
  suggestion ("worth a reply when you get a minute"), and drop it. Unread
  mail may be stated plainly. Nobody wants to be nagged by their own inbox.
- When you are told the question is not about their mail, do not mention
  email at all. Answer in a sentence or two, then offer one concrete thing
  you could do next, like drafting a reply or going through what is urgent.
- When they ask you to write, draft or send an email to anyone, including a
  company or a support address, do not put it in your prose. Say at most one
  short sentence, then give the email in a fenced block that starts with a
  line containing only \`\`\`email and ends with a line containing only \`\`\`.
  Inside the block: a "To:" line with the name and address if the messages
  show them (leave the address out rather than invent one), a "Subject:"
  line, a blank line, then the body only. No signature block. The app turns
  that block into a card the person can edit and send.
- You may be given things they have asked you to remember. Honour them
  without mentioning them. If one contradicts another, the later one wins.
- You may be given what the app has already read out of their mail: what
  people asked them for, what they promised, questions left open, dates
  coming up. Each line says whose move it is and points at a numbered
  message where it has one. When they ask what is waiting on them, what
  they owe, what somebody promised, what is due, or what is coming up,
  answer from those first and show the messages they point at. Who, what
  and when are the answer; a due date is part of it, not decoration. Say
  when something is overdue. If the list is empty or does not cover what
  they asked, fall back to the messages, and say so if there is nothing.
- When they tell you something to keep from now on, keep it. That is:
  how they like things done, a fact about themselves, who somebody is to
  them, or a situation they are in for a while. Put it in a fenced block
  that opens with a line of \`\`\`remember and closes with \`\`\`, with three
  lines inside:
    kind: preference | about_me | person | situation
    until: YYYY-MM-DD
    text: one sentence, in their words where you can
  "until" is only for a situation with an end in it, like travelling until
  the 12th; leave the line out otherwise. Then say in a few words outside
  the block that you have it, and nothing else. Do this when they say
  remember, keep in mind, note that, from now on, or plainly state a
  standing fact about themselves for you to use. "Do you remember what Sara
  said" is a question about their mail, not something to keep. "Remember to
  reply to Sara" is a task, and you have nowhere to put a task: say so.
- You cannot send, archive, delete or file anything yourself. Never claim to
  have done any of those things. The app can mark mail read when they ask it
  to, and it will tell them so itself; you do not need to.
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
        `Read: ${message.read ?? "unknown"}`,
        message.tags ? `Tags: ${message.tags}` : "",
        // A message the model asked to open comes through whole. Everything
        // else keeps its opening, which says what the message is without
        // paying to ship a mailbox.
        `${(message.body ?? "").slice(0, message.full === "yes" ? 4000 : 200)}`,
      ].filter(Boolean).join("\n")
    )
    .join("\n\n");

  // What the app knows and the model never did: the date, who is asking,
  // how they like to be written to, and the shape of the whole inbox rather
  // than only the dozen messages that came with the question.
  const facts: string[] = [];
  if (body.today) facts.push(`Today is ${String(body.today).slice(0, 60)}.`);
  if (body.user) facts.push(`You are talking to ${String(body.user).slice(0, 80)}.`);
  // What they do, in their own words. One line, and the most useful thing
  // there is for judging what matters in somebody else's inbox.
  if (body.occupation) {
    facts.push(`What they do: ${String(body.occupation).slice(0, 120)}.`);
  }
  if (body.tone) facts.push(`They like replies ${String(body.tone).slice(0, 120)}.`);
  if (body.inbox) facts.push(`Their whole inbox by tag: ${String(body.inbox).slice(0, 400)}.`);
  // What they have told you to remember, oldest first, so a later correction
  // reads as the last word on it.
  if (body.memories) {
    facts.push(`Things they have asked you to remember:\n${String(body.memories).slice(0, 2000)}`);
  }
  // What the second-tier read pulled out of their mail, already sorted into
  // whose move it is. The app built this from messages it holds; the model
  // reads it rather than re-deriving it from forty digests.
  if (body.facts) {
    facts.push(
      `What you already know from reading their mail. "On you" means the person you are talking to owes it; "on them" means the other person does. "[3]" is the numbered message it came from:\n${
        String(body.facts).slice(0, 4000)
      }`,
    );
  }
  // Where things stand with whoever they asked about: who the person is,
  // what is outstanding either way, and whose move it is. The app worked
  // this out from what it holds, so the model does not have to derive it
  // from a dozen of their emails.
  if (body.people) {
    facts.push(
      `What you know about the people they asked about:\n${String(body.people).slice(0, 2500)}`,
    );
  }
  // Where this conversation has got to: the queries already put to Gmail,
  // who it is about, what is still unanswered.
  //
  // None of this is in the transcript. The SEARCH lines are stripped before
  // the reader ever sees them, so they never come back in the history -- and
  // without this the model happily repeats a search that just found nothing
  // when it is asked to try again. Last in the preamble, because it is about
  // right now rather than about them.
  if (body.state) {
    facts.push(
      `Where this conversation has got to:\n${String(body.state).slice(0, 1200)}`,
    );
  }
  const preamble = facts.length ? `${facts.join("\n")}\n\n` : "";

  // The model may ask to look further rather than answer.
  //
  // The app used to decide this with keyword rules, and every one of them was
  // a guess at what somebody would type. "Find my upwork registration" needed
  // the literal words "welcome to upwork" before anything would search,
  // because no word list knows that a registration date lives in a welcome
  // email. The model knows. So it decides, and the app does the looking.
  // How many more times the model may ask to look before it has to answer.
  // Absent or zero means this is the last word.
  const hopsLeft = typeof body.hops_left === "number" ? body.hops_left : 0;
  // The app says so. It cannot be inferred from the history: the SEARCH
  // line is stripped from the turn before the reader ever sees it, so it is
  // never in the conversation that comes back.
  const hasSearched = body.searched === true;

  const searchRule = hopsLeft <= 0
    ? `You have already been given the results of a search; they are in the list
above alongside their recent mail. This is your last look, so answer from what
is here. If one of the messages is the thing they were looking for, show it
with a show block and put the answer to their question in the sentence beside
it. If it genuinely is not here, say "Nothing in your mail matched that." in
one plain sentence, not "recent mail": the whole account was searched. Do not
list what is here instead.`
    : `The messages above are only what the app picked out for this question:
the newest few, and the ones whose words matched. Their account holds years
more, and you can reach it.

If what they are asking for is not in the messages above, and it is the kind
of thing that would be in an email somewhere, do not tell them you cannot find
it. Reply with exactly one line and nothing else. There are two kinds of line,
and which one you choose is the whole skill.

When the question is about WHEN SOMETHING BEGAN, ask for the oldest mail:

OLDEST: from:linkedin | from:instagram

The account was created, the subscription started, the first order, the first
message from someone, when did I join, how long have I been with. Gmail hands
back the newest matches first, and a company that writes every day has years
of notifications on top of its welcome email, so searching for the welcome
finds the newest eight notifications and never the welcome. OLDEST walks back
to the very first mail matching each query instead. One query per thing they
asked about, separated by "|", using Gmail's from: where you know the sender
and plain words where you do not: "from:stripe", "from:twitter OR from:x.com",
"upwork". Do not add words like "welcome": the oldest mail from them is the
evidence whatever it says.

When you can SEE the right message but not enough of it, ask to read it:

OPEN: 3

Each message above is shown from its opening only. That is enough to know
what a message is and often not enough to answer from it: the ask in an
email usually comes after the paragraph explaining it, the amount is under
the pleasantries, the date is at the bottom. If the answer is in a message
you were given and you cannot see it, say OPEN: and the numbers, up to four,
separated by "|" or commas. You get those messages whole and everything else
as before. Use this before searching when the thing they asked about is
plainly one of the messages in front of you -- searching for what you are
already holding is the slowest way to answer.

When the question is about WHAT AN EMAIL SAID and you cannot see the message
at all, ask by wording:

SEARCH: words | different words | different words again

Think about what the evidence would actually look like, not about how they
phrased the question. They asked a question; the email was written by somebody
who had never heard it. "Did the invoice from Stripe get paid" is answered by
an email that says none of those words, so the hypotheses are the wordings the
email might really use:

SEARCH: stripe receipt | stripe payment succeeded | stripe invoice paid

Rules for each alternative:
- Two or three words. Never more. They are joined with AND, so every extra
  word makes it stricter and a five word guess matches nothing.
- Only words that would appear in the email itself. Not "registration", which
  is your word for it, unless the email would really say it.
- Two to four alternatives, separated by "|", best guess first.
- Gmail's from: and subject: are fine when you know them. No questions, no
  sentences.

You have ${hopsLeft} ${hopsLeft === 1 ? "look" : "looks"} left. ${
      hasSearched
        ? `A previous look has already run and what it found is in the list
above. If it missed, do not repeat it: if you searched by wording, try other
wording, or ask for OLDEST if the question is really about when something
started. If you asked for OLDEST and got nothing, the sender is probably
named differently: try the name as a plain word instead of from:.`
        : `Use it whenever looking would help.`
    }

Never explain that you are about to look: the line, and nothing else.`;

  // No digest and no inbox line means the app decided this has nothing to do
  // with their mail. Saying "nothing in your recent mail covers that" to
  // "what can you do?" is the wrong answer to the wrong question, and there
  // is nothing there worth searching for either.
  const aboutMail = digest.length > 0 || Boolean(body.inbox);

  const content = !aboutMail
    ? `${preamble}This is not a question about their mail.\n\nQuestion: ${question}`
    : digest
    ? `${preamble}Question: ${question}\n\nTheir messages:\n\n${digest}\n\n${searchRule}`
    : `${preamble}Question: ${question}\n\nThey have no matching recent messages.\n\n${searchRule}`;

  // The conversation so far, so follow-ups resolve. Only the two roles the
  // model expects, capped in count and length: the app sends what is on
  // screen, and a stray system-role turn from a client must never get in.
  const history = Array.isArray(body.history) ? body.history : [];
  const prior = history
    .slice(-6)
    .filter(
      (turn: Record<string, unknown>) =>
        (turn.role === "user" || turn.role === "assistant") &&
        typeof turn.content === "string" && turn.content.length > 0,
    )
    .map((turn: Record<string, string>) => ({
      role: turn.role,
      content: turn.content.slice(0, 700),
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

// ------------------------------------------------------- auto-reply runtime
//
// Writing one real reply on somebody's behalf.
//
// The whole safety model is the order of what follows. The boundaries are
// read before the person's own rules, and the rules carry the caveat that
// they cannot license a claim. An instruction can say how to write; it can
// never widen what may be said. Everything else is a consequence of that.
//
// The model is also allowed to refuse. `handled: false` with a reason is a
// first-class answer, and the app treats it as an escalation rather than a
// failure -- an assistant that cannot say "not this one" will answer
// everything, which is the failure mode that matters.

const AUTOREPLY_SYSTEM = `You are writing one reply on somebody's behalf, from
a setup they approved. You are not them; you write as their assistant.

Return JSON only, no prose:
{
  "handled": boolean,
  "reply": "the reply, ready to send, or empty when handled is false",
  "reason": "one sentence: why you answered, or why you did not",
  "category": "which of the kinds of mail they allowed this was",
  "evidence": ["the approved facts you used"],
  "withheld": ["what you did not answer, and why"],
  "confidence": 0.0
}

Answer only when ALL of these hold. Otherwise handled is false.
- The message is one of the kinds they allowed you to answer.
- Nothing in it touches anything on their "must come back to them" list. If
  any part does, the whole message goes back to them, even if you could have
  answered the rest.
- Every fact your reply states appears in what they told you. A price, a
  date, a policy, a promise, a name, an availability -- if it is not there,
  you do not have it and you may not produce it. Not from the email you are
  answering, not from what is usual in their industry, not from anywhere.

Writing it:
- Follow their rules for how you write. Those shape the wording only; they
  never let you state something you were not given, and they never override
  the two lists above.
- Answer what was actually asked. Do not add a sales pitch, do not invite
  further questions unless that is their style, and do not restate their
  question back at them.
- Where you can answer part of it and not the rest, answer the part and say
  plainly that you will come back on the rest. Put the rest in withheld.
- No subject line, no quoted original, no signature block beyond a short
  sign-off. Plain text.

confidence is how sure you are that this reply is correct and inside what
they allowed. Be honest and be harsh: 0.9 and above only when the message is
squarely one of their allowed kinds and every fact you used was handed to
you. Anything you had to interpret belongs below 0.7.`;

async function autoReply(body: Record<string, string>) {
  const content = [
    `Their setup:\n${body.briefing ?? ""}`,
    body.thread ? `\nEarlier in this conversation:\n${body.thread}` : "",
    `\nThe message to answer:\nFrom: ${body.from ?? ""}\nDate: ${body.date ?? ""}\nSubject: ${body.subject ?? ""}\n\n${(body.body ?? "").slice(0, AUTOREPLY_BODY_LIMIT)}`,
    body.today ? `\nToday is ${body.today}.` : "",
  ].join("\n");

  const raw = await openai(
    DRAFT_MODEL,
    [
      { role: "system", content: AUTOREPLY_SYSTEM },
      { role: "user", content },
    ],
    true,
  );

  const parsed = JSON.parse(raw);
  const list = (value: unknown) =>
    Array.isArray(value) ? value.filter((item) => typeof item === "string") : [];
  const reply = typeof parsed.reply === "string" ? parsed.reply.trim() : "";
  // A reply that came back empty is a refusal however the flag was set.
  const handled = parsed.handled === true && reply.length > 0;

  return json({
    handled,
    reply: handled ? reply : "",
    reason: typeof parsed.reason === "string" ? parsed.reason : "",
    category: typeof parsed.category === "string" ? parsed.category : "",
    evidence: list(parsed.evidence),
    withheld: list(parsed.withheld),
    confidence: typeof parsed.confidence === "number" ? parsed.confidence : 0,
    model: DRAFT_MODEL,
  });
}

/// More than the classifier reads. A request is often qualified halfway down
/// -- "and we'd need it before the 14th" -- and answering the top of an email
/// while missing that is exactly the mistake this must not make.
const AUTOREPLY_BODY_LIMIT = 3000;

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
      case "autoreply":
        return await autoReply(payload);
      case "autoreply_understanding":
        return await autoReplyUnderstanding(payload);
      case "autoreply_example":
        return await autoReplyExample(payload);
      case "extract":
        return await extract(payload);
      case "draft":
        return await draft(payload);
      case "refine":
        return await refine(payload);
      case "revise":
        return await revise(payload);
      case "search":
        return await search(payload);
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
