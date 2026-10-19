alter table public.profiles
  add column if not exists date_of_birth date;

alter table public.event_members
  add column if not exists full_name text,
  add column if not exists date_of_birth date,
  add column if not exists details_locked_at timestamptz;

update public.event_members m
set full_name = p.full_name,
    date_of_birth = p.date_of_birth
from public.profiles p
where p.id = m.user_id
  and (m.full_name is null or m.date_of_birth is null);

update public.event_members
set details_locked_at = coalesce(joined_at, now())
where attendance_status = 'attending'
  and nullif(trim(full_name), '') is not null
  and date_of_birth is not null
  and nullif(trim(phone), '') is not null;

drop function public.update_my_event_details(uuid, text, text, integer, boolean);

create function public.update_my_event_details(
  p_event_id uuid,
  p_full_name text,
  p_date_of_birth date,
  p_passport_english_name text,
  p_phone text,
  p_insurance_opt_in boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  member_lock timestamptz;
begin
  if auth.uid() is null then raise exception 'Sign in before updating registration details'; end if;
  select details_locked_at into member_lock
  from public.event_members
  where event_id = p_event_id and user_id = auth.uid() and status = 'registered'
  for update;
  if not found then raise exception 'An active invitation is required'; end if;
  if member_lock is not null then raise exception 'Registration details are locked'; end if;
  if nullif(trim(p_full_name), '') is null then raise exception 'Full name is required'; end if;
  if p_date_of_birth is null or p_date_of_birth > current_date then raise exception 'A valid date of birth is required'; end if;
  if nullif(trim(p_phone), '') is null then raise exception 'Phone number is required'; end if;
  if exists (
    select 1 from public.events
    where id = p_event_id and event_type = 'international' and registration_open
  ) and nullif(trim(p_passport_english_name), '') is null then
    raise exception 'Passport English name is required';
  end if;

  update public.profiles
  set full_name = trim(p_full_name),
      date_of_birth = p_date_of_birth,
      passport_english_name = nullif(trim(p_passport_english_name), ''),
      phone = trim(p_phone)
  where id = auth.uid();

  update public.event_members
  set full_name = trim(p_full_name),
      date_of_birth = p_date_of_birth,
      passport_english_name = nullif(trim(p_passport_english_name), ''),
      phone = trim(p_phone),
      insurance_opt_in = case
        when exists (select 1 from public.events where id = p_event_id and insurance_enabled)
        then p_insurance_opt_in
        else null
      end
  where event_id = p_event_id and user_id = auth.uid();
end;
$$;

revoke execute on function public.update_my_event_details(uuid, text, date, text, text, boolean) from public, anon;
grant execute on function public.update_my_event_details(uuid, text, date, text, text, boolean) to authenticated;

create or replace function public.respond_to_event(p_event_id uuid, p_attending boolean)
returns void
language plpgsql
security definer
set search_path = ''
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
  if p_attending and not exists (
    select 1 from public.event_members
    where event_id = p_event_id and user_id = auth.uid() and status = 'registered'
      and nullif(trim(full_name), '') is not null and date_of_birth is not null
      and nullif(trim(phone), '') is not null
  ) then raise exception 'Complete your basic details before confirming attendance'; end if;

  update public.event_members
  set attendance_status = case when p_attending then 'attending' else 'not_attending' end,
      details_locked_at = case when p_attending then coalesce(details_locked_at, now()) else details_locked_at end
  where event_id = p_event_id and user_id = auth.uid();

  if not p_attending then
    delete from public.room_bookings where event_id = p_event_id and user_id = auth.uid();
    delete from public.vehicle_bookings where event_id = p_event_id and user_id = auth.uid();
  end if;
end;
$$;

create or replace function public.cancel_resource_selection(p_event_id uuid, p_resource_type text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'Sign in before cancelling a selection'; end if;
  if not exists (
    select 1 from public.event_members
    where event_id = p_event_id and user_id = auth.uid()
      and status = 'registered' and attendance_status = 'attending'
  ) then raise exception 'An attending invitee is required'; end if;
  if not exists (
    select 1 from public.events
    where id = p_event_id and registration_open and resource_selection_open
  ) then raise exception 'Resource selection is not open'; end if;

  if p_resource_type = 'room' then
    delete from public.room_bookings where event_id = p_event_id and user_id = auth.uid();
  elsif p_resource_type = 'vehicle' then
    delete from public.vehicle_bookings where event_id = p_event_id and user_id = auth.uid();
  else
    raise exception 'Invalid resource type';
  end if;
end;
$$;

revoke execute on function public.cancel_resource_selection(uuid, text) from public, anon;
grant execute on function public.cancel_resource_selection(uuid, text) to authenticated;
