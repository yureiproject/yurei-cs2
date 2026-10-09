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