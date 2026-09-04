-- Everything you taught Maily, following the account rather than the phone.
--
-- Today almost none of it does. `AppSettings`, `PersonPreferences`, the
-- onboarding answers and the whole Auto-Reply setup live in `UserDefaults` or
-- in a JSON file, so a new phone starts blank: the tone every draft is written
-- in resets to "match how I already write", every important and muted sender
-- is forgotten, and the eleven-question Auto-Reply setup has to be answered
-- again from nothing. Only chats, searches and memories follow the person.
--
-- Four rows per user rather than one blob, because the four documents are
-- written at wildly different rates. `people` changes every time somebody taps
-- "important" while scrolling; `autoreply` changes during a setup flow and
-- then almost never. One blob would rewrite the entire Auto-Reply config on
-- every star -- and, worse, one blob means one conflict: change your tone on
-- the phone and star a sender on the iPad, and last-write-wins throws one of
-- them away wholesale.
--
-- Additive. Nothing reads this until the app that writes it ships.

create table if not exists public.user_settings (
    user_id           uuid  not null references auth.users(id) on delete cascade,
    -- 'app' | 'people' | 'onboarding' | 'autoreply'
    scope             text  not null,
    payload           jsonb not null default '{}'::jsonb,

    -- The *device's* clock, and what last-write-wins is decided on. Kept
    -- separate from `server_updated_at` because a phone with a wrong clock
    -- should not be able to lie about when the server received something.
    updated_at        timestamptz not null,
    server_updated_at timestamptz not null default now(),

    -- Which phone wrote it. Not used for conflict resolution -- only for
    -- working out, later, why two devices disagree.
    device_id         text,

    primary key (user_id, scope),
    constraint user_settings_scope_check
        check (scope in ('app', 'people', 'onboarding', 'autoreply'))
);

create index if not exists user_settings_user_idx
    on public.user_settings (user_id);

alter table public.user_settings enable row level security;

-- Client-written, unlike the metering and entitlement tables. These are the
-- person's own preferences and the app has to be able to save them.
drop policy if exists "settings are private to their owner" on public.user_settings;

create policy "settings are private to their owner"
    on public.user_settings for all
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- A clock ahead of the server gets clamped, not rejected.
--
-- `updated_at` decides which write wins, and it comes from the device. A phone
-- set a year into the future would otherwise win every conflict it ever had,
-- permanently, and nothing the person did on any other device would stick.
-- Rejecting the write instead would lose a real edit over a wrong clock, so it
-- lands -- it just cannot claim to be from the future.
create or replace function public.clamp_settings_clock()
returns trigger
language plpgsql
as $$
begin
    new.server_updated_at := now();
    if new.updated_at > now() + interval '24 hours' then
        new.updated_at := now();
    end if;
    return new;
end;
$$;

drop trigger if exists user_settings_clamp on public.user_settings;

create trigger user_settings_clamp
    before insert or update on public.user_settings
    for each row execute function public.clamp_settings_clock();

-- ⚠️ What is deliberately NOT here, and why it is a rule rather than an
-- oversight.
--
-- Nothing derived from the content of anybody's mail. Not the classification
-- cache (model-written summaries of message bodies), not the semantic index
-- (`SemanticIndex.swift` says outright that the day it becomes a server call
-- is the day the app is in breach), not `FactStore` (commitments read out of
-- message text), and none of `MailboxMigration.scopedKeys` -- read state,
-- snoozes, history ids -- which belong to a mailbox on a device rather than
-- to a person.
--
-- Gmail's Limited Use terms are the line. `0001` records the one deliberate
-- exception, `chats`, and this is not a second one.
--
-- ⚠️ One thing here is close to the line and is called out rather than
-- waved through: `people.important` and `people.muted` are **email
-- addresses**, and an address is Gmail data. They are here because they are
-- metadata rather than content, and because a person put them there by
-- tapping a star -- not because a model read a message. That is the same
-- footing the `chats` exception rests on, and `chats` carries quoted bodies,
-- which is far more exposed. It is still a new category of Gmail-derived data
-- leaving the device, and the privacy policy has to say so.
