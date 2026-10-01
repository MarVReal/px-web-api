-- "Last Activity" shown on Kanban cards: bumped by every audit-log write that references the task.
alter table tasks add column last_activity_at timestamptz not null default now();
update tasks t set last_activity_at = coalesce((select max(created_at) from task_activity_logs l where l.task_id = t.id), t.created_at);

create or replace function write_activity(p_org uuid, p_team uuid, p_pipeline uuid, p_task uuid,
  p_type text, p_desc text, p_prev jsonb default null, p_new jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into task_activity_logs (organization_id, user_id, team_id, pipeline_id, task_id, activity_type, description, previous_value, new_value)
  values (p_org, auth.uid(), p_team, p_pipeline, p_task, p_type, p_desc, p_prev, p_new);
  if p_task is not null then
    update tasks set last_activity_at = now() where id = p_task;
  end if;
end $$;
revoke execute on function write_activity(uuid,uuid,uuid,uuid,text,text,jsonb,jsonb) from public, anon, authenticated;
