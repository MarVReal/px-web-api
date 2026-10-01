-- AI-written report narratives (Gemini, called only from the generate-report Edge Function).

-- 1. Task titles and descriptions leave the system when AI writing is used, so it is an opt-in switch per
--    organization. Admins change it in Organization Settings.
alter table organization_settings add column ai_reports_enabled boolean not null default false;

-- 2. Mark which saved reports were drafted with AI.
alter table monthly_reports
  add column ai_generated boolean not null default false,
  add column ai_model text;

-- 3. One row per AI request. Written only by the Edge Function (service role); it also drives the usage limits.
create table ai_report_usage (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  model text not null,
  status text not null check (status in ('ok', 'error')),
  task_count integer not null default 0,
  input_tokens integer,
  output_tokens integer,
  error text,
  created_at timestamptz not null default now()
);
create index ai_report_usage_user_id_created_at_idx on ai_report_usage (user_id, created_at desc);
create index ai_report_usage_organization_id_created_at_idx on ai_report_usage (organization_id, created_at desc);

alter table ai_report_usage enable row level security;
create policy ai_report_usage_select on ai_report_usage for select to authenticated using (is_org_admin(organization_id));
revoke all on ai_report_usage from anon, authenticated;
grant select on ai_report_usage to authenticated;
