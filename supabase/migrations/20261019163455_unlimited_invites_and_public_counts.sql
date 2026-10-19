alter table public.invitations
  alter column max_uses drop not null;

drop function public.create_invitation(uuid, integer);

create function public.create_invitation(p_event_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  raw_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if not exists (
    select 1 from public.events
    where id = p_event_id and published and registration_open
  ) then raise exception 'Registration is closed'; end if;

  insert into public.invitations (event_id, token_hash, created_by, max_uses)
  values (p_event_id, encode(extensions.digest(raw_token, 'sha256'), 'hex'), auth.uid(), null);
  return raw_token;
end;
$$;

revoke execute on function public.create_invitation(uuid) from public, anon;
grant execute on function public.create_invitation(uuid) to authenticated;

create or replace function public.accept_invitation(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  invite public.invitations%rowtype;
begin
  if current_user_id is null then raise exception 'Sign in before accepting an invitation'; end if;
  select * into invite from public.invitations
  where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
  for update;
  if not found or invite.expires_at < now() then raise exception 'Invitation is invalid or expired'; end if;
  if not exists (
    select 1 from public.events
    where id = invite.event_id and published and registration_open
  ) then raise exception 'Registration is closed'; end if;
  if exists (
    select 1 from public.event_members
    where event_id = invite.event_id and user_id = current_user_id
  ) then return invite.event_id; end if;

  insert into public.event_members (event_id, user_id, invited_by)
  values (invite.event_id, current_user_id, invite.created_by);
  update public.invitations set use_count = use_count + 1 where id = invite.id;
  return invite.event_id;
end;
$$;

create or replace function public.published_event_registration_counts()
returns table (event_id uuid, registered_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select e.id, count(m.user_id)::bigint
  from public.events e
  left join public.event_members m
    on m.event_id = e.id
    and m.status = 'registered'
    and m.attendance_status = 'attending'
  where auth.uid() is not null
    and e.published
  group by e.id;
$$;

revoke execute on function public.published_event_registration_counts() from public, anon;
grant execute on function public.published_event_registration_counts() to authenticated;
