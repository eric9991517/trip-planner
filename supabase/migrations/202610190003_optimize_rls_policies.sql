drop policy if exists profiles_read_self_or_admin on public.profiles;
create policy profiles_read_self_or_admin on public.profiles for select to authenticated
using (id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists profiles_update_self_or_admin on public.profiles;
create policy profiles_update_self_or_admin on public.profiles for update to authenticated
using (id = (select auth.uid()) or (select public.is_admin()))
with check (id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists events_read_published_or_admin on public.events;
create policy events_read_published_or_admin on public.events for select to authenticated
using (published or (select public.is_admin()));

drop policy if exists events_admin_insert on public.events;
create policy events_admin_insert on public.events for insert to authenticated
with check ((select public.is_admin()) and owner_user_id = (select auth.uid()));

drop policy if exists events_admin_update on public.events;
create policy events_admin_update on public.events for update to authenticated
using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists events_admin_delete on public.events;
create policy events_admin_delete on public.events for delete to authenticated
using ((select public.is_admin()));

drop policy if exists members_read_self_or_admin on public.event_members;
create policy members_read_self_or_admin on public.event_members for select to authenticated
using (user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists rooms_read_members_or_admin on public.rooms;
create policy rooms_read_members_or_admin on public.rooms for select to authenticated
using ((select public.is_admin()) or exists (
  select 1 from public.event_members m
  where m.event_id = rooms.event_id and m.user_id = (select auth.uid()) and m.status = 'registered'
));

drop policy if exists rooms_admin_insert on public.rooms;
create policy rooms_admin_insert on public.rooms for insert to authenticated
with check ((select public.is_admin()));

drop policy if exists rooms_admin_update on public.rooms;
create policy rooms_admin_update on public.rooms for update to authenticated
using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists rooms_admin_delete on public.rooms;
create policy rooms_admin_delete on public.rooms for delete to authenticated
using ((select public.is_admin()));

drop policy if exists vehicles_read_members_or_admin on public.vehicles;
create policy vehicles_read_members_or_admin on public.vehicles for select to authenticated
using ((select public.is_admin()) or exists (
  select 1 from public.event_members m
  where m.event_id = vehicles.event_id and m.user_id = (select auth.uid()) and m.status = 'registered'
));

drop policy if exists vehicles_admin_insert on public.vehicles;
create policy vehicles_admin_insert on public.vehicles for insert to authenticated
with check ((select public.is_admin()));

drop policy if exists vehicles_admin_update on public.vehicles;
create policy vehicles_admin_update on public.vehicles for update to authenticated
using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists vehicles_admin_delete on public.vehicles;
create policy vehicles_admin_delete on public.vehicles for delete to authenticated
using ((select public.is_admin()));

drop policy if exists room_bookings_read_event_members on public.room_bookings;
create policy room_bookings_read_event_members on public.room_bookings for select to authenticated
using ((select public.is_admin()) or exists (
  select 1 from public.event_members m
  where m.event_id = room_bookings.event_id and m.user_id = (select auth.uid()) and m.status = 'registered'
));

drop policy if exists vehicle_bookings_read_event_members on public.vehicle_bookings;
create policy vehicle_bookings_read_event_members on public.vehicle_bookings for select to authenticated
using ((select public.is_admin()) or exists (
  select 1 from public.event_members m
  where m.event_id = vehicle_bookings.event_id and m.user_id = (select auth.uid()) and m.status = 'registered'
));
