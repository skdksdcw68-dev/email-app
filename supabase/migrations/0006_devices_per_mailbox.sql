-- One phone, several mailboxes.
--
-- `devices` was keyed on the APNs token alone, which said: this phone
-- belongs to one mailbox. That was true when the app held one. With two it
-- fails in a way nobody would guess from the outside, because the failure is
-- silence:
--
--   The token is registered for whichever mailbox happened to be active when
--   APNs handed it over -- and APNs hands one over about once per install.
--   So in practice only the first mailbox somebody connected ever got a row,
--   and every account added afterwards received no notifications at all.
--   Worse, `upsert` merges on the primary key, so re-registering would have
--   overwritten the first mailbox rather than adding the second.
--
-- The key becomes the pair. One row per (phone, mailbox), which is what the
-- relationship actually is.
--
-- Additive and safe against the function that is deployed right now: the old
-- one selects `token, environment` and filters on an address column, and
-- both still exist afterwards. That ordering matters, because Supabase has
-- no CI here -- migrations and functions are both applied by hand, so a
-- schema change and a function change are never simultaneous.

-- `gmail_address` was honest when Gmail was the only provider. It is about
-- to hold Microsoft and IMAP addresses too.
alter table public.devices
    rename column gmail_address to address;

-- Which provider, so a notice can be routed without guessing from the
-- domain -- plenty of custom domains sit on Gmail, and plenty of
-- outlook.com addresses do not.
alter table public.devices
    add column if not exists provider text not null default 'gmail';

-- The app's own id for the mailbox, matching `mailbox_id` on chats and
-- searches (0005). Derived from provider + address, so it is stable and
-- carries no address in it -- which is what lets a push payload name a
-- mailbox without naming a person's email.
alter table public.devices
    add column if not exists mailbox_id text;

-- The change that actually fixes it.
alter table public.devices
    drop constraint if exists devices_pkey;

alter table public.devices
    add primary key (token, address);

-- The old index was on `lower(gmail_address)` while the function filters on
-- plain equality, so it was never used -- the app already lowercases before
-- writing. A plain index on the column is the one that gets picked.
drop index if exists devices_gmail_idx;

create index if not exists devices_address_idx
    on public.devices (address);

create index if not exists devices_mailbox_idx
    on public.devices (user_id, mailbox_id);

-- RLS is untouched and still the only guard: the anon key ships inside the
-- .ipa, so every policy stays keyed on auth.uid(). The webhook continues to
-- read under the service role, because Pub/Sub is not a signed-in user and
-- has to find devices for an address without being anybody.
