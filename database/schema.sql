-- ============================================================================
-- FINSTACK TURF — Supabase PostgreSQL schema (v2)
-- Run this entire script once in Supabase SQL Editor (fresh project).
-- All money values are INR. Absent players are not charged.
--
-- What v2 adds over the prototype:
--   * Members are club records (profiles) that an admin can create directly.
--     A member later signs up with the same email and is linked automatically.
--   * The very first person to sign up becomes the admin automatically.
--   * Members can submit deposit requests (UPI / cash) that an admin approves.
--   * Unsettled matches can be edited or deleted by an admin.
--   * Admins can play too: any approved, active profile can attend a match.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  full_name text not null default 'Member',
  email text,
  phone text,
  role text not null default 'member' check (role in ('admin','member')),
  approved boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_email_lower_idx on public.profiles (lower(email)) where email is not null;

create table if not exists public.wallets (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  match_date date not null,
  venue text not null,
  turf_cost numeric(12,2) not null check (turf_cost >= 0),
  extra_cost numeric(12,2) not null default 0 check (extra_cost >= 0),
  total_cost numeric(12,2) generated always as (turf_cost + extra_cost) stored,
  notes text,
  status text not null default 'unsettled' check (status in ('unsettled','settled')),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  settled_at timestamptz
);

create table if not exists public.match_attendance (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  profile_id uuid not null references public.profiles(id),
  share_amount numeric(12,2) not null default 0 check (share_amount >= 0),
  unique(match_id, profile_id)
);

create table if not exists public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id),
  amount numeric(12,2) not null check (amount <> 0),
  transaction_type text not null check (transaction_type in ('deposit','match_deduction','credit','debit')),
  description text not null,
  match_id uuid references public.matches(id) on delete set null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.deposit_requests (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  method text not null default 'upi' check (method in ('upi','cash','bank','other')),
  reference text,
  note text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  created_at timestamptz not null default now(),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  review_note text,
  transaction_id uuid references public.wallet_transactions(id) on delete set null
);

