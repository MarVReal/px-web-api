-- Per-pipeline categories & tags (dropdown values), and links replacing file attachments.

-- ===== per-pipeline categories & tags =====
create table pipeline_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  pipeline_id uuid not null references pipelines(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 40),
  color text not null default 'gray',
  position int not null default 0,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique (pipeline_id, name)
);
create table pipeline_tags (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  pipeline_id uuid not null references pipelines(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 40),
  color text not null default 'blue',
  position int not null default 0,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique (pipeline_id, name)
);
create index on pipeline_categories (pipeline_id);
create index on pipeline_tags (pipeline_id);

alter table tasks add column category_id uuid references pipeline_categories(id) on delete set null;
create table task_tags (
  task_id uuid not null references tasks(id) on delete cascade,
  tag_id uuid not null references pipeline_tags(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  primary key (task_id, tag_id)
);
create index on task_tags (tag_id);

-- backfill from the old free-text columns
insert into pipeline_categories (organization_id, pipeline_id, name)
  select distinct t.organization_id, t.pipeline_id, btrim(t.category) from tasks t where btrim(coalesce(t.category, '')) <> '';
update tasks t set category_id = c.id from pipeline_categories c where c.pipeline_id = t.pipeline_id and c.name = btrim(t.category);
insert into pipeline_tags (organization_id, pipeline_id, name)
  select distinct t.organization_id, t.pipeline_id, btrim(g) from tasks t cross join lateral unnest(t.tags) g where btrim(g) <> '';
insert into task_tags (task_id, tag_id, organization_id)
  select distinct t.id, pt.id, t.organization_id from tasks t cross join lateral unnest(t.tags) g
  join pipeline_tags pt on pt.pipeline_id = t.pipeline_id and pt.name = btrim(g);

-- ===== links replace file attachments =====
create table task_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  task_id uuid not null references tasks(id) on delete cascade,
  title text check (char_length(title) <= 200),
  url text not null check (char_length(url) <= 2048 and url ~* '^https?://[^[:space:]]+$'),
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index on task_links (task_id);

drop policy if exists px_attach_select on storage.objects;
drop policy if exists px_attach_insert on storage.objects;
drop policy if exists px_attach_delete on storage.objects;
drop table task_attachments cascade;
drop function attachments_after();
alter table organization_settings drop column attachments_enabled;

-- ===== triggers =====
create or replace function labels_before() returns trigger language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_pipe uuid; begin
  if tg_table_name in ('pipeline_categories', 'pipeline_tags') then
    select organization_id into v_org from pipelines where id = new.pipeline_id;
    new.created_by := coalesce(new.created_by, auth.uid());
  elsif tg_table_name = 'task_tags' then
    select t.organization_id, t.pipeline_id into v_org, v_pipe from tasks t where t.id = new.task_id;
    if not exists (select 1 from pipeline_tags where id = new.tag_id and pipeline_id = v_pipe) then
      raise exception 'tag does not belong to this task''s pipeline'; end if;
    new.created_by := coalesce(new.created_by, auth.uid());
  elsif tg_table_name = 'task_links' then
    select organization_id into v_org from tasks where id = new.task_id;
    new.created_by := coalesce(new.created_by, auth.uid());
  end if;
  if v_org is null then raise exception 'parent not found'; end if;
  new.organization_id := v_org;
  return new; end $$;
create trigger trg_pcat_org before insert on pipeline_categories for each row execute function labels_before();
create trigger trg_ptag_org before insert on pipeline_tags for each row execute function labels_before();
create trigger trg_ttag_org before insert on task_tags for each row execute function labels_before();
create trigger trg_tlink_org before insert on task_links for each row execute function labels_before();

create or replace function tasks_before_write() returns trigger language plpgsql security definer set search_path = public as $$
declare v_kind stage_kind; begin
  select kind into v_kind from pipeline_stages where id = new.stage_id;
  if v_kind = 'done' then
    if tg_op = 'INSERT' or old.completed_at is null then new.completed_at := now(); end if;
    new.progress := 100;
  else
    new.completed_at := null;
  end if;
  if new.category_id is not null and not exists (select 1 from pipeline_categories where id = new.category_id and pipeline_id = new.pipeline_id) then
    raise exception 'category does not belong to this pipeline'; end if;
  return new; end $$;

create or replace function tasks_after_write() returns trigger language plpgsql security definer set search_path = public as $$
declare v_who text := actor_name(); v_from text; v_to text; v_kind stage_kind; r record; v_old text; v_new text; begin
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
  if new.category_id is distinct from old.category_id then
    select name into v_old from pipeline_categories where id = old.category_id;
    select name into v_new from pipeline_categories where id = new.category_id;
    perform write_activity(new.organization_id, new.team_id, new.pipeline_id, new.id, 'category_changed',
      v_who || ' changed category of "' || new.title || '" from ' || coalesce(v_old,'none') || ' to ' || coalesce(v_new,'none') || '.',
      to_jsonb(v_old), to_jsonb(v_new));
  end if;
  if new.title is distinct from old.title or new.description is distinct from old.description
     or new.notes is distinct from old.notes or new.start_date is distinct from old.start_date
     or new.estimated_hours is distinct from old.estimated_hours or (new.progress is distinct from old.progress and new.stage_id = old.stage_id) then
    perform write_activity(new.organization_id, new.team_id, new.pipeline_id, new.id, 'task_edited',
      v_who || ' edited task "' || new.title || '".',
      jsonb_build_object('title', old.title, 'description', old.description, 'estimated_hours', old.estimated_hours, 'progress', old.progress),
      jsonb_build_object('title', new.title, 'description', new.description, 'estimated_hours', new.estimated_hours, 'progress', new.progress));
  end if;
  return new; end $$;

create or replace function task_extras_audit() returns trigger language plpgsql security definer set search_path = public as $$
declare v_task tasks; v_name text; begin
  select * into v_task from tasks where id = coalesce(new.task_id, old.task_id);
  if v_task.id is null then return coalesce(new, old); end if;
  if tg_table_name = 'task_tags' then
    select name into v_name from pipeline_tags where id = coalesce(new.tag_id, old.tag_id);
    if tg_op = 'INSERT' then
      perform write_activity(v_task.organization_id, v_task.team_id, v_task.pipeline_id, v_task.id, 'tag_added',
        actor_name() || ' added tag #' || v_name || ' to "' || v_task.title || '".', null, to_jsonb(v_name));
    else
      perform write_activity(v_task.organization_id, v_task.team_id, v_task.pipeline_id, v_task.id, 'tag_removed',
        actor_name() || ' removed tag #' || coalesce(v_name,'?') || ' from "' || v_task.title || '".', to_jsonb(v_name), null);
    end if;
  elsif tg_table_name = 'task_links' then
    if tg_op = 'INSERT' then
      perform write_activity(v_task.organization_id, v_task.team_id, v_task.pipeline_id, v_task.id, 'link_added',
        actor_name() || ' added a link to "' || v_task.title || '".', null, to_jsonb(new.url));
    else
      perform write_activity(v_task.organization_id, v_task.team_id, v_task.pipeline_id, v_task.id, 'link_removed',
        actor_name() || ' removed a link from "' || v_task.title || '".', to_jsonb(old.url), null);
    end if;
  end if;
  return coalesce(new, old); end $$;
create trigger trg_ttag_audit after insert or delete on task_tags for each row execute function task_extras_audit();
create trigger trg_tlink_audit after insert or delete on task_links for each row execute function task_extras_audit();

alter table tasks drop column category, drop column tags;

-- ===== RLS =====
alter table pipeline_categories enable row level security;
alter table pipeline_tags enable row level security;
alter table task_tags enable row level security;
alter table task_links enable row level security;
revoke all on pipeline_categories, pipeline_tags, task_tags, task_links from anon;

create policy pcat_select on pipeline_categories for select to authenticated
  using (exists (select 1 from pipelines p where p.id = pipeline_id and can_access_team(p.team_id)));
create policy pcat_write on pipeline_categories for all to authenticated
  using (exists (select 1 from pipelines p where p.id = pipeline_id and can_manage_team(p.team_id)))
  with check (exists (select 1 from pipelines p where p.id = pipeline_id and can_manage_team(p.team_id)));
create policy ptag_select on pipeline_tags for select to authenticated
  using (exists (select 1 from pipelines p where p.id = pipeline_id and can_access_team(p.team_id)));
create policy ptag_write on pipeline_tags for all to authenticated
  using (exists (select 1 from pipelines p where p.id = pipeline_id and can_manage_team(p.team_id)))
  with check (exists (select 1 from pipelines p where p.id = pipeline_id and can_manage_team(p.team_id)));

create policy ttag_select on task_tags for select to authenticated using (can_view_task(task_id));
create policy ttag_insert on task_tags for insert to authenticated with check (can_edit_task(task_id));
create policy ttag_delete on task_tags for delete to authenticated using (can_edit_task(task_id));

create policy tlink_select on task_links for select to authenticated using (can_view_task(task_id));
create policy tlink_insert on task_links for insert to authenticated with check (can_view_task(task_id) and created_by = auth.uid());
create policy tlink_delete on task_links for delete to authenticated
  using (created_by = auth.uid() or exists (select 1 from tasks t where t.id = task_id and can_manage_team(t.team_id)));

revoke execute on function labels_before(), task_extras_audit(), tasks_before_write(), tasks_after_write() from public, anon, authenticated;
