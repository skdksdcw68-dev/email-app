-- What the ledger got wrong, found by reading the ledger rather than the code.
--
-- Two of the three faults behind "the AI usage is not correct" are fixed here;
-- the third -- gpt-5-nano thinking for a thousand tokens before answering
-- "important" -- is one line in the edge function.
--
-- 🔴 1. gpt-5.6-luna has been priced at $1.25 in / $10 out since 0007. OpenAI
-- cut it to $0.20 / $0.02 cached / $1.20 on 30 July 2026, and the table never
-- heard. Every chat turn was metered at 5.4x what it cost. `ai_model_prices`
-- is effective-dated for exactly this: a new row from the day of the cut, and
-- `record_ai_usage` picks it up for every call from now on. The rows already
-- written are re-rated from their token counts -- 0007 kept the counts so a
-- wrong rate would never be permanent.
--
-- 🔴 2. The subscription key outlived the subscription. `record_ai_usage`
-- stamped every row with `entitlements.original_transaction_id` whether or
-- not that subscription was still live, and `spend_check` summed by that key
-- whenever one existed. So a lapsed Max subscriber, back on free, had the
-- paid month's $12 checked against a $0.30 ceiling -- blocked on the first
-- call -- and, worse, their lapsed-period rows kept the old key and never
-- counted against anything. One definition of "which subscription is paying",
-- used by both sides: the key while the subscription is live, null otherwise.
-- Free spend is what the *account* spent while free.

-- ---------------------------------------------------------------- 1. luna

insert into public.ai_model_prices
    (model, effective_from, input_per_mtok, cached_input_per_mtok, output_per_mtok)
values
    ('gpt-5.6-luna', '2026-07-30', 0.200000, 0.020000, 1.200000)
on conflict (model, effective_from) do nothing;

-- Re-rate what was written at the old rate. Same arithmetic as
-- `record_ai_usage`: cached tokens are part of prompt tokens, reasoning
-- tokens are part of completion tokens.
update public.ai_usage u
set cost_usd = (greatest(u.prompt_tokens - u.cached_tokens, 0)::numeric / 1000000) * 0.200000
             + (u.cached_tokens::numeric / 1000000) * 0.020000
             + (u.completion_tokens::numeric / 1000000) * 1.200000
where u.model = 'gpt-5.6-luna'
  and u.created_at >= '2026-07-30';

-- ---------------------------------------------- 2. which subscription pays

-- The key only while the subscription is live: a plan that is not free, and
-- either no expiry, an expiry still ahead, or a grace period. The same test
-- `spend_check` applies to decide the effective plan, so the two can never
-- disagree about whether somebody is paying.
create or replace function public.live_subscription_key(for_user uuid)
returns text
language sql
security definer
set search_path = public
stable
as $$
    select e.original_transaction_id
    from public.entitlements e
    where e.user_id = for_user
      and e.original_transaction_id is not null
      and coalesce(e.plan, 'free') <> 'free'
      and (
          e.expires_at is null
          or e.expires_at > now()
          or coalesce(e.is_in_grace, false)
      );
$$;

revoke execute on function public.live_subscription_key(uuid) from public;
grant execute on function public.live_subscription_key(uuid) to service_role;

-- `record_ai_usage`, unchanged from 0014 except for where the key comes from.
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
    v_price    public.ai_model_prices%rowtype;
    v_billable integer;
    v_cost     numeric(12,8) := 0;
    v_subkey   text;
