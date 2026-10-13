-- Allow each admin-created poll to define its own answer choices.
-- Existing polls keep the familiar Yes/No options and previous votes remain valid.
alter table public.team_polls
  add column if not exists options jsonb not null
  default '[{"value":"yes","label":"Oui"},{"value":"no","label":"Non"}]'::jsonb;

do $$ begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.team_polls'::regclass and conname='team_polls_options_count_check'
  ) then
    alter table public.team_polls add constraint team_polls_options_count_check
      check (jsonb_typeof(options)='array' and jsonb_array_length(options) between 2 and 6);
  end if;
end $$;

-- The previous release restricted votes to yes/no. Poll options now determine valid votes.
alter table public.team_poll_votes drop constraint if exists team_poll_votes_choice_check;

create or replace function public.validate_team_poll_vote_choice()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  poll_options jsonb;
  poll_closes_at timestamptz;
begin
  select p.options,p.closes_at into poll_options,poll_closes_at
    from public.team_polls p
   where p.id=new.poll_id and p.team_id=new.team_id;
  if not found then raise exception 'Sondage introuvable'; end if;
  if poll_closes_at<=now() then raise exception 'Ce sondage est terminé'; end if;
  if not exists (
    select 1 from jsonb_array_elements(poll_options) option
     where option->>'value'=new.choice
       and char_length(btrim(coalesce(option->>'label',''))) between 1 and 40
  ) then raise exception 'Réponse invalide pour ce sondage'; end if;
  new.updated_at=now();
  return new;
end $$;
revoke all on function public.validate_team_poll_vote_choice() from public,anon,authenticated;

drop trigger if exists team_poll_vote_choice_validation on public.team_poll_votes;
create trigger team_poll_vote_choice_validation
before insert or update of choice, poll_id, team_id on public.team_poll_votes
for each row execute function public.validate_team_poll_vote_choice();
