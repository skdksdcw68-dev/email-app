-- Which mailbox a synced row belongs to.
--
-- Chats and searches are both derived from mail: a conversation quotes
-- messages, a search remembers how many results a mailbox returned. Neither
-- carried a mailbox column, because until now there was only one -- and the
-- app's disconnect path called an unqualified DELETE on the whole table.
--
-- With two mailboxes that is destructive in a way nobody would expect:
-- disconnecting one account wiped every conversation and every saved search
-- the person had, on every device. This column is what lets the delete say
-- which mailbox it means.
--
-- Nullable on purpose. Rows written before this are backfilled by the app on
-- first launch of the build that migrates the mailbox, and a row that somehow
-- misses out is still readable -- it simply is not tied to a mailbox, which
-- is exactly what it was yesterday.

alter table public.chats
    add column if not exists mailbox_id text;

alter table public.searches
    add column if not exists mailbox_id text;

-- Deletes and reads both filter on (user_id, mailbox_id), so index the pair.
create index if not exists chats_mailbox_idx
    on public.chats (user_id, mailbox_id);

create index if not exists searches_mailbox_idx
    on public.searches (user_id, mailbox_id);

-- RLS is unchanged and still the only guard: the anon key ships inside the
-- .ipa, so every policy stays keyed on auth.uid() and nothing here trusts a
-- filter the client sent. mailbox_id narrows what a signed-in person asks
-- for; it does not decide what they are allowed to see.
