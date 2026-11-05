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
