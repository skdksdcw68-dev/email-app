-- The categories a mailbox sorts into, following the account.
--
-- One more settings scope. Per mailbox, like `people` and `writing`: a
-- support inbox has "Support requests" and a personal one does not. The
-- payload is the whole list as one JSON string -- order, names, colours,
-- what the AI is told -- and last write wins per mailbox.
--
-- Nothing derived from mail is in it. Which messages landed in a category is
-- worked out on the phone and stays there; this is the list of labels the
-- person wrote, which is the same footing as the tone they chose.

alter table public.user_settings
    drop constraint if exists user_settings_scope_check;

alter table public.user_settings
    add constraint user_settings_scope_check
    check (scope in ('app', 'people', 'onboarding', 'autoreply', 'profile', 'writing', 'categories'));
