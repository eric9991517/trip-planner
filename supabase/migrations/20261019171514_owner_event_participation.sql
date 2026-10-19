create or replace function public.add_event_owner_as_member()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.event_members (
    event_id,
    user_id,
    status,
    full_name,
    passport_english_name,
    phone,
    date_of_birth
  )
  select
    new.id,
    p.id,
    'registered',
    p.full_name,
    p.passport_english_name,
    p.phone,
    p.date_of_birth
  from public.profiles p
  where p.id = new.owner_user_id
    and p.role = 'owner'
  on conflict (event_id, user_id) do update
    set status = 'registered'
    where public.event_members.status = 'cancelled';

  return new;
end;
$$;

revoke execute on function public.add_event_owner_as_member() from public, anon, authenticated;

create trigger events_add_owner_as_member
after insert on public.events
for each row execute function public.add_event_owner_as_member();

insert into public.event_members (
  event_id,
  user_id,
  status,
  full_name,
  passport_english_name,
  phone,
  date_of_birth
)
select
  e.id,
  p.id,
  'registered',
  p.full_name,
  p.passport_english_name,
  p.phone,
  p.date_of_birth
from public.events e
join public.profiles p on p.id = e.owner_user_id
where p.role = 'owner'
on conflict (event_id, user_id) do update
  set status = 'registered'
  where public.event_members.status = 'cancelled';
