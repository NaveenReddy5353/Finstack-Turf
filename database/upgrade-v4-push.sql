-- ============================================================================
-- FINSTACK TURF — v4: push notifications (alerts when the app is closed)
-- Safe to run on an existing project (idempotent). Also included in schema.sql.
-- Pairs with supabase/functions/push-notify/index.ts + a Database Webhook.
-- ============================================================================

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  failures int not null default 0
);
create index if not exists push_subscriptions_profile_idx on public.push_subscriptions(profile_id);

alter table public.push_subscriptions enable row level security;
drop policy if exists "push read own" on public.push_subscriptions;
create policy "push read own" on public.push_subscriptions for select to authenticated using (profile_id = public.current_profile_id());
revoke insert, update, delete on public.push_subscriptions from anon, authenticated;

-- Called by the app after the browser grants notification permission.
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_me uuid := public.current_profile_id();
begin
  if not public.is_approved_member() then raise exception 'Your account is not approved yet'; end if;
  if coalesce(p_endpoint,'') = '' or coalesce(p_p256dh,'') = '' or coalesce(p_auth,'') = '' then raise exception 'Invalid push subscription'; end if;
  insert into public.push_subscriptions(profile_id, endpoint, p256dh, auth, user_agent)
  values (v_me, p_endpoint, p_p256dh, p_auth, left(coalesce(p_user_agent,''), 200))
  on conflict (endpoint) do update set profile_id = excluded.profile_id, p256dh = excluded.p256dh, auth = excluded.auth,
    user_agent = excluded.user_agent, last_seen_at = now(), failures = 0
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.remove_push_subscription(p_endpoint text)
returns void language sql security definer set search_path = public
as $$ delete from public.push_subscriptions where endpoint = p_endpoint and profile_id = public.current_profile_id(); $$;

do $$
declare f text;
begin
  foreach f in array array['public.save_push_subscription(text,text,text,text)', 'public.remove_push_subscription(text)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;

-- The Edge Function reads subscriptions with the service role key (bypasses RLS), so no extra grants are needed.
