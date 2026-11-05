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
