-- Internal/trigger functions must not be callable through the REST API (e.g. forging audit rows).
revoke execute on function actor_name(), write_activity(uuid,uuid,uuid,uuid,text,text,jsonb,jsonb),
  push_notification(uuid,uuid,text,text,text,uuid), generate_due_notifications(),
  tasks_before_write(), tasks_after_write(), assignees_after(), comments_after(), attachments_after(), structure_audit(),
  derive_org_id(), lock_scope_columns(), stamp_actor(), handle_new_user(), guard_last_admin(), set_updated_at()
  from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon;
