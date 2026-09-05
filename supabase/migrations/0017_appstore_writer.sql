-- The writer `entitlements` never had.
--
-- 🔴 Every purchase took the money and wrote nothing.
--
-- `Store.swift` posts the signed transaction to `functions/v1/appstore`.
-- That function did not exist. The post is a `try?`, so the 404 was
-- swallowed; `transaction.finish()` ran anyway, and a finished consumable is
-- never redelivered. Somebody bought a credit pack, the charge went through,
-- `credit_usd` stayed at zero, and there was no way to recover it. Meanwhile
-- `entitlements` had no writer of any kind, so every account's effective
-- plan was `free` forever however much they paid.
--
-- This migration is the database half. The edge function verifies Apple's
-- signature; everything after that happens here, in one statement, because
-- the three things it does must not half-happen:
--
--   1. record the transaction, so a consumable cannot be credited twice
--   2. decide who owns the subscription
--   3. write the entitlement, but only for the owner
--
-- ⚠️ **One key, derived once.** Drobe derives its subscription key three
-- different ways, and the only path that can re-anchor a lapsed subscription
-- writes to a row nobody reads. Worse, when its RevenueCat call fails the key
-- silently changes mid-period and the account gets a fresh full allowance --
-- the exact reset the ledger existed to prevent, walked back in through the
-- key. Maily has exactly one: Apple's `original_transaction_id`. It is what
-- `spend_check` sums against, it is what `subscription_owner` is keyed on,
-- and it is the only thing Apple guarantees survives renewal, restore,
-- device change and reinstall.

-- Every Apple transaction this system has ever acted on.
--
-- The point is the primary key. Apple delivers the same transaction more than
-- once by design -- the app posts it, then the server notification arrives,
-- then the notification is retried -- and a consumable credited on each
-- delivery is money given away.
create table if not exists public.appstore_transactions (
    transaction_id          text primary key,
    original_transaction_id text,
    user_id                 uuid references auth.users(id) on delete set null,
    product_id              text,
    -- 'subscription' | 'credit'
    kind                    text not null,
    credited_usd            numeric(12, 6) not null default 0,
    created_at              timestamptz not null default now()
);

create index if not exists appstore_transactions_original_idx
    on public.appstore_transactions (original_transaction_id);

alter table public.appstore_transactions enable row level security;

-- 🔴 No policies. Service role only, like `entitlements` and
-- `subscription_owner`: a client that could write here could credit itself.

-- Ownership, with the one door Drobe got right.
--
-- The rule worth copying wholesale: ownership moves to a new payer **only**
-- when the previous period has genuinely lapsed, and never on a restore --
-- because a restore never lapses anything. Somebody who lets their
-- subscription die and somebody else who then subscribes on the same Apple ID
-- are a real sequence of events, and refusing the second person forever
-- because of the first is how a paying customer is turned away.
--
-- And Drobe's other principle, which this encodes: *money beats bookkeeping*.
-- A free rider costs one subscription; refusing somebody who has actually
-- paid costs the customer.
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

    -- Somebody else holds it. A restore stops here, always.
    if not coalesce(p_paid, false) then
        return owner;
    end if;

    -- Money has moved, from an account that is not the owner. It only
    -- re-anchors if the owner's own period has actually ended -- otherwise
    -- this is a second account restoring a live subscription, which is the
    -- attack the table exists to stop.
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

    return p_user_id;
end;
$$;

revoke execute on function public.claim_subscription(text, uuid, boolean) from anon, authenticated;

