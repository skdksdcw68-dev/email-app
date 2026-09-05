-- Two ways `apply_appstore_transaction` could give away more than it meant to.
--
-- **1. A refund could eat into the plan's own allowance.** Apple refunds a
-- consumable by sending a REFUND notification, and the edge function turns
-- that into a negative credit. Nothing stopped the sum going below zero -- and
-- `spend_check` computes `ceiling + credit`, so a refund of credit somebody
-- had already spent would have quietly reduced their Pro allowance below $6.
-- Taking back unspent credit is right; charging a refund against the
-- subscription they are still paying for is not.
--
-- **2. A subscription with no expiry date was granted forever.**
-- `spend_check` reads a null `expires_at` as "no end", which is correct for a
-- brand-new row and dangerous for a written one. Apple always sends
-- `expiresDate` for an auto-renewable subscription, so a missing one means the
-- payload was not what we thought it was -- and the safe reading of "I do not
-- know when this ends" is not "never".

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
    gone    boolean;
begin
    if p_user_id is null or p_transaction_id is null then
        return jsonb_build_object('applied', false, 'reason', 'no_user');
    end if;

    gone := coalesce(p_revoked, false);

    -- A subscription that does not say when it ends is refused rather than
    -- granted open-endedly. See the note at the top.
    if p_kind = 'subscription' and not gone and p_expires_at is null then
        return jsonb_build_object('applied', false, 'reason', 'no_expiry');
    end if;

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
        return jsonb_build_object(
            'applied', false, 'reason', 'other_account', 'first_seen', fresh
        );
    end if;

    if p_kind = 'credit' then
        if not fresh then
            return jsonb_build_object('applied', false, 'reason', 'duplicate');
        end if;

        insert into public.entitlements (user_id, credit_usd, updated_at)
        values (owner, greatest(0, coalesce(p_credit_usd, 0)), now())
        on conflict (user_id) do update
        set credit_usd = greatest(
                0,
                public.entitlements.credit_usd + coalesce(p_credit_usd, 0)
            ),
            updated_at = now();

        return jsonb_build_object(
            'applied', true,
            'kind', 'credit',
            'refund', coalesce(p_credit_usd, 0) < 0
        );
    end if;

    -- A subscription. Replaying this is harmless -- it writes the same state
    -- from the same signed receipt -- so unlike a consumable it is applied
    -- every time, which is what makes a retried notification self-healing.
    insert into public.entitlements (
        user_id, plan, original_transaction_id, product_id,
        expires_at, is_in_grace, updated_at
    ) values (
        owner,
        case when gone then 'free' else coalesce(p_plan, 'free') end,
        p_original_transaction_id,
        p_product_id,
        case when gone then now() else p_expires_at end,
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
        'plan', case when gone then 'free' else coalesce(p_plan, 'free') end
    );
end;
$$;

revoke execute on function public.apply_appstore_transaction(
    uuid, text, text, text, text, text, timestamptz, boolean, boolean, numeric, boolean
) from anon, authenticated;
