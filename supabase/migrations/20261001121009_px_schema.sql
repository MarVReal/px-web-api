-- Project-X core schema. Multi-tenant: every org-owned table carries organization_id.
create extension if not exists pgcrypto;

create type member_role as enum ('admin', 'section_head', 'staff');
create type task_priority as enum ('low', 'medium', 'high', 'urgent');
create type invitation_status as enum ('pending', 'accepted', 'revoked', 'expired');
create type report_scope as enum ('individual', 'team', 'organization');
create type report_status as enum ('draft', 'final');
create type subscription_plan as enum ('free', 'pro', 'business', 'enterprise');
create type subscription_status as enum ('trialing', 'active', 'past_due', 'canceled');
create type stage_kind as enum ('backlog', 'active', 'review', 'done');

create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ---------- identity ----------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text not null default '',
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 120),
  slug text unique,
  logo_url text,
  description text,
  industry text,
  timezone text not null default 'UTC',
  reporting_period text not null default 'monthly',
  plan subscription_plan not null default 'free',
  subscription_status subscription_status not null default 'trialing',
  billing_customer_id text,           -- future Stripe
  limits jsonb not null default '{}', -- future plan limits
  created_by uuid references profiles(id),
  updated_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table organization_settings (
  organization_id uuid primary key references organizations(id) on delete cascade,
  section_heads_can_create_pipelines boolean not null default true,
  attachments_enabled boolean not null default true,
  settings jsonb not null default '{}',
  updated_by uuid references profiles(id),
  updated_at timestamptz not null default now()
);

create table organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  role member_role not null default 'staff',
  position_title text,
  is_active boolean not null default true,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, user_id)
);
create index on organization_members (user_id);

create table divisions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  description text,
  created_by uuid references profiles(id),
  updated_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, name)
);

create table teams (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  division_id uuid references divisions(id) on delete set null,
  name text not null,
  description text,
  is_archived boolean not null default false,
  created_by uuid references profiles(id),
  updated_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, name)
);
create index on teams (organization_id);

create table team_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  team_id uuid not null references teams(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  is_head boolean not null default false,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  unique (team_id, user_id)
);
create index on team_members (user_id);
create index on team_members (organization_id);

-- ---------- permissions (system roles; custom roles can be added later) ----------
create table permissions (
  key text primary key,
  description text
);
create table role_permissions (
  role member_role not null,
  permission_key text not null references permissions(key) on delete cascade,
  primary key (role, permission_key)
);

create table invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  email text not null,
  role member_role not null default 'staff',
  team_id uuid references teams(id) on delete set null,
  division_id uuid references divisions(id) on delete set null,
  position_title text,
  token uuid not null unique default gen_random_uuid(),
  status invitation_status not null default 'pending',
  expires_at timestamptz not null default now() + interval '7 days',
  accepted_by uuid references profiles(id),
  accepted_at timestamptz,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create unique index invitations_one_pending on invitations (organization_id, lower(email)) where status = 'pending';

-- ---------- pipelines & tasks ----------
create table pipelines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  team_id uuid not null references teams(id) on delete cascade,
  name text not null,
  description text,
  is_archived boolean not null default false,
  created_by uuid references profiles(id),
  updated_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on pipelines (organization_id, team_id);

create table pipeline_stages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  pipeline_id uuid not null references pipelines(id) on delete cascade,
  name text not null,
  position int not null default 0,
  kind stage_kind not null default 'active',  -- 'done' marks completion for reports
  color text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on pipeline_stages (pipeline_id, position);

create table tasks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  team_id uuid not null references teams(id) on delete cascade,
  pipeline_id uuid not null references pipelines(id) on delete cascade,
  stage_id uuid not null references pipeline_stages(id),
  parent_task_id uuid references tasks(id) on delete cascade,
  related_task_id uuid references tasks(id) on delete set null,
  title text not null check (char_length(title) between 1 and 300),
  description text,
  notes text,
  priority task_priority not null default 'medium',
  category text,
  tags text[] not null default '{}',
  start_date date,
  due_date date,
  estimated_hours numeric(8,2),
  progress int not null default 0 check (progress between 0 and 100),
  position double precision not null default 0,
  recurrence jsonb,
  completed_at timestamptz,
  created_by uuid references profiles(id),
  updated_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on tasks (organization_id);
create index on tasks (pipeline_id, stage_id, position);
create index on tasks (team_id);
create index on tasks (due_date);
create index on tasks (completed_at);
create index tasks_title_search on tasks using gin (to_tsvector('simple', title));

create table task_assignees (
  task_id uuid not null references tasks(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  is_primary boolean not null default false,
  assigned_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  primary key (task_id, user_id)
);
create index on task_assignees (user_id);

create table task_comments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  task_id uuid not null references tasks(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 5000),
  mentions uuid[] not null default '{}',
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on task_comments (task_id, created_at);

create table task_attachments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  task_id uuid not null references tasks(id) on delete cascade,
  file_name text not null,
  storage_path text not null,
  mime_type text,
  size_bytes bigint,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index on task_attachments (task_id);

create table task_activity_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id uuid references profiles(id),
  team_id uuid references teams(id) on delete set null,
  pipeline_id uuid references pipelines(id) on delete set null,
  task_id uuid references tasks(id) on delete set null,
  activity_type text not null,
  description text not null,
  previous_value jsonb,
  new_value jsonb,
  created_at timestamptz not null default now()
);
create index on task_activity_logs (organization_id, created_at desc);
create index on task_activity_logs (task_id, created_at);
create index on task_activity_logs (user_id, created_at);
create index on task_activity_logs (team_id, created_at);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  type text not null,
  title text not null,
  body text,
  task_id uuid references tasks(id) on delete cascade,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
create index on notifications (user_id, is_read, created_at desc);

-- ---------- reports ----------
create table monthly_reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  scope report_scope not null,
  team_id uuid references teams(id) on delete cascade,
  subject_user_id uuid references profiles(id) on delete cascade,
  period_start date not null,           -- first day of month
  status report_status not null default 'draft',
  narrative text,
  summary jsonb not null default '{}',
  created_by uuid references profiles(id),
  updated_by uuid references profiles(id),
  finalized_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on monthly_reports (organization_id, period_start);

create table monthly_report_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  report_id uuid not null references monthly_reports(id) on delete cascade,
  task_id uuid references tasks(id) on delete set null,
  child_report_id uuid references monthly_reports(id) on delete set null, -- org report compiles team reports
  title text not null,
  assignee_name text,
  status text,
  completed_on date,
  remarks text,
  position int not null default 0
);
create index on monthly_report_items (report_id);

-- updated_at triggers
do $$ declare t text; begin
  foreach t in array array['profiles','organizations','organization_members','divisions','teams','pipelines',
    'pipeline_stages','tasks','task_comments','monthly_reports'] loop
    execute format('create trigger trg_%I_updated before update on %I for each row execute function set_updated_at()', t, t);
  end loop; end $$;
