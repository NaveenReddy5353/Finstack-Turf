-- Finstack Turf: run once in Supabase SQL Editor.
-- Links a signed-in login to its member record by email (fixes members re-added after their login existed).
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
