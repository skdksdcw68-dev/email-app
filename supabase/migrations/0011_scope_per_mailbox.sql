-- Settings that belong to one address, rather than to the person.
--
-- `user_settings` was keyed (user_id, scope), which assumed every setting
-- belongs to the *account*. Two of them do not:
--
--   people  -- who matters and who is muted. Marking an accountant important
--             in a work inbox should not mark them important in a personal
--             one. They are a different relationship at each address.
--
--   writing -- tone and custom instructions. This is the strongest case of
--             all: the voice is the thing most obviously tied to who is
--             receiving the mail. Formal from work@, casual from personal@.
--
-- So the key gains a mailbox. Nullable, because most scopes stay
-- account-wide -- appearance, the onboarding answers, the profile, the
-- Auto-Reply setup -- and a null there means "everywhere".

alter table public.user_settings
    add column if not exists mailbox_id text;

-- The primary key has to change with it. A per-mailbox scope needs one row
-- per mailbox, and the old key allowed exactly one row per scope.
alter table public.user_settings
    drop constraint if exists user_settings_pkey;

-- Nulls do not compare equal in a unique index, so a plain (user_id, scope,
-- mailbox_id) key would let an account-level scope be inserted twice. The
-- empty string stands in for "no mailbox" instead, which does compare.
alter table public.user_settings
    alter column mailbox_id set default '';

update public.user_settings set mailbox_id = '' where mailbox_id is null;

alter table public.user_settings
    alter column mailbox_id set not null;

alter table public.user_settings
    add constraint user_settings_pkey primary key (user_id, scope, mailbox_id);

alter table public.user_settings
    drop constraint if exists user_settings_scope_check;

alter table public.user_settings
    add constraint user_settings_scope_check
    check (scope in ('app', 'people', 'onboarding', 'autoreply', 'profile', 'writing'));

-- ⚠️ The existing `people` rows are left where they are, keyed to the empty
-- mailbox. They are somebody's real stars and mutes, and throwing them away
-- to make the model tidy would be a worse trade than carrying them: the app
-- reads the account-level row as a starting point when a mailbox has none of
-- its own, and writes per-mailbox from then on.

-- Chats stop being per-mailbox.
--
-- One assistant, one history, whichever inbox is open. The column stays --
-- it still records *where a conversation happened*, which is worth knowing
-- and is what stops an answer citing mail from an address you are not
-- looking at -- but nothing filters on it any more.
comment on column public.chats.mailbox_id is
    'Which mailbox was active when this conversation happened. Recorded, not filtered on: the history is one list across every mailbox.';
