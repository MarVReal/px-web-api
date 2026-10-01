-- Bug fix: lock_scope_columns() referenced new.team_id / new.pipeline_id in `and` expressions, which fail on tables
-- without those columns (updating teams, divisions, members or reports raised "record new has no field ...").
create or replace function lock_scope_columns() returns trigger language plpgsql set search_path = public as $$
begin
  if new.organization_id is distinct from old.organization_id then raise exception 'organization_id is immutable'; end if;
  if tg_table_name = 'tasks' then
    if new.team_id is distinct from old.team_id then raise exception 'team_id is immutable'; end if;
    if new.pipeline_id is distinct from old.pipeline_id then raise exception 'pipeline_id is immutable'; end if;
  elsif tg_table_name = 'pipelines' then
    if new.team_id is distinct from old.team_id then raise exception 'team_id is immutable'; end if;
  end if;
  return new; end $$;
revoke execute on function lock_scope_columns() from public, anon, authenticated;

-- Reports cover an arbitrary date range (e.g. Sep 1 - Sep 15), not just a calendar month.
-- (table keeps its original name monthly_reports; period_start/period_end are inclusive dates)
alter table monthly_reports add column period_end date;
update monthly_reports set period_end = (period_start + interval '1 month' - interval '1 day')::date;
alter table monthly_reports alter column period_end set not null;
alter table monthly_reports add constraint monthly_reports_period_chk check (period_end >= period_start and period_end - period_start <= 366);

drop function report_summary(report_scope, uuid, uuid, date);
create function report_summary(p_scope report_scope, p_team uuid, p_user uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare v_start date := p_from; v_end date := p_to + 1;  -- v_end is exclusive
  v_result jsonb; begin
  if p_from is null or p_to is null or p_to < p_from then raise exception 'invalid date range'; end if;
  if p_to - p_from > 366 then raise exception 'date range is limited to one year'; end if;
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
              -- delayed = due date already passed (within the range) and not finished on time
              (due_date is not null and due_date < least(v_end, current_date)
                 and (completed_at is null or completed_at::date > due_date)) as delayed
    from scoped where completed_at is null or completed_at < v_end
  )
  select jsonb_build_object(
    'period_start', v_start, 'period_end', p_to,
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
grant execute on function report_summary(report_scope, uuid, uuid, date, date) to authenticated;
