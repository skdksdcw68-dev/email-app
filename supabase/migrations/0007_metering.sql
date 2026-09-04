-- What each answer actually cost.
--
-- Until now nothing here knew. The `ai` function reads OpenAI's reply, takes
-- `choices[0].message.content`, and throws `payload.usage` away -- the exact
-- token counts, arriving on every single call, discarded. On the streaming
-- path it is worse: the request never asks for usage at all, so none is even
-- produced.
--
-- That was survivable while the app was one person's. It is not survivable as
-- a product, for two reasons that are really the same reason:
--
--   The OpenAI key lives in this project's secrets, not on anybody's phone.
--   Every user spends the operator's money. The app's own Usage screen says
--   the opposite -- "Maily runs on your own API key" -- which was never true
--   of the deployed system.
--
-- So: count what is spent, per person, from the provider's own numbers.
--
-- Additive and safe against the function deployed right now. Nothing reads
-- these tables until the next `ai` deploy, and that ordering is deliberate --
-- Supabase has no CI here, so a schema change and a function change are never
-- simultaneous.

-- ---------------------------------------------------------------- prices

-- What a model costs, per million tokens, from when.
--
-- In the database rather than as constants in `index.ts`, and the reason is
-- auditing rather than convenience: with a constant in code, an old usage
-- row's cost becomes unverifiable the moment somebody edits the constant.
-- `effective_from` means "what did we charge in September" stays answerable a
-- year later.
--
-- `numeric`, never `float8`. Money in binary floating point is a usage screen
-- that reads $0.30000000000000004.
create table if not exists public.ai_model_prices (
    model                 text          not null,
    effective_from        timestamptz   not null default now(),
    input_per_mtok        numeric(12,6) not null,
    -- Nullable: a model with no prompt caching has no cached rate, which is
    -- different from having a rate of zero.
    cached_input_per_mtok numeric(12,6),
    output_per_mtok       numeric(12,6) not null,
    primary key (model, effective_from)
);

alter table public.ai_model_prices enable row level security;

-- Deliberately no policy. RLS on with zero policies means only the service
-- role can read this, which is the point: the client must never see prices,
-- because the client must never compute cost. A jailbroken phone cannot
-- under-report a bill it is not trusted to calculate.

-- ⚠️ CONFIRM THESE NUMBERS before trusting any figure on the Usage screen.
-- They are the shape of the answer, not the answer -- check the current rates
-- at platform.openai.com/docs/pricing and UPDATE.
--
-- Being wrong here is recoverable and that is by design: `ai_usage` stores the
-- raw token counts beside the computed cost, so a corrected rate plus one
-- recompute fixes every historical row. Storing only the dollar figure would
-- have made a wrong rate permanent.
insert into public.ai_model_prices
    (model, effective_from, input_per_mtok, cached_input_per_mtok, output_per_mtok)
values
    ('gpt-5-nano',   '2026-01-01', 0.050000, 0.005000, 0.400000),
    ('gpt-5.6-luna', '2026-01-01', 1.250000, 0.125000, 10.000000)
on conflict (model, effective_from) do nothing;

-- ---------------------------------------------------------------- the ledger

-- One row per call to OpenAI. Append-only.
create table if not exists public.ai_usage (
    id                bigint generated always as identity primary key,
    user_id           uuid not null references auth.users(id) on delete cascade,
    -- 'classify', 'ask_stream', 'draft'... the same action strings the router
    -- already dispatches on.
    action            text not null,
    model             text not null,

    -- Raw, as the provider reported them. Two of these are subsets and the
    -- cost formula has to know that or it charges twice for the same token:
    --   cached_tokens    ⊂ prompt_tokens
    --   reasoning_tokens ⊂ completion_tokens
    prompt_tokens     integer not null default 0,
    cached_tokens     integer not null default 0,
    completion_tokens integer not null default 0,
    reasoning_tokens  integer not null default 0,

    cost_usd          numeric(12,8) not null default 0,

    -- Which billing period this call belongs to. Null until 0008 creates
    -- periods; the foreign key is added there rather than here, because it
    -- points at a table that does not exist yet.
    period_id         uuid,

    created_at        timestamptz not null default now()
);

