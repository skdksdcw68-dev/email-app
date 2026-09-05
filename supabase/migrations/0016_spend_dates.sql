-- The two dates a usage screen needs, from the server rather than the phone.
--
-- The Usage screen printed "Renews 1 Oct" worked out from `Calendar.current`
-- on the device. Two things wrong with that:
--
--   1. It is the *device's* clock and the device's time zone. Somebody in
--      Addis is nine hours ahead of the server that decides when the window
--      turns over, so on the last day of a month the screen and the ledger
--      disagreed about which month it was.
--   2. It guessed. Abel's rule for this whole area is that nothing about
--      usage is estimated -- and a date the client derives is an estimate of
--      a rule that lives here.
--
-- 🔴 The two dates are genuinely different and the screen must not conflate
-- them:
--
--   `period_end` -- when the *allowance* comes back. The ledger sums from
--   `date_trunc('month', now())`, so the allowance window is a calendar month
--   and turns over on the 1st, for everybody, whatever day they subscribed.
--
--   `renews_at` -- when Apple next *charges*. That is the subscription's own
--   anniversary and has nothing to do with the 1st.
--
-- Saying "renews" for the first of those was the bug: somebody who subscribed
-- on the 20th read "Renews 1 Oct" and reasonably concluded they would be
-- billed then.
--
-- ⚠️ `create or replace` cannot change a function's return type, so both this
-- and its wrapper are dropped and rebuilt. `my_spend` first -- it depends on
-- the other.

drop function if exists public.my_spend();
drop function if exists public.spend_check(uuid);

create function public.spend_check(for_user uuid)
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

    subkey := held.original_transaction_id;

    if subkey is null then
        select coalesce(sum(u.cost_usd), 0) into used
        from public.ai_usage u
        where u.user_id = for_user
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

revoke execute on function public.spend_check(uuid) from anon, authenticated;

-- The version a signed-in person may call, which takes no argument and so
-- cannot be asked about anybody else.
create function public.my_spend()
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
language sql
security definer
set search_path = public
as $$
    select * from public.spend_check(auth.uid());
$$;

grant execute on function public.my_spend() to authenticated;
