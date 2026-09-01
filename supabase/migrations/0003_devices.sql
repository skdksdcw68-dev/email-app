-- Where to send a push, and for which mailbox.
--
-- Gmail's notification says only "something changed for this address, at this
-- history id". It carries no mail and no user id, so the address is the only
-- thing to look a device up by, and it is the reason `gmail_address` is here
-- rather than being derivable from `user_id`: one Maily account may connect a
-- different mailbox later, and one mailbox may be open on two phones.
--
-- The token is not a secret in the usual sense -- it is useless without the
-- APNs key -- but it identifies a device, so RLS applies like everywhere else.

create table if not exists public.devices (
  -- APNs device tokens are unique and stable per install, so they are the
  -- key. Reinstalling produces a new one; the old row ages out when APNs
  -- reports it unregistered.
  token          text primary key,
  user_id        uuid        not null references auth.users (id) on delete cascade,
  gmail_address  text        not null,
  -- 'production' for TestFlight and the App Store, 'sandbox' for a build run
  -- from Xcode. Sending a token to the wrong host fails as BadDeviceToken,
  -- which looks like a broken token rather than a wrong host, so the device
  -- says which one it is.
  environment    text        not null default 'production',
  bundle_id      text        not null,
  updated_at     timestamptz not null default now()
);

alter table public.devices enable row level security;

drop policy if exists "devices belong to their owner" on public.devices;
create policy "devices belong to their owner"
  on public.devices
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index if not exists devices_gmail_idx
  on public.devices (lower(gmail_address));

-- The webhook runs under the service role, which bypasses RLS: it has to find
-- devices for an address without being anybody, because Pub/Sub is not a
-- signed-in user.
