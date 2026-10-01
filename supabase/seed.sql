-- DEVELOPMENT ONLY seed data. NEVER run this against a hosted or production project.
-- This repository is public and the password below is public: any hosted project that contains these
-- accounts can be signed into by anyone. They were removed from the production project on 2026-10-02.
-- Local logins (password for all: Demo1234!): admin@demo.com, sectionhead@demo.com, staff1@demo.com, staff2@demo.com

do $$
declare
  pw text := crypt('Demo1234!', gen_salt('bf'));
  u_admin uuid := '00000000-0000-0000-0000-0000000000a1';
  u_head  uuid := '00000000-0000-0000-0000-0000000000a2';
  u_s1    uuid := '00000000-0000-0000-0000-0000000000a3';
  u_s2    uuid := '00000000-0000-0000-0000-0000000000a4';
  v_org uuid := '00000000-0000-0000-0000-0000000000b1';
  d_ops uuid := gen_random_uuid(); d_tech uuid := gen_random_uuid();
  t_ops uuid := gen_random_uuid(); t_data uuid := gen_random_uuid(); t_dev uuid := gen_random_uuid();
  v_pipe uuid := gen_random_uuid();
  s_backlog uuid := gen_random_uuid(); s_plan uuid := gen_random_uuid(); s_prog uuid := gen_random_uuid();
  s_review uuid := gen_random_uuid(); s_done uuid := gen_random_uuid();
  rec record;
begin
  for rec in select * from (values
    (u_admin,'admin@demo.com','Alex Admin'), (u_head,'sectionhead@demo.com','Sam Head'),
    (u_s1,'staff1@demo.com','Mar Villareal'), (u_s2,'staff2@demo.com','Juan Dela Cruz')) as x(id,email,name) loop
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change, email_change_token_new)
    values ('00000000-0000-0000-0000-000000000000', rec.id, 'authenticated', 'authenticated', rec.email, pw, now(),
      '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', rec.name), now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), rec.id, rec.id::text, 'email',
      jsonb_build_object('sub', rec.id::text, 'email', rec.email, 'email_verified', true), now(), now(), now());
  end loop;

  insert into organizations (id, name, description, industry, timezone, created_by)
    values (v_org, 'Demo Organization', 'Demo tenant for development', 'Public Service', 'Asia/Manila', u_admin);
  insert into organization_settings (organization_id) values (v_org);
  insert into organization_members (organization_id, user_id, role, position_title) values
    (v_org, u_admin, 'admin', 'Director'), (v_org, u_head, 'section_head', 'Section Chief'),
    (v_org, u_s1, 'staff', 'Data Analyst'), (v_org, u_s2, 'staff', 'Developer');

  insert into divisions (id, organization_id, name) values (d_ops, v_org, 'Operations Division'), (d_tech, v_org, 'Technology Division');
  insert into teams (id, organization_id, division_id, name) values
    (t_ops, v_org, d_ops, 'Operations Team'), (t_data, v_org, d_tech, 'Data Team'), (t_dev, v_org, d_tech, 'Development Team');
  insert into team_members (team_id, user_id, is_head) values
    (t_data, u_head, true), (t_data, u_s1, false), (t_data, u_s2, false), (t_dev, u_s2, false);

  insert into pipelines (id, team_id, name, description) values (v_pipe, t_data, 'Project Implementation', 'Monthly data quality activities');
  insert into pipeline_stages (id, pipeline_id, name, position, kind) values
    (s_backlog, v_pipe, 'Backlog', 0, 'backlog'), (s_plan, v_pipe, 'Planning', 1, 'active'),
    (s_prog, v_pipe, 'In Progress', 2, 'active'), (s_review, v_pipe, 'For Review', 3, 'review'), (s_done, v_pipe, 'Completed', 4, 'done');

  insert into pipeline_categories (pipeline_id, name, color, position) values
    (v_pipe, 'Documentation', '#667085', 0), (v_pipe, 'Planning', '#2e90fa', 1), (v_pipe, 'Data Quality', '#12b76a', 2), (v_pipe, 'Reporting', '#f79009', 3), (v_pipe, 'Automation', '#15b79e', 4);
  insert into pipeline_tags (pipeline_id, name, color, position) values
    (v_pipe, 'q4', '#2e90fa', 0), (v_pipe, 'compliance', '#7a5af8', 1), (v_pipe, 'blocked', '#f04438', 2);

  insert into tasks (pipeline_id, stage_id, title, description, priority, category_id, due_date, position, created_by) values
    (v_pipe, s_backlog, 'Draft data sharing agreement', 'Prepare template for partner agencies', 'low', (select id from pipeline_categories where pipeline_id = v_pipe and name = 'Documentation'), current_date + 14, 1, u_head),
    (v_pipe, s_plan, 'Plan Q4 data audit', 'Scope and schedule', 'medium', (select id from pipeline_categories where pipeline_id = v_pipe and name = 'Planning'), current_date + 7, 1, u_head),
    (v_pipe, s_prog, 'Validate Beneficiary Masterlist', 'Cross-check against source registry', 'high', (select id from pipeline_categories where pipeline_id = v_pipe and name = 'Data Quality'), current_date + 3, 1, u_head),
    (v_pipe, s_prog, 'Clean duplicate records', null, 'medium', (select id from pipeline_categories where pipeline_id = v_pipe and name = 'Data Quality'), current_date - 2, 2, u_head),
    (v_pipe, s_review, 'Monthly dashboard refresh', 'Refresh KPIs', 'medium', (select id from pipeline_categories where pipeline_id = v_pipe and name = 'Reporting'), current_date + 1, 1, u_head),
    (v_pipe, s_done, 'Set up validation scripts', null, 'low', (select id from pipeline_categories where pipeline_id = v_pipe and name = 'Automation'), current_date - 5, 1, u_head);

  insert into task_assignees (task_id, user_id, is_primary)
    select id, u_s1, true from tasks where title in ('Validate Beneficiary Masterlist', 'Monthly dashboard refresh', 'Set up validation scripts');
  insert into task_assignees (task_id, user_id, is_primary)
    select id, u_s2, true from tasks where title in ('Clean duplicate records', 'Plan Q4 data audit');
end $$;
