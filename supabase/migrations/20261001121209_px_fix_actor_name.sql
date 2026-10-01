-- actor_name() returned NULL when there is no signed-in user (e.g. seed/system writes).
create or replace function actor_name() returns text language sql stable security definer set search_path = public as $$
  select coalesce((select coalesce(nullif(full_name,''), email) from profiles where id = auth.uid()), 'System') $$;
revoke execute on function actor_name() from public, anon, authenticated;
