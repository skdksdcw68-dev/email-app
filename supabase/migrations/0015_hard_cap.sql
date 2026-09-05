-- Max at 2.5x Pro, and a hard cap nothing gets past.
--
-- Abel: "make it 2.5x usage but cap it with 5x".
--
-- Max moves from $11 to $15 so the paywall can say "2.5x the usage of Pro"
-- and have it be literally true, rather than the 1.83x it was.
--
-- 🔴 The cap is the important half, and it is not a revenue rule.
--
-- Everything else in this system fails open on purpose: `spend_check` in the
-- edge function lets a request through when the database cannot be reached,
-- because refusing on failure would stop every paying subscriber during an
-- outage. That trade is only safe if there is a floor underneath it. This is
-- the floor -- 5x the Pro allowance, whatever the plan, whatever has been
-- bought. It is the distance between a runaway loop and an unbounded OpenAI
-- bill.
--
-- Bought credit stops here too. Somebody who has genuinely paid for more than
-- $30 of provider cost in one month is a conversation, not an automatic
-- top-up.

create or replace function public.spend_check(for_user uuid)
returns table (
    plan          text,
    allowance_usd numeric,
    spent_usd     numeric,
    credit_usd    numeric,
    is_allowed    boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
    held      public.entitlements%rowtype;
    effective text;
    ceiling   numeric;
    used      numeric;
    subkey    text;
    credit    numeric;
    hard_cap  numeric;
begin
    select * into held from public.entitlements where user_id = for_user;

    effective := coalesce(held.plan, 'free');
    -- Grace is deliberately still paid: somebody whose card failed this
    -- morning has not stopped being a customer.
    if held.expires_at is not null
       and held.expires_at < now()
       and not coalesce(held.is_in_grace, false) then
        effective := 'free';
    end if;

    ceiling := case effective
                   when 'pro' then 6.0
                   when 'max' then 15.0
                   else 0.30
               end;

    -- 5x Pro, not 5x this plan. A fixed ceiling is the point: it does not
    -- move when somebody upgrades, so the worst case is knowable.
    hard_cap := 30.0;

    subkey := held.original_transaction_id;

    if subkey is null then
        select coalesce(sum(u.cost_usd), 0) into used
        from public.ai_usage u
        where u.user_id = for_user
          and u.created_at >= date_trunc('month', now());
    else
        -- Against the subscription. Every account that has ever held it
        -- counts towards one total, which is what makes restoring on a fresh
        -- account worthless.
        select coalesce(sum(u.cost_usd), 0) into used
        from public.ai_usage u
        where u.subscription_key = subkey
          and u.created_at >= date_trunc('month', now());
    end if;

    credit := coalesce(held.credit_usd, 0);

    return query select
        effective,
        ceiling,
        used,
        credit,
        (used < least(ceiling + credit, hard_cap));
end;
$$;

revoke execute on function public.spend_check(uuid) from anon, authenticated;
