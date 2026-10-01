-- Authorization helpers + Row Level Security. Org membership is ALWAYS derived from auth.uid().

-- ---------- helpers (security definer so they can read membership tables without recursion) ----------
create or replace function is_org_member(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from organization_members
    where organization_id = p_org and user_id = auth.uid() and is_active) $$;

create or replace function org_role(p_org uuid) returns member_role
language sql stable security definer set search_path = public as $$
  select role from organization_members
    where organization_id = p_org and user_id = auth.uid() and is_active $$;

create or replace function is_org_admin(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(org_role(p_org) = 'admin', false) $$;

create or replace function in_team(p_team uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from team_members tm
    join organization_members om on om.organization_id = tm.organization_id and om.user_id = tm.user_id
    where tm.team_id = p_team and tm.user_id = auth.uid() and om.is_active) $$;

create or replace function is_team_head(p_team uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from team_members tm
    join organization_members om on om.organization_id = tm.organization_id and om.user_id = tm.user_id
    where tm.team_id = p_team and tm.user_id = auth.uid() and tm.is_head and om.is_active
      and om.role in ('section_head','admin')) $$;

-- admin of the team's org, or any member of the team
create or replace function can_access_team(p_team uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from teams t where t.id = p_team and is_org_admin(t.organization_id)) or in_team(p_team) $$;

create or replace function can_manage_team(p_team uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from teams t where t.id = p_team and is_org_admin(t.organization_id)) or is_team_head(p_team) $$;

create or replace function can_view_task(p_task uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from tasks t where t.id = p_task and (
      is_org_admin(t.organization_id) or in_team(t.team_id)
      or exists (select 1 from task_assignees a where a.task_id = t.id and a.user_id = auth.uid()))) $$;

create or replace function can_edit_task(p_task uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from tasks t where t.id = p_task and (
      can_manage_team(t.team_id) or t.created_by = auth.uid()
      or exists (select 1 from task_assignees a where a.task_id = t.id and a.user_id = auth.uid()))) $$;

create or replace function shares_org_with(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from organization_members a join organization_members b
    on a.organization_id = b.organization_id
    where a.user_id = auth.uid() and b.user_id = p_user and a.is_active) $$;

create or replace function has_permission(p_org uuid, p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from role_permissions rp where rp.role = org_role(p_org) and rp.permission_key = p_key) $$;

-- ---------- enable RLS ----------
do $$ declare t text; begin
  foreach t in array array['profiles','organizations','organization_settings','organization_members','divisions',
    'teams','team_members','permissions','role_permissions','invitations','pipelines','pipeline_stages','tasks',
    'task_assignees','task_comments','task_attachments','task_activity_logs','notifications','monthly_reports',
    'monthly_report_items'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon', t);
  end loop; end $$;

-- profiles
create policy profiles_select on profiles for select to authenticated
  using (id = auth.uid() or shares_org_with(id));
create policy profiles_update on profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- organizations (creation only via create_organization RPC)
create policy orgs_select on organizations for select to authenticated using (is_org_member(id));
create policy orgs_update on organizations for update to authenticated
  using (is_org_admin(id)) with check (is_org_admin(id));

create policy org_settings_select on organization_settings for select to authenticated using (is_org_member(organization_id));
create policy org_settings_update on organization_settings for update to authenticated
  using (is_org_admin(organization_id)) with check (is_org_admin(organization_id));

-- members (insert only via RPCs)
create policy members_select on organization_members for select to authenticated using (is_org_member(organization_id));
create policy members_update on organization_members for update to authenticated
  using (is_org_admin(organization_id)) with check (is_org_admin(organization_id));
create policy members_delete on organization_members for delete to authenticated using (is_org_admin(organization_id));

create policy divisions_select on divisions for select to authenticated using (is_org_member(organization_id));
create policy divisions_write on divisions for all to authenticated
  using (is_org_admin(organization_id)) with check (is_org_admin(organization_id));

create policy teams_select on teams for select to authenticated
  using (is_org_admin(organization_id) or in_team(id));
create policy teams_write on teams for all to authenticated
  using (is_org_admin(organization_id)) with check (is_org_admin(organization_id));

create policy team_members_select on team_members for select to authenticated
  using (is_org_admin(organization_id) or in_team(team_id));
create policy team_members_write on team_members for all to authenticated
  using (is_org_admin(organization_id)) with check (is_org_admin(organization_id));

create policy permissions_select on permissions for select to authenticated using (true);
create policy role_permissions_select on role_permissions for select to authenticated using (true);

create policy invitations_admin on invitations for all to authenticated
  using (is_org_admin(organization_id)) with check (is_org_admin(organization_id));

-- pipelines
create policy pipelines_select on pipelines for select to authenticated using (can_access_team(team_id));
create policy pipelines_insert on pipelines for insert to authenticated with check (
  is_org_admin(organization_id) or (is_team_head(team_id) and coalesce(
    (select section_heads_can_create_pipelines from organization_settings s where s.organization_id = pipelines.organization_id), true)));
create policy pipelines_update on pipelines for update to authenticated
  using (can_manage_team(team_id)) with check (can_manage_team(team_id));
create policy pipelines_delete on pipelines for delete to authenticated
  using (exists (select 1 from teams t where t.id = team_id and is_org_admin(t.organization_id)));

create policy stages_select on pipeline_stages for select to authenticated
  using (exists (select 1 from pipelines p where p.id = pipeline_id and can_access_team(p.team_id)));
create policy stages_write on pipeline_stages for all to authenticated
  using (exists (select 1 from pipelines p where p.id = pipeline_id and can_manage_team(p.team_id)))
  with check (exists (select 1 from pipelines p where p.id = pipeline_id and can_manage_team(p.team_id)));

-- tasks
-- inline (not can_view_task) so INSERT ... RETURNING can see the new row
create policy tasks_select on tasks for select to authenticated using (
  is_org_admin(organization_id) or in_team(team_id)
  or exists (select 1 from task_assignees a where a.task_id = tasks.id and a.user_id = auth.uid()));
create policy tasks_insert on tasks for insert to authenticated with check (can_access_team(team_id));
create policy tasks_update on tasks for update to authenticated
  using (can_edit_task(id)) with check (can_access_team(team_id));
create policy tasks_delete on tasks for delete to authenticated using (can_manage_team(team_id));

create policy assignees_select on task_assignees for select to authenticated using (can_view_task(task_id));
-- managers assign anyone on the task's team; staff may only assign/unassign themselves
create policy assignees_insert on task_assignees for insert to authenticated with check (
  exists (select 1 from tasks t where t.id = task_id and (can_manage_team(t.team_id)
    or (user_id = auth.uid() and in_team(t.team_id)))));
create policy assignees_update on task_assignees for update to authenticated
  using (exists (select 1 from tasks t where t.id = task_id and can_manage_team(t.team_id)))
  with check (exists (select 1 from tasks t where t.id = task_id and can_manage_team(t.team_id)));
create policy assignees_delete on task_assignees for delete to authenticated using (
  user_id = auth.uid() or exists (select 1 from tasks t where t.id = task_id and can_manage_team(t.team_id)));

create policy comments_select on task_comments for select to authenticated using (can_view_task(task_id));
create policy comments_insert on task_comments for insert to authenticated
  with check (can_view_task(task_id) and created_by = auth.uid());
create policy comments_update on task_comments for update to authenticated
  using (created_by = auth.uid()) with check (created_by = auth.uid());
create policy comments_delete on task_comments for delete to authenticated
  using (created_by = auth.uid() or exists (select 1 from tasks t where t.id = task_id and can_manage_team(t.team_id)));

create policy attachments_select on task_attachments for select to authenticated using (can_view_task(task_id));
create policy attachments_insert on task_attachments for insert to authenticated
  with check (can_view_task(task_id) and created_by = auth.uid());
create policy attachments_delete on task_attachments for delete to authenticated
  using (created_by = auth.uid() or exists (select 1 from tasks t where t.id = task_id and can_manage_team(t.team_id)));

-- activity logs: read-only for everyone; rows are written by security-definer triggers only
create policy activity_select on task_activity_logs for select to authenticated using (
  is_org_admin(organization_id) or user_id = auth.uid()
  or (team_id is not null and is_team_head(team_id))
  or (task_id is not null and can_view_task(task_id)));
revoke insert, update, delete on task_activity_logs from authenticated;

create policy notifications_select on notifications for select to authenticated using (user_id = auth.uid());
create policy notifications_update on notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notifications_delete on notifications for delete to authenticated using (user_id = auth.uid());
revoke insert on notifications from authenticated;

-- reports
create or replace function can_view_report(p_org uuid, p_scope report_scope, p_team uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_org_admin(p_org)
    or (p_scope = 'individual' and p_user = auth.uid())
    or (p_scope = 'team' and p_team is not null and is_team_head(p_team))
    or (p_scope = 'individual' and exists (select 1 from team_members tm
          where tm.user_id = p_user and is_team_head(tm.team_id))) $$;

create policy reports_select on monthly_reports for select to authenticated
  using (can_view_report(organization_id, scope, team_id, subject_user_id));
create policy reports_insert on monthly_reports for insert to authenticated
  with check (can_view_report(organization_id, scope, team_id, subject_user_id));
create policy reports_update on monthly_reports for update to authenticated
  using (can_view_report(organization_id, scope, team_id, subject_user_id))
  with check (can_view_report(organization_id, scope, team_id, subject_user_id));
create policy reports_delete on monthly_reports for delete to authenticated using (is_org_admin(organization_id));

create policy report_items_all on monthly_report_items for all to authenticated
  using (exists (select 1 from monthly_reports r where r.id = report_id
    and can_view_report(r.organization_id, r.scope, r.team_id, r.subject_user_id)))
  with check (exists (select 1 from monthly_reports r where r.id = report_id
    and can_view_report(r.organization_id, r.scope, r.team_id, r.subject_user_id)));

-- ---------- never trust client-supplied organization_id: derive it from the parent row ----------
create or replace function derive_org_id() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_org uuid; begin
  if tg_table_name = 'team_members' then select organization_id into v_org from teams where id = new.team_id;
  elsif tg_table_name = 'pipelines' then select organization_id into v_org from teams where id = new.team_id;
  elsif tg_table_name = 'pipeline_stages' then select organization_id into v_org from pipelines where id = new.pipeline_id;
  elsif tg_table_name = 'tasks' then
    select organization_id, team_id into v_org, new.team_id from pipelines where id = new.pipeline_id;
    if not exists (select 1 from pipeline_stages where id = new.stage_id and pipeline_id = new.pipeline_id) then
      raise exception 'stage does not belong to pipeline'; end if;
  elsif tg_table_name in ('task_assignees','task_comments','task_attachments') then
    select organization_id into v_org from tasks where id = new.task_id;
    if tg_table_name = 'task_assignees' and not exists (
        select 1 from tasks t join team_members tm on tm.team_id = t.team_id
        where t.id = new.task_id and tm.user_id = new.user_id) then
      raise exception 'assignee must be a member of the task''s team'; end if;
  elsif tg_table_name = 'monthly_report_items' then select organization_id into v_org from monthly_reports where id = new.report_id;
  end if;
  if v_org is null then raise exception 'parent not found'; end if;
  new.organization_id := v_org;
  return new; end $$;

do $$ declare t text; begin
  foreach t in array array['team_members','pipelines','pipeline_stages','tasks','task_assignees','task_comments',
    'task_attachments','monthly_report_items'] loop
    execute format('create trigger trg_%I_org before insert on %I for each row execute function derive_org_id()', t, t);
  end loop; end $$;

-- scope/org columns are immutable once set
create or replace function lock_scope_columns() returns trigger language plpgsql as $$
begin
  if new.organization_id is distinct from old.organization_id then raise exception 'organization_id is immutable'; end if;
  if tg_table_name in ('tasks','pipelines') and new.team_id is distinct from old.team_id then
    raise exception 'team_id is immutable'; end if;
  if tg_table_name = 'tasks' and new.pipeline_id is distinct from old.pipeline_id then
    raise exception 'pipeline_id is immutable'; end if;
  return new; end $$;
do $$ declare t text; begin
  foreach t in array array['tasks','pipelines','teams','divisions','organization_members','monthly_reports'] loop
    execute format('create trigger trg_%I_lock before update on %I for each row execute function lock_scope_columns()', t, t);
  end loop; end $$;

-- audit stamps
create or replace function stamp_actor() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then new.created_by := coalesce(new.created_by, auth.uid()); end if;
  if to_jsonb(new) ? 'updated_by' then new.updated_by := auth.uid(); end if;
  return new; end $$;
do $$ declare t text; begin
  foreach t in array array['divisions','teams','pipelines','tasks','monthly_reports'] loop
    execute format('create trigger trg_%I_actor before insert or update on %I for each row execute function stamp_actor()', t, t);
  end loop; end $$;

-- ---------- RPCs ----------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)));
  return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();
