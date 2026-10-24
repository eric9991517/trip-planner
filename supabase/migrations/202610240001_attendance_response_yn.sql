alter table public.event_members
  add column if not exists attendance_yn char(1)
  check (attendance_yn in ('Y', 'N'));

update public.event_members
set attendance_yn = case
  when attendance_status = 'attending' then 'Y'
  when attendance_status = 'not_attending' then 'N'
  else null
end
where attendance_yn is null;

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
      attendance_yn = case when p_attending then 'Y' else 'N' end,
      details_locked_at = case when p_attending then coalesce(details_locked_at, now()) else details_locked_at end
  where event_id = p_event_id and user_id = auth.uid();

  if not p_attending then
    delete from public.room_bookings where event_id = p_event_id and user_id = auth.uid();
    delete from public.vehicle_bookings where event_id = p_event_id and user_id = auth.uid();
  end if;
end;
$$;

revoke execute on function public.respond_to_event(uuid, boolean) from public, anon;
grant execute on function public.respond_to_event(uuid, boolean) to authenticated;
