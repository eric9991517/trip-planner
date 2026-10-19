create extension if not exists pgcrypto with schema extensions;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  passport_english_name text,
  phone text,
  age integer check (age between 0 and 120),
  role text not null default 'member' check (role in ('owner', 'admin', 'member')),
  created_at timestamptz not null default now()
);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  event_type text not null check (event_type in ('domestic', 'international')),
  destination text not null default '',
  starts_on date not null,
  ends_on date not null,
  description text not null default '',
  published boolean not null default true,
  registration_open boolean not null default true,
  insurance_enabled boolean not null default false,
  insurance_coverage integer not null default 0 check (insurance_coverage >= 0),
  insurance_premium integer not null default 0 check (insurance_premium >= 0),
  owner_user_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on),
  check (not insurance_enabled or event_type = 'international')
);

create table public.event_members (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'registered' check (status in ('registered', 'cancelled')),
  invited_by uuid references public.profiles(id),
  joined_at timestamptz not null default now(),
  passport_english_name text,
  phone text,
  age integer check (age between 0 and 120),
  insurance_opt_in boolean,
  primary key (event_id, user_id)
);

create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  token_hash text not null unique,
  created_by uuid not null references public.profiles(id),
  max_uses integer not null default 1 check (max_uses > 0),
  use_count integer not null default 0 check (use_count >= 0),
  expires_at timestamptz not null default now() + interval '30 days',
  created_at timestamptz not null default now()
);

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null,
  capacity integer not null check (capacity > 0),
  created_at timestamptz not null default now(),
  unique (event_id, name),
  unique (event_id, id)
);

create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  name text not null,
  driver_name text not null default '',
  departure text not null default '',
  seats integer not null check (seats >= 0),
  created_at timestamptz not null default now(),
  unique (event_id, name),
  unique (event_id, id)
);

create table public.room_bookings (
  event_id uuid not null,
  user_id uuid not null,
  room_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (event_id, user_id),
  foreign key (event_id, user_id) references public.event_members(event_id, user_id) on delete cascade,
  foreign key (event_id, room_id) references public.rooms(event_id, id) on delete cascade
);

