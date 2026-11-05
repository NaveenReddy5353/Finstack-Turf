-- ============================================================================
-- FINSTACK TURF — v6 "Stadium": match time & venue link, captains & teams,
-- vote comments, live scoring (ball-by-ball or totals), chat.
-- Safe to run on an existing project (idempotent). Adds columns/tables and
-- functions only; nothing existing is removed or changed in meaning.
-- ============================================================================

-- ---------------------------------------------------------------- matches: details
alter table public.matches add column if not exists start_time time;
alter table public.matches add column if not exists venue_url text;
alter table public.matches add column if not exists overs int not null default 10 check (overs between 1 and 50);
alter table public.matches add column if not exists captain_a uuid references public.profiles(id) on delete set null;
alter table public.matches add column if not exists captain_b uuid references public.profiles(id) on delete set null;
alter table public.matches add column if not exists team_a_name text not null default 'Team A';
alter table public.matches add column if not exists team_b_name text not null default 'Team B';
alter table public.matches add column if not exists play_status text not null default 'upcoming' check (play_status in ('upcoming','live','completed'));
alter table public.matches add column if not exists toss_winner text check (toss_winner in ('A','B'));
alter table public.matches add column if not exists toss_decision text check (toss_decision in ('bat','bowl'));
alter table public.matches add column if not exists winner text check (winner in ('A','B','tie','none'));
alter table public.matches add column if not exists result_text text;
alter table public.matches add column if not exists mom_profile_id uuid references public.profiles(id) on delete set null;
alter table public.matches add column if not exists started_at timestamptz;
alter table public.matches add column if not exists completed_at timestamptz;

alter table public.match_votes add column if not exists comment text;

-- ---------------------------------------------------------------- teams
create table if not exists public.match_teams (
  match_id uuid not null references public.matches(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  team text not null check (team in ('A','B')),
  primary key (match_id, profile_id)
);

-- ---------------------------------------------------------------- scoring
create table if not exists public.match_innings (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  innings_no int not null check (innings_no in (1,2)),
  batting_team text not null check (batting_team in ('A','B')),
  runs int not null default 0,
  wickets int not null default 0,
  balls int not null default 0,          -- legal balls bowled
  extras int not null default 0,
  status text not null default 'pending' check (status in ('pending','live','completed')),
  manual boolean not null default false, -- totals typed in rather than ball-by-ball
  updated_at timestamptz not null default now(),
  unique (match_id, innings_no)
);

create table if not exists public.match_balls (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  innings_no int not null check (innings_no in (1,2)),
  seq int not null,
  over_no int not null,
  ball_in_over int not null,
  batter_id uuid references public.profiles(id) on delete set null,
  bowler_id uuid references public.profiles(id) on delete set null,
  runs int not null default 0,            -- runs off the bat (or run byes for byes)
  extra_type text check (extra_type in ('wd','nb','b','lb')),
  extra_runs int not null default 0,
  is_wicket boolean not null default false,
  wicket_type text,
  out_player_id uuid references public.profiles(id) on delete set null,
  legal boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (match_id, innings_no, seq)
);
create index if not exists match_balls_match_idx on public.match_balls(match_id, innings_no, seq);

-- ---------------------------------------------------------------- chat
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete set null,
  match_id uuid references public.matches(id) on delete cascade,   -- null = club group chat
  kind text not null default 'chat' check (kind in ('chat','vote','system')),
  body text not null,
  created_at timestamptz not null default now()
);
create index if not exists messages_match_created_idx on public.messages(match_id, created_at desc);
create index if not exists messages_created_idx on public.messages(created_at desc);

-- ---------------------------------------------------------------- RLS
alter table public.match_teams enable row level security;
alter table public.match_innings enable row level security;
alter table public.match_balls enable row level security;
alter table public.messages enable row level security;
drop policy if exists "approved read teams" on public.match_teams;
create policy "approved read teams" on public.match_teams for select to authenticated using (public.is_approved_member());
drop policy if exists "approved read innings" on public.match_innings;
create policy "approved read innings" on public.match_innings for select to authenticated using (public.is_approved_member());
drop policy if exists "approved read balls" on public.match_balls;
create policy "approved read balls" on public.match_balls for select to authenticated using (public.is_approved_member());
drop policy if exists "approved read messages" on public.messages;
create policy "approved read messages" on public.messages for select to authenticated using (public.is_approved_member());
revoke insert, update, delete on public.match_teams, public.match_innings, public.match_balls, public.messages from anon, authenticated;

