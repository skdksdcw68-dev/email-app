-- 🔴 Every "revoked" function in this project was callable by anyone.
--
-- Proved against production with nothing but the anon key, which ships inside
-- the .ipa and is public by design:
--
--     POST /rest/v1/rpc/apply_appstore_transaction
--     {"p_user_id": "<any account>", "p_plan": "max", ...}
--     -> 409, foreign key violation
--
-- A foreign key violation means it **ran**. With a real user id it would have
-- written the row -- so anybody who unzipped the app could have given
-- themselves Max, any expiry date, and any amount of credit, and the entire
-- billing system was decoration.
--
-- ## Why every one of these was wrong
--
-- Postgres grants `EXECUTE` to `PUBLIC` on every function at creation. Every
-- migration here ended with
--
--     revoke execute on function ... from anon, authenticated;
--
-- and that does nothing at all. `anon` and `authenticated` never held a grant
-- of their own to revoke -- they could call it through `PUBLIC`, and revoking
-- a privilege somebody does not directly hold is a silent no-op. The line
-- reads exactly like a lock and is not one, which is why it survived five
-- migrations and a security review.
--
--     ✅  revoke execute on function ... from public;
--     ❌  revoke execute on function ... from anon, authenticated;
--
-- `pg_proc.proacl` shows it: an entry with an empty grantee (`=X/postgres`)
-- *is* the PUBLIC grant. `record_ai_usage` was the only function in the schema
-- without one, and it was the only one actually protected.
--
-- ⚠️ Tables were never affected. `anon` holds full table grants -- that is the
-- normal Supabase arrangement -- and row level security is what refuses the
-- writes. `entitlements`, `subscription_owner` and `appstore_transactions`
-- have no write policies at all, so RLS denies everything. The functions were
-- the hole precisely because `security definer` runs past RLS by design.

revoke execute on function public.spend_check(uuid) from public;

revoke execute on function public.claim_subscription(text, uuid) from public;
revoke execute on function public.claim_subscription(text, uuid, boolean) from public;

revoke execute on function public.apply_appstore_transaction(
    uuid, text, text, text, text, text, timestamptz, boolean, boolean, numeric, boolean
) from public;

-- The one a signed-in person is *meant* to call. It takes no argument and
-- reads `auth.uid()` itself, so it cannot be asked about anybody else -- but
-- there is no reason for a signed-out caller to reach it either.
revoke execute on function public.my_spend() from public, anon;
grant execute on function public.my_spend() to authenticated;

-- Said out loud rather than relied on. `service_role` holds its own explicit
-- grant on each of these, so removing PUBLIC does not touch the edge
-- functions -- but a future `revoke ... from public` on a function that has
-- no explicit service-role grant would take the backend down, and the failure
-- would look like a bug in the caller.
grant execute on function public.spend_check(uuid) to service_role;
grant execute on function public.claim_subscription(text, uuid, boolean) to service_role;
grant execute on function public.apply_appstore_transaction(
    uuid, text, text, text, text, text, timestamptz, boolean, boolean, numeric, boolean
) to service_role;

-- 🔴 For everything written after this: a new `security definer` function is
-- world-callable the moment it is created. Revoke from `public`, then grant to
-- the one role that should have it. Nothing else is a lock.
