create table if not exists public.team_polls (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  question text not null check (char_length(btrim(question)) between 1 and 240),
  closes_at timestamptz not null,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (id, team_id)
);
create table if not exists public.team_poll_votes (
  poll_id uuid not null,
  team_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  player_id text not null,
  choice text not null check (choice in ('yes','no')),
  updated_at timestamptz not null default now(),
  primary key (poll_id, user_id),
  foreign key (poll_id, team_id) references public.team_polls(id, team_id) on delete cascade
);
create index if not exists team_polls_team_created_idx on public.team_polls(team_id, created_at desc);
create index if not exists team_poll_votes_team_poll_idx on public.team_poll_votes(team_id, poll_id);
alter table public.team_polls enable row level security;
alter table public.team_poll_votes enable row level security;
revoke all on public.team_polls, public.team_poll_votes from anon, authenticated;
grant select, insert on public.team_polls to authenticated;
grant select, insert, update on public.team_poll_votes to authenticated;
drop policy if exists team_polls_read on public.team_polls;
create policy team_polls_read on public.team_polls for select to authenticated
  using (team_id = public.current_team_id());
drop policy if exists team_polls_admin_create on public.team_polls;
create policy team_polls_admin_create on public.team_polls for insert to authenticated
  with check (team_id = public.current_team_id() and created_by = auth.uid()
    and closes_at > now()
    and exists(select 1 from public.team_members where user_id=auth.uid() and team_id=team_polls.team_id and role='admin'));
drop policy if exists team_poll_votes_read on public.team_poll_votes;
create policy team_poll_votes_read on public.team_poll_votes for select to authenticated
  using (team_id = public.current_team_id());
drop policy if exists team_poll_votes_insert_own on public.team_poll_votes;
create policy team_poll_votes_insert_own on public.team_poll_votes for insert to authenticated
  with check (team_id = public.current_team_id() and user_id = auth.uid()
    and player_id = public.current_player_id()
    and exists(select 1 from public.team_polls p where p.id=poll_id and p.team_id=team_poll_votes.team_id and p.closes_at>now()));
drop policy if exists team_poll_votes_update_own on public.team_poll_votes;
create policy team_poll_votes_update_own on public.team_poll_votes for update to authenticated
  using (team_id = public.current_team_id() and user_id = auth.uid()
    and exists(select 1 from public.team_polls p where p.id=poll_id and p.team_id=team_poll_votes.team_id and p.closes_at>now()))
  with check (team_id = public.current_team_id() and user_id = auth.uid()
    and player_id = public.current_player_id()
    and exists(select 1 from public.team_polls p where p.id=poll_id and p.team_id=team_poll_votes.team_id and p.closes_at>now()));
do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='team_polls') then
    alter publication supabase_realtime add table public.team_polls;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='team_poll_votes') then
    alter publication supabase_realtime add table public.team_poll_votes;
  end if;
exception when undefined_object or insufficient_privilege then null;
end $$;
