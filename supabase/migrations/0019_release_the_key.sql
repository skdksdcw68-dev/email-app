-- Re-anchoring could not actually happen.
--
-- Found by running the sequence rather than reading it: A subscribes, A's
-- subscription lapses, B subscribes on the same Apple ID. `claim_subscription`
-- correctly moved ownership to B -- and then the entitlement write for B threw
--
--     duplicate key value violates unique constraint
--     "entitlements_original_transaction_id_key"
--
-- because A's row still held `orig-1`. The whole transaction rolled back, so B
-- had paid and received nothing, and the one door this design deliberately
-- left open was welded shut.
--
-- ⚠️ The unique constraint is right and stays. Two accounts holding one
-- subscription key would split a single subscription's spend into two full
-- allowances, which is the exact abuse the ledger exists to prevent. What was
-- missing is that a hand-over has two halves: the new owner takes the key, and
-- the old owner has to let go of it.
--
-- Letting go is not a punishment. By the time this runs the previous owner's
-- period has already been checked to have ended -- they are not losing a
-- subscription, they are losing the record of one that already expired. Their
-- usage rows keep the key (`ai_usage.subscription_key`), so the month's spend
-- still counts against the subscription and B inherits it until the 1st. That
-- inheritance is the whole anti-abuse property and it is deliberate.

create or replace function public.claim_subscription(
    p_original_app_user_id text,
    p_user_id uuid,
    p_paid boolean
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    owner       uuid;
    owner_ends  timestamptz;
begin
    insert into public.subscription_owner (original_app_user_id, user_id)
    values (p_original_app_user_id, p_user_id)
    on conflict (original_app_user_id) do nothing;

    select o.user_id into owner
    from public.subscription_owner o
    where o.original_app_user_id = p_original_app_user_id;

    if owner is null or owner = p_user_id then
        return p_user_id;
    end if;

    -- Somebody else holds it. A restore stops here, always: a restore never
    -- lapses anything, so it can never be the event that hands a subscription
    -- to a different account.
    if not coalesce(p_paid, false) then
        return owner;
    end if;

    select e.expires_at into owner_ends
    from public.entitlements e
    where e.user_id = owner;

    if owner_ends is null or owner_ends > now() then
        return owner;
    end if;

    update public.subscription_owner
    set user_id        = p_user_id,
        claimed_at     = now(),
        released_at    = now(),
        released_by    = 'lapsed',
        transferred_to = p_user_id
    where original_app_user_id = p_original_app_user_id;

    -- 🔴 The half that was missing. Without it the caller's own entitlement
    -- write fails on the unique key and the entire hand-over rolls back.
    update public.entitlements
    set original_transaction_id = null,
        plan                    = 'free',
        is_in_grace             = false,
        updated_at              = now()
    where user_id = owner
      and original_transaction_id = p_original_app_user_id;

    return p_user_id;
end;
$$;

revoke execute on function public.claim_subscription(text, uuid, boolean) from anon, authenticated;
