-- One subscription, one Maily account.
--
-- Taken from Drobe, where it was learned the hard way, and it closes a hole
-- `entitlements` had no concept of.
--
-- RevenueCat's Restore Behavior is a dashboard setting with no API. Until it
-- is changed, restoring a purchase on a second account hands that account the
-- entitlement -- and the failure is worse than it first looks, because it goes
-- wrong in both directions at once:
--
--   * the stranger who restored it is shown Pro the server will refuse, so the
--     app draws a plan that does not work; and
--   * the person who actually paid stops looking entitled to RevenueCat, so
--     the app takes Pro away from the one account that is definitely owed it.
--
-- RevenueCat deciding B holds the entitlement is not the same as Maily
-- deciding B gets Pro. This table is Maily's own answer and does not care what
-- the dashboard says: the first account seen with a given subscription claims
-- it, and every other account is refused, restore or no restore. Flipping the
-- setting later cannot change an ownership already recorded here.

create table if not exists public.subscription_owner (
    -- RevenueCat's stable identity for the subscription. Survives transfer,
    -- restore, device change and reinstall, which is exactly why it is the
    -- key rather than a transaction id.
    original_app_user_id text primary key,

    user_id     uuid not null references auth.users(id) on delete cascade,
    claimed_at  timestamptz not null default now(),

    -- The legitimate hand-over: somebody really did mean to move their
    -- subscription to another account. This whole table exists to make that
    -- hard, so it needs one deliberate door rather than none.
    released_at    timestamptz,
    released_by    text,
    transferred_to uuid references auth.users(id) on delete set null
);

create index if not exists subscription_owner_user_idx
    on public.subscription_owner (user_id);

alter table public.subscription_owner enable row level security;

-- 🔴 No policies at all. Service role only: an account that could write here
-- could claim somebody else's subscription, which is the entire thing being
-- prevented.

-- Claims a subscription for an account, or reports who already holds it.
--
-- Returns the *owning* user id -- the caller's own when the claim succeeded or
-- was already theirs, somebody else's when it was not. One statement, so two
-- devices racing to restore cannot both win.
create or replace function public.claim_subscription(
    p_original_app_user_id text,
    p_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    owner uuid;
begin
    insert into public.subscription_owner (original_app_user_id, user_id)
    values (p_original_app_user_id, p_user_id)
    on conflict (original_app_user_id) do nothing;

    select o.user_id into owner
    from public.subscription_owner o
    where o.original_app_user_id = p_original_app_user_id;

    -- A released subscription is claimable again, by whoever asks next.
    if owner is null then
        return p_user_id;
    end if;

    return owner;
end;
$$;

revoke execute on function public.claim_subscription(text, uuid) from anon, authenticated;
