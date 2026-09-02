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

// ------------------------------------------------------------------ revise

// One requested change to a draft the assistant wrote, and nothing else.
// The failure mode to guard against is the model "helpfully" rewriting the
// whole thing when asked to warm up one line.
async function revise(body: Record<string, string>) {
  const tone = body.tone ?? "match how I already write";

  const system = `You revise an email draft. Apply exactly the change asked for and
nothing else.

Tone: ${tone}.

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
- Show at most eight. If more match, show the eight that matter and say how
  many there were. Show nothing when the answer is a number, a yes or no, or
  a summary across many messages; then it is prose, or stats.
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
        `${(message.body ?? "").slice(0, 400)}`,
      ].filter(Boolean).join("\n")
    )
    .join("\n\n");

  // What the app knows and the model never did: the date, who is asking,
  // how they like to be written to, and the shape of the whole inbox rather
  // than only the dozen messages that came with the question.
  const facts: string[] = [];
  if (body.today) facts.push(`Today is ${String(body.today).slice(0, 60)}.`);
  if (body.user) facts.push(`You are talking to ${String(body.user).slice(0, 80)}.`);
  if (body.tone) facts.push(`They like replies ${String(body.tone).slice(0, 120)}.`);
  if (body.inbox) facts.push(`Their whole inbox by tag: ${String(body.inbox).slice(0, 400)}.`);
  // What they have told you to remember, oldest first, so a later correction
  // reads as the last word on it.
  if (body.memories) {
    facts.push(`Things they have asked you to remember:\n${String(body.memories).slice(0, 2000)}`);
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
    : `The messages above are only the recent mail on their phone, roughly three
months of it. Their account holds years more, and you can reach it.

If what they are asking for is not in the messages above, and it is the kind
of thing that would be in an email somewhere, do not tell them you cannot find
it. Reply with exactly one line and nothing else:

SEARCH: words | different words | different words again

Think about what the evidence would actually look like, not about how they
phrased the question. They asked a question; the email was written by somebody
who had never heard it. "When was my Upwork account created" is answered by an
email that says none of those words, so the hypotheses are the wordings a
welcome email might really use:

SEARCH: upwork welcome | welcome to upwork | upwork account created

Rules for each alternative:
- Two or three words. Never more. They are joined with AND, so every extra
  word makes it stricter and a five word guess matches nothing.
- Only words that would appear in the email itself. Not "registration", which
  is your word for it, unless the email would really say it.
- Two to four alternatives, separated by "|", best guess first.
- No questions, no sentences, no Gmail operators.

You have ${hopsLeft} ${hopsLeft === 1 ? "look" : "looks"} left. ${
      hasSearched
        ? `A previous search has already run and what it found is in the list
above. If it missed, do not repeat the same words: think about what other
wording the email would have used, and try those instead.`
        : `Use it whenever looking would help.`
    }

Never explain that you are about to search: the line, and nothing else.`;

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
