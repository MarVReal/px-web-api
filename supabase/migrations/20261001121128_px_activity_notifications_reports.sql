-- Centralized audit trail, notifications, permission seed data, and report summaries.

-- ---------- permission catalogue ----------
insert into permissions (key, description) values
  ('organization.view','View organization'), ('organization.manage','Manage organization settings'),
  ('users.view','View users'), ('users.manage','Invite and manage users'),
  ('teams.view','View teams'), ('teams.manage','Create and manage teams'),
  ('pipelines.view','View pipelines'), ('pipelines.create','Create pipelines'), ('pipelines.manage','Manage pipelines and stages'),
  ('tasks.view','View tasks'), ('tasks.create','Create tasks'), ('tasks.edit','Edit tasks'),
  ('tasks.assign','Assign tasks'), ('tasks.move','Move tasks between stages'), ('tasks.delete','Delete tasks'),
  ('reports.view','View reports'), ('reports.create','Generate reports'), ('reports.manage','Compile organization reports'),
  ('activity.view','View activity log'), ('settings.manage','Manage settings');

insert into role_permissions (role, permission_key)
  select 'admin', key from permissions;
insert into role_permissions (role, permission_key) values
  ('section_head','organization.view'), ('section_head','users.view'), ('section_head','teams.view'),
  ('section_head','pipelines.view'), ('section_head','pipelines.create'), ('section_head','pipelines.manage'),
  ('section_head','tasks.view'), ('section_head','tasks.create'), ('section_head','tasks.edit'),
  ('section_head','tasks.assign'), ('section_head','tasks.move'), ('section_head','tasks.delete'),
  ('section_head','reports.view'), ('section_head','reports.create'), ('section_head','activity.view'),
  ('staff','organization.view'), ('staff','teams.view'), ('staff','pipelines.view'),
  ('staff','tasks.view'), ('staff','tasks.create'), ('staff','tasks.edit'), ('staff','tasks.move'),
  ('staff','reports.view'), ('staff','reports.create'), ('staff','activity.view');

-- ---------- helpers ----------
create or replace function actor_name() returns text language sql stable security definer set search_path = public as $$
  select coalesce((select coalesce(nullif(full_name,''), email) from profiles where id = auth.uid()), 'System') $$;

create or replace function write_activity(p_org uuid, p_team uuid, p_pipeline uuid, p_task uuid,
  p_type text, p_desc text, p_prev jsonb default null, p_new jsonb default null) returns void
language sql security definer set search_path = public as $$
  insert into task_activity_logs (organization_id, user_id, team_id, pipeline_id, task_id, activity_type, description, previous_value, new_value)
  values (p_org, auth.uid(), p_team, p_pipeline, p_task, p_type, p_desc, p_prev, p_new) $$;

