# px-web-api — Project-X backend (Supabase)

No server code: Postgres + Auth + RLS + Realtime + Storage on Supabase. This repo is the source of truth for the database.

## Layout
- `supabase/migrations/` — timestamped migrations; filenames match the versions recorded on the hosted project (`supabase_migrations.schema_migrations`)
- `supabase/seed.sql` — **dev only** demo org + users (`admin@demo.com`, `sectionhead@demo.com`, `staff1@demo.com`, `staff2@demo.com`, password `Demo1234!`). Never run against production.
- `supabase/config.toml` — Supabase CLI config (Postgres 17)
- `supabase/functions/generate-report/` — Edge Function that writes report narratives with Gemini (see below)
- `supabase/tests/` — tests that run with plain Node, no database or network

## AI-written reports (`generate-report`)
The Reports page calls this function; the browser never sees the Gemini key.
- **Secrets** (Supabase dashboard → Edge Functions → Secrets, or `supabase secrets set`): `GEMINI_API_KEY` (required) and `GEMINI_MODEL` (optional, defaults to `gemini-3.5-flash-lite`). Never put these in the repo, in `environment.ts` or in a Vercel variable: this repository and the app bundle are public.
- **What it reads:** the title and description of each task in the report period, read as the signed-in user so row-level security applies. Nothing else is sent to Google.
- **Switches and limits:** `organization_settings.ai_reports_enabled` (off by default, admins turn it on in Organization Settings), 30 reports per user per 24 hours and 500 per organization per 30 days. Every request is logged in `ai_report_usage` (admins can read it).
- **Tests:** `node --experimental-strip-types --no-warnings --test supabase/tests/generate_report.test.ts`
- **Deploy:** `supabase functions deploy generate-report` (keeps `verify_jwt = true`).

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
