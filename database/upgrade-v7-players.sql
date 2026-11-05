-- ============================================================================
-- FINSTACK TURF — v7: match end time, overs at toss, player profiles & photos,
-- chat retention, real-cricket scoring guards, automatic player of the match.
-- Safe to run on an existing project (idempotent).
-- ============================================================================

-- ---------------------------------------------------------------- columns
alter table public.matches add column if not exists end_time time;
alter table public.matches alter column overs drop not null;
alter table public.matches alter column overs set default null;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists playing_role text check (playing_role in ('batter','bowler','all-rounder','keeper'));
alter table public.profiles add column if not exists bio text;

-- ---------------------------------------------------------------- match details (end time, overs optional)
drop function if exists public.admin_set_match_details(uuid,time,text,int,uuid,uuid,text,text);
create or replace function public.admin_set_match_details(
  p_match_id uuid, p_start_time time, p_venue_url text, p_overs int,
  p_captain_a uuid, p_captain_b uuid, p_team_a_name text, p_team_b_name text, p_end_time time default null
) returns void language plpgsql security definer set search_path = public
as $$
declare v_row public.matches%rowtype; v_old_a uuid; v_old_b uuid; v_url text := nullif(trim(coalesce(p_venue_url,'')),'');
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_row from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_url is not null and v_url !~* '^https?://' then raise exception 'Venue link must start with http:// or https://'; end if;
  if p_captain_a is not null and p_captain_a = p_captain_b then raise exception 'Choose two different captains'; end if;
  if p_end_time is not null and p_start_time is not null and p_end_time <= p_start_time then raise exception 'End time must be after start time'; end if;
  if p_overs is not null and (p_overs < 1 or p_overs > 50) then raise exception 'Overs must be between 1 and 50'; end if;
  v_old_a := v_row.captain_a; v_old_b := v_row.captain_b;
  update public.matches set start_time = p_start_time, end_time = p_end_time, venue_url = v_url, overs = coalesce(p_overs, overs),
    captain_a = p_captain_a, captain_b = p_captain_b,
    team_a_name = coalesce(nullif(trim(p_team_a_name),''), 'Team A'), team_b_name = coalesce(nullif(trim(p_team_b_name),''), 'Team B'),
    updated_at = now()
  where id = p_match_id;
  select * into v_row from public.matches where id = p_match_id;
  if p_captain_a is not null and p_captain_a is distinct from v_old_a then
    perform public.notify_profiles(array[p_captain_a], 'match', 'You are captain of ' || v_row.team_a_name,
      public.match_label(v_row) || ' · pick your team once the team sheet is locked.', p_match_id);
  end if;
  if p_captain_b is not null and p_captain_b is distinct from v_old_b then
    perform public.notify_profiles(array[p_captain_b], 'match', 'You are captain of ' || v_row.team_b_name,
      public.match_label(v_row) || ' · pick your team once the team sheet is locked.', p_match_id);
  end if;
end;
$$;

-- Overs can be set by admin or captains once the team sheet is locked (before/at the toss).
create or replace function public.set_match_overs(p_match_id uuid, p_overs int)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.can_score(p_match_id) then raise exception 'Only the admin or the captains can set overs'; end if;
  if p_overs is null or p_overs < 1 or p_overs > 50 then raise exception 'Overs must be between 1 and 50'; end if;
  update public.matches set overs = p_overs, updated_at = now() where id = p_match_id and play_status <> 'completed';
  if not found then raise exception 'Match not found or already completed'; end if;
end;
$$;

-- Start match now takes overs as well.
drop function if exists public.start_match(uuid,text,text);
create or replace function public.start_match(p_match_id uuid, p_toss_winner text, p_toss_decision text, p_overs int default null)
returns void language plpgsql security definer set search_path = public
as $$
declare v_row public.matches%rowtype; v_bat_first text;
begin
  if not public.can_score(p_match_id) then raise exception 'Only the admin or the captains can start the match'; end if;
  select * into v_row from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_row.status = 'voting' then raise exception 'Close voting first'; end if;
  if v_row.play_status = 'completed' then raise exception 'This match is already finished'; end if;
  if p_toss_winner not in ('A','B') or p_toss_decision not in ('bat','bowl') then raise exception 'Enter the toss result'; end if;
  if p_overs is not null then
    if p_overs < 1 or p_overs > 50 then raise exception 'Overs must be between 1 and 50'; end if;
    update public.matches set overs = p_overs where id = p_match_id; v_row.overs := p_overs;
  end if;
  if v_row.overs is null then raise exception 'Set the overs per side first'; end if;
  v_bat_first := case when p_toss_decision = 'bat' then p_toss_winner else case p_toss_winner when 'A' then 'B' else 'A' end end;
  insert into public.match_innings(match_id, innings_no, batting_team, status) values (p_match_id, 1, v_bat_first, 'live')
  on conflict (match_id, innings_no) do update set batting_team = excluded.batting_team, status = 'live';
  insert into public.match_innings(match_id, innings_no, batting_team, status) values (p_match_id, 2, case v_bat_first when 'A' then 'B' else 'A' end, 'pending')
  on conflict (match_id, innings_no) do update set batting_team = excluded.batting_team;
  update public.matches set play_status = 'live', toss_winner = p_toss_winner, toss_decision = p_toss_decision, started_at = coalesce(started_at, now()), updated_at = now() where id = p_match_id;
  perform public.notify_profiles(public.active_member_ids(), 'match', '🔴 LIVE: ' || public.match_label(v_row),
    public.team_name(v_row, p_toss_winner) || ' won the toss and chose to ' || p_toss_decision || '. ' || public.team_name(v_row, v_bat_first) || ' batting first · ' || v_row.overs || ' overs. Tap for live score.', p_match_id);