-- backfill profiles for auth users that existed before this schema
insert into profiles (id, email, full_name)
  select id, email, coalesce(raw_user_meta_data->>'full_name', split_part(email, '@', 1)) from auth.users
  on conflict do nothing;

create or replace function create_organization(p_name text, p_description text default null,
  p_industry text default null, p_timezone text default 'UTC') returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid; begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if char_length(trim(coalesce(p_name,''))) < 2 then raise exception 'organization name too short'; end if;
  insert into organizations (name, description, industry, timezone, created_by)
    values (trim(p_name), p_description, p_industry, coalesce(p_timezone,'UTC'), auth.uid()) returning id into v_org;
  insert into organization_settings (organization_id, updated_by) values (v_org, auth.uid());
  insert into organization_members (organization_id, user_id, role, created_by) values (v_org, auth.uid(), 'admin', auth.uid());
  return v_org; end $$;

-- Public preview so an invitee can see what they're joining before they sign up.
create or replace function get_invitation_preview(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('email', i.email, 'role', i.role, 'organization_name', o.name,
    'team_name', t.name, 'valid', i.status = 'pending' and i.expires_at > now())
  from invitations i join organizations o on o.id = i.organization_id left join teams t on t.id = i.team_id
  where i.token = p_token $$;
grant execute on function get_invitation_preview(uuid) to anon, authenticated;

create or replace function accept_invitation(p_token uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_inv invitations; v_email text; begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select email into v_email from auth.users where id = auth.uid();
  select * into v_inv from invitations where token = p_token for update;
  if not found or v_inv.status <> 'pending' or v_inv.expires_at < now() then
    raise exception 'invitation is invalid, used, or expired'; end if;
  if lower(v_inv.email) <> lower(v_email) then raise exception 'invitation was issued to a different email'; end if;
  insert into organization_members (organization_id, user_id, role, position_title, created_by)
    values (v_inv.organization_id, auth.uid(), v_inv.role, v_inv.position_title, v_inv.created_by)
    on conflict (organization_id, user_id) do update set is_active = true, role = excluded.role;
  if v_inv.team_id is not null then
    insert into team_members (organization_id, team_id, user_id, is_head, created_by)
      values (v_inv.organization_id, v_inv.team_id, auth.uid(), v_inv.role = 'section_head', v_inv.created_by)
      on conflict (team_id, user_id) do nothing;
  end if;
  update invitations set status = 'accepted', accepted_by = auth.uid(), accepted_at = now() where id = v_inv.id;
  return v_inv.organization_id; end $$;

-- Move a task (stage and/or order). Activity logging happens in the tasks trigger.
create or replace function move_task(p_task uuid, p_stage uuid, p_position double precision) returns tasks
language plpgsql security invoker set search_path = public as $$
declare v_row tasks; begin
  update tasks set stage_id = p_stage, position = p_position where id = p_task returning * into v_row;
  if not found then raise exception 'task not found or not permitted'; end if;
  return v_row; end $$;

-- Prevent removing/demoting the last admin; keep team_members consistent.
create or replace function guard_last_admin() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.role = 'admin' and exists (select 1 from organizations where id = old.organization_id) and (tg_op = 'DELETE' or new.role <> 'admin' or not new.is_active) then
    if not exists (select 1 from organization_members where organization_id = old.organization_id
        and role = 'admin' and is_active and id <> old.id) then
      raise exception 'an organization must keep at least one admin'; end if;
  end if;
  return coalesce(new, old); end $$;
create trigger trg_guard_last_admin before update or delete on organization_members
  for each row execute function guard_last_admin();

revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function get_invitation_preview(uuid) to anon;