-- Applies one verified Apple transaction.
--
-- Called only by the `appstore` edge function, after it has checked Apple's
-- signature. Nothing here trusts the app: by the time these arguments exist
-- they have been read out of a payload signed by Apple's own certificate
-- chain.
create or replace function public.apply_appstore_transaction(
    p_user_id                 uuid,
    p_transaction_id          text,
    p_original_transaction_id text,
    p_product_id              text,
    p_kind                    text,
    p_plan                    text,
    p_expires_at              timestamptz,
    p_is_in_grace             boolean,
    p_revoked                 boolean,
    p_credit_usd              numeric,
    p_paid                    boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    owner   uuid;
    fresh   boolean := false;
    written int;
begin
    if p_user_id is null or p_transaction_id is null then
        return jsonb_build_object('applied', false, 'reason', 'no_user');
    end if;

    -- Who this subscription belongs to. Consumables have no
    -- `original_transaction_id` worth claiming, so they skip it.
    if p_original_transaction_id is not null and p_kind = 'subscription' then
        owner := public.claim_subscription(
            p_original_transaction_id, p_user_id, p_paid
        );
    else
        owner := p_user_id;
    end if;

    -- 🔴 The idempotency gate. `on conflict do nothing` and then asking
    -- whether a row appeared is the whole protection against crediting a
    -- consumable twice, and it has to be one statement -- check-then-insert
    -- loses the race between the app's post and Apple's notification, which
    -- routinely arrive within the same second.
    insert into public.appstore_transactions (
        transaction_id, original_transaction_id, user_id,
        product_id, kind, credited_usd
    ) values (
        p_transaction_id, p_original_transaction_id, owner,
        p_product_id, p_kind,
        case when p_kind = 'credit' then coalesce(p_credit_usd, 0) else 0 end
    )
    on conflict (transaction_id) do nothing;

    get diagnostics written = row_count;
    fresh := written > 0;

    if owner <> p_user_id then
        -- Somebody else owns it. Nothing is written for this account, and the
        -- caller is told plainly rather than being shown a plan that every
        -- request would then refuse.
        return jsonb_build_object(
            'applied', false, 'reason', 'other_account', 'first_seen', fresh
        );
    end if;

    if p_kind = 'credit' then
        -- Only on first sight. A replayed consumable is the one replay that
        -- costs real money.
        if not fresh then
            return jsonb_build_object('applied', false, 'reason', 'duplicate');
        end if;

        insert into public.entitlements (user_id, credit_usd, updated_at)
        values (owner, coalesce(p_credit_usd, 0), now())
        on conflict (user_id) do update
        set credit_usd = public.entitlements.credit_usd + coalesce(p_credit_usd, 0),
            updated_at = now();

        return jsonb_build_object('applied', true, 'kind', 'credit');
    end if;

    -- A subscription. Replaying this is harmless -- it writes the same state
    -- from the same signed receipt -- so unlike a consumable it is applied
    -- every time, which is what makes a retried notification self-healing.
    insert into public.entitlements (
        user_id, plan, original_transaction_id, product_id,
        expires_at, is_in_grace, updated_at
    ) values (
        owner,
        case when coalesce(p_revoked, false) then 'free' else coalesce(p_plan, 'free') end,
        p_original_transaction_id,
        p_product_id,
        case when coalesce(p_revoked, false) then now() else p_expires_at end,
        coalesce(p_is_in_grace, false),
        now()
    )
    on conflict (user_id) do update
    set plan = excluded.plan,
        original_transaction_id = excluded.original_transaction_id,
        product_id = excluded.product_id,
        expires_at = excluded.expires_at,
        is_in_grace = excluded.is_in_grace,
        updated_at = now();

    return jsonb_build_object(
        'applied', true,
        'kind', 'subscription',
        'plan', case when coalesce(p_revoked, false) then 'free' else coalesce(p_plan, 'free') end
    );
end;
$$;

revoke execute on function public.apply_appstore_transaction(
    uuid, text, text, text, text, text, timestamptz, boolean, boolean, numeric, boolean
) from anon, authenticated;

-- ⚠️ `entitlements.original_transaction_id` is `unique`, and it has to stay
-- that way: it is the subscription key `spend_check` sums against, and two
-- accounts holding the same one would split a single subscription's spend
-- into two full allowances. The upsert above can violate it -- an account
-- writing a key another row already holds -- and that is the correct
-- behaviour: it raises, the edge function returns 409, and nothing is
-- silently split. `claim_subscription` should have refused first; this is the
-- constraint that catches it if it did not.
