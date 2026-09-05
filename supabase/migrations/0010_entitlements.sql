-- What somebody has paid for.
--
-- 🔴 **Written only by the server, never by the app.** There is no insert,
-- update or delete policy on this table -- only a select. A client that could
-- write its own entitlement could grant itself Max, and the anon key ships in
-- the .ipa, so "the app would not do that" is not a control.
--
-- The writer is the `appstore` function, which Apple calls directly with
-- signed server notifications. Apple is the only source of truth about
-- whether a subscription is live, and this table is a cache of what Apple
-- last said.

create table if not exists public.entitlements (
    user_id            uuid primary key references auth.users(id) on delete cascade,

    -- 'free' | 'pro' | 'max'
    plan               text not null default 'free',

    -- Apple's identifiers, so a notification can be matched to a person.
    -- `original_transaction_id` is the one that survives renewals: every
    -- renewal of the same subscription carries it, and it is the only stable
    -- handle Apple offers.
    original_transaction_id text unique,
    product_id         text,

    -- When the current period ends. Past this, `plan` means nothing -- the
    -- gate reads both.
    expires_at         timestamptz,

    -- Set when Apple says the subscription is in billing retry or grace.
    -- Access continues; the app can say so rather than cutting somebody off
    -- while their bank sorts itself out.
    is_in_grace        boolean not null default false,

    -- Bought credit, in dollars of provider cost, on top of the plan's
    -- monthly allowance. Consumables, so this only ever goes up when bought
    -- and down as it is spent.
    credit_usd         numeric(12, 6) not null default 0,

    updated_at         timestamptz not null default now()
);

create index if not exists entitlements_txn_idx
    on public.entitlements (original_transaction_id);

alter table public.entitlements enable row level security;

-- Read your own, and nothing else. No write policy exists on purpose: see the
-- note at the top.
drop policy if exists "entitlements are readable by their owner" on public.entitlements;

create policy "entitlements are readable by their owner"
    on public.entitlements for select
    using (auth.uid() = user_id);

-- What the server asks before doing any paid work.
--
-- One function rather than a query in the edge function, so the rule lives
-- beside the data and cannot drift between callers. Returns the plan, what is
-- left, and whether to refuse -- and it is the *server's* answer, computed
-- from the server's own metering rather than from anything the app claims.
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
begin
    select * into held from public.entitlements where user_id = for_user;

    -- No row, an expired period, or a cancelled subscription all mean free.
    -- Grace is deliberately still paid: somebody whose card failed this
    -- morning has not stopped being a customer.
    effective := coalesce(held.plan, 'free');
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

    select coalesce(sum(u.cost_usd), 0) into used
    from public.ai_usage u
    where u.user_id = for_user
      and u.created_at >= date_trunc('month', now());

    return query select
        effective,
        ceiling,
        used,
        coalesce(held.credit_usd, 0),
        (used < ceiling + coalesce(held.credit_usd, 0));
end;
$$;

-- Callable by a signed-in person, for their own row only. The function is
-- `security definer` so it can read `ai_usage` past RLS, which is why it takes
-- the user id rather than trusting a parameter for anything else.
revoke execute on function public.spend_check(uuid) from anon, authenticated;
