create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create or replace function private.event_registration_details(p_event_id uuid)
returns table (
  user_id uuid,
  full_name text,
  passport_english_name text,
  phone text,
  date_of_birth date,
  email text,
  attendance_status text,
  room_name text,
  vehicle_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Sign in before viewing registration details'; end if;
  if not exists (
    select 1
    from public.events e
    join public.profiles actor on actor.id = auth.uid()
    where e.id = p_event_id
      and (actor.role = 'admin' or (actor.role = 'owner' and e.owner_user_id = auth.uid()))
  ) then raise exception 'Only the event owner or an admin may view registration details'; end if;

  return query
  select
    m.user_id,
    coalesce(nullif(trim(m.full_name), ''), p.full_name),
    coalesce(nullif(trim(m.passport_english_name), ''), p.passport_english_name),
    coalesce(nullif(trim(m.phone), ''), p.phone),
    coalesce(m.date_of_birth, p.date_of_birth),
    u.email::text,
    m.attendance_status,
    r.name,
    v.name
  from public.event_members m
  join public.profiles p on p.id = m.user_id
  join auth.users u on u.id = m.user_id
  left join public.room_bookings rb on rb.event_id = m.event_id and rb.user_id = m.user_id
  left join public.rooms r on r.event_id = rb.event_id and r.id = rb.room_id
  left join public.vehicle_bookings vb on vb.event_id = m.event_id and vb.user_id = m.user_id
  left join public.vehicles v on v.event_id = vb.event_id and v.id = vb.vehicle_id
  where m.event_id = p_event_id and m.status = 'registered'
  order by coalesce(nullif(trim(m.full_name), ''), p.full_name), u.email;
end;
$$;

revoke all on function private.event_registration_details(uuid) from public, anon;
grant execute on function private.event_registration_details(uuid) to authenticated;

create or replace function public.event_registration_details(p_event_id uuid)
returns table (
  user_id uuid,
  full_name text,
  passport_english_name text,
  phone text,
  date_of_birth date,
  email text,
  attendance_status text,
  room_name text,
  vehicle_name text
)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.event_registration_details(p_event_id);
$$;

revoke execute on function public.event_registration_details(uuid) from public, anon, authenticated;
grant execute on function public.event_registration_details(uuid) to authenticated;
