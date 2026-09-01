-- What people looked for.
--
-- Two jobs in one table, which is why it is one table. For the person, it is
-- the list of recent searches under an empty search box, so looking for the
-- same thing twice takes one tap. For the app, it is the honest answer to
-- "what do people actually come here to find", which is the question that
-- decides what gets built next.
--
-- Locked to the signed-in user by RLS, like everything else here. Aggregate
-- reporting runs in the dashboard under the service role, which bypasses RLS
-- by design.

create table if not exists public.searches (
  id          uuid primary key,
  user_id     uuid        not null references auth.users (id) on delete cascade,
  text        text        not null,
  -- 'mail' for a plain search, 'ai' for one the model wrote a query for.
  mode        text        not null default 'mail',
  -- How many came back. A search that found nothing is the interesting one.
  results     integer     not null default 0,
  created_at  timestamptz not null default now()
);

alter table public.searches enable row level security;

drop policy if exists "searches are private to their owner" on public.searches;
create policy "searches are private to their owner"
  on public.searches
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index if not exists searches_user_created_idx
  on public.searches (user_id, created_at desc);
create index if not exists searches_created_idx
  on public.searches (created_at desc);
