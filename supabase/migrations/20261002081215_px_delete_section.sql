-- Deleting a section (a row in `teams`) removes its members, pipelines, tasks and saved reports through foreign-key
-- cascades. Two things need to behave while that happens:
--
-- 1. structure_audit() wrote a "removed X from <section>" entry for every membership the cascade deleted. By then the
--    section row is gone, its name is NULL, the whole description became NULL and the delete failed with a
--    not-null error. Memberships removed by a cascade are now skipped; a normal removal is still logged.
-- 2. One entry is written when an admin deletes a section, so the activity log shows who deleted what. It is skipped
--    when the whole organization is being deleted (the organization row, which the log references, is already gone).
--
-- The notification and activity wording also says "section" instead of "team", matching the interface.

create or replace function structure_audit() returns trigger
language plpgsql security definer set search_path = public as $$
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
    if v_team is null then return coalesce(new, old); end if; -- the section itself is being deleted
    select coalesce(nullif(full_name,''), email) into v_user from profiles where id = coalesce(new.user_id, old.user_id);
    if tg_op = 'INSERT' then
      perform write_activity(new.organization_id, new.team_id, null, null, 'user_added', actor_name() || ' added ' || v_user || ' to ' || v_team || '.');
      perform push_notification(new.organization_id, new.user_id, 'team_added', 'Added to section', v_team, null);
    else
      perform write_activity(old.organization_id, old.team_id, null, null, 'user_removed', actor_name() || ' removed ' || v_user || ' from ' || v_team || '.');
      perform push_notification(old.organization_id, old.user_id, 'team_removed', 'Removed from section', v_team, null);
    end if;
  elsif tg_table_name = 'organization_members' and new.role is distinct from old.role then
    select coalesce(nullif(full_name,''), email) into v_user from profiles where id = new.user_id;
    perform write_activity(new.organization_id, null, null, null, 'role_changed',
      actor_name() || ' changed role of ' || v_user || ' from ' || old.role || ' to ' || new.role || '.', to_jsonb(old.role), to_jsonb(new.role));
  end if;
  return coalesce(new, old); end $$;

create or replace function teams_deleted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from organizations where id = old.organization_id) then
    perform write_activity(old.organization_id, null, null, null, 'team_deleted',
      actor_name() || ' deleted the section "' || old.name || '".', jsonb_build_object('name', old.name), null);
  end if;
  return old; end $$;
revoke execute on function teams_deleted() from public, anon, authenticated;
create trigger trg_teams_deleted after delete on teams for each row execute function teams_deleted();