create index if not exists wallet_transactions_profile_created_idx on public.wallet_transactions(profile_id, created_at desc);
create index if not exists matches_date_idx on public.matches(match_date desc);
create index if not exists deposit_requests_status_idx on public.deposit_requests(status, created_at desc);
create index if not exists deposit_requests_profile_idx on public.deposit_requests(profile_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Helper functions (security definer so RLS policies can call them)
-- ---------------------------------------------------------------------------
create or replace function public.current_profile_id()
returns uuid language sql stable security definer set search_path = public
as $$ select id from public.profiles where user_id = auth.uid() limit 1; $$;

create or replace function public.is_approved_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select exists(select 1 from public.profiles where user_id = auth.uid() and role = 'admin' and approved = true and active = true); $$;

create or replace function public.is_approved_member()
returns boolean language sql stable security definer set search_path = public
as $$ select exists(select 1 from public.profiles where user_id = auth.uid() and approved = true and active = true); $$;

-- New auth users: link to an admin-created profile with the same email,
-- otherwise create a pending profile. The first ever user becomes admin.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_email text := lower(trim(new.email)); v_profile uuid; v_name text;
begin
  v_name := nullif(trim(coalesce(new.raw_user_meta_data->>'full_name','')),'');
  select id into v_profile from public.profiles where user_id is null and email is not null and lower(email) = v_email limit 1;
  if v_profile is not null then
    update public.profiles set user_id = new.id, full_name = coalesce(full_name, v_name, 'Member') where id = v_profile;
  elsif not exists (select 1 from public.profiles where role = 'admin') then
    insert into public.profiles(user_id, full_name, email, role, approved) values (new.id, coalesce(v_name,'Admin'), v_email, 'admin', true) returning id into v_profile;
  else
    insert into public.profiles(user_id, full_name, email, role, approved) values (new.id, coalesce(v_name,'Member'), v_email, 'member', false) returning id into v_profile;
  end if;
  insert into public.wallets(profile_id) values (v_profile) on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_finstack on auth.users;
create trigger on_auth_user_created_finstack
after insert on auth.users for each row execute procedure public.handle_new_user();

-- Called by the app right after sign-in. Links the signed-in auth user to the
-- club member record with the same email (e.g. when a member was re-added after
-- the login already existed), or creates a profile if none exists yet.
create or replace function public.link_my_profile()
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_email text; v_name text; v_profile uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  select id into v_profile from public.profiles where user_id = v_uid;
  if v_profile is not null then return v_profile; end if;
  select lower(trim(email)), nullif(trim(coalesce(raw_user_meta_data->>'full_name','')),'') into v_email, v_name from auth.users where id = v_uid;
  select id into v_profile from public.profiles where user_id is null and email is not null and lower(email) = v_email limit 1;
  if v_profile is not null then
    update public.profiles set user_id = v_uid where id = v_profile;
  elsif not exists (select 1 from public.profiles where role = 'admin') then
    insert into public.profiles(user_id, full_name, email, role, approved) values (v_uid, coalesce(v_name,'Admin'), v_email, 'admin', true) returning id into v_profile;
  else
    insert into public.profiles(user_id, full_name, email, role, approved) values (v_uid, coalesce(v_name,'Member'), v_email, 'member', false) returning id into v_profile;
  end if;
  insert into public.wallets(profile_id) values (v_profile) on conflict do nothing;
  return v_profile;
end;
$$;
revoke all on function public.link_my_profile() from public, anon;
grant execute on function public.link_my_profile() to authenticated;

-- ---------------------------------------------------------------------------
-- Row level security: clients can only READ. All writes go through RPCs.
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.wallets enable row level security;
alter table public.matches enable row level security;
alter table public.match_attendance enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.deposit_requests enable row level security;

drop policy if exists "profile read self or admin" on public.profiles;
drop policy if exists "admin update profiles" on public.profiles;
drop policy if exists "profiles readable by approved members" on public.profiles;
create policy "profiles readable by approved members" on public.profiles for select to authenticated
using (user_id = auth.uid() or public.is_approved_member());

drop policy if exists "wallet read self or admin" on public.wallets;
create policy "wallet read self or admin" on public.wallets for select to authenticated
using (profile_id = public.current_profile_id() or public.is_approved_admin());

drop policy if exists "approved read matches" on public.matches;
create policy "approved read matches" on public.matches for select to authenticated
using (public.is_approved_member());

drop policy if exists "approved read attendance" on public.match_attendance;
create policy "approved read attendance" on public.match_attendance for select to authenticated
using (public.is_approved_member());

drop policy if exists "ledger read self or admin" on public.wallet_transactions;
create policy "ledger read self or admin" on public.wallet_transactions for select to authenticated
using (profile_id = public.current_profile_id() or public.is_approved_admin());

drop policy if exists "deposit requests read self or admin" on public.deposit_requests;
create policy "deposit requests read self or admin" on public.deposit_requests for select to authenticated
using (profile_id = public.current_profile_id() or public.is_approved_admin());

revoke insert, update, delete on public.profiles from anon, authenticated;
revoke insert, update, delete on public.wallets from anon, authenticated;
revoke insert, update, delete on public.matches from anon, authenticated;
revoke insert, update, delete on public.match_attendance from anon, authenticated;
revoke insert, update, delete on public.wallet_transactions from anon, authenticated;
revoke insert, update, delete on public.deposit_requests from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Member management (admin)
-- ---------------------------------------------------------------------------
create or replace function public.admin_add_member(p_full_name text, p_email text, p_phone text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_email text := nullif(lower(trim(coalesce(p_email,''))),'');
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  if length(trim(coalesce(p_full_name,''))) < 2 then raise exception 'Member name is required'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address'; end if;
  if v_email is not null and exists(select 1 from public.profiles where lower(email) = v_email) then raise exception 'A member with this email already exists'; end if;
  insert into public.profiles(full_name, email, phone, role, approved, active)
  values (trim(p_full_name), v_email, nullif(trim(coalesce(p_phone,'')),''), 'member', true, true)
  returning id into v_id;
  insert into public.wallets(profile_id) values (v_id) on conflict do nothing;
  return v_id;
end;
$$;

create or replace function public.admin_update_member(
  p_profile_id uuid, p_full_name text, p_email text, p_phone text, p_role text, p_active boolean
) returns void language plpgsql security definer set search_path = public
as $$
declare v_email text := nullif(lower(trim(coalesce(p_email,''))),''); v_self uuid := public.current_profile_id(); v_old public.profiles%rowtype;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_old from public.profiles where id = p_profile_id;
  if not found then raise exception 'Member not found'; end if;
  if length(trim(coalesce(p_full_name,''))) < 2 then raise exception 'Member name is required'; end if;
  if p_role not in ('admin','member') then raise exception 'Invalid role'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address'; end if;
  if v_email is not null and exists(select 1 from public.profiles where lower(email) = v_email and id <> p_profile_id) then raise exception 'Another member already uses this email'; end if;
  if v_old.user_id is not null and v_email is distinct from lower(v_old.email) then raise exception 'Email cannot be changed after the member has signed in'; end if;
  if p_profile_id = v_self and (p_role <> 'admin' or p_active = false) then raise exception 'You cannot remove your own admin access'; end if;
  update public.profiles set full_name = trim(p_full_name), email = v_email, phone = nullif(trim(coalesce(p_phone,'')),''), role = p_role, active = p_active
  where id = p_profile_id;
end;
$$;

create or replace function public.admin_approve_member(p_profile_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  update public.profiles set approved = true, active = true where id = p_profile_id;
  if not found then raise exception 'Member not found'; end if;
  insert into public.wallets(profile_id) values (p_profile_id) on conflict do nothing;
end;
$$;

-- Remove a member who never played and has no money movement (e.g. created by mistake).
create or replace function public.admin_delete_member(p_profile_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  if p_profile_id = public.current_profile_id() then raise exception 'You cannot delete your own account'; end if;
  if exists(select 1 from public.wallet_transactions where profile_id = p_profile_id) or exists(select 1 from public.match_attendance where profile_id = p_profile_id) then
    raise exception 'This member has wallet or match history. Mark them inactive instead.';
  end if;
  delete from public.deposit_requests where profile_id = p_profile_id;
  delete from public.profiles where id = p_profile_id;
  if not found then raise exception 'Member not found'; end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Wallet: admin adjustments and member deposit requests
-- ---------------------------------------------------------------------------
create or replace function public.admin_wallet_adjustment(
  p_profile_id uuid, p_type text, p_amount numeric, p_description text
) returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_balance numeric;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  if p_type not in ('deposit','credit','debit') then raise exception 'Invalid transaction type'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception 'Enter a valid amount'; end if;
  if length(trim(coalesce(p_description,''))) = 0 then raise exception 'Description is required'; end if;
  if not exists(select 1 from public.profiles where id = p_profile_id and approved = true) then raise exception 'Member is not approved'; end if;
  insert into public.wallets(profile_id) values (p_profile_id) on conflict do nothing;
  select coalesce(sum(amount),0) into v_balance from public.wallet_transactions where profile_id = p_profile_id;
  if p_type = 'debit' and v_balance < p_amount then raise exception 'Insufficient wallet balance'; end if;
  insert into public.wallet_transactions(profile_id, amount, transaction_type, description, created_by)
  values (p_profile_id, case when p_type = 'debit' then -p_amount else p_amount end, p_type, trim(p_description), public.current_profile_id())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.member_request_deposit(p_amount numeric, p_method text, p_reference text, p_note text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_profile uuid := public.current_profile_id();
begin
  if not public.is_approved_member() then raise exception 'Your account is not approved yet'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception 'Enter a valid amount'; end if;
  if coalesce(p_method,'upi') not in ('upi','cash','bank','other') then raise exception 'Invalid payment method'; end if;
  if (select count(*) from public.deposit_requests where profile_id = v_profile and status = 'pending') >= 5 then
    raise exception 'You already have 5 pending requests. Wait for the admin to review them.';
  end if;
  insert into public.deposit_requests(profile_id, amount, method, reference, note)
  values (v_profile, round(p_amount,2), coalesce(p_method,'upi'), nullif(trim(coalesce(p_reference,'')),''), nullif(trim(coalesce(p_note,'')),''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.member_cancel_deposit_request(p_request_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  update public.deposit_requests set status = 'cancelled', reviewed_at = now()
  where id = p_request_id and profile_id = public.current_profile_id() and status = 'pending';
  if not found then raise exception 'Only your own pending requests can be cancelled'; end if;
end;
$$;

create or replace function public.admin_review_deposit(p_request_id uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_req public.deposit_requests%rowtype; v_tx uuid; v_name text;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_req from public.deposit_requests where id = p_request_id for update;
  if not found then raise exception 'Deposit request not found'; end if;
  if v_req.status <> 'pending' then raise exception 'This request has already been reviewed'; end if;
  if p_approve then
    insert into public.wallets(profile_id) values (v_req.profile_id) on conflict do nothing;
    insert into public.wallet_transactions(profile_id, amount, transaction_type, description, created_by)
    values (v_req.profile_id, v_req.amount, 'deposit',
      'Deposit via ' || upper(v_req.method) || coalesce(' (ref ' || v_req.reference || ')',''), public.current_profile_id())
    returning id into v_tx;
  end if;
  update public.deposit_requests
  set status = case when p_approve then 'approved' else 'rejected' end,
      reviewed_by = public.current_profile_id(), reviewed_at = now(),
      review_note = nullif(trim(coalesce(p_note,'')),''), transaction_id = v_tx
  where id = p_request_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Matches: create / update / delete (unsettled only) / settle once
-- ---------------------------------------------------------------------------
create or replace function public.validate_attendees(p_attendee_ids uuid[])
returns void language plpgsql security definer set search_path = public
as $$
begin
  if coalesce(array_length(p_attendee_ids,1),0) = 0 then raise exception 'Select at least one attendee'; end if;
  if (select count(distinct x) from unnest(p_attendee_ids) x) <> array_length(p_attendee_ids,1) then raise exception 'Duplicate attendees are not allowed'; end if;
  if exists(select 1 from unnest(p_attendee_ids) x left join public.profiles p on p.id = x where p.id is null or p.approved = false or p.active = false) then
    raise exception 'All attendees must be approved, active members';
  end if;
end;
$$;

-- Per-player shares are rounded to 2 decimals; the last attendee absorbs the
-- rounding remainder so the shares add up to the full cost.
create or replace function public.write_attendance(p_match_id uuid, p_total numeric, p_attendee_ids uuid[])
returns void language plpgsql security definer set search_path = public
as $$
declare v_count integer := array_length(p_attendee_ids,1); v_share numeric; v_user uuid; v_i integer := 0; v_allocated numeric := 0;
begin
  delete from public.match_attendance where match_id = p_match_id;
  foreach v_user in array p_attendee_ids loop
    v_i := v_i + 1;
    if v_i < v_count then v_share := round(p_total / v_count, 2); v_allocated := v_allocated + v_share;
    else v_share := p_total - v_allocated; end if;
    insert into public.match_attendance(match_id, profile_id, share_amount) values (p_match_id, v_user, v_share);
  end loop;
end;
$$;

create or replace function public.admin_create_match(
  p_match_date date, p_venue text, p_turf_cost numeric, p_extra_cost numeric, p_notes text, p_attendee_ids uuid[]
) returns uuid language plpgsql security definer set search_path = public
as $$
declare v_match uuid;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  if p_match_date is null or length(trim(coalesce(p_venue,''))) = 0 then raise exception 'Date and venue are required'; end if;
  if p_turf_cost is null or p_turf_cost <= 0 or coalesce(p_extra_cost,0) < 0 then raise exception 'Invalid match cost'; end if;
  perform public.validate_attendees(p_attendee_ids);
  insert into public.matches(match_date, venue, turf_cost, extra_cost, notes, created_by)
  values (p_match_date, trim(p_venue), p_turf_cost, coalesce(p_extra_cost,0), nullif(trim(coalesce(p_notes,'')),''), public.current_profile_id())
  returning id into v_match;
  perform public.write_attendance(v_match, p_turf_cost + coalesce(p_extra_cost,0), p_attendee_ids);
  return v_match;
end;
$$;

create or replace function public.admin_update_match(
  p_match_id uuid, p_match_date date, p_venue text, p_turf_cost numeric, p_extra_cost numeric, p_notes text, p_attendee_ids uuid[]
) returns void language plpgsql security definer set search_path = public
as $$
declare v_status text;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select status into v_status from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_status = 'settled' then raise exception 'A settled match cannot be edited'; end if;
  if p_match_date is null or length(trim(coalesce(p_venue,''))) = 0 then raise exception 'Date and venue are required'; end if;
  if p_turf_cost is null or p_turf_cost <= 0 or coalesce(p_extra_cost,0) < 0 then raise exception 'Invalid match cost'; end if;
  perform public.validate_attendees(p_attendee_ids);
  update public.matches set match_date = p_match_date, venue = trim(p_venue), turf_cost = p_turf_cost, extra_cost = coalesce(p_extra_cost,0),
    notes = nullif(trim(coalesce(p_notes,'')),''), updated_at = now()
  where id = p_match_id;
  perform public.write_attendance(p_match_id, p_turf_cost + coalesce(p_extra_cost,0), p_attendee_ids);
end;
$$;

create or replace function public.admin_delete_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_status text;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select status into v_status from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_status = 'settled' then raise exception 'A settled match cannot be deleted'; end if;
  delete from public.matches where id = p_match_id;
end;
$$;

-- Settle once, atomically. Any attendee with insufficient balance blocks settlement.
create or replace function public.admin_settle_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_match public.matches%rowtype; v_att record; v_balance numeric; v_short text := '';
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_match from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_match.status = 'settled' then raise exception 'This match is already settled'; end if;
  if not exists(select 1 from public.match_attendance where match_id = p_match_id) then raise exception 'No attendees found'; end if;
  for v_att in select a.*, p.full_name from public.match_attendance a join public.profiles p on p.id = a.profile_id where a.match_id = p_match_id order by p.full_name loop
    select coalesce(sum(amount),0) into v_balance from public.wallet_transactions where profile_id = v_att.profile_id;
    if v_balance < v_att.share_amount then v_short := v_short || case when v_short = '' then '' else ', ' end || v_att.full_name; end if;
  end loop;
  if v_short <> '' then raise exception 'Insufficient wallet balance: %. Top up before settling.', v_short; end if;
  for v_att in select * from public.match_attendance where match_id = p_match_id order by profile_id loop
    insert into public.wallet_transactions(profile_id, amount, transaction_type, description, match_id, created_by)
    values (v_att.profile_id, -v_att.share_amount, 'match_deduction',
      'Turf match: ' || v_match.venue || ' (' || v_match.match_date::text || ')', p_match_id, public.current_profile_id());
  end loop;
  update public.matches set status = 'settled', settled_at = now(), updated_at = now() where id = p_match_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Function permissions
-- ---------------------------------------------------------------------------
revoke all on function public.validate_attendees(uuid[]) from public, anon, authenticated;
revoke all on function public.write_attendance(uuid, numeric, uuid[]) from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.admin_add_member(text,text,text)',
    'public.admin_update_member(uuid,text,text,text,text,boolean)',
    'public.admin_approve_member(uuid)',
    'public.admin_delete_member(uuid)',
    'public.admin_wallet_adjustment(uuid,text,numeric,text)',
    'public.member_request_deposit(numeric,text,text,text)',
    'public.member_cancel_deposit_request(uuid)',
    'public.admin_review_deposit(uuid,boolean,text)',
    'public.admin_create_match(date,text,numeric,numeric,text,uuid[])',
    'public.admin_update_match(uuid,date,text,numeric,numeric,text,uuid[])',
    'public.admin_delete_match(uuid)',
    'public.admin_settle_match(uuid)'
  ] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Admin bootstrap: the FIRST account that signs up becomes the admin
-- automatically. To promote anyone else later, run:
--   update public.profiles set role = 'admin', approved = true where lower(email) = 'person@example.com';
-- ---------------------------------------------------------------------------

-- ============================================================================
-- FINSTACK TURF — v3 upgrade: match voting + in-app notifications
-- Safe to run on an existing v2 project (idempotent). Also included in schema.sql.
-- ============================================================================

-- ---------------------------------------------------------------- tables
alter table public.matches drop constraint if exists matches_status_check;
alter table public.matches add constraint matches_status_check check (status in ('voting','unsettled','settled'));
alter table public.matches add column if not exists voting_closed_at timestamptz;

create table if not exists public.match_votes (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  vote text not null check (vote in ('yes','no')),
  updated_at timestamptz not null default now(),
  unique(match_id, profile_id)
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'info',
  title text not null,
  body text,
  match_id uuid references public.matches(id) on delete cascade,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notifications_profile_idx on public.notifications(profile_id, read, created_at desc);
create index if not exists match_votes_match_idx on public.match_votes(match_id);

alter table public.match_votes enable row level security;
alter table public.notifications enable row level security;

drop policy if exists "approved read votes" on public.match_votes;
create policy "approved read votes" on public.match_votes for select to authenticated using (public.is_approved_member());
drop policy if exists "notifications read own" on public.notifications;
create policy "notifications read own" on public.notifications for select to authenticated using (profile_id = public.current_profile_id());

revoke insert, update, delete on public.match_votes from anon, authenticated;
revoke insert, update, delete on public.notifications from anon, authenticated;

-- Live updates in the app (ignore error if already added)
do $$ begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.match_votes;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.matches;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ---------------------------------------------------------------- helpers
create or replace function public.notify_profiles(p_ids uuid[], p_kind text, p_title text, p_body text, p_match_id uuid)
returns void language sql security definer set search_path = public
as $$
  insert into public.notifications(profile_id, kind, title, body, match_id)
  select distinct x, p_kind, p_title, p_body, p_match_id from unnest(p_ids) x where x is not null;
$$;
revoke all on function public.notify_profiles(uuid[],text,text,text,uuid) from public, anon, authenticated;

create or replace function public.active_member_ids()
returns uuid[] language sql stable security definer set search_path = public
as $$ select coalesce(array_agg(id), '{}') from public.profiles where approved and active; $$;
revoke all on function public.active_member_ids() from public, anon, authenticated;

create or replace function public.match_label(p_match public.matches)
returns text language sql immutable
as $$ select p_match.venue || ' · ' || to_char(p_match.match_date, 'DD Mon'); $$;

-- ---------------------------------------------------------------- notifications RPCs
create or replace function public.mark_notifications_read(p_ids uuid[])
returns void language sql security definer set search_path = public
as $$
  update public.notifications set read = true
  where profile_id = public.current_profile_id() and (p_ids is null or id = any(p_ids));
$$;

-- ---------------------------------------------------------------- matches: create (with optional voting)
drop function if exists public.admin_create_match(date,text,numeric,numeric,text,uuid[]);
create or replace function public.admin_create_match(
  p_match_date date, p_venue text, p_turf_cost numeric, p_extra_cost numeric, p_notes text, p_attendee_ids uuid[], p_open_voting boolean default false
) returns uuid language plpgsql security definer set search_path = public
as $$
declare v_match uuid; v_row public.matches%rowtype;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  if p_match_date is null or length(trim(coalesce(p_venue,''))) = 0 then raise exception 'Date and venue are required'; end if;
  if p_turf_cost is null or p_turf_cost <= 0 or coalesce(p_extra_cost,0) < 0 then raise exception 'Invalid match cost'; end if;
  if not coalesce(p_open_voting,false) then perform public.validate_attendees(p_attendee_ids); end if;
  insert into public.matches(match_date, venue, turf_cost, extra_cost, notes, created_by, status)
  values (p_match_date, trim(p_venue), p_turf_cost, coalesce(p_extra_cost,0), nullif(trim(coalesce(p_notes,'')),''), public.current_profile_id(),
          case when coalesce(p_open_voting,false) then 'voting' else 'unsettled' end)
  returning id into v_match;
  select * into v_row from public.matches where id = v_match;
  if coalesce(p_open_voting,false) then
    perform public.notify_profiles(public.active_member_ids(), 'vote',
      'New match: are you in?',
      public.match_label(v_row) || ' · est. ' || to_char(v_row.total_cost, 'FM999999990.00') || ' total. Tap to vote.', v_match);
  else
    perform public.write_attendance(v_match, p_turf_cost + coalesce(p_extra_cost,0), p_attendee_ids);
    perform public.notify_profiles(p_attendee_ids, 'match', 'You are on the team sheet',
      public.match_label(v_row) || ' · your share ' || to_char(round((p_turf_cost + coalesce(p_extra_cost,0)) / array_length(p_attendee_ids,1), 2), 'FM999999990.00'), v_match);
  end if;
  return v_match;
end;
$$;

-- Edit: allowed while voting or unsettled. While voting, attendance is ignored (comes from votes).
create or replace function public.admin_update_match(
  p_match_id uuid, p_match_date date, p_venue text, p_turf_cost numeric, p_extra_cost numeric, p_notes text, p_attendee_ids uuid[]
) returns void language plpgsql security definer set search_path = public
as $$
declare v_status text;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select status into v_status from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_status = 'settled' then raise exception 'A settled match cannot be edited'; end if;
  if p_match_date is null or length(trim(coalesce(p_venue,''))) = 0 then raise exception 'Date and venue are required'; end if;
  if p_turf_cost is null or p_turf_cost <= 0 or coalesce(p_extra_cost,0) < 0 then raise exception 'Invalid match cost'; end if;
  if v_status = 'unsettled' then perform public.validate_attendees(p_attendee_ids); end if;
  update public.matches set match_date = p_match_date, venue = trim(p_venue), turf_cost = p_turf_cost, extra_cost = coalesce(p_extra_cost,0),
    notes = nullif(trim(coalesce(p_notes,'')),''), updated_at = now()
  where id = p_match_id;
  if v_status = 'unsettled' then perform public.write_attendance(p_match_id, p_turf_cost + coalesce(p_extra_cost,0), p_attendee_ids); end if;
end;
$$;

-- ---------------------------------------------------------------- voting
-- Locks attendance from the YES votes, splits the cost, moves match to 'unsettled'.
create or replace function public.close_match_voting(p_match_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_row public.matches%rowtype; v_ids uuid[]; v_share numeric;
begin
  select * into v_row from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_row.status <> 'voting' then raise exception 'Voting is already closed for this match'; end if;
  select coalesce(array_agg(v.profile_id), '{}') into v_ids
  from public.match_votes v join public.profiles p on p.id = v.profile_id
  where v.match_id = p_match_id and v.vote = 'yes' and p.approved and p.active;
  if coalesce(array_length(v_ids,1),0) = 0 then raise exception 'Nobody has voted yes yet. Wait for votes or delete the match.'; end if;
  perform public.write_attendance(p_match_id, v_row.total_cost, v_ids);
  update public.matches set status = 'unsettled', voting_closed_at = now(), updated_at = now() where id = p_match_id;
  v_share := round(v_row.total_cost / array_length(v_ids,1), 2);
  perform public.notify_profiles(v_ids, 'match', 'Team sheet locked — you are in',
    public.match_label(v_row) || ' · ' || array_length(v_ids,1) || ' players · your share ' || to_char(v_share, 'FM999999990.00') || coalesce(' (' || p_reason || ')',''), p_match_id);
  perform public.notify_profiles(
    (select coalesce(array_agg(id),'{}') from public.profiles where role = 'admin' and approved and active),
    'admin', 'Voting closed: ' || public.match_label(v_row),
    array_length(v_ids,1) || ' players in · ' || to_char(v_share, 'FM999999990.00') || ' each. Review and settle when the match is played.', p_match_id);
end;
$$;
revoke all on function public.close_match_voting(uuid,text) from public, anon, authenticated;

create or replace function public.member_vote(p_match_id uuid, p_vote text)
returns text language plpgsql security definer set search_path = public
as $$
declare v_me uuid := public.current_profile_id(); v_status text; v_total int; v_voted int;
begin
  if not public.is_approved_member() then raise exception 'Your account is not approved yet'; end if;
  if p_vote not in ('yes','no') then raise exception 'Vote must be yes or no'; end if;
  select status into v_status from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_status <> 'voting' then raise exception 'Voting has closed for this match'; end if;
  insert into public.match_votes(match_id, profile_id, vote) values (p_match_id, v_me, p_vote)
  on conflict (match_id, profile_id) do update set vote = excluded.vote, updated_at = now();
  update public.notifications set read = true where profile_id = v_me and match_id = p_match_id and kind = 'vote';
  -- auto-close once every active member has voted
  select count(*) into v_total from public.profiles where approved and active;
  select count(*) into v_voted from public.match_votes v join public.profiles p on p.id = v.profile_id where v.match_id = p_match_id and p.approved and p.active;
  if v_voted >= v_total and exists (select 1 from public.match_votes where match_id = p_match_id and vote = 'yes') then
    perform public.close_match_voting(p_match_id, 'everyone voted');
    return 'closed';
  end if;
  return 'recorded';
end;
$$;

create or replace function public.admin_close_voting(p_match_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  perform public.close_match_voting(p_match_id, 'closed by admin');
end;
$$;

-- Reopen voting on an unsettled match (e.g. closed too early). Keeps existing votes.
create or replace function public.admin_reopen_voting(p_match_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_status text;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select status into v_status from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_status <> 'unsettled' then raise exception 'Only an unsettled match can be reopened for voting'; end if;
  delete from public.match_attendance where match_id = p_match_id;
  update public.matches set status = 'voting', voting_closed_at = null, updated_at = now() where id = p_match_id;
  perform public.notify_profiles(public.active_member_ids(), 'vote', 'Voting reopened',
    (select public.match_label(m) from public.matches m where m.id = p_match_id) || ' · please confirm again.', p_match_id);
end;
$$;

-- Admin can nudge everyone who has not voted yet.
create or replace function public.admin_remind_voters(p_match_id uuid)
returns integer language plpgsql security definer set search_path = public
as $$
declare v_ids uuid[]; v_row public.matches%rowtype;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_row from public.matches where id = p_match_id;
  if not found or v_row.status <> 'voting' then raise exception 'This match is not open for voting'; end if;
  select coalesce(array_agg(p.id),'{}') into v_ids from public.profiles p
  where p.approved and p.active and not exists (select 1 from public.match_votes v where v.match_id = p_match_id and v.profile_id = p.id);
  if coalesce(array_length(v_ids,1),0) = 0 then return 0; end if;
  perform public.notify_profiles(v_ids, 'vote', 'Reminder: please vote', public.match_label(v_row) || ' · tap to say if you are in.', p_match_id);
  return array_length(v_ids,1);
end;
$$;

-- ---------------------------------------------------------------- settle: notify attendees
create or replace function public.admin_settle_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_match public.matches%rowtype; v_att record; v_balance numeric; v_short text := '';
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_match from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_match.status = 'settled' then raise exception 'This match is already settled'; end if;
  if v_match.status = 'voting' then raise exception 'Close voting first to lock the attendance'; end if;
  if not exists(select 1 from public.match_attendance where match_id = p_match_id) then raise exception 'No attendees found'; end if;
  for v_att in select a.*, p.full_name from public.match_attendance a join public.profiles p on p.id = a.profile_id where a.match_id = p_match_id order by p.full_name loop
    select coalesce(sum(amount),0) into v_balance from public.wallet_transactions where profile_id = v_att.profile_id;
    if v_balance < v_att.share_amount then v_short := v_short || case when v_short = '' then '' else ', ' end || v_att.full_name; end if;
  end loop;
  if v_short <> '' then raise exception 'Insufficient wallet balance: %. Top up before settling.', v_short; end if;
  for v_att in select * from public.match_attendance where match_id = p_match_id order by profile_id loop
    insert into public.wallet_transactions(profile_id, amount, transaction_type, description, match_id, created_by)
    values (v_att.profile_id, -v_att.share_amount, 'match_deduction',
      'Turf match: ' || v_match.venue || ' (' || v_match.match_date::text || ')', p_match_id, public.current_profile_id());
    insert into public.notifications(profile_id, kind, title, body, match_id)
    values (v_att.profile_id, 'wallet', 'Match settled', public.match_label(v_match) || ' · ' || to_char(v_att.share_amount,'FM999999990.00') || ' deducted from your Kiddy Bank.', p_match_id);
  end loop;
  update public.matches set status = 'settled', settled_at = now(), updated_at = now() where id = p_match_id;
end;
$$;

-- ---------------------------------------------------------------- deposits: notify
create or replace function public.member_request_deposit(p_amount numeric, p_method text, p_reference text, p_note text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_profile uuid := public.current_profile_id(); v_name text;
begin
  if not public.is_approved_member() then raise exception 'Your account is not approved yet'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception 'Enter a valid amount'; end if;
  if coalesce(p_method,'upi') not in ('upi','cash','bank','other') then raise exception 'Invalid payment method'; end if;
  if (select count(*) from public.deposit_requests where profile_id = v_profile and status = 'pending') >= 5 then
    raise exception 'You already have 5 pending requests. Wait for the admin to review them.';
  end if;
  insert into public.deposit_requests(profile_id, amount, method, reference, note)
  values (v_profile, round(p_amount,2), coalesce(p_method,'upi'), nullif(trim(coalesce(p_reference,'')),''), nullif(trim(coalesce(p_note,'')),''))
  returning id into v_id;
  select full_name into v_name from public.profiles where id = v_profile;
  perform public.notify_profiles(
    (select coalesce(array_agg(id),'{}') from public.profiles where role = 'admin' and approved and active),
    'deposit', 'Deposit request from ' || v_name, to_char(round(p_amount,2),'FM999999990.00') || ' via ' || upper(coalesce(p_method,'upi')) || ' — review it on the Deposits page.', null);
  return v_id;
end;
$$;

create or replace function public.admin_review_deposit(p_request_id uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_req public.deposit_requests%rowtype; v_tx uuid;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_req from public.deposit_requests where id = p_request_id for update;
  if not found then raise exception 'Deposit request not found'; end if;
  if v_req.status <> 'pending' then raise exception 'This request has already been reviewed'; end if;
  if p_approve then
    insert into public.wallets(profile_id) values (v_req.profile_id) on conflict do nothing;
    insert into public.wallet_transactions(profile_id, amount, transaction_type, description, created_by)
    values (v_req.profile_id, v_req.amount, 'deposit',
      'Deposit via ' || upper(v_req.method) || coalesce(' (ref ' || v_req.reference || ')',''), public.current_profile_id())
    returning id into v_tx;
  end if;
  update public.deposit_requests
  set status = case when p_approve then 'approved' else 'rejected' end,
      reviewed_by = public.current_profile_id(), reviewed_at = now(),
      review_note = nullif(trim(coalesce(p_note,'')),''), transaction_id = v_tx
  where id = p_request_id;
  insert into public.notifications(profile_id, kind, title, body)
  values (v_req.profile_id, 'wallet',
    case when p_approve then 'Deposit approved' else 'Deposit request rejected' end,
    to_char(v_req.amount,'FM999999990.00') || case when p_approve then ' added to your Kiddy Bank.' else ' was not approved.' end || coalesce(' Note: ' || nullif(trim(coalesce(p_note,'')),''), ''));
end;
$$;

-- ---------------------------------------------------------------- permissions
do $$
declare f text;
begin
  foreach f in array array[
    'public.mark_notifications_read(uuid[])',
    'public.admin_create_match(date,text,numeric,numeric,text,uuid[],boolean)',
    'public.admin_update_match(uuid,date,text,numeric,numeric,text,uuid[])',
    'public.member_vote(uuid,text)',
    'public.admin_close_voting(uuid)',
    'public.admin_reopen_voting(uuid)',
    'public.admin_remind_voters(uuid)',
    'public.admin_settle_match(uuid)',
    'public.member_request_deposit(numeric,text,text,text)',
    'public.admin_review_deposit(uuid,boolean,text)'
  ] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;

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

-- ============================================================================
-- FINSTACK TURF — v5: club-wide activity notifications + balances in messages
-- Safe to run on an existing project (idempotent). Only replaces functions;
-- no table changes, no data changes.
-- ============================================================================

create or replace function public.wallet_balance(p_profile_id uuid)
returns numeric language sql stable security definer set search_path = public
as $$ select coalesce(sum(amount),0) from public.wallet_transactions where profile_id = p_profile_id; $$;
revoke all on function public.wallet_balance(uuid) from public, anon, authenticated;

create or replace function public.inr(p numeric)
returns text language sql immutable
as $$ select '₹' || to_char(coalesce(p,0), 'FM999999990.00'); $$;

create or replace function public.everyone_except(p_except uuid)
returns uuid[] language sql stable security definer set search_path = public
as $$ select coalesce(array_agg(id), '{}') from public.profiles where approved and active and (p_except is null or id <> p_except); $$;
revoke all on function public.everyone_except(uuid) from public, anon, authenticated;

create or replace function public.my_name()
returns text language sql stable security definer set search_path = public
as $$ select coalesce((select full_name from public.profiles where user_id = auth.uid()), 'Admin'); $$;
revoke all on function public.my_name() from public, anon, authenticated;

-- ---------------------------------------------------------------- members
create or replace function public.admin_add_member(p_full_name text, p_email text, p_phone text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_email text := nullif(lower(trim(coalesce(p_email,''))),'');
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  if length(trim(coalesce(p_full_name,''))) < 2 then raise exception 'Member name is required'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address'; end if;
  if v_email is not null and exists(select 1 from public.profiles where lower(email) = v_email) then raise exception 'A member with this email already exists'; end if;
  insert into public.profiles(full_name, email, phone, role, approved, active)
  values (trim(p_full_name), v_email, nullif(trim(coalesce(p_phone,'')),''), 'member', true, true)
  returning id into v_id;
  insert into public.wallets(profile_id) values (v_id) on conflict do nothing;
  perform public.notify_profiles(public.everyone_except(v_id), 'activity', 'New squad member', trim(p_full_name) || ' has been added to Finstack Turf by ' || public.my_name() || '.', null);
  return v_id;
end;
$$;

create or replace function public.admin_approve_member(p_profile_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_name text;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  update public.profiles set approved = true, active = true where id = p_profile_id returning full_name into v_name;
  if not found then raise exception 'Member not found'; end if;
  insert into public.wallets(profile_id) values (p_profile_id) on conflict do nothing;
  perform public.notify_profiles(array[p_profile_id], 'activity', 'You are approved', 'Welcome to Finstack Turf! You can now vote on matches and see your Kiddy Bank.', null);
  perform public.notify_profiles(public.everyone_except(p_profile_id), 'activity', 'New squad member', v_name || ' joined Finstack Turf.', null);
end;
$$;

-- ---------------------------------------------------------------- wallet
create or replace function public.admin_wallet_adjustment(
  p_profile_id uuid, p_type text, p_amount numeric, p_description text
) returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_balance numeric;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  if p_type not in ('deposit','credit','debit') then raise exception 'Invalid transaction type'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception 'Enter a valid amount'; end if;
  if length(trim(coalesce(p_description,''))) = 0 then raise exception 'Description is required'; end if;
  if not exists(select 1 from public.profiles where id = p_profile_id and approved = true) then raise exception 'Member is not approved'; end if;
  insert into public.wallets(profile_id) values (p_profile_id) on conflict do nothing;
  v_balance := public.wallet_balance(p_profile_id);
  if p_type = 'debit' and v_balance < p_amount then raise exception 'Insufficient wallet balance'; end if;
  insert into public.wallet_transactions(profile_id, amount, transaction_type, description, created_by)
  values (p_profile_id, case when p_type = 'debit' then -p_amount else p_amount end, p_type, trim(p_description), public.current_profile_id())
  returning id into v_id;
  v_balance := public.wallet_balance(p_profile_id);
  perform public.notify_profiles(array[p_profile_id], 'wallet',
    case p_type when 'deposit' then 'Deposit added: ' || public.inr(p_amount) when 'credit' then 'Credit added: ' || public.inr(p_amount) else 'Deducted: ' || public.inr(p_amount) end,
    trim(p_description) || ' · Balance now ' || public.inr(v_balance) || '.', null);
  return v_id;
end;
$$;

create or replace function public.admin_review_deposit(p_request_id uuid, p_approve boolean, p_note text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_req public.deposit_requests%rowtype; v_tx uuid; v_balance numeric;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_req from public.deposit_requests where id = p_request_id for update;
  if not found then raise exception 'Deposit request not found'; end if;
  if v_req.status <> 'pending' then raise exception 'This request has already been reviewed'; end if;
  if p_approve then
    insert into public.wallets(profile_id) values (v_req.profile_id) on conflict do nothing;
    insert into public.wallet_transactions(profile_id, amount, transaction_type, description, created_by)
    values (v_req.profile_id, v_req.amount, 'deposit',
      'Deposit via ' || upper(v_req.method) || coalesce(' (ref ' || v_req.reference || ')',''), public.current_profile_id())
    returning id into v_tx;
  end if;
  update public.deposit_requests
  set status = case when p_approve then 'approved' else 'rejected' end,
      reviewed_by = public.current_profile_id(), reviewed_at = now(),
      review_note = nullif(trim(coalesce(p_note,'')),''), transaction_id = v_tx
  where id = p_request_id;
  v_balance := public.wallet_balance(v_req.profile_id);
  insert into public.notifications(profile_id, kind, title, body)
  values (v_req.profile_id, 'wallet',
    case when p_approve then 'Deposit approved: ' || public.inr(v_req.amount) else 'Deposit request rejected' end,
    case when p_approve then public.inr(v_req.amount) || ' added to your Kiddy Bank · Balance now ' || public.inr(v_balance) || '.'
         else public.inr(v_req.amount) || ' via ' || upper(v_req.method) || ' was not approved. Balance stays ' || public.inr(v_balance) || '.' end
    || coalesce(' Note: ' || nullif(trim(coalesce(p_note,'')),''), ''));
end;
$$;

-- ---------------------------------------------------------------- matches
create or replace function public.admin_create_match(
  p_match_date date, p_venue text, p_turf_cost numeric, p_extra_cost numeric, p_notes text, p_attendee_ids uuid[], p_open_voting boolean default false
) returns uuid language plpgsql security definer set search_path = public
as $$
declare v_match uuid; v_row public.matches%rowtype; v_share numeric;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  if p_match_date is null or length(trim(coalesce(p_venue,''))) = 0 then raise exception 'Date and venue are required'; end if;
  if p_turf_cost is null or p_turf_cost <= 0 or coalesce(p_extra_cost,0) < 0 then raise exception 'Invalid match cost'; end if;
  if not coalesce(p_open_voting,false) then perform public.validate_attendees(p_attendee_ids); end if;
  insert into public.matches(match_date, venue, turf_cost, extra_cost, notes, created_by, status)
  values (p_match_date, trim(p_venue), p_turf_cost, coalesce(p_extra_cost,0), nullif(trim(coalesce(p_notes,'')),''), public.current_profile_id(),
          case when coalesce(p_open_voting,false) then 'voting' else 'unsettled' end)
  returning id into v_match;
  select * into v_row from public.matches where id = v_match;
  if coalesce(p_open_voting,false) then
    perform public.notify_profiles(public.active_member_ids(), 'vote', 'New match: are you in?',
      public.match_label(v_row) || ' · est. ' || public.inr(v_row.total_cost) || ' total. Tap to vote.', v_match);
  else
    perform public.write_attendance(v_match, v_row.total_cost, p_attendee_ids);
    v_share := round(v_row.total_cost / array_length(p_attendee_ids,1), 2);
    perform public.notify_profiles(p_attendee_ids, 'match', 'You are on the team sheet',
      public.match_label(v_row) || ' · ' || array_length(p_attendee_ids,1) || ' players · your share ' || public.inr(v_share) || '.', v_match);
    perform public.notify_profiles(
      (select coalesce(array_agg(id),'{}') from public.profiles where approved and active and not (id = any(p_attendee_ids))),
      'activity', 'Match created: ' || public.match_label(v_row),
      array_length(p_attendee_ids,1) || ' players selected · ' || public.inr(v_row.total_cost) || ' total. You are not on this team sheet.', v_match);
  end if;
  return v_match;
end;
$$;

create or replace function public.admin_update_match(
  p_match_id uuid, p_match_date date, p_venue text, p_turf_cost numeric, p_extra_cost numeric, p_notes text, p_attendee_ids uuid[]
) returns void language plpgsql security definer set search_path = public
as $$
declare v_old public.matches%rowtype; v_row public.matches%rowtype; v_changes text := '';
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_old from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_old.status = 'settled' then raise exception 'A settled match cannot be edited'; end if;
  if p_match_date is null or length(trim(coalesce(p_venue,''))) = 0 then raise exception 'Date and venue are required'; end if;
  if p_turf_cost is null or p_turf_cost <= 0 or coalesce(p_extra_cost,0) < 0 then raise exception 'Invalid match cost'; end if;
  if v_old.status = 'unsettled' then perform public.validate_attendees(p_attendee_ids); end if;
  update public.matches set match_date = p_match_date, venue = trim(p_venue), turf_cost = p_turf_cost, extra_cost = coalesce(p_extra_cost,0),
    notes = nullif(trim(coalesce(p_notes,'')),''), updated_at = now()
  where id = p_match_id;
  if v_old.status = 'unsettled' then perform public.write_attendance(p_match_id, p_turf_cost + coalesce(p_extra_cost,0), p_attendee_ids); end if;
  select * into v_row from public.matches where id = p_match_id;
  if v_old.match_date <> v_row.match_date then v_changes := v_changes || 'date → ' || to_char(v_row.match_date,'DD Mon') || ', '; end if;
  if v_old.venue <> v_row.venue then v_changes := v_changes || 'venue → ' || v_row.venue || ', '; end if;
  if v_old.total_cost <> v_row.total_cost then v_changes := v_changes || 'cost → ' || public.inr(v_row.total_cost) || ', '; end if;
  if v_old.status = 'unsettled' then v_changes := v_changes || 'team sheet updated, '; end if;
  v_changes := rtrim(v_changes, ', ');
  if v_changes <> '' then
    perform public.notify_profiles(public.active_member_ids(), 'activity', 'Match updated: ' || public.match_label(v_row),
      v_changes || '. Check the Matches page.', p_match_id);
  end if;
end;
$$;

create or replace function public.admin_delete_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_row public.matches%rowtype;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_row from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_row.status = 'settled' then raise exception 'A settled match cannot be deleted'; end if;
  -- notifications linked to the match are removed by the cascade, so send this one without a match link
  delete from public.matches where id = p_match_id;
  perform public.notify_profiles(public.active_member_ids(), 'activity', 'Match cancelled: ' || public.match_label(v_row),
    'The match on ' || to_char(v_row.match_date,'DD Mon') || ' at ' || v_row.venue || ' was removed by ' || public.my_name() || '. No money was deducted.', null);
end;
$$;

-- ---------------------------------------------------------------- voting
create or replace function public.close_match_voting(p_match_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_row public.matches%rowtype; v_ids uuid[]; v_share numeric;
begin
  select * into v_row from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_row.status <> 'voting' then raise exception 'Voting is already closed for this match'; end if;
  select coalesce(array_agg(v.profile_id), '{}') into v_ids
  from public.match_votes v join public.profiles p on p.id = v.profile_id
  where v.match_id = p_match_id and v.vote = 'yes' and p.approved and p.active;
  if coalesce(array_length(v_ids,1),0) = 0 then raise exception 'Nobody has voted yes yet. Wait for votes or delete the match.'; end if;
  perform public.write_attendance(p_match_id, v_row.total_cost, v_ids);
  update public.matches set status = 'unsettled', voting_closed_at = now(), updated_at = now() where id = p_match_id;
  v_share := round(v_row.total_cost / array_length(v_ids,1), 2);
  perform public.notify_profiles(v_ids, 'match', 'Team sheet locked — you are in',
    public.match_label(v_row) || ' · ' || array_length(v_ids,1) || ' players · your share ' || public.inr(v_share) || ' will be deducted after the match' || coalesce(' (' || p_reason || ')','') || '.', p_match_id);
  perform public.notify_profiles(
    (select coalesce(array_agg(id),'{}') from public.profiles where approved and active and not (id = any(v_ids))),
    'activity', 'Team sheet locked: ' || public.match_label(v_row),
    array_length(v_ids,1) || ' players in · ' || public.inr(v_share) || ' each. You are not playing this one.', p_match_id);
end;
$$;

create or replace function public.member_vote(p_match_id uuid, p_vote text)
returns text language plpgsql security definer set search_path = public
as $$
declare v_me uuid := public.current_profile_id(); v_row public.matches%rowtype; v_total int; v_voted int; v_yes int; v_old text; v_name text;
begin
  if not public.is_approved_member() then raise exception 'Your account is not approved yet'; end if;
  if p_vote not in ('yes','no') then raise exception 'Vote must be yes or no'; end if;
  select * into v_row from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_row.status <> 'voting' then raise exception 'Voting has closed for this match'; end if;
  select vote into v_old from public.match_votes where match_id = p_match_id and profile_id = v_me;
  insert into public.match_votes(match_id, profile_id, vote) values (p_match_id, v_me, p_vote)
  on conflict (match_id, profile_id) do update set vote = excluded.vote, updated_at = now();
  update public.notifications set read = true where profile_id = v_me and match_id = p_match_id and kind = 'vote';
  select count(*) into v_total from public.profiles where approved and active;
  select count(*), count(*) filter (where v.vote = 'yes') into v_voted, v_yes
  from public.match_votes v join public.profiles p on p.id = v.profile_id where v.match_id = p_match_id and p.approved and p.active;
  select full_name into v_name from public.profiles where id = v_me;
  if v_old is distinct from p_vote then
    perform public.notify_profiles(public.everyone_except(v_me), 'activity',
      v_name || case when p_vote = 'yes' then ' is in' else ' is out' end || case when v_old is not null then ' (changed)' else '' end || ' · ' || public.match_label(v_row),
      v_yes || ' in · ' || (v_total - v_voted) || ' yet to vote' || case when v_yes > 0 then ' · ~' || public.inr(round(v_row.total_cost / v_yes, 2)) || ' each' else '' end, p_match_id);
  end if;
  if v_voted >= v_total and v_yes > 0 then
    perform public.close_match_voting(p_match_id, 'everyone voted');
    return 'closed';
  end if;
  return 'recorded';
end;
$$;

-- ---------------------------------------------------------------- settle (balance shown)
create or replace function public.admin_settle_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_match public.matches%rowtype; v_att record; v_balance numeric; v_short text := ''; v_ids uuid[];
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_match from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_match.status = 'settled' then raise exception 'This match is already settled'; end if;
  if v_match.status = 'voting' then raise exception 'Close voting first to lock the attendance'; end if;
  if not exists(select 1 from public.match_attendance where match_id = p_match_id) then raise exception 'No attendees found'; end if;
  for v_att in select a.*, p.full_name from public.match_attendance a join public.profiles p on p.id = a.profile_id where a.match_id = p_match_id order by p.full_name loop
    if public.wallet_balance(v_att.profile_id) < v_att.share_amount then v_short := v_short || case when v_short = '' then '' else ', ' end || v_att.full_name; end if;
  end loop;
  if v_short <> '' then raise exception 'Insufficient wallet balance: %. Top up before settling.', v_short; end if;
  for v_att in select * from public.match_attendance where match_id = p_match_id order by profile_id loop
    insert into public.wallet_transactions(profile_id, amount, transaction_type, description, match_id, created_by)
    values (v_att.profile_id, -v_att.share_amount, 'match_deduction',
      'Turf match: ' || v_match.venue || ' (' || v_match.match_date::text || ')', p_match_id, public.current_profile_id());
    v_balance := public.wallet_balance(v_att.profile_id);
    insert into public.notifications(profile_id, kind, title, body, match_id)
    values (v_att.profile_id, 'wallet', 'Match settled: ' || public.inr(v_att.share_amount) || ' deducted',
      public.match_label(v_match) || ' · Balance now ' || public.inr(v_balance) || '.', p_match_id);
  end loop;
  update public.matches set status = 'settled', settled_at = now(), updated_at = now() where id = p_match_id;
  select coalesce(array_agg(profile_id),'{}') into v_ids from public.match_attendance where match_id = p_match_id;
  perform public.notify_profiles(
    (select coalesce(array_agg(id),'{}') from public.profiles where approved and active and not (id = any(v_ids))),
    'activity', 'Match settled: ' || public.match_label(v_match),
    public.inr(v_match.total_cost) || ' split between ' || array_length(v_ids,1) || ' players. Nothing deducted from you.', p_match_id);
end;
$$;

-- ---------------------------------------------------------------- permissions (unchanged signatures)
do $$
declare f text;
begin
  foreach f in array array[
    'public.admin_add_member(text,text,text)',
    'public.admin_approve_member(uuid)',
    'public.admin_wallet_adjustment(uuid,text,numeric,text)',
    'public.admin_review_deposit(uuid,boolean,text)',
    'public.admin_create_match(date,text,numeric,numeric,text,uuid[],boolean)',
    'public.admin_update_match(uuid,date,text,numeric,numeric,text,uuid[])',
    'public.admin_delete_match(uuid)',
    'public.member_vote(uuid,text)',
    'public.admin_settle_match(uuid)'
  ] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;
revoke all on function public.close_match_voting(uuid,text) from public, anon, authenticated;
