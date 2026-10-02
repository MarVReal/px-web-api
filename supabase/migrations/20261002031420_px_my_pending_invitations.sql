-- Lets a signed-in user see the pending invitations addressed to their own email.
-- RLS only lets org admins read `invitations`, so the invitee cannot query the table directly. Without this the
-- onboarding screen cannot tell a new user they were already invited, and they end up creating a duplicate
-- organization instead of joining the one that invited them.
create or replace function my_pending_invitations() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'token', i.token, 'role', i.role, 'organization_name', o.name, 'team_name', t.name, 'expires_at', i.expires_at)
    order by i.created_at desc), '[]'::jsonb)
  from invitations i
  join auth.users u on u.id = auth.uid() and lower(u.email) = lower(i.email)
  join organizations o on o.id = i.organization_id
  left join teams t on t.id = i.team_id
  where i.status = 'pending' and i.expires_at > now() $$;

revoke execute on function my_pending_invitations() from public, anon;
grant execute on function my_pending_invitations() to authenticated;
