alter table public.events
  add column if not exists resource_selection_open boolean not null default false;

alter table public.event_members
  add column if not exists attendance_status text not null default 'pending'
  check (attendance_status in ('pending', 'attending', 'not_attending'));

update public.event_members m
set attendance_status = 'attending'
where exists (
  select 1 from public.room_bookings b
  where b.event_id = m.event_id and b.user_id = m.user_id
) or exists (
  select 1 from public.vehicle_bookings b
  where b.event_id = m.event_id and b.user_id = m.user_id
);

create or replace function public.respond_to_event(p_event_id uuid, p_attending boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Sign in before responding'; end if;
  if not exists (
    select 1 from public.event_members
    where event_id = p_event_id and user_id = auth.uid() and status = 'registered'
  ) then raise exception 'An active invitation is required'; end if;
  if not exists (
    select 1 from public.events where id = p_event_id and registration_open
  ) then raise exception 'Registration is closed'; end if;

  update public.event_members
  set attendance_status = case when p_attending then 'attending' else 'not_attending' end
  where event_id = p_event_id and user_id = auth.uid();

  if not p_attending then
    delete from public.room_bookings where event_id = p_event_id and user_id = auth.uid();
    delete from public.vehicle_bookings where event_id = p_event_id and user_id = auth.uid();
  end if;
end;
$$;

create or replace function public.choose_room(p_event_id uuid, p_room_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  capacity_count integer;
  occupied_count integer;
begin
  if auth.uid() is null or not exists (
    select 1 from public.event_members
    where event_id = p_event_id and user_id = auth.uid() and status = 'registered' and attendance_status = 'attending'
  ) then raise exception 'An attending invitee is required'; end if;
  if not exists (
    select 1 from public.events where id = p_event_id and registration_open and resource_selection_open
  ) then raise exception 'Room selection is not open'; end if;

  select capacity into capacity_count from public.rooms where event_id = p_event_id and id = p_room_id for update;
  if capacity_count is null then raise exception 'Room not found'; end if;
  if exists (select 1 from public.room_bookings where event_id = p_event_id and user_id = auth.uid() and room_id = p_room_id) then return; end if;
  select count(*) into occupied_count from public.room_bookings where event_id = p_event_id and room_id = p_room_id;
  if occupied_count >= capacity_count then raise exception 'Room is full'; end if;
  insert into public.room_bookings (event_id, user_id, room_id) values (p_event_id, auth.uid(), p_room_id)
  on conflict (event_id, user_id) do update set room_id = excluded.room_id, created_at = now();
end;
$$;

create or replace function public.choose_vehicle(p_event_id uuid, p_vehicle_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  seat_count integer;
  occupied_count integer;
begin
  if auth.uid() is null or not exists (
    select 1 from public.event_members
    where event_id = p_event_id and user_id = auth.uid() and status = 'registered' and attendance_status = 'attending'
  ) then raise exception 'An attending invitee is required'; end if;
  if not exists (
    select 1 from public.events where id = p_event_id and registration_open and resource_selection_open
  ) then raise exception 'Vehicle selection is not open'; end if;

  select seats into seat_count from public.vehicles where event_id = p_event_id and id = p_vehicle_id for update;
  if seat_count is null then raise exception 'Vehicle not found'; end if;
  if exists (select 1 from public.vehicle_bookings where event_id = p_event_id and user_id = auth.uid() and vehicle_id = p_vehicle_id) then return; end if;
  select count(*) into occupied_count from public.vehicle_bookings where event_id = p_event_id and vehicle_id = p_vehicle_id;
  if occupied_count >= seat_count then raise exception 'Vehicle is full'; end if;
  insert into public.vehicle_bookings (event_id, user_id, vehicle_id) values (p_event_id, auth.uid(), p_vehicle_id)
  on conflict (event_id, user_id) do update set vehicle_id = excluded.vehicle_id, created_at = now();
end;
$$;

create or replace function public.resource_roster(p_event_id uuid)
returns table (resource_type text, resource_id uuid, resource_name text, user_id uuid, full_name text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_admin() and not exists (
    select 1 from public.event_members m join public.events e on e.id = m.event_id
    where m.event_id = p_event_id and m.user_id = auth.uid() and m.status = 'registered'
      and m.attendance_status = 'attending' and e.resource_selection_open
  ) then raise exception 'Resource selection is not open to this user'; end if;
  return query
  select 'room'::text, r.id, r.name, b.user_id, p.full_name
  from public.room_bookings b
  join public.rooms r on r.event_id = b.event_id and r.id = b.room_id
  join public.profiles p on p.id = b.user_id
  where b.event_id = p_event_id
  union all
  select 'vehicle'::text, v.id, v.name, b.user_id, p.full_name
  from public.vehicle_bookings b
  join public.vehicles v on v.event_id = b.event_id and v.id = b.vehicle_id
  join public.profiles p on p.id = b.user_id
  where b.event_id = p_event_id;
end;
$$;

drop policy if exists rooms_read_members_or_admin on public.rooms;
create policy rooms_read_members_or_admin on public.rooms for select to authenticated
using ((select public.is_admin()) or exists (
  select 1 from public.event_members m join public.events e on e.id = m.event_id
  where m.event_id = rooms.event_id and m.user_id = (select auth.uid())
    and m.status = 'registered' and m.attendance_status = 'attending' and e.resource_selection_open
));

drop policy if exists vehicles_read_members_or_admin on public.vehicles;
create policy vehicles_read_members_or_admin on public.vehicles for select to authenticated
using ((select public.is_admin()) or exists (
  select 1 from public.event_members m join public.events e on e.id = m.event_id
  where m.event_id = vehicles.event_id and m.user_id = (select auth.uid())
    and m.status = 'registered' and m.attendance_status = 'attending' and e.resource_selection_open
));

drop policy if exists room_bookings_read_event_members on public.room_bookings;
create policy room_bookings_read_event_members on public.room_bookings for select to authenticated
using ((select public.is_admin()) or exists (
  select 1 from public.event_members m join public.events e on e.id = m.event_id
  where m.event_id = room_bookings.event_id and m.user_id = (select auth.uid())
    and m.status = 'registered' and m.attendance_status = 'attending' and e.resource_selection_open
));

drop policy if exists vehicle_bookings_read_event_members on public.vehicle_bookings;
create policy vehicle_bookings_read_event_members on public.vehicle_bookings for select to authenticated
using ((select public.is_admin()) or exists (
  select 1 from public.event_members m join public.events e on e.id = m.event_id
  where m.event_id = vehicle_bookings.event_id and m.user_id = (select auth.uid())
    and m.status = 'registered' and m.attendance_status = 'attending' and e.resource_selection_open
));

grant execute on function public.respond_to_event(uuid, boolean) to authenticated;
revoke execute on function public.respond_to_event(uuid, boolean) from public, anon;