do $$ begin alter publication supabase_realtime add table public.match_innings; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.match_balls; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.messages; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.match_teams; exception when duplicate_object then null; when undefined_object then null; end $$;

-- ---------------------------------------------------------------- helpers
create or replace function public.can_score(p_match_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select public.is_approved_admin() or exists (
    select 1 from public.matches m where m.id = p_match_id and public.current_profile_id() in (m.captain_a, m.captain_b));
$$;
revoke all on function public.can_score(uuid) from public, anon, authenticated;

create or replace function public.team_name(p_match public.matches, p_team text)
returns text language sql immutable
as $$ select case p_team when 'A' then p_match.team_a_name when 'B' then p_match.team_b_name else 'Tie' end; $$;

-- ---------------------------------------------------------------- match details (admin)
create or replace function public.admin_set_match_details(
  p_match_id uuid, p_start_time time, p_venue_url text, p_overs int,
  p_captain_a uuid, p_captain_b uuid, p_team_a_name text, p_team_b_name text
) returns void language plpgsql security definer set search_path = public
as $$
declare v_row public.matches%rowtype; v_old_a uuid; v_old_b uuid; v_url text := nullif(trim(coalesce(p_venue_url,'')),'');
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  select * into v_row from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_url is not null and v_url !~* '^https?://' then raise exception 'Venue link must start with http:// or https://'; end if;
  if p_captain_a is not null and p_captain_a = p_captain_b then raise exception 'Choose two different captains'; end if;
  v_old_a := v_row.captain_a; v_old_b := v_row.captain_b;
  update public.matches set start_time = p_start_time, venue_url = v_url, overs = coalesce(p_overs, overs),
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

-- ---------------------------------------------------------------- vote with comment
drop function if exists public.member_vote(uuid, text);
create or replace function public.member_vote(p_match_id uuid, p_vote text, p_comment text default null)
returns text language plpgsql security definer set search_path = public
as $$
declare v_me uuid := public.current_profile_id(); v_row public.matches%rowtype; v_total int; v_voted int; v_yes int; v_old text; v_name text;
        v_comment text := nullif(trim(coalesce(p_comment,'')),'');
begin
  if not public.is_approved_member() then raise exception 'Your account is not approved yet'; end if;
  if p_vote not in ('yes','no') then raise exception 'Vote must be yes or no'; end if;
  select * into v_row from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_row.status <> 'voting' then raise exception 'Voting has closed for this match'; end if;
  select vote into v_old from public.match_votes where match_id = p_match_id and profile_id = v_me;
  insert into public.match_votes(match_id, profile_id, vote, comment) values (p_match_id, v_me, p_vote, v_comment)
  on conflict (match_id, profile_id) do update set vote = excluded.vote, comment = coalesce(excluded.comment, public.match_votes.comment), updated_at = now();
  update public.notifications set read = true where profile_id = v_me and match_id = p_match_id and kind = 'vote';
  select count(*) into v_total from public.profiles where approved and active;
  select count(*), count(*) filter (where v.vote = 'yes') into v_voted, v_yes
  from public.match_votes v join public.profiles p on p.id = v.profile_id where v.match_id = p_match_id and p.approved and p.active;
  select full_name into v_name from public.profiles where id = v_me;
  if v_comment is not null then
    insert into public.messages(profile_id, match_id, kind, body) values (v_me, p_match_id, 'vote', '(' || case when p_vote = 'yes' then 'in' else 'out' end || ') ' || v_comment);
  end if;
  if v_old is distinct from p_vote or v_comment is not null then
    perform public.notify_profiles(public.everyone_except(v_me), 'activity',
      v_name || case when p_vote = 'yes' then ' is in' else ' is out' end || case when v_old is not null and v_old <> p_vote then ' (changed)' else '' end || ' · ' || public.match_label(v_row),
      v_yes || ' in · ' || (v_total - v_voted) || ' yet to vote' || case when v_yes > 0 then ' · ~' || public.inr(round(v_row.total_cost / v_yes, 2)) || ' each' else '' end
      || coalesce(' · "' || left(v_comment, 80) || '"', ''), p_match_id);
  end if;
  if v_voted >= v_total and v_yes > 0 then
    perform public.close_match_voting(p_match_id, 'everyone voted');
    return 'closed';
  end if;
  return 'recorded';
end;
$$;

-- ---------------------------------------------------------------- teams (admin or captains)
create or replace function public.set_match_teams(p_match_id uuid, p_assignments jsonb)
returns void language plpgsql security definer set search_path = public
as $$
declare v_row public.matches%rowtype; r record; v_a int; v_b int;
begin
  if not public.can_score(p_match_id) then raise exception 'Only the admin or the captains can pick teams'; end if;
  select * into v_row from public.matches where id = p_match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if v_row.status = 'voting' then raise exception 'Close voting first — teams are picked from the locked team sheet'; end if;
  if v_row.play_status = 'completed' then raise exception 'This match is finished'; end if;
  delete from public.match_teams where match_id = p_match_id;
  for r in select (e->>'profile_id')::uuid as pid, upper(e->>'team') as team from jsonb_array_elements(coalesce(p_assignments,'[]'::jsonb)) e loop
    if r.team not in ('A','B') then continue; end if;
    if not exists (select 1 from public.match_attendance where match_id = p_match_id and profile_id = r.pid) then raise exception 'All players must be on the team sheet'; end if;
    insert into public.match_teams(match_id, profile_id, team) values (p_match_id, r.pid, r.team) on conflict (match_id, profile_id) do update set team = excluded.team;
  end loop;
  select count(*) filter (where team='A'), count(*) filter (where team='B') into v_a, v_b from public.match_teams where match_id = p_match_id;
  perform public.notify_profiles(public.everyone_except(public.current_profile_id()), 'activity', 'Teams updated: ' || public.match_label(v_row),
    v_row.team_a_name || ' (' || v_a || ') vs ' || v_row.team_b_name || ' (' || v_b || ') · picked by ' || public.my_name() || '.', p_match_id);
end;
$$;

-- ---------------------------------------------------------------- scoring
create or replace function public.recompute_innings(p_match_id uuid, p_innings_no int)
returns void language sql security definer set search_path = public
as $$
  update public.match_innings i set
    runs = coalesce((select sum(b.runs + b.extra_runs) from public.match_balls b where b.match_id = i.match_id and b.innings_no = i.innings_no), 0),
    wickets = coalesce((select count(*) from public.match_balls b where b.match_id = i.match_id and b.innings_no = i.innings_no and b.is_wicket), 0),
    balls = coalesce((select count(*) from public.match_balls b where b.match_id = i.match_id and b.innings_no = i.innings_no and b.legal), 0),
    extras = coalesce((select sum(b.extra_runs) from public.match_balls b where b.match_id = i.match_id and b.innings_no = i.innings_no), 0),
    manual = false, updated_at = now()
  where i.match_id = p_match_id and i.innings_no = p_innings_no;
$$;
revoke all on function public.recompute_innings(uuid,int) from public, anon, authenticated;

create or replace function public.start_match(p_match_id uuid, p_toss_winner text, p_toss_decision text)
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
  v_bat_first := case when p_toss_decision = 'bat' then p_toss_winner else case p_toss_winner when 'A' then 'B' else 'A' end end;
  insert into public.match_innings(match_id, innings_no, batting_team, status) values (p_match_id, 1, v_bat_first, 'live')
  on conflict (match_id, innings_no) do update set batting_team = excluded.batting_team, status = 'live';
  insert into public.match_innings(match_id, innings_no, batting_team, status) values (p_match_id, 2, case v_bat_first when 'A' then 'B' else 'A' end, 'pending')
  on conflict (match_id, innings_no) do update set batting_team = excluded.batting_team;
  update public.matches set play_status = 'live', toss_winner = p_toss_winner, toss_decision = p_toss_decision, started_at = coalesce(started_at, now()), updated_at = now() where id = p_match_id;
  perform public.notify_profiles(public.active_member_ids(), 'match', '🔴 LIVE: ' || public.match_label(v_row),
    public.team_name(v_row, p_toss_winner) || ' won the toss and chose to ' || p_toss_decision || '. ' || public.team_name(v_row, v_bat_first) || ' batting first. Tap for live score.', p_match_id);
end;
$$;

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
  v_legal := p_extra_type is null or p_extra_type in ('b','lb');
  v_extra := case when p_extra_type in ('wd','nb') then coalesce(nullif(p_extra_runs,0),1) when p_extra_type in ('b','lb') then coalesce(p_extra_runs,0) else 0 end;
  select coalesce(max(seq),0) + 1 into v_seq from public.match_balls where match_id = p_match_id and innings_no = p_innings_no;
  v_over := v_i.balls / 6; v_ball := case when v_legal then v_i.balls % 6 + 1 else v_i.balls % 6 end;
  insert into public.match_balls(match_id, innings_no, seq, over_no, ball_in_over, batter_id, bowler_id, runs, extra_type, extra_runs, is_wicket, wicket_type, out_player_id, legal, created_by)
  values (p_match_id, p_innings_no, v_seq, v_over + 1, v_ball, p_batter, p_bowler, coalesce(p_runs,0), p_extra_type, v_extra, coalesce(p_is_wicket,false), p_wicket_type, coalesce(p_out_player, case when coalesce(p_is_wicket,false) then p_batter end), v_legal, public.current_profile_id());
  -- incremental update works whether the innings started ball-by-ball or from a typed total
  update public.match_innings set runs = runs + coalesce(p_runs,0) + v_extra, wickets = wickets + case when coalesce(p_is_wicket,false) then 1 else 0 end,
    balls = balls + case when v_legal then 1 else 0 end, extras = extras + v_extra, updated_at = now()
  where match_id = p_match_id and innings_no = p_innings_no;
  select * into v_i from public.match_innings where match_id = p_match_id and innings_no = p_innings_no;
  -- auto end of innings: all overs bowled, all out (10), or target chased
  if v_i.balls >= v_m.overs * 6 or v_i.wickets >= 10 or (p_innings_no = 2 and v_i.runs > (select runs from public.match_innings where match_id = p_match_id and innings_no = 1)) then
    update public.match_innings set status = 'completed', updated_at = now() where match_id = p_match_id and innings_no = p_innings_no;
    if p_innings_no = 1 then update public.match_innings set status = 'live', updated_at = now() where match_id = p_match_id and innings_no = 2; end if;
  end if;
  return jsonb_build_object('runs', v_i.runs, 'wickets', v_i.wickets, 'balls', v_i.balls, 'status', (select status from public.match_innings where match_id = p_match_id and innings_no = p_innings_no));
end;
$$;

create or replace function public.undo_ball(p_match_id uuid, p_innings_no int)
returns void language plpgsql security definer set search_path = public
as $$
declare v_seq int; v_b public.match_balls%rowtype;
begin
  if not public.can_score(p_match_id) then raise exception 'Only the admin or the captains can score'; end if;
  select max(seq) into v_seq from public.match_balls where match_id = p_match_id and innings_no = p_innings_no;
  if v_seq is null then raise exception 'Nothing to undo'; end if;
  delete from public.match_balls where match_id = p_match_id and innings_no = p_innings_no and seq = v_seq returning * into v_b;
  update public.match_innings set runs = greatest(runs - v_b.runs - v_b.extra_runs, 0), wickets = greatest(wickets - case when v_b.is_wicket then 1 else 0 end, 0),
    balls = greatest(balls - case when v_b.legal then 1 else 0 end, 0), extras = greatest(extras - v_b.extra_runs, 0), status = 'live', updated_at = now()
  where match_id = p_match_id and innings_no = p_innings_no;
  if p_innings_no = 1 then update public.match_innings set status = 'pending', updated_at = now() where match_id = p_match_id and innings_no = 2 and balls = 0 and manual = false; end if;
end;
$$;

-- Type totals directly (no ball-by-ball). p_overs like 7.3 = 7 overs 3 balls.
create or replace function public.set_innings_total(p_match_id uuid, p_innings_no int, p_runs int, p_wickets int, p_overs numeric, p_completed boolean)
returns void language plpgsql security definer set search_path = public
as $$
declare v_m public.matches%rowtype; v_balls int;
begin
  if not public.can_score(p_match_id) then raise exception 'Only the admin or the captains can score'; end if;
  select * into v_m from public.matches where id = p_match_id for update;
  if not found or v_m.play_status <> 'live' then raise exception 'Start the match first (toss)'; end if;
  if p_runs < 0 or p_wickets < 0 or p_wickets > 10 then raise exception 'Invalid score'; end if;
  v_balls := floor(coalesce(p_overs,0)) * 6 + round((coalesce(p_overs,0) - floor(coalesce(p_overs,0))) * 10);
  if v_balls > v_m.overs * 6 then raise exception 'Overs exceed the match limit of %', v_m.overs; end if;
  update public.match_innings set runs = p_runs, wickets = p_wickets, balls = v_balls, manual = true, updated_at = now(),
    status = case when coalesce(p_completed,false) then 'completed' else 'live' end
  where match_id = p_match_id and innings_no = p_innings_no;
  if not found then raise exception 'Innings not found'; end if;
  if coalesce(p_completed,false) and p_innings_no = 1 then
    update public.match_innings set status = 'live', updated_at = now() where match_id = p_match_id and innings_no = 2 and status = 'pending';
  end if;
end;
$$;

create or replace function public.end_match(p_match_id uuid, p_winner text, p_result_text text, p_mom uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_m public.matches%rowtype; v_i1 public.match_innings%rowtype; v_i2 public.match_innings%rowtype; v_winner text; v_text text; v_mom_name text;
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
  update public.match_innings set status = 'completed', updated_at = now() where match_id = p_match_id;
  update public.matches set play_status = 'completed', winner = v_winner, result_text = v_text, mom_profile_id = p_mom, completed_at = now(), updated_at = now() where id = p_match_id;
  select full_name into v_mom_name from public.profiles where id = p_mom;
  perform public.notify_profiles(public.active_member_ids(), 'match', '🏆 ' || v_text,
    public.match_label(v_m) || ' · ' || v_m.team_a_name || ' ' || v_i1.runs || '/' || v_i1.wickets || ' vs ' || v_m.team_b_name || ' ' || coalesce(v_i2.runs,0) || '/' || coalesce(v_i2.wickets,0)
    || coalesce(' · Player of the match: ' || v_mom_name, '') || '. Scorecard in the app.', p_match_id);
  insert into public.messages(profile_id, match_id, kind, body) values (null, p_match_id, 'system', v_text || coalesce(' · Player of the match: ' || v_mom_name, ''));
end;
$$;

-- Reopen a completed match for score corrections (admin only).
create or replace function public.admin_reopen_match(p_match_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_approved_admin() then raise exception 'Admin access required'; end if;
  update public.matches set play_status = 'live', winner = null, result_text = null, completed_at = null, updated_at = now() where id = p_match_id and play_status = 'completed';
  if not found then raise exception 'Match is not completed'; end if;
  update public.match_innings set status = case innings_no when 1 then 'completed' else 'live' end, updated_at = now() where match_id = p_match_id;
end;
$$;

-- ---------------------------------------------------------------- chat
create or replace function public.post_message(p_body text, p_match_id uuid default null)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_body text := trim(coalesce(p_body,''));
begin
  if not public.is_approved_member() then raise exception 'Your account is not approved yet'; end if;
  if length(v_body) = 0 then raise exception 'Message is empty'; end if;
  if length(v_body) > 2000 then raise exception 'Message is too long (max 2000 characters)'; end if;
  if p_match_id is not null and not exists (select 1 from public.matches where id = p_match_id) then raise exception 'Match not found'; end if;
  insert into public.messages(profile_id, match_id, kind, body) values (public.current_profile_id(), p_match_id, 'chat', v_body) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.delete_message(p_message_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  delete from public.messages where id = p_message_id and (profile_id = public.current_profile_id() or public.is_approved_admin());
  if not found then raise exception 'You can only delete your own messages'; end if;
end;
$$;

-- ---------------------------------------------------------------- permissions
do $$
declare f text;
begin
  foreach f in array array[
    'public.admin_set_match_details(uuid,time,text,int,uuid,uuid,text,text)',
    'public.member_vote(uuid,text,text)',
    'public.set_match_teams(uuid,jsonb)',
    'public.start_match(uuid,text,text)',
    'public.score_ball(uuid,int,uuid,uuid,int,text,int,boolean,text,uuid)',
    'public.undo_ball(uuid,int)',
    'public.set_innings_total(uuid,int,int,int,numeric,boolean)',
    'public.end_match(uuid,text,text,uuid)',
    'public.admin_reopen_match(uuid)',
    'public.post_message(text,uuid)',
    'public.delete_message(uuid)'
  ] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;
