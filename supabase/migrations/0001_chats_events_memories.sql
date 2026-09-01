-- Maily's three tables.
--
-- Every one of them is locked to the signed-in user by Row Level Security,
-- and the policies are written against auth.uid() rather than a column the
-- client could set. The anon key in the app is public -- anyone can pull it
-- out of an .ipa -- so RLS is the only thing standing between one person's
-- rows and another's, and it must hold on its own.

-- ---------------------------------------------------------------- chats
--
-- Conversations with the assistant, so they follow the person to a new
-- phone. `turns` is the same JSON the app already writes to disk, kept whole
-- rather than shredded into rows: a conversation is only ever read and
-- written as one thing, and there is nothing to query inside it that the app
-- does not already hold.
--
-- These contain quoted email content. That is a deliberate product decision,
-- and it is the reason the RLS policy below has no exceptions in it.

create table if not exists public.chats (
  id          uuid primary key,
  user_id     uuid        not null references auth.users (id) on delete cascade,
  title       text        not null default 'New chat',
  turns       jsonb       not null default '[]'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.chats enable row level security;

drop policy if exists "chats are private to their owner" on public.chats;
create policy "chats are private to their owner"
  on public.chats
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index if not exists chats_user_updated_idx
  on public.chats (user_id, updated_at desc);

-- --------------------------------------------------------------- events
--
-- Product analytics: who uses the app, what they use it for, what they ask
-- the assistant about, and where it fails them.
--
-- `properties` carries shape, never content: how long a question was, whether
-- it needed the mailbox, how many emails were retrieved, whether the answer
-- became a draft and whether that draft was sent. What the person actually
-- typed is not in here. Their chats are already synced above if they are
-- signed in, and duplicating the text into an analytics table would mean two
-- places to honour a deletion instead of one.

create table if not exists public.events (
  id          bigint generated always as identity primary key,
  user_id     uuid        not null references auth.users (id) on delete cascade,
  name        text        not null,
  properties  jsonb       not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

alter table public.events enable row level security;

-- Write-only from the app. A client can add its own events and read its own
-- history back; it can never see anybody else's. Aggregate reporting runs in
-- the dashboard under the service role, which bypasses RLS by design.
drop policy if exists "people can record their own events" on public.events;
create policy "people can record their own events"
  on public.events
  for insert
  with check (auth.uid() = user_id);

drop policy if exists "people can read their own events" on public.events;
create policy "people can read their own events"
  on public.events
  for select
  using (auth.uid() = user_id);

create index if not exists events_name_created_idx
  on public.events (name, created_at desc);
create index if not exists events_user_created_idx
  on public.events (user_id, created_at desc);

-- ------------------------------------------------------------- memories
--
-- What the assistant has been told to remember about the person: "I sign off
-- as Abel", "keep replies to three lines", "Yohannes is my accountant".
-- Small, few, and read on every question, so they are their own table rather
-- than a blob on the account.

create table if not exists public.memories (
  id          uuid primary key,
  user_id     uuid        not null references auth.users (id) on delete cascade,
  fact        text        not null,
  created_at  timestamptz not null default now()
);

alter table public.memories enable row level security;

drop policy if exists "memories are private to their owner" on public.memories;
create policy "memories are private to their owner"
  on public.memories
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index if not exists memories_user_created_idx
  on public.memories (user_id, created_at desc);
