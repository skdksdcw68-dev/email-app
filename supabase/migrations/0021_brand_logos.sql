-- Sender logos, resolved once for everybody.
--
-- 🔴 The reason this exists is not caching, it is *where the work happens*.
--
-- Maily resolved a sender's logo on the phone, per row, while somebody was
-- scrolling: a DNS lookup, then maybe an apple-touch-icon fetch, then a
-- favicon fetch. Four round trips per newsletter, repeated on every device,
-- for every user, forever. Rows filled in one at a time and out of order, and
-- some never arrived at all. Abel's word for the result was "trash", and the
-- problem was never which sources were being asked.
--
-- Gmail and Shortwave resolve on a server, once, for every user. By the time a
-- message list reaches the phone each sender already has a URL attached, and
-- the phone's only job is to download a picture. That is what this table is.
--
-- The first person who ever receives mail from `tiktok.com` pays for the
-- lookup. Everybody after that -- every user, every device, every reinstall --
-- gets the answer instantly.

create table if not exists public.brand_logos (
    -- The organisational domain, lowercased: `tiktok.com`, never
    -- `e.tiktok.com`. Stripping happens before anything is stored, so one
    -- company is one row however many sending hosts it uses.
    domain      text primary key,

    -- Where the phone should fetch the picture. Usually the sender's own site
    -- or an icon service; for BIMI it points back at this project, because a
    -- BIMI logo is SVG and has to be rasterised before a phone can draw it.
    url         text,

    -- Rasterised BIMI only. Kept here rather than in Storage so there is no
    -- bucket to create, no public-access policy to get wrong, and nothing to
    -- clean up: a logo is a few kilobytes and there will never be many.
    png         bytea,

    -- 'bimi' | 'apple-touch-icon' | 'favicon' | 'none'. Worth recording: it is
    -- how you tell "we found the official mark" from "we scraped something",
    -- and how a bad tier gets found later.
    source      text,
    width       integer,

    -- ⚠️ A miss is a result and is stored like one. Without it, every domain
    -- that has no logo -- and there are many -- is re-probed by the server on
    -- every request forever.
    missing     boolean not null default false,

    resolved_at timestamptz not null default now()
);

create index if not exists brand_logos_resolved_idx
    on public.brand_logos (resolved_at);

alter table public.brand_logos enable row level security;

-- 🔴 No policies. Service role only, and the client never touches this table
-- -- it asks the `logos` edge function, which is what does the resolving. A
-- client that could write here could put any image next to any sender's name.
--
-- (And note what is *not* here: no user id, no message id, nothing about who
-- asked. A domain is the whole row. Somebody's mail cannot be reconstructed
-- from a list of companies that send mail to somebody, somewhere.)

-- ⏱ How long an answer stands, for whoever reads this next: a found logo is
-- good for 90 days and a miss is retried after 14, because a company that had
-- no logo last year may have published one since. The rule lives in the
-- `logos` function's query rather than here -- a helper taking a whole row
-- cannot be written as `(row public.brand_logos)` anyway, since `row` is
-- reserved.
