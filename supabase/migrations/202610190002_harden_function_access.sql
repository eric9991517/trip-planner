create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.is_admin()
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select auth.uid() is not null and exists (select 1 from public.profiles where id = auth.uid() and role in ('owner', 'admin')) $$;

revoke all on function private.is_admin() from public, anon;
grant execute on function private.is_admin() to authenticated;

create or replace function public.is_admin()
returns boolean language sql stable security invoker set search_path = private, pg_temp
as $$ select private.is_admin() $$;

revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

revoke execute on function public.create_profile_for_user(), public.protect_profile_role(), public.prevent_capacity_below_occupancy() from public, anon, authenticated;

create index if not exists event_members_user_id_idx on public.event_members (user_id);
create index if not exists event_members_invited_by_idx on public.event_members (invited_by);
create index if not exists events_owner_user_id_idx on public.events (owner_user_id);
create index if not exists invitations_event_id_idx on public.invitations (event_id);
create index if not exists invitations_created_by_idx on public.invitations (created_by);
create index if not exists room_bookings_event_room_idx on public.room_bookings (event_id, room_id);
create index if not exists vehicle_bookings_event_vehicle_idx on public.vehicle_bookings (event_id, vehicle_id);