create index if not exists ai_usage_user_period_idx
    on public.ai_usage (user_id, period_id);

create index if not exists ai_usage_user_time_idx
    on public.ai_usage (user_id, created_at desc);

alter table public.ai_usage enable row level security;

-- Read your own. That is the whole client-facing surface.
--
-- Dropped first so this file can be run twice without erroring. `create
-- policy` has no `if not exists`, and everything else here does -- which
-- matters because this one is being applied by hand in the SQL editor rather
-- than by `db push` (the CLI cannot reach the database from the machine this
-- was written on), so the migration history will not know it has run and a
-- later `db push` will try it again.
drop policy if exists "usage is private to the person who spent it" on public.ai_usage;

create policy "usage is private to the person who spent it"
    on public.ai_usage for select
    using (auth.uid() = user_id);

-- No insert, update or delete policy, and their absence is the design.
--
-- Only the Edge Function writes here, under the service role. A client that
-- can insert usage rows is a client that inserts zeros; a client that can
-- delete them is a client that deletes its own bill. This is a ledger, and a
-- ledger nobody can edit is the only kind worth keeping.

-- ---------------------------------------------------------------- recording

-- Write one call's usage and return what it cost.
--
-- `security definer` so the Edge Function can price a call without the price
-- table being readable by anyone else. `search_path` is pinned because a
-- definer function that resolves names through the caller's path is how
-- privilege escalation happens.
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
    v_price   public.ai_model_prices%rowtype;
    v_billable integer;
    v_cost    numeric(12,8) := 0;
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

    -- A model with no price row still gets a row, at zero. Losing the token
    -- counts because a rate was missing would lose the only thing that lets
    -- the cost be worked out afterwards -- and metering must never be the
    -- reason an answer fails to arrive.
    insert into public.ai_usage (
        user_id, action, model,
        prompt_tokens, cached_tokens, completion_tokens, reasoning_tokens,
        cost_usd
    ) values (
        p_user, p_action, p_model,
        coalesce(p_prompt, 0), coalesce(p_cached, 0),
        coalesce(p_completion, 0), coalesce(p_reasoning, 0),
        v_cost
    );

    return v_cost;
end;
$$;

-- Nobody calls this but the service role. `security definer` plus a grant to
-- `authenticated` would let any signed-in client write its own ledger rows,
-- which is exactly what the missing insert policy above is preventing.
revoke execute on function public.record_ai_usage(uuid, text, text, integer, integer, integer, integer)
    from public, anon, authenticated;

-- ---------------------------------------------------------------- reading it

-- What one person has spent, ever, and this calendar month.
--
-- A view rather than a stored total, for now. It is exact, it needs no
-- maintenance, and the row counts are small enough that the index carries it.
-- When plans arrive in 0008 the number that matters becomes "spent this
-- period", which is kept as a running total on the period row instead --
-- because after buying credits the figure has to move immediately, and a
-- number people refresh to check is a number that must not be stale.
create or replace view public.my_ai_spend
with (security_invoker = true) as
select
    user_id,
    sum(cost_usd)                                              as total_usd,
    sum(cost_usd) filter (where created_at >= date_trunc('month', now())) as month_usd,
    count(*)                                                   as calls,
    max(created_at)                                            as last_call_at
from public.ai_usage
group by user_id;

-- `security_invoker = true` is load-bearing, not decoration. Without it the
-- view runs with its owner's rights and quietly ignores RLS on `ai_usage`,
-- which would hand every user's spend to every caller. The anon key ships in
-- the .ipa, so RLS is the only guard there has ever been here.
