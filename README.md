# px-web-api — Project-X backend (Supabase)

No server code: Postgres + Auth + RLS + Realtime + Storage on Supabase. This repo is the source of truth for the database.

## Layout
- `supabase/migrations/` — timestamped migrations; filenames match the versions recorded on the hosted project (`supabase_migrations.schema_migrations`)
- `supabase/seed.sql` — **dev only** demo org + users (`admin@demo.com`, `sectionhead@demo.com`, `staff1@demo.com`, `staff2@demo.com`, password `Demo1234!`). Never run against production.
- `supabase/config.toml` — Supabase CLI config (Postgres 17)

## Security model
- Org membership is always derived from `auth.uid()`; child rows get `organization_id` from their parent via triggers (client values are ignored).
- `task_activity_logs` has no write grants for clients; rows come from security-definer triggers. Internal functions are not callable via the API.
- The frontend only ever uses the publishable key.

## Workflow
```bash
supabase login
supabase link --project-ref qpezkonaaanwlvwzqltb
supabase migration new my_change     # create a new timestamped file
supabase db push                     # apply pending migrations to the hosted project
```
Rules: never edit a migration that has been applied — add a new one. Merge database changes before the frontend change that needs them.

Due/overdue notifications: schedule `select generate_due_notifications();` with pg_cron (not scheduled yet).
