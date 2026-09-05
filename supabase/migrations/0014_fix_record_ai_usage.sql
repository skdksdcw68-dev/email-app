-- Put back the three things 0013 dropped.
--
-- 0013 rewrote `record_ai_usage` to stamp usage with the subscription that
-- was paying, which was right and is kept. It also rewrote the costing, which
-- was not asked for and lost three properties of the 0007 version. Every
-- dollar in the system comes through this function, so nothing downstream --
-- the percentage on the Usage screen, the ceiling, the enforcement about to
-- be built on top of it -- is trustworthy until this is right.
--
-- 🔴 **1. Reasoning tokens were being billed twice.**
--
-- 0007 says it outright: "Reasoning tokens need no separate line: OpenAI
-- already counts them inside completion_tokens." 0013 billed
-- `completion + reasoning`. On a reasoning model that overcharges the output
-- line by up to double, and output is the expensive side -- $10 per million
-- on `gpt-5.6-luna` against $1.25 in. So the ceiling arrived early, and every
-- historical figure is overstated.
--
-- 🔴 **2. A model with no cached rate lost the row entirely.**
--
-- `cached_input_per_mtok` is nullable by design. 0007 coalesced it to the
-- full input rate; 0013 did not, so the arithmetic produced NULL, the insert
-- into a `not null` column failed, and -- because `meter()` in the edge
-- function swallows errors so that billing can never break an answer -- the
-- usage row vanished silently. Unmetered calls, no trace.
--
-- 🔴 **3. The effective-dated price lookup was gone.**
--
-- `ai_model_prices` is keyed `(model, effective_from)` precisely so a rate
-- change does not re-rate history. 0013 did a bare `where model = p_model`,
-- which takes whichever row Postgres feels like returning. Add a second rate
-- for a model and past costs start moving around.
--
-- Precision goes back to numeric(12,8) too, matching the column.

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

    -- Which subscription was paying, from 0013 and the one part of it worth
    -- keeping. Read here rather than passed in: a caller that could name its
    -- own key could spend against somebody else's allowance.
    --
    -- Null for anybody who has never subscribed, and that is correct -- their
    -- spend is their own and the free ceiling is per account by definition.
    select e.original_transaction_id into v_subkey
    from public.entitlements e
    where e.user_id = p_user;

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
    from public, anon, authenticated;

-- What the app is allowed to ask about its own spending.
--
-- `spend_check(uuid)` takes a user id and must stay revoked from
-- `authenticated`: a caller that could pass any id could read anybody's
-- spend. This wrapper takes none and reads `auth.uid()`, so it can only ever
-- answer about the caller.
create or replace function public.my_spend()
returns table (
    plan          text,
    allowance_usd numeric,
    spent_usd     numeric,
    credit_usd    numeric,
    is_allowed    boolean
)
language sql
security definer
set search_path = public
as $$
    select * from public.spend_check(auth.uid());
$$;

grant execute on function public.my_spend() to authenticated;

-- The account-scoped view is retired.
--
-- It summed `ai_usage` grouped by `user_id` while enforcement counts by
-- `subscription_key`. After a subscription moves between accounts those are
-- two different totals by design, so the number the app drew and the number
-- the server refused on could not agree. One source, and it is the one that
-- actually gates.
drop view if exists public.my_ai_spend;