end;
$$;

-- ---------------------------------------------------------------- scoring guard: a dismissed batter cannot face again
create or replace function public.score_ball(
  p_match_id uuid, p_innings_no int, p_batter uuid, p_bowler uuid, p_runs int, p_extra_type text, p_extra_runs int,
  p_is_wicket boolean, p_wicket_type text, p_out_player uuid
) returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_m public.matches%rowtype; v_i public.match_innings%rowtype; v_seq int; v_legal boolean; v_over int; v_ball int; v_extra int;
begin
  if not public.can_score(p_match_id) then raise exception 'Only the admin or the captains can score'; end if;
  select * into v_m from public.matches where id = p_match_id for update;
  if not found or v_m.play_status <> 'live' then raise exception 'Match is not live'; end if;
  select * into v_i from public.match_innings where match_id = p_match_id and innings_no = p_innings_no for update;
  if not found or v_i.status <> 'live' then raise exception 'This innings is not live'; end if;
  if p_extra_type is not null and p_extra_type not in ('wd','nb','b','lb') then raise exception 'Invalid extra type'; end if;
  if coalesce(p_runs,0) < 0 or coalesce(p_runs,0) > 7 then raise exception 'Invalid runs'; end if;
  if p_batter is not null and exists (select 1 from public.match_balls b where b.match_id = p_match_id and b.innings_no = p_innings_no and b.is_wicket and b.out_player_id = p_batter) then
    raise exception '% is already out — pick the next batter', (select full_name from public.profiles where id = p_batter);
  end if;
  v_legal := p_extra_type is null or p_extra_type in ('b','lb');
  v_extra := case when p_extra_type in ('wd','nb') then coalesce(nullif(p_extra_runs,0),1) when p_extra_type in ('b','lb') then coalesce(p_extra_runs,0) else 0 end;
  select coalesce(max(seq),0) + 1 into v_seq from public.match_balls where match_id = p_match_id and innings_no = p_innings_no;
  v_over := v_i.balls / 6; v_ball := case when v_legal then v_i.balls % 6 + 1 else v_i.balls % 6 end;
  insert into public.match_balls(match_id, innings_no, seq, over_no, ball_in_over, batter_id, bowler_id, runs, extra_type, extra_runs, is_wicket, wicket_type, out_player_id, legal, created_by)
  values (p_match_id, p_innings_no, v_seq, v_over + 1, v_ball, p_batter, p_bowler, coalesce(p_runs,0), p_extra_type, v_extra, coalesce(p_is_wicket,false), p_wicket_type, coalesce(p_out_player, case when coalesce(p_is_wicket,false) then p_batter end), v_legal, public.current_profile_id());
  update public.match_innings set runs = runs + coalesce(p_runs,0) + v_extra, wickets = wickets + case when coalesce(p_is_wicket,false) then 1 else 0 end,
    balls = balls + case when v_legal then 1 else 0 end, extras = extras + v_extra, updated_at = now()
  where match_id = p_match_id and innings_no = p_innings_no;
  select * into v_i from public.match_innings where match_id = p_match_id and innings_no = p_innings_no;
  if v_i.balls >= v_m.overs * 6 or v_i.wickets >= 10 or (p_innings_no = 2 and v_i.runs > (select runs from public.match_innings where match_id = p_match_id and innings_no = 1)) then
    update public.match_innings set status = 'completed', updated_at = now() where match_id = p_match_id and innings_no = p_innings_no;
    if p_innings_no = 1 then update public.match_innings set status = 'live', updated_at = now() where match_id = p_match_id and innings_no = 2; end if;
  end if;
  return jsonb_build_object('runs', v_i.runs, 'wickets', v_i.wickets, 'balls', v_i.balls, 'status', (select status from public.match_innings where match_id = p_match_id and innings_no = p_innings_no),
    'over_complete', v_legal and v_i.balls % 6 = 0 and v_i.balls > 0);
