-- Memories get a kind and an end date.
--
-- "Keep replies short" holds until it is changed; "travelling until the
-- 12th" stops being true on the 13th, and an assistant still applying it in
-- October is worse than one that never knew. The model decides both at the
-- moment the person says it; the app stops sending an expired one.
--
-- Rows written before this have neither, and every one of them was a
-- preference, which is what the default says. Row-level security is
-- untouched: the owner policy from 0001 still gates every row.

alter table public.memories
  add column if not exists kind text not null default 'preference',
  add column if not exists expires_at timestamptz;

alter table public.memories
  drop constraint if exists memories_kind_check;

alter table public.memories
  add constraint memories_kind_check
  check (kind in ('preference', 'about_me', 'person', 'situation'));
