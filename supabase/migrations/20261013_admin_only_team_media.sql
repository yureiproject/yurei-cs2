-- Only team administrators can add, replace, or remove lineup videos and callout images.
drop policy if exists team_media_upload on storage.objects;
create policy team_media_upload on storage.objects for insert to authenticated with check (
  bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text
  and exists(select 1 from public.team_members where user_id=auth.uid() and team_id=public.current_team_id() and role='admin'));

drop policy if exists team_media_update on storage.objects;
create policy team_media_update on storage.objects for update to authenticated using (
  bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text
  and exists(select 1 from public.team_members where user_id=auth.uid() and team_id=public.current_team_id() and role='admin'))
with check (
  bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text
  and exists(select 1 from public.team_members where user_id=auth.uid() and team_id=public.current_team_id() and role='admin'));

drop policy if exists team_media_delete on storage.objects;
create policy team_media_delete on storage.objects for delete to authenticated using (
  bucket_id='redline-team-media' and (storage.foldername(name))[1]=public.current_team_id()::text
  and exists(select 1 from public.team_members where user_id=auth.uid() and team_id=public.current_team_id() and role='admin'));

