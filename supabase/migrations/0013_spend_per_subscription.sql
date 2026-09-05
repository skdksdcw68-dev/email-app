-- Count the allowance against the subscription, not the account.
--
-- 🔴 This closes the hole Drobe was actually attacked through, before Maily
-- ships rather than after.
--
-- `spend_check` in 0010 summed `ai_usage where user_id = X` -- a property of
-- the ACCOUNT -- against a ceiling that belongs to the SUBSCRIPTION. Those are
-- two different things the moment a subscription can move between accounts,
-- and moving one is a button in the App Store:
--
--   Buy Pro on account A. Spend the whole $6. Make account B with a throwaway
--   address, press Restore. The subscription transfers, the period is
--   unchanged -- but B has no `ai_usage` rows, so `spent` is zero and B gets
--   another $6. Repeat for as long as somebody can make email addresses.
--
-- Drobe priced its version of this at $1.20 an account, unbounded. Maily's
-- ceiling is five times that.
--
-- The fix is the one RevenueCat makes possible: `original_app_user_id` is the
-- App User ID that FIRST bought, and it survives every transfer, restore,
-- device change and reinstall. Spend counted against that follows the
-- subscription wherever it goes, so a transfer arrives at a total that already
-- knows what has been spent.
--
-- ⚠️ This holds whichever way RevenueCat's Restore Behavior is set. That
-- setting decides *who* gets the plan; this decides how much allowance came
-- with it. Separate problems, and the dashboard cannot fix this one.

-- Which subscription a person's spending belongs to. Null for somebody who
-- has never subscribed -- their spend is their own, and the free ceiling is
-- per account by definition.
alter table public.ai_usage
    add column if not exists subscription_key text;

create index if not exists ai_usage_subscription_period_idx
    on public.ai_usage (subscription_key, created_at desc)
    where subscription_key is not null;

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
                   when 'max' then 11.0
                   else 0.30
               end;

    subkey := held.original_transaction_id;

    if subkey is null then
        -- No subscription: spend is the account's own, and so is the free
        -- ceiling. Nothing to carry between accounts because nothing was
        -- bought.
        select coalesce(sum(u.cost_usd), 0) into used
        from public.ai_usage u
        where u.user_id = for_user
          and u.created_at >= date_trunc('month', now());
    else
        -- 🔴 Against the subscription. Every account that has ever held this
        -- subscription counts towards one total, which is what makes the
        -- restore trick worthless.
        select coalesce(sum(u.cost_usd), 0) into used
        from public.ai_usage u
        where u.subscription_key = subkey
          and u.created_at >= date_trunc('month', now());
    end if;

    return query select
        effective,
        ceiling,
        used,
        coalesce(held.credit_usd, 0),
        (used < ceiling + coalesce(held.credit_usd, 0));
end;
$$;

revoke execute on function public.spend_check(uuid) from anon, authenticated;

-- Usage is stamped with the subscription that was paying at the time.
--
-- Read from the entitlements table inside the function rather than passed in:
-- a caller that could name its own subscription key could spend against somebody else's
-- allowance, or against a key nobody is watching.
--
-- ⚠️ Parameter names are 0007's exactly. Postgres refuses to rename an input
-- parameter through create-or-replace, and renaming them would mean
-- dropping the function -- which the deployed ai edge function calls by
-- name right now.
create or replace function public.record_ai_usage(
    p_user       uuid,
    p_action     text,
    p_model      text,
    p_prompt     integer,
    p_cached     integer,
    p_completion integer,
    p_reasoning  integer
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
    price  public.ai_model_prices%rowtype;
    cost   numeric(12, 6);
    subkey text;
begin
    select * into price from public.ai_model_prices where model = p_model;
    if not found then
        -- An unpriced model is recorded at zero rather than dropped. Losing
        -- the token counts would make the cost unrecoverable; a zero is
        -- visibly wrong and can be recomputed once the rate is added.
        cost := 0;
    else
        cost := (greatest(p_prompt - p_cached, 0)::numeric / 1000000) * price.input_per_mtok
              + (p_cached::numeric / 1000000) * price.cached_input_per_mtok
              + ((p_completion + coalesce(p_reasoning, 0))::numeric / 1000000) * price.output_per_mtok;
    end if;

    select e.original_transaction_id into subkey
    from public.entitlements e where e.user_id = p_user;

    insert into public.ai_usage (
        user_id, subscription_key, action, model,
        prompt_tokens, cached_tokens, completion_tokens, reasoning_tokens, cost_usd
    ) values (
        p_user, subkey, p_action, p_model,
        p_prompt, p_cached, p_completion, p_reasoning, cost
    );

    return cost;
end;
$$;

revoke execute on function public.record_ai_usage(uuid, text, text, integer, integer, integer, integer)
    from anon, authenticated;
