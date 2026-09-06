-- `live_subscription_key(uuid)` came out of 0023 callable by `anon` and
-- `authenticated`.
--
-- Not through PUBLIC -- 0023 revoked that, as 0020 says to -- but through the
-- project's default privileges, which grant EXECUTE on every new function in
-- `public` to both roles explicitly. `pg_proc.proacl` showed it:
--
--     {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}
--
-- It takes a user id and runs as definer, so a signed-in caller could read
-- anybody's `original_transaction_id`. Only the edge function and the two
-- functions that call it need it.
--
-- 🔴 The rule, now with its second half: a new function needs
-- `revoke ... from public, anon, authenticated` -- all three -- and then the
-- grant it actually needs. Check `proacl` afterwards, every time.

revoke execute on function public.live_subscription_key(uuid)
    from public, anon, authenticated;
grant execute on function public.live_subscription_key(uuid) to service_role;
