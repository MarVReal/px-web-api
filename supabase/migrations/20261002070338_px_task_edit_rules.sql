-- Who may change what on a task, and a trail for deleted comments.
--
-- * Task details (title, description, dates, priority, category, tags, assignees...) can be edited only by Admins
--   and by the Section Head of the task's section. Staff can still move cards, comment and add links.
--   The person who creates a task has a short window to finish publishing it (the app adds assignees and tags right
--   after the insert); once that passes, only Admins and Section Heads can change the details.
-- * Deleting a comment is recorded in the activity log (deleting a link already was).
-- * A card that leaves a Done stage no longer keeps the 100% progress it was given on the way in.

-- ---------- helper ----------
create or replace function can_edit_task_details(p_task uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from tasks t where t.id = p_task and (
    can_manage_team(t.team_id)
    or (t.created_by = auth.uid() and t.created_at > now() - interval '2 minutes'))) $$;
revoke execute on function can_edit_task_details(uuid) from public, anon;
grant execute on function can_edit_task_details(uuid) to authenticated;

-- ---------- task details: Admin / Section Head only ----------
-- Dragging a card (stage, position) and the system-managed columns (progress, completed_at, last_activity_at,
-- updated_*) stay open to everyone who can already update the task. Calls with no signed-in user (service role,
-- SQL editor, scheduled jobs) are trusted and skipped.
create or replace function tasks_guard_details() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if can_manage_team(old.team_id) then return new; end if;
  if old.created_by = auth.uid() and old.created_at > now() - interval '2 minutes' then return new; end if;
  if (new.title, new.description, new.notes, new.priority, new.category_id, new.start_date, new.due_date,
      new.estimated_hours, new.recurrence, new.parent_task_id, new.related_task_id)
     is distinct from
     (old.title, old.description, old.notes, old.priority, old.category_id, old.start_date, old.due_date,
      old.estimated_hours, old.recurrence, old.parent_task_id, old.related_task_id) then
    raise exception 'Only an Admin or Section Head can edit task details.' using errcode = '42501';
  end if;
  return new; end $$;
revoke execute on function tasks_guard_details() from public, anon, authenticated;
create trigger trg_tasks_guard before update on tasks for each row execute function tasks_guard_details();

-- Tags are task details.
alter policy ttag_insert on task_tags with check (can_edit_task_details(task_id));
alter policy ttag_delete on task_tags using (can_edit_task_details(task_id));

-- Assignees are task details too: managers assign anyone; staff may only add themselves while publishing their own task.
alter policy assignees_insert on task_assignees with check (
  exists (select 1 from tasks t where t.id = task_assignees.task_id and (can_manage_team(t.team_id)
    or (task_assignees.user_id = (select auth.uid()) and in_team(t.team_id)
        and t.created_by = (select auth.uid()) and t.created_at > now() - interval '2 minutes'))));
alter policy assignees_delete on task_assignees using (
  exists (select 1 from tasks t where t.id = task_assignees.task_id and can_manage_team(t.team_id)));

-- ---------- deleted comments go in the activity log ----------
create or replace function comments_deleted() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_task tasks; v_author text; begin
  select * into v_task from tasks where id = old.task_id;
  if v_task.id is null then return old; end if; -- the whole task is being deleted
  select coalesce(nullif(full_name, ''), email) into v_author from profiles where id = old.created_by;
  perform write_activity(v_task.organization_id, v_task.team_id, v_task.pipeline_id, v_task.id, 'comment_deleted',
    actor_name() || ' deleted ' || case when old.created_by = auth.uid() then 'their comment' else 'a comment by ' || coalesce(v_author, 'a former member') end
      || ' on "' || v_task.title || '".',
    jsonb_build_object('comment_id', old.id, 'author', v_author, 'body', left(old.body, 200)), null);
  return old; end $$;
revoke execute on function comments_deleted() from public, anon, authenticated;
create trigger trg_comments_deleted after delete on task_comments for each row execute function comments_deleted();

-- ---------- progress no longer sticks at 100% ----------
create or replace function tasks_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_kind stage_kind; begin
  select kind into v_kind from pipeline_stages where id = new.stage_id;
  if v_kind = 'done' then
    if tg_op = 'INSERT' or old.completed_at is null then new.completed_at := now(); end if;
    new.progress := 100;
  else
    -- moving a card back out of Done clears the 100% it was given when it went in
    if tg_op = 'UPDATE' and old.completed_at is not null and new.progress = 100 then new.progress := 0; end if;
    new.completed_at := null;
  end if;
  if new.category_id is not null and not exists (select 1 from pipeline_categories where id = new.category_id and pipeline_id = new.pipeline_id) then
    raise exception 'category does not belong to this pipeline'; end if;
  return new; end $$;

-- Cards that already carry a stuck 100% outside a Done stage (progress is only ever set by this trigger).
-- The audit trigger is paused so this clean-up does not write "edited" entries to the activity log.
alter table tasks disable trigger trg_tasks_after;
update tasks t set progress = 0
  from pipeline_stages s
  where s.id = t.stage_id and s.kind <> 'done' and t.progress = 100;
alter table tasks enable trigger trg_tasks_after;
