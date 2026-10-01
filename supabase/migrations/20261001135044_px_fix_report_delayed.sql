-- Bug fix: "delayed" counted every unfinished task due later in the report month.
-- Delayed now means the due date has already passed (within the period) and the task was not finished on time.
create or replace function report_summary(p_scope report_scope, p_team uuid, p_user uuid, p_month date) returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare v_start date := date_trunc('month', p_month)::date; v_end date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_result jsonb; begin
  with scoped as (
    select t.id, t.title, t.due_date, t.estimated_hours, t.completed_at, t.created_at, t.team_id, s.kind, s.name as stage_name,
      (select string_agg(coalesce(nullif(p.full_name,''), p.email), ', ') from task_assignees a join profiles p on p.id = a.user_id where a.task_id = t.id) as assignees
    from tasks t join pipeline_stages s on s.id = t.stage_id
    where t.created_at < v_end and (t.completed_at is null or t.completed_at >= v_start)
      and (p_scope = 'organization' or (p_scope = 'team' and t.team_id = p_team)
           or (p_scope = 'individual' and exists (select 1 from task_assignees a where a.task_id = t.id and a.user_id = p_user)))
  ), classed as (
    select *, case when completed_at >= v_start and completed_at < v_end then 'completed'
                   when completed_at is not null then 'completed_later'
                   when kind = 'backlog' then 'pending' else 'in_progress' end as status,
              (completed_at is null and created_at < v_start) as carried_over,
              -- delayed = the due date has already passed (within the period) and it was not finished on time
              (due_date is not null and due_date < least(v_end, current_date)
                 and (completed_at is null or completed_at::date > due_date)) as delayed
    from scoped where completed_at is null or completed_at < v_end
  )
  select jsonb_build_object(
    'period_start', v_start,
    'total', count(*),
    'completed', count(*) filter (where status = 'completed'),
    'in_progress', count(*) filter (where status = 'in_progress'),
    'pending', count(*) filter (where status = 'pending'),
    'carried_over', count(*) filter (where carried_over),
    'delayed', count(*) filter (where delayed),
    'completion_rate', case when count(*) = 0 then 0 else round(100.0 * count(*) filter (where status = 'completed') / count(*), 1) end,
    'effort_hours', coalesce(sum(estimated_hours) filter (where status = 'completed'), 0),
    'tasks', coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'assignees', assignees, 'status', status,
        'stage', stage_name, 'completed_on', completed_at::date, 'due_date', due_date, 'delayed', delayed, 'carried_over', carried_over)
        order by completed_at nulls last, title), '[]'::jsonb))
  into v_result from classed;
  return v_result; end $$;
grant execute on function report_summary(report_scope, uuid, uuid, date) to authenticated;
