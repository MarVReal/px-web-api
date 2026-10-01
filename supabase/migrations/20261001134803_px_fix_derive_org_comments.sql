-- Bug fix: inserting a comment failed with `record "new" has no field "user_id"`.
-- plpgsql resolves every field in an expression, so `table = 'task_assignees' and ... new.user_id` still evaluated new.user_id
-- for other tables. The assignee check now lives in its own branch. task_attachments no longer exists (replaced by task_links).
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
  elsif tg_table_name = 'task_assignees' then
    select organization_id into v_org from tasks where id = new.task_id;
    -- nested (not `and`): plpgsql would otherwise resolve new.user_id for other tables too
    if not exists (select 1 from tasks t join team_members tm on tm.team_id = t.team_id
        where t.id = new.task_id and tm.user_id = new.user_id) then
      raise exception 'assignee must be a member of the task''s team'; end if;
  elsif tg_table_name = 'task_comments' then
    select organization_id into v_org from tasks where id = new.task_id;
  elsif tg_table_name = 'monthly_report_items' then select organization_id into v_org from monthly_reports where id = new.report_id;
  end if;
  if v_org is null then raise exception 'parent not found'; end if;
  new.organization_id := v_org;
  return new; end $$;
revoke execute on function derive_org_id() from public, anon, authenticated;