create table public.vehicle_bookings (
  event_id uuid not null,
  user_id uuid not null,
  vehicle_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (event_id, user_id),
  foreign key (event_id, user_id) references public.event_members(event_id, user_id) on delete cascade,
  foreign key (event_id, vehicle_id) references public.vehicles(event_id, id) on delete cascade
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists (select 1 from public.profiles where id = auth.uid() and role in ('owner', 'admin')) $$;

create or replace function public.create_profile_for_user()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.create_profile_for_user();

create or replace function public.protect_profile_role()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if auth.uid() is not null and new.role is distinct from old.role and not exists (
    select 1 from public.profiles where id = auth.uid() and role = 'owner'
  ) then
    raise exception 'Only the owner may change account roles';
  end if;
  return new;
end;
$$;

create trigger protect_profile_role_before_update
before update on public.profiles
for each row execute procedure public.protect_profile_role();

create or replace function public.accept_invitation(p_token text)
returns uuid language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  current_user_id uuid := auth.uid();
  invite public.invitations%rowtype;
begin
  if current_user_id is null then raise exception 'Sign in before accepting an invitation'; end if;
  select * into invite from public.invitations
  where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
  for update;
  if not found then raise exception 'Invitation is invalid or expired'; end if;
  if invite.expires_at < now() then raise exception 'Invitation is invalid or expired'; end if;
  if not exists (select 1 from public.events where id = invite.event_id and published and registration_open) then raise exception 'Registration is closed'; end if;
  if exists (select 1 from public.event_members where event_id = invite.event_id and user_id = current_user_id) then
    return invite.event_id;
  end if;
  if invite.use_count >= invite.max_uses then raise exception 'Invitation has already been used'; end if;
  insert into public.event_members (event_id, user_id, invited_by)
  values (invite.event_id, current_user_id, invite.created_by);
  update public.invitations set use_count = use_count + 1 where id = invite.id;
  return invite.event_id;
end;
$$;

create or replace function public.create_invitation(p_event_id uuid, p_max_uses integer default 1)
returns text language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  raw_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_max_uses < 1 or p_max_uses > 100 then raise exception 'Invalid invitation use limit'; end if;
  insert into public.invitations (event_id, token_hash, created_by, max_uses)
  values (p_event_id, encode(extensions.digest(raw_token, 'sha256'), 'hex'), auth.uid(), p_max_uses);
  return raw_token;
end;
$$;

create or replace function public.choose_room(p_event_id uuid, p_room_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  capacity_count integer;
  occupied_count integer;
begin
  if auth.uid() is null or not exists (select 1 from public.event_members where event_id = p_event_id and user_id = auth.uid() and status = 'registered') then raise exception 'An active invitation is required'; end if;
  if not exists (select 1 from public.events where id = p_event_id and registration_open) then raise exception 'Registration is closed'; end if;
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
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  seat_count integer;
  occupied_count integer;
begin
  if auth.uid() is null or not exists (select 1 from public.event_members where event_id = p_event_id and user_id = auth.uid() and status = 'registered') then raise exception 'An active invitation is required'; end if;
  if not exists (select 1 from public.events where id = p_event_id and registration_open) then raise exception 'Registration is closed'; end if;
  select seats into seat_count from public.vehicles where event_id = p_event_id and id = p_vehicle_id for update;
  if seat_count is null then raise exception 'Vehicle not found'; end if;
  if exists (select 1 from public.vehicle_bookings where event_id = p_event_id and user_id = auth.uid() and vehicle_id = p_vehicle_id) then return; end if;
  select count(*) into occupied_count from public.vehicle_bookings where event_id = p_event_id and vehicle_id = p_vehicle_id;
  if occupied_count >= seat_count then raise exception 'Vehicle is full'; end if;
  insert into public.vehicle_bookings (event_id, user_id, vehicle_id) values (p_event_id, auth.uid(), p_vehicle_id)
  on conflict (event_id, user_id) do update set vehicle_id = excluded.vehicle_id, created_at = now();
end;
$$;

create or replace function public.update_my_event_details(p_event_id uuid, p_passport_english_name text, p_phone text, p_age integer, p_insurance_opt_in boolean)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from public.event_members where event_id = p_event_id and user_id = auth.uid() and status = 'registered') then raise exception 'An active invitation is required'; end if;
  if p_age is not null and p_age not between 0 and 120 then raise exception 'Invalid age'; end if;
  if exists (select 1 from public.events where id = p_event_id and event_type = 'international' and registration_open) and coalesce(trim(p_passport_english_name), '') = '' then raise exception 'Passport English name is required'; end if;
  update public.event_members set passport_english_name = p_passport_english_name, phone = p_phone, age = p_age, insurance_opt_in = case when exists (select 1 from public.events where id = p_event_id and insurance_enabled) then p_insurance_opt_in else null end where event_id = p_event_id and user_id = auth.uid();
end;
$$;

create or replace function public.resource_roster(p_event_id uuid)
returns table (resource_type text, resource_id uuid, resource_name text, user_id uuid, full_name text)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() and not exists (select 1 from public.event_members where event_id = p_event_id and user_id = auth.uid() and status = 'registered') then raise exception 'An active invitation is required'; end if;
  return query
  select 'room'::text, r.id, r.name, b.user_id, p.full_name from public.room_bookings b join public.rooms r on r.event_id = b.event_id and r.id = b.room_id join public.profiles p on p.id = b.user_id where b.event_id = p_event_id
  union all
  select 'vehicle'::text, v.id, v.name, b.user_id, p.full_name from public.vehicle_bookings b join public.vehicles v on v.event_id = b.event_id and v.id = b.vehicle_id join public.profiles p on p.id = b.user_id where b.event_id = p_event_id;
end;
$$;

create or replace function public.set_user_role(p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'owner') then raise exception 'Only the owner may manage administrators'; end if;
  if p_role not in ('member', 'admin') then raise exception 'Invalid role'; end if;
  update public.profiles set role = p_role where id = p_user_id;
  if not found then raise exception 'User not found'; end if;
end;
$$;

create or replace function public.prevent_capacity_below_occupancy()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  occupied integer;
begin
  if tg_table_name = 'rooms' then
    select count(*) into occupied from public.room_bookings where room_id = new.id;
    if new.capacity < occupied then raise exception 'Capacity cannot be lower than current bookings'; end if;
  else
    select count(*) into occupied from public.vehicle_bookings where vehicle_id = new.id;
    if new.seats < occupied then raise exception 'Capacity cannot be lower than current bookings'; end if;
  end if;
  return new;
end;
$$;

create trigger rooms_capacity_guard before update of capacity on public.rooms
for each row execute procedure public.prevent_capacity_below_occupancy();
create trigger vehicles_capacity_guard before update of seats on public.vehicles
for each row execute procedure public.prevent_capacity_below_occupancy();

alter table public.profiles enable row level security;
alter table public.events enable row level security;
alter table public.event_members enable row level security;
alter table public.invitations enable row level security;
alter table public.rooms enable row level security;
alter table public.vehicles enable row level security;
alter table public.room_bookings enable row level security;
alter table public.vehicle_bookings enable row level security;

create policy "profiles_read_self_or_admin" on public.profiles for select to authenticated using (id = auth.uid() or public.is_admin());
create policy "profiles_update_self_or_admin" on public.profiles for update to authenticated using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());
create policy "events_read_published_or_admin" on public.events for select to authenticated using (published or public.is_admin());
create policy "events_admin_insert" on public.events for insert to authenticated with check (public.is_admin() and owner_user_id = auth.uid());
create policy "events_admin_update" on public.events for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "events_admin_delete" on public.events for delete to authenticated using (public.is_admin());
create policy "members_read_self_or_admin" on public.event_members for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "rooms_read_members_or_admin" on public.rooms for select to authenticated using (public.is_admin() or exists (select 1 from public.event_members m where m.event_id = rooms.event_id and m.user_id = auth.uid() and m.status = 'registered'));
create policy "rooms_admin_insert" on public.rooms for insert to authenticated with check (public.is_admin());
create policy "rooms_admin_update" on public.rooms for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "rooms_admin_delete" on public.rooms for delete to authenticated using (public.is_admin());
create policy "vehicles_read_members_or_admin" on public.vehicles for select to authenticated using (public.is_admin() or exists (select 1 from public.event_members m where m.event_id = vehicles.event_id and m.user_id = auth.uid() and m.status = 'registered'));
create policy "vehicles_admin_insert" on public.vehicles for insert to authenticated with check (public.is_admin());
create policy "vehicles_admin_update" on public.vehicles for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "vehicles_admin_delete" on public.vehicles for delete to authenticated using (public.is_admin());
create policy "room_bookings_read_event_members" on public.room_bookings for select to authenticated using (public.is_admin() or exists (select 1 from public.event_members m where m.event_id = room_bookings.event_id and m.user_id = auth.uid() and m.status = 'registered'));
create policy "vehicle_bookings_read_event_members" on public.vehicle_bookings for select to authenticated using (public.is_admin() or exists (select 1 from public.event_members m where m.event_id = vehicle_bookings.event_id and m.user_id = auth.uid() and m.status = 'registered'));

revoke all on public.invitations from anon, authenticated;
revoke all on public.invitations from public;
revoke all on public.event_members, public.room_bookings, public.vehicle_bookings from public, anon, authenticated;
grant select, update on public.profiles to authenticated;
revoke all on public.profiles, public.events, public.rooms, public.vehicles from public, anon;
grant select, insert, update, delete on public.events, public.rooms, public.vehicles to authenticated;
grant select on public.event_members, public.room_bookings, public.vehicle_bookings to authenticated;
grant execute on function public.accept_invitation(text), public.create_invitation(uuid, integer), public.choose_room(uuid, uuid), public.choose_vehicle(uuid, uuid), public.update_my_event_details(uuid, text, text, integer, boolean), public.resource_roster(uuid), public.set_user_role(uuid, text) to authenticated;
revoke execute on function public.accept_invitation(text), public.create_invitation(uuid, integer), public.choose_room(uuid, uuid), public.choose_vehicle(uuid, uuid), public.update_my_event_details(uuid, text, text, integer, boolean), public.resource_roster(uuid), public.set_user_role(uuid, text) from public, anon;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;