end;
$$;

-- ---------------------------------------------------------------- automatic player of the match (CricHeroes-style points)
-- batting: 1/run, +1 per four, +2 per six, +5 for 25+, +10 for 50+ ; bowling: 20/wicket, +5 per maiden-ish (none), -0.5 per run conceded above 6 rpo
create or replace function public.match_points(p_match_id uuid)
returns table (profile_id uuid, points numeric, runs int, balls int, fours int, sixes int, wickets int, conceded int, bowled_balls int)
language sql stable security definer set search_path = public
as $$
  with bat as (
    select b.batter_id as pid,
           sum(case when b.extra_type is null or b.extra_type = 'nb' then b.runs else 0 end)::int as runs,
           count(*) filter (where b.extra_type is distinct from 'wd')::int as balls,
           count(*) filter (where b.runs = 4 and (b.extra_type is null or b.extra_type = 'nb'))::int as fours,
           count(*) filter (where b.runs = 6 and (b.extra_type is null or b.extra_type = 'nb'))::int as sixes
    from public.match_balls b where b.match_id = p_match_id and b.batter_id is not null group by b.batter_id),
  bowl as (
    select b.bowler_id as pid,
           count(*) filter (where b.is_wicket and coalesce(b.wicket_type,'') not ilike '%run%')::int as wickets,
           sum(case when b.extra_type in ('b','lb') then 0 else b.runs + b.extra_runs end)::int as conceded,
           count(*) filter (where b.legal)::int as bowled_balls
    from public.match_balls b where b.match_id = p_match_id and b.bowler_id is not null group by b.bowler_id)
  select coalesce(bat.pid, bowl.pid) as profile_id,
         round(coalesce(bat.runs,0) + coalesce(bat.fours,0) + 2*coalesce(bat.sixes,0)
           + case when coalesce(bat.runs,0) >= 50 then 10 when coalesce(bat.runs,0) >= 25 then 5 else 0 end
           + 20*coalesce(bowl.wickets,0)
           - greatest(coalesce(bowl.conceded,0) - coalesce(bowl.bowled_balls,0), 0) * 0.5, 1) as points,
         coalesce(bat.runs,0), coalesce(bat.balls,0), coalesce(bat.fours,0), coalesce(bat.sixes,0),
         coalesce(bowl.wickets,0), coalesce(bowl.conceded,0), coalesce(bowl.bowled_balls,0)
  from bat full outer join bowl on bat.pid = bowl.pid;
$$;
revoke all on function public.match_points(uuid) from public, anon;
grant execute on function public.match_points(uuid) to authenticated;