begin
    -- The rate that was in force when the call happened. A price added later
    -- must not silently re-rate calls that came before it.
    select * into v_price
    from public.ai_model_prices
    where model = p_model
      and effective_from <= now()
    order by effective_from desc
    limit 1;

    if found then
        -- Cached tokens are part of prompt_tokens, so bill the remainder at
        -- the full rate and the cached part at the cached one. Reasoning
        -- tokens need no separate line: OpenAI already counts them inside
        -- completion_tokens.
        v_billable := greatest(coalesce(p_prompt, 0) - coalesce(p_cached, 0), 0);

        v_cost := (v_billable::numeric / 1000000) * v_price.input_per_mtok
                + (coalesce(p_cached, 0)::numeric / 1000000)
                      * coalesce(v_price.cached_input_per_mtok, v_price.input_per_mtok)
                + (coalesce(p_completion, 0)::numeric / 1000000) * v_price.output_per_mtok;
    end if;

    -- Which subscription is paying, if one is. Null for anybody who is on
    -- free -- never subscribed, or lapsed -- and that is what makes their
    -- spend count against the free ceiling rather than vanish.
    v_subkey := public.live_subscription_key(p_user);

    -- A model with no price row still gets a row, at zero. Losing the token
    -- counts because a rate was missing would lose the only thing that lets
    -- the cost be worked out afterwards -- and metering must never be the
    -- reason an answer fails to arrive.
    insert into public.ai_usage (
        user_id, subscription_key, action, model,
        prompt_tokens, cached_tokens, completion_tokens, reasoning_tokens,
        cost_usd
    ) values (
        p_user, v_subkey, p_action, p_model,
        coalesce(p_prompt, 0), coalesce(p_cached, 0),
        coalesce(p_completion, 0), coalesce(p_reasoning, 0),
        v_cost
    );

    return v_cost;
end;
$$;

revoke execute on function public.record_ai_usage(uuid, text, text, integer, integer, integer, integer)
    from public;
grant execute on function public.record_ai_usage(uuid, text, text, integer, integer, integer, integer)
    to service_role;

-- `spend_check`, unchanged from 0016 except for which rows are summed. Same
-- return type, so `my_spend()` keeps working as it is.
create or replace function public.spend_check(for_user uuid)
returns table (
    plan          text,
    allowance_usd numeric,
    spent_usd     numeric,
    credit_usd    numeric,
    is_allowed    boolean,
    period_end    timestamptz,
    renews_at     timestamptz,
    is_in_grace   boolean
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
    window_start timestamptz;
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

    -- Named once and used twice, so the figure on screen and the figure the
    -- refusal is computed from can never be windows of different lengths.
    window_start := date_trunc('month', now());

    -- Null on free, whether never subscribed or lapsed. The same function
    -- `record_ai_usage` stamps rows with, so what is summed here is exactly
    -- what was written there.
    subkey := public.live_subscription_key(for_user);

    if subkey is null then
        -- What this account spent while on free. Rows carrying a key were
        -- spent against a subscription, and a lapsed one does not owe them
        -- to the free ceiling.
        select coalesce(sum(u.cost_usd), 0) into used
        from public.ai_usage u
        where u.user_id = for_user
          and u.subscription_key is null
          and u.created_at >= window_start;
    else
        -- Against the subscription. Every account that has ever held it
        -- counts towards one total, which is what makes restoring on a fresh
        -- account worthless.
        select coalesce(sum(u.cost_usd), 0) into used
        from public.ai_usage u
        where u.subscription_key = subkey
          and u.created_at >= window_start;
    end if;

    credit := coalesce(held.credit_usd, 0);

    return query select
        effective,
        ceiling,
        used,
        credit,
        (used < least(ceiling + credit, hard_cap)),
        window_start + interval '1 month',
        -- Null on free, and that is the honest answer: nothing renews.
        case when effective = 'free' then null else held.expires_at end,
        coalesce(held.is_in_grace, false);
end;
$$;

revoke execute on function public.spend_check(uuid) from public;
grant execute on function public.spend_check(uuid) to service_role;

-- Rows written while a subscription was already lapsed carried its key and
-- counted for nothing. Give them back to the account they belong to.
update public.ai_usage u
set subscription_key = null
from public.entitlements e
where e.user_id = u.user_id
  and u.subscription_key = e.original_transaction_id
  and e.expires_at is not null
  and u.created_at > e.expires_at
  and not coalesce(e.is_in_grace, false);
