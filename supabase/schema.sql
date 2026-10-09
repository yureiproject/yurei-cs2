-- Redline CS2 Team Hub: Supabase setup
-- Run this once in Supabase Dashboard > SQL Editor.
-- The browser client uses only the publishable/anon key; never expose a service-role key.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists supabase_vault with schema vault;

create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  owner_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.team_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  player_id text not null,
  display_name text not null check (char_length(display_name) between 1 and 60),
  role text not null default 'player' check (role in ('admin','player')),
  player_role text not null default 'Rifler',
  avatar_path text,
  created_at timestamptz not null default now(),
  unique (team_id, player_id)
);

-- Safe to rerun if the earlier schema was already installed.
alter table public.team_members add column if not exists player_role text not null default 'Rifler';
alter table public.team_members add column if not exists avatar_path text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname='team_members_player_role_check') then
    alter table public.team_members add constraint team_members_player_role_check
      check (player_role in ('IGL','Entry','AWPer','Support','Lurker','Rifler','Coach','Substitute'));
  end if;
end $$;

create table if not exists public.team_state (
  team_id uuid primary key references public.teams(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.team_invites (
  token_hash text primary key,
  invite_id uuid not null default gen_random_uuid() unique,
  team_id uuid not null references public.teams(id) on delete cascade,
  player_id text,
  created_by uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  redeemed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

-- The first administrator is explicitly allow-listed from SQL Editor before public signup is enabled.
create table if not exists public.bootstrap_admins (
  email text primary key check (email = lower(trim(email))),
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.bootstrap_admins enable row level security;
revoke all on public.bootstrap_admins from public, anon, authenticated;

-- Legacy ciphertext columns are nullable; new credentials are stored in Supabase Vault.
-- Vault IDs are metadata only. Secret values are never returned to browser JavaScript.
create table if not exists public.team_integrations (
  team_id uuid primary key references public.teams(id) on delete cascade,
  faceit_key_cipher bytea,
  leetify_key_cipher bytea,
  faceit_secret_id uuid,
  leetify_secret_id uuid,
  updated_at timestamptz not null default now()
);
alter table public.team_integrations alter column faceit_key_cipher drop not null;
alter table public.team_integrations alter column leetify_key_cipher drop not null;
alter table public.team_integrations add column if not exists faceit_secret_id uuid;
alter table public.team_integrations add column if not exists leetify_secret_id uuid;

create table if not exists public.player_integrations (
  team_id uuid not null references public.teams(id) on delete cascade,
  player_id text not null,
  faceit_nickname text not null,
  steam_id64 text not null check (steam_id64 ~ '^[0-9]{17}$'),
  updated_at timestamptz not null default now(),
  primary key (team_id,player_id)
);

create index if not exists team_members_team_idx on public.team_members(team_id);
create index if not exists team_invites_lookup_idx on public.team_invites(team_id, player_id, expires_at);

create or replace function public.current_team_id()
returns uuid language sql stable security definer
set search_path = public, auth
as $$ select team_id from public.team_members where user_id = auth.uid() limit 1 $$;

create or replace function public.current_player_id()
returns text language sql stable security definer
set search_path = public, auth
as $$ select player_id from public.team_members where user_id = auth.uid() limit 1 $$;

create or replace function public.bootstrap_team(team_name text, player_id text, display_name text)
returns uuid language plpgsql security definer
set search_path = public, auth, extensions
as $$
declare new_team uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if not exists (
    select 1 from public.bootstrap_admins
     where email=lower(auth.jwt()->>'email') and claimed_at is null
  ) then raise exception 'Adresse non autorisée pour le compte administrateur initial'; end if;
  perform pg_advisory_xact_lock(hashtext('redline:bootstrap_team'));
  
  if length(trim(team_name)) not between 1 and 80 or length(trim(display_name)) not between 1 and 60 then
    raise exception 'Nom d’équipe ou de joueur invalide';
  end if;
  if exists(select 1 from public.teams) then raise exception 'Une équipe existe déjà sur ce projet'; end if;
  new_team := gen_random_uuid();
  insert into public.teams(id,name,owner_id) values(new_team,trim(team_name),auth.uid());
  insert into public.team_members(user_id,team_id,player_id,display_name,role)
    values(auth.uid(),new_team,player_id,trim(display_name),'admin');
  insert into public.team_state(team_id,state,updated_by)
    values(new_team,jsonb_build_object('profile',player_id),auth.uid());
  update public.bootstrap_admins set claimed_at=now()
   where email=lower(auth.jwt()->>'email') and claimed_at is null;
  return new_team;
end $$;

create or replace function public.create_team_invite(requested_player text)
returns table(invite_code text, expires_at timestamptz)
language plpgsql security definer
set search_path = public, auth, extensions
as $$
declare team uuid; raw_token text; expiry timestamptz;
begin
  team := public.current_team_id();
  if team is null or not exists(select 1 from public.team_members where user_id=auth.uid() and role='admin') then
    raise exception 'Réservé à l’administrateur';
  end if;
  
  perform pg_advisory_xact_lock(hashtext(team::text),hashtext(requested_player));
  if exists(select 1 from public.team_members m where m.team_id=team and m.player_id=requested_player) then
    raise exception 'Ce profil a déjà un compte';
  end if;
  raw_token := encode(extensions.gen_random_bytes(24),'hex');
  expiry := now() + interval '7 days';
  update public.team_invites set expires_at=now()
    where team_id=team and player_id=requested_player and redeemed_at is null;
  insert into public.team_invites(token_hash,team_id,player_id,created_by,expires_at)
    values(encode(extensions.digest(raw_token,'sha256'),'hex'),team,requested_player,auth.uid(),expiry);
  return query select raw_token,expiry;
end $$;

create or replace function public.admin_list_invites()
returns table(player_id text, expires_at timestamptz, redeemed_at timestamptz)
language plpgsql security definer
set search_path = public, auth
as $$
declare team uuid := public.current_team_id();
begin
  if team is null or not exists(select 1 from public.team_members where user_id=auth.uid() and role='admin') then
    raise exception 'Réservé à l’administrateur';
  end if;
  return query select i.player_id,i.expires_at,i.redeemed_at
    from public.team_invites i where i.team_id=team order by i.created_at desc;
end $$;

create or replace function public.admin_revoke_invite(target_player_id text)
returns void language plpgsql security definer
set search_path = public, auth
as $$
declare team uuid := public.current_team_id();
begin
  if team is null or not exists(select 1 from public.team_members where user_id=auth.uid() and role='admin') then
    raise exception 'Réservé à l’administrateur';
  end if;
  update public.team_invites set expires_at=now()
   where team_id=team and player_id=target_player_id and redeemed_at is null and expires_at>now();
end $$;

create or replace function public.join_team(invite_code text, display_name text)
returns uuid language plpgsql security definer
set search_path = public, auth, extensions
as $$
declare inv public.team_invites%rowtype;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if length(trim(display_name)) not between 1 and 60 then raise exception 'Nom invalide'; end if;
  if exists(select 1 from public.team_members where user_id=auth.uid()) then raise exception 'Ce compte est déjà lié à une équipe'; end if;
  select * into inv from public.team_invites
   where token_hash=encode(extensions.digest(invite_code,'sha256'),'hex')
     and redeemed_at is null and expires_at>now() for update;
  if not found then raise exception 'Code invalide ou expiré'; end if;
  insert into public.team_members(user_id,team_id,player_id,display_name,role)
    values(auth.uid(),inv.team_id,inv.player_id,trim(display_name),'player');
  update public.team_invites set redeemed_at=now() where token_hash=inv.token_hash;
  return inv.team_id;
end $$;

create or replace function public.save_team_state(new_state jsonb)
returns void language plpgsql security definer
set search_path = public, auth
as $$
declare
  team uuid := public.current_team_id();
  player text := public.current_player_id();
  is_admin boolean;
  old_state jsonb;
  old_routines jsonb;
  new_routines jsonb;
  old_avail jsonb;
  new_avail jsonb;
  kept_avail jsonb;
  own_avail jsonb;
  old_events jsonb;
  new_events jsonb;
  kept_events jsonb;
  own_events jsonb;
  old_notes jsonb;
  new_notes jsonb;
  notes jsonb;
  mine jsonb;
  new_mine jsonb;
  shared jsonb := '{}'::jsonb;
  field_name text;
  merged jsonb;
begin
  if team is null or player is null then raise exception 'Compte d’équipe requis'; end if;
  if jsonb_typeof(new_state) <> 'object' then raise exception 'Données invalides'; end if;
  select role='admin' into is_admin from public.team_members where user_id=auth.uid() and team_id=team;
  select state into old_state from public.team_state where team_id=team for update;
  old_state := coalesce(old_state,'{}'::jsonb);
  old_routines := coalesce(old_state->'routines','{}'::jsonb);
  new_routines := coalesce(new_state->'routines','{}'::jsonb);
  old_avail := coalesce(old_state->'availability','{}'::jsonb);
  new_avail := coalesce(new_state->'availability','{}'::jsonb);
  old_events := coalesce(old_state->'events','[]'::jsonb);
  new_events := coalesce(new_state->'events','[]'::jsonb);
  old_notes := coalesce(old_state->'playerNotes','{}'::jsonb);
  new_notes := coalesce(new_state->'playerNotes','{}'::jsonb);

  if is_admin then
    shared := new_state - 'profile' - 'routines' - 'availability' - 'events';
    notes := new_notes;
  else
    foreach field_name in array array['view','matches','roleNotes','mapNotes','mapMedia'] loop
      if new_state ? field_name then shared := shared || jsonb_build_object(field_name,new_state->field_name); end if;
    end loop;
    mine := coalesce(old_notes->public.current_player_id(),'{}'::jsonb);
    new_mine := coalesce(new_notes->public.current_player_id(),'{}'::jsonb);
    if new_mine ? 'avatarData' then mine := mine || jsonb_build_object('avatarData',new_mine->'avatarData'); end if;
    if new_mine ? 'lineups' then mine := mine || jsonb_build_object('lineups',new_mine->'lineups'); end if;
    notes := old_notes || jsonb_build_object(public.current_player_id(),mine);
  end if;

  select coalesce(jsonb_object_agg(k,v),'{}'::jsonb) into kept_avail
    from jsonb_each(old_avail) as a(k,v) where k not like player || '|%';
  select coalesce(jsonb_object_agg(k,v),'{}'::jsonb) into own_avail
    from jsonb_each(new_avail) as a(k,v) where k like player || '|%';
  select coalesce(jsonb_agg(v),'[]'::jsonb) into kept_events
    from jsonb_array_elements(old_events) as e(v) where v->>'owner' is distinct from player;
  select coalesce(jsonb_agg(v),'[]'::jsonb) into own_events
    from jsonb_array_elements(new_events) as e(v) where v->>'owner'=player;

  merged := old_state || shared ||
    jsonb_build_object(
      'profile',player,
      'playerNotes',notes,
      'routines', old_routines || case when new_routines ? player then jsonb_build_object(player,new_routines->player) else '{}'::jsonb end,
      'availability', kept_avail || own_avail,
      'events', kept_events || own_events
    );
  insert into public.team_state(team_id,state,updated_by,updated_at)
    values(team,merged,auth.uid(),now())
    on conflict(team_id) do update set state=excluded.state,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
end $$;

create or replace function public.admin_update_player(
  target_player_id text,
  new_display_name text,
  new_player_role text,
  new_avatar_path text default null
)
returns void language plpgsql security definer
set search_path = public, auth
as $$
declare team uuid := public.current_team_id();
begin
  if team is null or not exists(select 1 from public.team_members where user_id=auth.uid() and role='admin') then
    raise exception 'Réservé à l’administrateur';
  end if;
  
  if new_player_role not in ('IGL','Entry','AWPer','Support','Lurker','Rifler','Coach','Substitute') then
    raise exception 'Rôle joueur invalide';
  end if;
  update public.team_members set
    display_name=coalesce(nullif(trim(new_display_name),''),display_name),
    player_role=new_player_role,
    avatar_path=coalesce(new_avatar_path,avatar_path)
  where team_id=team and player_id=target_player_id;
  if not found then raise exception 'Membre introuvable'; end if;
end $$;

create or replace function public.update_player_integration(new_faceit_nickname text, new_steam_id64 text)
returns void language plpgsql security definer
set search_path = public, auth
as $$
declare team uuid := public.current_team_id(); player text := public.current_player_id();
begin
  if team is null or player is null then raise exception 'Compte d’équipe requis'; end if;
  if length(trim(new_faceit_nickname)) not between 2 and 60 then raise exception 'Pseudo FACEIT invalide'; end if;
  if new_steam_id64 !~ '^[0-9]{17}$' then raise exception 'SteamID64 invalide'; end if;
  insert into public.player_integrations(team_id,player_id,faceit_nickname,steam_id64,updated_at)
    values(team,player,trim(new_faceit_nickname),new_steam_id64,now())
  on conflict(team_id,player_id) do update set
    faceit_nickname=excluded.faceit_nickname,steam_id64=excluded.steam_id64,updated_at=now();
end $$;

create or replace function public.admin_set_team_api_keys(new_faceit_key text, new_leetify_key text)
returns void language plpgsql security definer
set search_path = public, auth, vault
as $$
declare team uuid := public.current_team_id(); faceit_id uuid; leetify_id uuid;
begin
  if team is null or not exists(select 1 from public.team_members where user_id=auth.uid() and role='admin') then
    raise exception 'Réservé à l’administrateur';
  end if;
  if length(trim(new_faceit_key)) < 8 or length(trim(new_leetify_key)) < 8 then
    raise exception 'Clé FACEIT ou Leetify invalide';
  end if;
  select faceit_secret_id,leetify_secret_id into faceit_id,leetify_id
    from public.team_integrations where team_id=team for update;
  if faceit_id is null then
    faceit_id := vault.create_secret(trim(new_faceit_key),'yurei_'||team||'_faceit','FACEIT app key for Yurei team');
  else
    perform vault.update_secret(faceit_id,trim(new_faceit_key),'yurei_'||team||'_faceit','FACEIT app key for Yurei team');
  end if;
  if leetify_id is null then
    leetify_id := vault.create_secret(trim(new_leetify_key),'yurei_'||team||'_leetify','Leetify app key for Yurei team');
  else
    perform vault.update_secret(leetify_id,trim(new_leetify_key),'yurei_'||team||'_leetify','Leetify app key for Yurei team');
  end if;
  insert into public.team_integrations(team_id,faceit_secret_id,leetify_secret_id,updated_at)
    values(team,faceit_id,leetify_id,now())
  on conflict(team_id) do update set faceit_secret_id=excluded.faceit_secret_id,
    leetify_secret_id=excluded.leetify_secret_id,updated_at=now();
end $$;

create or replace function public.edge_get_team_api_keys(target_team_id uuid)
returns table(faceit_api_key text,leetify_api_key text)
language sql security definer
set search_path = public, vault
as $$
  select f.decrypted_secret,l.decrypted_secret
    from public.team_integrations i
    join vault.decrypted_secrets f on f.id=i.faceit_secret_id
    join vault.decrypted_secrets l on l.id=i.leetify_secret_id
   where i.team_id=target_team_id
$$;

create or replace function public.current_integration_status()
returns boolean language plpgsql stable security definer
set search_path = public, auth
as $$
declare team uuid := public.current_team_id();
begin
  if team is null then raise exception 'Compte d’équipe requis'; end if;
  return exists(select 1 from public.team_integrations where team_id=team
    and faceit_secret_id is not null and leetify_secret_id is not null);
end $$;

alter table public.teams enable row level security;
alter table public.team_members enable row level security;
alter table public.team_state enable row level security;
alter table public.team_invites enable row level security;
alter table public.team_integrations enable row level security;
alter table public.player_integrations enable row level security;

drop policy if exists teams_read_member on public.teams;
create policy teams_read_member on public.teams for select to authenticated
  using (id=public.current_team_id());
drop policy if exists teams_admin_update on public.teams;
create policy teams_admin_update on public.teams for update to authenticated
  using (id=public.current_team_id() and exists(select 1 from public.team_members where user_id=auth.uid() and role='admin'))
  with check (id=public.current_team_id());

drop policy if exists members_read_team on public.team_members;
create policy members_read_team on public.team_members for select to authenticated
  using (team_id=public.current_team_id());
drop policy if exists members_update_self on public.team_members;
create policy members_update_self on public.team_members for update to authenticated
  using (user_id=auth.uid()) with check (user_id=auth.uid() and team_id=public.current_team_id() and player_id=public.current_player_id());

drop policy if exists state_read_team on public.team_state;
create policy state_read_team on public.team_state for select to authenticated
  using (team_id=public.current_team_id());
drop policy if exists player_integrations_read_team on public.player_integrations;
create policy player_integrations_read_team on public.player_integrations for select to authenticated
  using (team_id=public.current_team_id());
drop policy if exists team_integrations_admin_read on public.team_integrations;
create policy team_integrations_admin_read on public.team_integrations for select to authenticated
  using (team_id=public.current_team_id() and exists(select 1 from public.team_members where user_id=auth.uid() and role='admin'));

revoke all on public.teams,public.team_members,public.team_state,public.team_invites,public.team_integrations,public.player_integrations from anon,authenticated;
grant select on public.teams,public.team_members,public.team_state,public.player_integrations to authenticated;
grant select on public.team_integrations to authenticated;
grant update(display_name) on public.team_members to authenticated;
grant update(name) on public.teams to authenticated;
revoke all on function public.current_team_id() from public,anon;
revoke all on function public.current_player_id() from public,anon;
revoke all on function public.bootstrap_team(text,text,text) from public,anon;
revoke all on function public.create_team_invite(text) from public,anon;
revoke all on function public.admin_list_invites() from public,anon;
revoke all on function public.admin_revoke_invite(text) from public,anon;
revoke all on function public.join_team(text,text) from public,anon;
revoke all on function public.save_team_state(jsonb) from public,anon;
revoke all on function public.admin_update_player(text,text,text,text) from public,anon;
revoke all on function public.update_player_integration(text,text) from public,anon;
revoke all on function public.admin_set_team_api_keys(text,text) from public,anon;
revoke all on function public.edge_get_team_api_keys(uuid) from public,anon,authenticated;
revoke all on function public.current_integration_status() from public,anon;
grant execute on function public.current_team_id() to authenticated;
grant execute on function public.current_player_id() to authenticated;
grant execute on function public.bootstrap_team(text,text,text) to authenticated;
grant execute on function public.create_team_invite(text) to authenticated;
grant execute on function public.admin_list_invites() to authenticated;
grant execute on function public.admin_revoke_invite(text) to authenticated;
grant execute on function public.join_team(text,text) to authenticated;
grant execute on function public.save_team_state(jsonb) to authenticated;
grant execute on function public.admin_update_player(text,text,text,text) to authenticated;
grant execute on function public.update_player_integration(text,text) to authenticated;
grant execute on function public.admin_set_team_api_keys(text,text) to authenticated;
grant execute on function public.edge_get_team_api_keys(uuid) to service_role;
grant execute on function public.current_integration_status() to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('redline-team-media','redline-team-media',false,52428800,array['image/png','image/jpeg','image/webp','video/mp4','video/webm','video/quicktime'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists team_media_read on storage.objects;
create policy team_media_read on storage.objects for select to authenticated
  using (bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text);
drop policy if exists team_media_upload on storage.objects;
create policy team_media_upload on storage.objects for insert to authenticated
  with check (bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text);
drop policy if exists team_media_update on storage.objects;
create policy team_media_update on storage.objects for update to authenticated
  using (bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text)
  with check (bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text);
drop policy if exists team_media_delete on storage.objects;
create policy team_media_delete on storage.objects for delete to authenticated
  using (bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text);


-- Dynamic member profiles: new roster entries are created when an invited user redeems a code.
-- Replace the fixed demo roster with members created only after one-time invite redemption.
-- Safe to re-run after a partial deployment.
alter table public.team_members drop constraint if exists team_members_player_id_check;
alter table public.player_integrations drop constraint if exists player_integrations_player_id_check;
alter table public.team_invites drop constraint if exists team_invites_player_id_check;
alter table public.team_invites alter column player_id drop not null;
alter table public.team_invites add column if not exists invite_id uuid default gen_random_uuid();
alter table public.team_invites add column if not exists redeemed_by uuid references auth.users(id) on delete set null;
update public.team_invites set invite_id=gen_random_uuid() where invite_id is null;
alter table public.team_invites alter column invite_id set default gen_random_uuid();
alter table public.team_invites alter column invite_id set not null;
create unique index if not exists team_invites_invite_id_uidx on public.team_invites(invite_id);

-- Give existing members unique stable profile IDs and retain their linked game integration.
update public.player_integrations i set player_id=m.user_id::text
from public.team_members m
where i.team_id=m.team_id and i.player_id=m.player_id and m.player_id<>m.user_id::text;
with old_ids as (
  select team_id,player_id as old_id,user_id::text as new_id from public.team_members
)
update public.team_state s set state=jsonb_set(s.state,'{profile}',to_jsonb(m.new_id),true)
from old_ids m where s.team_id=m.team_id and s.state->>'profile'=m.old_id;
update public.team_members set player_id=user_id::text where player_id<>user_id::text;

-- Remove the old fixed-slot RPCs before replacing their signatures.
drop function if exists public.bootstrap_team(text,text,text);
drop function if exists public.create_team_invite(text);
drop function if exists public.admin_list_invites();
drop function if exists public.admin_revoke_invite(text);
drop function if exists public.bootstrap_team(text,text);
drop function if exists public.create_team_invite();
drop function if exists public.admin_list_invites();
drop function if exists public.admin_revoke_invite(uuid);

create function public.bootstrap_team(team_name text, display_name text)
returns uuid language plpgsql security definer
set search_path = public, auth, extensions
as $$
declare new_team uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if not exists (
    select 1 from public.bootstrap_admins
     where email=lower(auth.jwt()->>'email') and claimed_at is null
  ) then raise exception 'Adresse non autorisée pour le compte administrateur initial'; end if;
  perform pg_advisory_xact_lock(hashtext('redline:bootstrap_team'));
  if length(trim(team_name)) not between 1 and 80 or length(trim(display_name)) not between 1 and 60 then
    raise exception 'Nom d’équipe ou de joueur invalide';
  end if;
  if exists(select 1 from public.teams) then raise exception 'Une équipe existe déjà sur ce projet'; end if;
  new_team := gen_random_uuid();
  insert into public.teams(id,name,owner_id) values(new_team,trim(team_name),auth.uid());
  insert into public.team_members(user_id,team_id,player_id,display_name,role)
    values(auth.uid(),new_team,auth.uid()::text,trim(display_name),'admin');
  insert into public.team_state(team_id,state,updated_by)
    values(new_team,jsonb_build_object('profile',auth.uid()::text),auth.uid());
  update public.bootstrap_admins set claimed_at=now()
   where email=lower(auth.jwt()->>'email') and claimed_at is null;
  return new_team;
end $$;

create function public.create_team_invite()
returns table(invite_code text, expires_at timestamptz)
language plpgsql security definer
set search_path = public, auth, extensions
as $$
declare team uuid; raw_token text; expiry timestamptz;
begin
  team := public.current_team_id();
  if team is null or not exists(select 1 from public.team_members where user_id=auth.uid() and role='admin') then
    raise exception 'Réservé à l’administrateur';
  end if;
  raw_token := encode(extensions.gen_random_bytes(24),'hex');
  expiry := now() + interval '7 days';
  insert into public.team_invites(invite_id,token_hash,team_id,player_id,created_by,expires_at)
    values(gen_random_uuid(),encode(extensions.digest(raw_token,'sha256'),'hex'),team,null,auth.uid(),expiry);
  return query select raw_token,expiry;
end $$;

create function public.admin_list_invites()
returns table(invite_id uuid, player_name text, expires_at timestamptz, redeemed_at timestamptz, created_at timestamptz)
language plpgsql security definer
set search_path = public, auth
as $$
declare team uuid := public.current_team_id();
begin
  if team is null or not exists(select 1 from public.team_members where user_id=auth.uid() and role='admin') then
    raise exception 'Réservé à l’administrateur';
  end if;
  return query select i.invite_id,m.display_name,i.expires_at,i.redeemed_at,i.created_at
    from public.team_invites i
    left join public.team_members m on m.user_id=i.redeemed_by and m.team_id=i.team_id
   where i.team_id=team order by i.created_at desc;
end $$;

create function public.admin_revoke_invite(target_invite_id uuid)
returns void language plpgsql security definer
set search_path = public, auth
as $$
declare team uuid := public.current_team_id();
begin
  if team is null or not exists(select 1 from public.team_members where user_id=auth.uid() and role='admin') then
    raise exception 'Réservé à l’administrateur';
  end if;
  update public.team_invites set expires_at=now()
   where team_id=team and invite_id=target_invite_id and redeemed_at is null and expires_at>now();
end $$;

create or replace function public.join_team(invite_code text, display_name text)
returns uuid language plpgsql security definer
set search_path = public, auth, extensions
as $$
declare inv public.team_invites%rowtype;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if length(trim(display_name)) not between 1 and 60 then raise exception 'Nom invalide'; end if;
  if exists(select 1 from public.team_members where user_id=auth.uid()) then raise exception 'Ce compte est déjà lié à une équipe'; end if;
  select * into inv from public.team_invites
   where token_hash=encode(extensions.digest(invite_code,'sha256'),'hex')
     and redeemed_at is null and expires_at>now() for update;
  if not found then raise exception 'Code invalide ou expiré'; end if;
  insert into public.team_members(user_id,team_id,player_id,display_name,role)
    values(auth.uid(),inv.team_id,auth.uid()::text,trim(display_name),'player');
  update public.team_invites set redeemed_at=now(),redeemed_by=auth.uid() where token_hash=inv.token_hash;
  return inv.team_id;
end $$;

create or replace function public.admin_update_player(
  target_player_id text,
  new_display_name text,
  new_player_role text,
  new_avatar_path text default null
)
returns void language plpgsql security definer
set search_path = public, auth
as $$
declare team uuid := public.current_team_id();
begin
  if team is null or not exists(select 1 from public.team_members where user_id=auth.uid() and role='admin') then
    raise exception 'Réservé à l’administrateur';
  end if;
  if new_player_role not in ('IGL','Entry','AWPer','Support','Lurker','Rifler','Coach','Substitute') then
    raise exception 'Rôle joueur invalide';
  end if;
  update public.team_members set
    display_name=coalesce(nullif(trim(new_display_name),''),display_name),
    player_role=new_player_role,
    avatar_path=coalesce(new_avatar_path,avatar_path)
  where team_id=team and player_id=target_player_id;
  if not found then raise exception 'Membre introuvable'; end if;
end $$;

revoke all on function public.bootstrap_team(text,text) from public,anon;
revoke all on function public.create_team_invite() from public,anon;
revoke all on function public.admin_list_invites() from public,anon;
revoke all on function public.admin_revoke_invite(uuid) from public,anon;
revoke all on function public.join_team(text,text) from public,anon;
revoke all on function public.admin_update_player(text,text,text,text) from public,anon;
grant execute on function public.bootstrap_team(text,text) to authenticated;
grant execute on function public.create_team_invite() to authenticated;
grant execute on function public.admin_list_invites() to authenticated;
grant execute on function public.admin_revoke_invite(uuid) to authenticated;
grant execute on function public.join_team(text,text) to authenticated;
grant execute on function public.admin_update_player(text,text,text,text) to authenticated;