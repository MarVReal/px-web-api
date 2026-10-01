-- One-time cleanup of the earlier prototype schema (migrations 001-011, all tables were empty).
-- Harmless on a fresh database (everything is "if exists").
drop trigger if exists on_auth_user_created on auth.users;
drop table if exists public.notifications, public.task_activity, public.task_attachments, public.task_links,
  public.task_comments, public.task_tags, public.tags, public.tasks, public.pipeline_stages, public.pipelines,
  public.organization_members, public.teams, public.profiles, public.organizations cascade;
drop function if exists public.can_access_task, public.handle_new_organization, public.handle_new_user, public.has_role,
  public.is_admin, public.is_organization_member, public.is_section_head, public.is_task_assignee, public.set_updated_at,
  public.shares_organization_with, public.user_team_id cascade;