create or replace function public.end_match(p_match_id uuid, p_winner text, p_result_text text, p_mom uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_m public.matches%rowtype; v_i1 public.match_innings%rowtype; v_i2 public.match_innings%rowtype; v_winner text; v_text text; v_mom uuid; v_mom_name text;
begin
  if not public.can_score(p_match_id) then raise exception 'Only the admin or the captains can end the match'; end if;
  select * into v_m from public.matches where id = p_match_id for update;
  if not found or v_m.play_status <> 'live' then raise exception 'Match is not live'; end if;
  select * into v_i1 from public.match_innings where match_id = p_match_id and innings_no = 1;
  select * into v_i2 from public.match_innings where match_id = p_match_id and innings_no = 2;
  v_winner := p_winner;
  if v_winner is null then
    if v_i1.runs > v_i2.runs then v_winner := v_i1.batting_team; elsif v_i2.runs > v_i1.runs then v_winner := v_i2.batting_team; else v_winner := 'tie'; end if;
  end if;
  if v_winner not in ('A','B','tie','none') then raise exception 'Invalid winner'; end if;
  v_text := nullif(trim(coalesce(p_result_text,'')),'');
  if v_text is null then
    v_text := case
      when v_winner = 'tie' then 'Match tied'
      when v_winner = 'none' then 'No result'
      when v_winner = v_i1.batting_team then public.team_name(v_m, v_winner) || ' won by ' || (v_i1.runs - v_i2.runs) || ' runs'
      else public.team_name(v_m, v_winner) || ' won by ' || (10 - v_i2.wickets) || ' wickets' end;
  end if;
  -- automatic player of the match from the ball-by-ball data (winning side preferred on ties of points)
  v_mom := p_mom;
  if v_mom is null then
    select mp.profile_id into v_mom from public.match_points(p_match_id) mp
    left join public.match_teams t on t.match_id = p_match_id and t.profile_id = mp.profile_id
    order by mp.points desc, (t.team = v_winner) desc nulls last, mp.runs desc limit 1;
  end if;
  update public.match_innings set status = 'completed', updated_at = now() where match_id = p_match_id;
  update public.matches set play_status = 'completed', winner = v_winner, result_text = v_text, mom_profile_id = v_mom, completed_at = now(), updated_at = now() where id = p_match_id;
  select full_name into v_mom_name from public.profiles where id = v_mom;
  perform public.notify_profiles(public.active_member_ids(), 'match', '🏆 ' || v_text,
    public.match_label(v_m) || ' · ' || v_m.team_a_name || ' ' || v_i1.runs || '/' || v_i1.wickets || ' vs ' || v_m.team_b_name || ' ' || coalesce(v_i2.runs,0) || '/' || coalesce(v_i2.wickets,0)
    || coalesce(' · Player of the match: ' || v_mom_name, '') || '. Scorecard in the app.', p_match_id);
  insert into public.messages(profile_id, match_id, kind, body) values (null, p_match_id, 'system', v_text || coalesce(' · Player of the match: ' || v_mom_name, ''));
end;
$$;

-- ---------------------------------------------------------------- my account
create or replace function public.update_my_profile(p_full_name text, p_phone text, p_playing_role text, p_avatar_url text, p_bio text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if public.current_profile_id() is null then raise exception 'Not signed in'; end if;
  if length(trim(coalesce(p_full_name,''))) < 2 then raise exception 'Name is required'; end if;
  if p_playing_role is not null and p_playing_role not in ('batter','bowler','all-rounder','keeper') then raise exception 'Invalid playing role'; end if;
  update public.profiles set full_name = trim(p_full_name), phone = nullif(trim(coalesce(p_phone,'')),''), playing_role = p_playing_role,
    avatar_url = nullif(trim(coalesce(p_avatar_url,'')),''), bio = left(nullif(trim(coalesce(p_bio,'')),''), 160)
  where id = public.current_profile_id();
end;
$$;

-- Profile photos: public bucket "avatars"; each member can write only inside their own folder <profile_id>/...
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
drop policy if exists "avatars public read" on storage.objects;
create policy "avatars public read" on storage.objects for select using (bucket_id = 'avatars');
drop policy if exists "avatars own write" on storage.objects;
create policy "avatars own write" on storage.objects for insert to authenticated with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.current_profile_id()::text);
drop policy if exists "avatars own update" on storage.objects;
create policy "avatars own update" on storage.objects for update to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.current_profile_id()::text);
drop policy if exists "avatars own delete" on storage.objects;
create policy "avatars own delete" on storage.objects for delete to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.current_profile_id()::text);

-- ---------------------------------------------------------------- chat retention
-- Admin button: clear group chat older than N days (0 = everything). Match comment threads are kept.
create or replace function public.admin_clear_chat(p_older_than_days int)
returns int language plpgsql security definer set search_path = public
as $$
declare n int;
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  delete from public.messages where match_id is null and created_at < now() - make_interval(days => greatest(coalesce(p_older_than_days,0),0));
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Nightly automatic cleanup (03:30 IST = 22:00 UTC): group chat older than 7 days.
-- Change the "7" below to keep more/less; delete the job with select cron.unschedule('finstack-chat-cleanup');
do $$ begin
  create extension if not exists pg_cron;
exception when others then raise notice 'pg_cron not available: enable it under Database → Extensions, then re-run this script'; end $$;
do $$ begin
  begin perform cron.unschedule('finstack-chat-cleanup'); exception when others then null; end;
  perform cron.schedule('finstack-chat-cleanup', '0 22 * * *',
    $cron$ delete from public.messages where match_id is null and created_at < now() - interval '7 days' $cron$);
  raise notice 'Nightly chat cleanup scheduled (keeps 7 days).';
exception when others then raise notice 'Chat cleanup not scheduled (pg_cron missing): %', sqlerrm; end $$;

-- ---------------------------------------------------------------- permissions
do $$
declare f text;
begin
  foreach f in array array[
    'public.admin_set_match_details(uuid,time,text,int,uuid,uuid,text,text,time)',
    'public.set_match_overs(uuid,int)',
    'public.start_match(uuid,text,text,int)',
    'public.score_ball(uuid,int,uuid,uuid,int,text,int,boolean,text,uuid)',
    'public.end_match(uuid,text,text,uuid)',
    'public.update_my_profile(text,text,text,text,text)',
    'public.admin_clear_chat(int)'
  ] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;
