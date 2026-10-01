-- 1. Signed-out visitors should not be able to call report_summary at all (row-level security already
--    returned nothing to them; this removes the entry point).
revoke execute on function public.report_summary(report_scope, uuid, uuid, date, date) from public, anon;
grant execute on function public.report_summary(report_scope, uuid, uuid, date, date) to authenticated;

-- 2. Evaluate auth.uid() once per query instead of once per row (Supabase performance advisor 0003).
--    Same rules as before, only wrapped in (select ...).
alter policy notifications_delete on notifications using (user_id = (select auth.uid()));
alter policy notifications_select on notifications using (user_id = (select auth.uid()));
alter policy notifications_update on notifications using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
alter policy profiles_select on profiles using (id = (select auth.uid()) or shares_org_with(id));
alter policy profiles_update on profiles using (id = (select auth.uid())) with check (id = (select auth.uid()));
alter policy activity_select on task_activity_logs using (
  is_org_admin(organization_id) or user_id = (select auth.uid())
  or (team_id is not null and is_team_head(team_id)) or (task_id is not null and can_view_task(task_id)));
alter policy assignees_delete on task_assignees using (
  user_id = (select auth.uid())
  or exists (select 1 from tasks t where t.id = task_assignees.task_id and can_manage_team(t.team_id)));
alter policy assignees_insert on task_assignees with check (
  exists (select 1 from tasks t where t.id = task_assignees.task_id
    and (can_manage_team(t.team_id) or (task_assignees.user_id = (select auth.uid()) and in_team(t.team_id)))));
alter policy comments_delete on task_comments using (
  created_by = (select auth.uid())
  or exists (select 1 from tasks t where t.id = task_comments.task_id and can_manage_team(t.team_id)));
alter policy comments_insert on task_comments with check (can_view_task(task_id) and created_by = (select auth.uid()));
alter policy comments_update on task_comments using (created_by = (select auth.uid())) with check (created_by = (select auth.uid()));
alter policy tlink_delete on task_links using (
  created_by = (select auth.uid())
  or exists (select 1 from tasks t where t.id = task_links.task_id and can_manage_team(t.team_id)));
alter policy tlink_insert on task_links with check (can_view_task(task_id) and created_by = (select auth.uid()));
alter policy tasks_select on tasks using (
  is_org_admin(organization_id) or in_team(team_id)
  or exists (select 1 from task_assignees a where a.task_id = tasks.id and a.user_id = (select auth.uid())));

-- 3. One SELECT rule per table: the catch-all "_write" (FOR ALL) policies also granted SELECT, so every read
--    ran two policies (advisor 0006). Split them into insert / update / delete with the same conditions.
drop policy divisions_write on divisions;
create policy divisions_insert on divisions for insert to authenticated with check (is_org_admin(organization_id));
create policy divisions_update on divisions for update to authenticated using (is_org_admin(organization_id)) with check (is_org_admin(organization_id));
create policy divisions_delete on divisions for delete to authenticated using (is_org_admin(organization_id));

drop policy teams_write on teams;
create policy teams_insert on teams for insert to authenticated with check (is_org_admin(organization_id));
create policy teams_update on teams for update to authenticated using (is_org_admin(organization_id)) with check (is_org_admin(organization_id));
create policy teams_delete on teams for delete to authenticated using (is_org_admin(organization_id));

drop policy team_members_write on team_members;
create policy team_members_insert on team_members for insert to authenticated with check (is_org_admin(organization_id));
create policy team_members_update on team_members for update to authenticated using (is_org_admin(organization_id)) with check (is_org_admin(organization_id));
create policy team_members_delete on team_members for delete to authenticated using (is_org_admin(organization_id));

drop policy pcat_write on pipeline_categories;
create policy pcat_insert on pipeline_categories for insert to authenticated with check (
  exists (select 1 from pipelines p where p.id = pipeline_categories.pipeline_id and can_manage_team(p.team_id)));
