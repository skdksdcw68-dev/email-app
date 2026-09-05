-- A fifth settings scope: who you are, as distinct from what you answered.
--
-- `onboarding` holds the eight question answers. The display name, the
-- occupation and the profile picture were being lumped in with them, which is
-- wrong twice over: they change for different reasons, and the picture is
-- fifty kilobytes that would be re-sent every time somebody changed an answer
-- about how they like their mail sorted.
--
-- The immediate reason is smaller and worse: `displayName` was not in the
-- payload at all. Pressing Save on Edit profile wrote it to UserDefaults and
-- nowhere else, so a new phone showed the name from whichever provider signed
-- you in, and the one you chose was gone.

alter table public.user_settings
    drop constraint if exists user_settings_scope_check;

alter table public.user_settings
    add constraint user_settings_scope_check
    check (scope in ('app', 'people', 'onboarding', 'autoreply', 'profile'));
