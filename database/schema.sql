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
