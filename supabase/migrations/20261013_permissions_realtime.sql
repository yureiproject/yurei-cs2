-- Yurei permissions and role cleanup. Apply once in Supabase SQL Editor.
alter table public.team_members add column if not exists can_create_events boolean not null default false;
alter table public.team_members alter column player_role set default 'Entry';

update public.team_members set player_role = case
  when lower(player_role) in ('igl') then 'IGL'
  when lower(player_role) in ('support') then 'Support'
  when lower(player_role) in ('lurker') then 'Lurker'
  when lower(player_role) in ('awper','awp') then 'AWPer'
  else 'Entry' end
where player_role not in ('IGL','Support','Lurker','AWPer','Entry');
alter table public.team_members drop constraint if exists team_members_player_role_check;
alter table public.team_members add constraint team_members_player_role_check
  check (player_role in ('IGL','Support','Lurker','AWPer','Entry'));

create or replace function public.admin_set_event_permission(target_user_id uuid, allow_create boolean)
returns void language plpgsql security definer set search_path=public,auth as $$
declare team uuid := public.current_team_id();
begin
  if team is null or not exists(select 1 from public.team_members where user_id=auth.uid() and team_id=team and role='admin') then
    raise exception 'Réservé à l’administrateur';
  end if;
  if not exists(select 1 from public.team_members where user_id=target_user_id and team_id=team and role='player') then
    raise exception 'Joueur introuvable';
  end if;
  update public.team_members set can_create_events=allow_create where user_id=target_user_id and team_id=team;
end $$;
revoke all on function public.admin_set_event_permission(uuid,boolean) from public,anon;
grant execute on function public.admin_set_event_permission(uuid,boolean) to authenticated;

create or replace function public.save_team_state(new_state jsonb)
returns void language plpgsql security definer set search_path=public,auth as $$
declare
  team uuid := public.current_team_id(); player text := public.current_player_id();
  is_admin boolean; can_manage_events boolean; old_state jsonb; old_routines jsonb; new_routines jsonb; old_routine_order jsonb; new_routine_order jsonb;
  old_avail jsonb; new_avail jsonb; kept_avail jsonb; own_avail jsonb;
  old_events jsonb; new_events jsonb; kept_events jsonb; own_events jsonb;
  old_notes jsonb; new_notes jsonb; notes jsonb; mine jsonb; new_mine jsonb;
  shared jsonb := '{}'::jsonb; field_name text; merged jsonb; event_item jsonb;
begin
  if team is null or player is null then raise exception 'Compte d’équipe requis'; end if;
  if jsonb_typeof(new_state) <> 'object' then raise exception 'Données invalides'; end if;
  select role='admin', role='admin' or can_create_events into is_admin,can_manage_events
    from public.team_members where user_id=auth.uid() and team_id=team;
  select state into old_state from public.team_state where team_id=team for update;
  old_state := coalesce(old_state,'{}'::jsonb);
  old_routines := coalesce(old_state->'routines','{}'::jsonb); new_routines := coalesce(new_state->'routines','{}'::jsonb);
  old_routine_order := coalesce(old_state->'routineOrder','{}'::jsonb); new_routine_order := coalesce(new_state->'routineOrder','{}'::jsonb);
  old_avail := coalesce(old_state->'availability','{}'::jsonb); new_avail := coalesce(new_state->'availability','{}'::jsonb);
  old_events := coalesce(old_state->'events','[]'::jsonb); new_events := coalesce(new_state->'events','[]'::jsonb);
  old_notes := coalesce(old_state->'playerNotes','{}'::jsonb); new_notes := coalesce(new_state->'playerNotes','{}'::jsonb);

  if is_admin then
    shared := new_state - 'profile' - 'routines' - 'routineOrder' - 'availability' - 'events'; notes := new_notes;
  else
    foreach field_name in array array['view','matches','roleNotes'] loop
      if new_state ? field_name then shared := shared || jsonb_build_object(field_name,new_state->field_name); end if;
    end loop;
    shared := shared || jsonb_build_object('mapNotes',coalesce(old_state->'mapNotes','{}'::jsonb),
                                           'mapMedia',coalesce(old_state->'mapMedia','{}'::jsonb));
    mine := coalesce(old_notes->public.current_player_id(),'{}'::jsonb); new_mine := coalesce(new_notes->public.current_player_id(),'{}'::jsonb);
    if new_mine ? 'avatarData' then mine := mine || jsonb_build_object('avatarData',new_mine->'avatarData'); end if;
    notes := old_notes || jsonb_build_object(public.current_player_id(),mine);
  end if;

  if not can_manage_events then
    for event_item in select value from jsonb_array_elements(new_events) loop
      if event_item->>'owner'=player and not exists(
        select 1 from jsonb_array_elements(old_events) prior(value) where prior.value->>'id'=event_item->>'id' and prior.value->>'owner'=player
      ) then raise exception 'Tu n’as pas la permission de créer un événement'; end if;
    end loop;
  end if;

  select coalesce(jsonb_object_agg(k,v),'{}'::jsonb) into kept_avail from jsonb_each(old_avail) a(k,v) where k not like player || '|%';
  select coalesce(jsonb_object_agg(k,v),'{}'::jsonb) into own_avail from jsonb_each(new_avail) a(k,v) where k like player || '|%';
  select coalesce(jsonb_agg(v),'[]'::jsonb) into kept_events from jsonb_array_elements(old_events) e(v) where v->>'owner' is distinct from player;
  select coalesce(jsonb_agg(v),'[]'::jsonb) into own_events from jsonb_array_elements(new_events) e(v) where v->>'owner'=player;
  merged := old_state || shared || jsonb_build_object('profile',player,'playerNotes',notes,
    'routines',old_routines || case when new_routines ? player then jsonb_build_object(player,new_routines->player) else '{}'::jsonb end,
    'routineOrder',old_routine_order || case when new_routine_order ? player then jsonb_build_object(player,new_routine_order->player) else '{}'::jsonb end,
    'availability',kept_avail || own_avail,'events',kept_events || own_events);
  insert into public.team_state(team_id,state,updated_by,updated_at) values(team,merged,auth.uid(),now())
    on conflict(team_id) do update set state=excluded.state,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
end $$;
revoke all on function public.save_team_state(jsonb) from public,anon;
grant execute on function public.save_team_state(jsonb) to authenticated;

-- Only team admins may add, replace, or remove shared lineup/callout media.
drop policy if exists team_media_upload on storage.objects;
create policy team_media_upload on storage.objects for insert to authenticated with check (
  bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text
  and exists(select 1 from public.team_members where user_id=auth.uid() and team_id=public.current_team_id() and role='admin'));
drop policy if exists team_media_update on storage.objects;
create policy team_media_update on storage.objects for update to authenticated using (
  bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text
  and exists(select 1 from public.team_members where user_id=auth.uid() and team_id=public.current_team_id() and role='admin'))
with check (bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text
  and exists(select 1 from public.team_members where user_id=auth.uid() and team_id=public.current_team_id() and role='admin'));
drop policy if exists team_media_delete on storage.objects;
create policy team_media_delete on storage.objects for delete to authenticated using (
  bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text
  and exists(select 1 from public.team_members where user_id=auth.uid() and team_id=public.current_team_id() and role='admin'));

-- Enable team_state updates for Supabase Realtime where publication configuration permits it.
do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='team_state') then
    alter publication supabase_realtime add table public.team_state;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='team_members') then
    alter publication supabase_realtime add table public.team_members;
  end if;
exception when undefined_object or insufficient_privilege then null;
end $$;