create policy pcat_update on pipeline_categories for update to authenticated
  using (exists (select 1 from pipelines p where p.id = pipeline_categories.pipeline_id and can_manage_team(p.team_id)))
  with check (exists (select 1 from pipelines p where p.id = pipeline_categories.pipeline_id and can_manage_team(p.team_id)));
create policy pcat_delete on pipeline_categories for delete to authenticated using (
  exists (select 1 from pipelines p where p.id = pipeline_categories.pipeline_id and can_manage_team(p.team_id)));

drop policy stages_write on pipeline_stages;
create policy stages_insert on pipeline_stages for insert to authenticated with check (
  exists (select 1 from pipelines p where p.id = pipeline_stages.pipeline_id and can_manage_team(p.team_id)));
create policy stages_update on pipeline_stages for update to authenticated
  using (exists (select 1 from pipelines p where p.id = pipeline_stages.pipeline_id and can_manage_team(p.team_id)))
  with check (exists (select 1 from pipelines p where p.id = pipeline_stages.pipeline_id and can_manage_team(p.team_id)));
create policy stages_delete on pipeline_stages for delete to authenticated using (
  exists (select 1 from pipelines p where p.id = pipeline_stages.pipeline_id and can_manage_team(p.team_id)));

drop policy ptag_write on pipeline_tags;
create policy ptag_insert on pipeline_tags for insert to authenticated with check (
  exists (select 1 from pipelines p where p.id = pipeline_tags.pipeline_id and can_manage_team(p.team_id)));
create policy ptag_update on pipeline_tags for update to authenticated
  using (exists (select 1 from pipelines p where p.id = pipeline_tags.pipeline_id and can_manage_team(p.team_id)))
  with check (exists (select 1 from pipelines p where p.id = pipeline_tags.pipeline_id and can_manage_team(p.team_id)));
create policy ptag_delete on pipeline_tags for delete to authenticated using (
  exists (select 1 from pipelines p where p.id = pipeline_tags.pipeline_id and can_manage_team(p.team_id)));

-- 4. Indexes on foreign keys used for joins, filters and cascades (advisor 0001). Audit columns
--    (created_by, updated_by, assigned_by, accepted_by) are deliberately not indexed to keep writes cheap.
create index if not exists invitations_division_id_idx on invitations (division_id);
create index if not exists invitations_team_id_idx on invitations (team_id);
create index if not exists monthly_report_items_child_report_id_idx on monthly_report_items (child_report_id);
create index if not exists monthly_report_items_organization_id_idx on monthly_report_items (organization_id);
create index if not exists monthly_report_items_task_id_idx on monthly_report_items (task_id);
create index if not exists monthly_reports_team_id_idx on monthly_reports (team_id);
create index if not exists monthly_reports_subject_user_id_idx on monthly_reports (subject_user_id);
create index if not exists notifications_organization_id_idx on notifications (organization_id);
create index if not exists notifications_task_id_idx on notifications (task_id);
create index if not exists pipeline_categories_organization_id_idx on pipeline_categories (organization_id);
create index if not exists pipeline_stages_organization_id_idx on pipeline_stages (organization_id);
create index if not exists pipeline_tags_organization_id_idx on pipeline_tags (organization_id);
create index if not exists pipelines_team_id_idx on pipelines (team_id);
create index if not exists role_permissions_permission_key_idx on role_permissions (permission_key);
create index if not exists task_activity_logs_pipeline_id_idx on task_activity_logs (pipeline_id);
create index if not exists task_assignees_organization_id_idx on task_assignees (organization_id);
create index if not exists task_comments_organization_id_idx on task_comments (organization_id);
create index if not exists task_links_organization_id_idx on task_links (organization_id);
create index if not exists task_tags_organization_id_idx on task_tags (organization_id);
create index if not exists tasks_category_id_idx on tasks (category_id);
create index if not exists tasks_parent_task_id_idx on tasks (parent_task_id);
create index if not exists tasks_related_task_id_idx on tasks (related_task_id);
create index if not exists tasks_stage_id_idx on tasks (stage_id);
create index if not exists teams_division_id_idx on teams (division_id);