create or replace function push_notification(p_org uuid, p_user uuid, p_type text, p_title text, p_body text, p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_user is null or p_user = auth.uid() then return; end if;
  insert into notifications (organization_id, user_id, type, title, body, task_id)
  values (p_org, p_user, p_type, p_title, p_body, p_task); end $$;

-- ---------- tasks ----------
create or replace function tasks_before_write() returns trigger language plpgsql security definer set search_path = public as $$
declare v_kind stage_kind; begin
  select kind into v_kind from pipeline_stages where id = new.stage_id;
  if v_kind = 'done' then
    if tg_op = 'INSERT' or old.completed_at is null then new.completed_at := now(); end if;
    new.progress := 100;
  else
    new.completed_at := null;
  end if;
  return new; end $$;
create trigger trg_tasks_before before insert or update on tasks for each row execute function tasks_before_write();

create or replace function tasks_after_write() returns trigger language plpgsql security definer set search_path = public as $$
declare v_who text := actor_name(); v_from text; v_to text; v_kind stage_kind; r record; begin
  if tg_op = 'INSERT' then
    perform write_activity(new.organization_id, new.team_id, new.pipeline_id, new.id, 'task_created',
      v_who || ' created task "' || new.title || '".', null, jsonb_build_object('title', new.title, 'stage_id', new.stage_id));
    return new;
  end if;

  if new.stage_id is distinct from old.stage_id then
    select name into v_from from pipeline_stages where id = old.stage_id;
    select name, kind into v_to, v_kind from pipeline_stages where id = new.stage_id;
    perform write_activity(new.organization_id, new.team_id, new.pipeline_id, new.id, 'task_moved',
      v_who || ' moved "' || new.title || '" from ' || v_from || ' to ' || v_to || '.',
      jsonb_build_object('stage_id', old.stage_id, 'stage', v_from),
      jsonb_build_object('stage_id', new.stage_id, 'stage', v_to));
    if v_kind = 'done' then
      perform write_activity(new.organization_id, new.team_id, new.pipeline_id, new.id, 'task_completed',
        v_who || ' completed "' || new.title || '".');
    end if;
    if v_kind in ('review','done') then
      for r in select distinct u from (select user_id u from task_assignees where task_id = new.id
                 union select new.created_by) x where u is not null loop
        perform push_notification(new.organization_id, r.u, case when v_kind = 'done' then 'task_completed' else 'task_review' end,
          case when v_kind = 'done' then 'Task completed' else 'Task moved to review' end,
          v_who || ' moved "' || new.title || '" to ' || v_to, new.id);
      end loop;
    end if;
  end if;
  if new.due_date is distinct from old.due_date then
    perform write_activity(new.organization_id, new.team_id, new.pipeline_id, new.id, 'due_date_changed',
      v_who || ' changed due date of "' || new.title || '" from ' || coalesce(old.due_date::text,'none') || ' to ' || coalesce(new.due_date::text,'none') || '.',
      to_jsonb(old.due_date), to_jsonb(new.due_date));
  end if;
  if new.priority is distinct from old.priority then
    perform write_activity(new.organization_id, new.team_id, new.pipeline_id, new.id, 'priority_changed',
      v_who || ' changed priority of "' || new.title || '" from ' || old.priority || ' to ' || new.priority || '.',
      to_jsonb(old.priority), to_jsonb(new.priority));
  end if;
  if new.title is distinct from old.title or new.description is distinct from old.description
     or new.notes is distinct from old.notes or new.category is distinct from old.category
     or new.tags is distinct from old.tags or new.start_date is distinct from old.start_date
     or new.estimated_hours is distinct from old.estimated_hours or new.progress is distinct from old.progress and new.stage_id = old.stage_id then
    perform write_activity(new.organization_id, new.team_id, new.pipeline_id, new.id, 'task_edited',
      v_who || ' edited task "' || new.title || '".',
      jsonb_build_object('title', old.title, 'description', old.description, 'category', old.category, 'progress', old.progress),
      jsonb_build_object('title', new.title, 'description', new.description, 'category', new.category, 'progress', new.progress));
  end if;
  return new; end $$;
create trigger trg_tasks_after after insert or update on tasks for each row execute function tasks_after_write();

create or replace function assignees_after() returns trigger language plpgsql security definer set search_path = public as $$
declare v_task tasks; v_name text; begin
  select * into v_task from tasks where id = coalesce(new.task_id, old.task_id);
  if v_task.id is null then return coalesce(new, old); end if;
  select coalesce(nullif(full_name,''), email) into v_name from profiles where id = coalesce(new.user_id, old.user_id);
  if tg_op = 'INSERT' then
    new.assigned_by := coalesce(new.assigned_by, auth.uid());
    perform write_activity(v_task.organization_id, v_task.team_id, v_task.pipeline_id, v_task.id, 'task_assigned',
      actor_name() || ' assigned "' || v_task.title || '" to ' || v_name || '.', null, to_jsonb(new.user_id));
    perform push_notification(v_task.organization_id, new.user_id, 'task_assigned', 'New task assigned', v_task.title, v_task.id);
    return new;
  else
    perform write_activity(v_task.organization_id, v_task.team_id, v_task.pipeline_id, v_task.id, 'task_unassigned',
      actor_name() || ' unassigned ' || v_name || ' from "' || v_task.title || '".', to_jsonb(old.user_id), null);
    perform push_notification(v_task.organization_id, old.user_id, 'task_unassigned', 'Removed from task', v_task.title, v_task.id);
    return old;
  end if; end $$;
create trigger trg_assignees_ins before insert on task_assignees for each row execute function assignees_after();
create trigger trg_assignees_del after delete on task_assignees for each row execute function assignees_after();

create or replace function comments_after() returns trigger language plpgsql security definer set search_path = public as $$
declare v_task tasks; m uuid; begin
  select * into v_task from tasks where id = new.task_id;
  perform write_activity(v_task.organization_id, v_task.team_id, v_task.pipeline_id, v_task.id, 'comment_added',
    actor_name() || ' commented on "' || v_task.title || '".', null, jsonb_build_object('comment_id', new.id));
  foreach m in array new.mentions loop
    if exists (select 1 from organization_members where organization_id = v_task.organization_id and user_id = m) then
      perform push_notification(v_task.organization_id, m, 'mention', 'You were mentioned', left(new.body, 140), v_task.id);
    end if;
  end loop;
  return new; end $$;
create trigger trg_comments_after after insert on task_comments for each row execute function comments_after();

create or replace function attachments_after() returns trigger language plpgsql security definer set search_path = public as $$
declare v_task tasks; begin
  select * into v_task from tasks where id = new.task_id;
  perform write_activity(v_task.organization_id, v_task.team_id, v_task.pipeline_id, v_task.id, 'attachment_uploaded',
    actor_name() || ' uploaded ' || new.file_name || ' to "' || v_task.title || '".', null, jsonb_build_object('file', new.file_name));
  return new; end $$;
create trigger trg_attachments_after after insert on task_attachments for each row execute function attachments_after();

-- ---------- pipelines / stages / team membership / roles ----------
create or replace function structure_audit() returns trigger language plpgsql security definer set search_path = public as $$
declare v_pipe pipelines; v_team text; v_user text; begin
  if tg_table_name = 'pipelines' then
    if tg_op = 'INSERT' then
      perform write_activity(new.organization_id, new.team_id, new.id, null, 'pipeline_created', actor_name() || ' created pipeline "' || new.name || '".');
    elsif new.name is distinct from old.name or new.is_archived is distinct from old.is_archived then
      perform write_activity(new.organization_id, new.team_id, new.id, null, 'pipeline_edited',
        actor_name() || ' edited pipeline "' || new.name || '".', to_jsonb(old.name), to_jsonb(new.name));
    end if;
  elsif tg_table_name = 'pipeline_stages' then
    select * into v_pipe from pipelines where id = new.pipeline_id;
    if tg_op = 'INSERT' then
      perform write_activity(new.organization_id, v_pipe.team_id, new.pipeline_id, null, 'stage_created',
        actor_name() || ' added stage "' || new.name || '" to ' || v_pipe.name || '.');
    elsif new.name is distinct from old.name then
      perform write_activity(new.organization_id, v_pipe.team_id, new.pipeline_id, null, 'stage_renamed',
        actor_name() || ' renamed stage "' || old.name || '" to "' || new.name || '".', to_jsonb(old.name), to_jsonb(new.name));
    end if;
  elsif tg_table_name = 'team_members' then
    select name into v_team from teams where id = coalesce(new.team_id, old.team_id);
    select coalesce(nullif(full_name,''), email) into v_user from profiles where id = coalesce(new.user_id, old.user_id);
    if tg_op = 'INSERT' then
      perform write_activity(new.organization_id, new.team_id, null, null, 'user_added', actor_name() || ' added ' || v_user || ' to ' || v_team || '.');
      perform push_notification(new.organization_id, new.user_id, 'team_added', 'Added to team', v_team, null);
    else
      perform write_activity(old.organization_id, old.team_id, null, null, 'user_removed', actor_name() || ' removed ' || v_user || ' from ' || v_team || '.');
      perform push_notification(old.organization_id, old.user_id, 'team_removed', 'Removed from team', v_team, null);
    end if;
  elsif tg_table_name = 'organization_members' and new.role is distinct from old.role then
    select coalesce(nullif(full_name,''), email) into v_user from profiles where id = new.user_id;
    perform write_activity(new.organization_id, null, null, null, 'role_changed',
      actor_name() || ' changed role of ' || v_user || ' from ' || old.role || ' to ' || new.role || '.', to_jsonb(old.role), to_jsonb(new.role));
  end if;
  return coalesce(new, old); end $$;
create trigger trg_pipelines_audit after insert or update on pipelines for each row execute function structure_audit();
create trigger trg_stages_audit after insert or update on pipeline_stages for each row execute function structure_audit();
create trigger trg_team_members_audit after insert or delete on team_members for each row execute function structure_audit();
create trigger trg_members_audit after update on organization_members for each row execute function structure_audit();

-- ---------- scheduled notifications (call from pg_cron or an Edge Function cron) ----------
create or replace function generate_due_notifications() returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; begin
  for r in
    select t.id, t.organization_id, t.title, t.due_date, a.user_id,
           case when t.due_date < current_date then 'task_overdue' else 'task_due_soon' end as kind
    from tasks t join task_assignees a on a.task_id = t.id
    where t.completed_at is null and t.due_date <= current_date + 1
  loop
    if not exists (select 1 from notifications where task_id = r.id and user_id = r.user_id and type = r.kind
                   and created_at > now() - interval '24 hours') then
      insert into notifications (organization_id, user_id, type, title, body, task_id)
      values (r.organization_id, r.user_id, r.kind,
        case when r.kind = 'task_overdue' then 'Task overdue' else 'Task due soon' end, r.title, r.id);
      n := n + 1;
    end if;
  end loop;
  return n; end $$;
revoke execute on function generate_due_notifications() from authenticated;

-- ---------- report summary (security invoker: RLS decides what the caller may aggregate) ----------
create or replace function report_summary(p_scope report_scope, p_team uuid, p_user uuid, p_month date) returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare v_start date := date_trunc('month', p_month)::date; v_end date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_result jsonb; begin
  with scoped as (
    select t.id, t.title, t.due_date, t.estimated_hours, t.completed_at, t.created_at, t.team_id, s.kind, s.name as stage_name,
      (select string_agg(coalesce(nullif(p.full_name,''), p.email), ', ') from task_assignees a join profiles p on p.id = a.user_id where a.task_id = t.id) as assignees,
      (select array_agg(a.user_id) from task_assignees a where a.task_id = t.id) as assignee_ids
    from tasks t join pipeline_stages s on s.id = t.stage_id
    where t.created_at < v_end and (t.completed_at is null or t.completed_at >= v_start)
      and (p_scope = 'organization' or (p_scope = 'team' and t.team_id = p_team)
           or (p_scope = 'individual' and exists (select 1 from task_assignees a where a.task_id = t.id and a.user_id = p_user)))
  ), classed as (
    select *, case when completed_at >= v_start and completed_at < v_end then 'completed'
                   when completed_at is not null then 'completed_later'
                   when kind = 'backlog' then 'pending' else 'in_progress' end as status,
              (completed_at is null and created_at < v_start) as carried_over,
              (due_date is not null and due_date < v_end and (completed_at is null or completed_at::date > due_date)) as delayed
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

-- ---------- realtime (kanban live updates) ----------
alter publication supabase_realtime add table tasks, task_assignees, notifications;
