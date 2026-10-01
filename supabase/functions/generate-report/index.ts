// Edge Function: generate-report. Writes an accomplishment-report narrative with Gemini from the titles and
// descriptions of the tasks in a date range. See handler.ts for the rules and prompt.ts for the prompt.
//
// Secrets (set in Supabase, never in the repo): GEMINI_API_KEY, and optionally GEMINI_MODEL.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { callGemini } from './gemini.ts';
import { handle } from './handler.ts';
import type { Deps, ReportData, TaskDetail } from './handler.ts';

const ORIGINS = [
  'https://px-web-app-marvreals-projects.vercel.app',
  'https://px-web-app.vercel.app',
  'https://px-web-app-git-main-marvreals-projects.vercel.app',
  'http://localhost:4200',
  ...(Deno.env.get('ALLOWED_ORIGINS')?.split(',').map((s) => s.trim()).filter(Boolean) ?? []),
];

/** Newer Supabase projects expose JSON dictionaries of keys; older ones expose a single legacy key. */
function key(dictVar: string, legacyVar: string): string {
  try {
    const dict = JSON.parse(Deno.env.get(dictVar) ?? '{}');
    if (dict?.default) return dict.default as string;
  } catch { /* fall through to the legacy variable */ }
  return Deno.env.get(legacyVar) ?? '';
}

const URL = Deno.env.get('SUPABASE_URL') ?? '';
const PUBLISHABLE = key('SUPABASE_PUBLISHABLE_KEYS', 'SUPABASE_ANON_KEY');
const SECRET = key('SUPABASE_SECRET_KEYS', 'SUPABASE_SERVICE_ROLE_KEY');
const plain = { auth: { persistSession: false, autoRefreshToken: false } };

function ok<T>(res: { data: T | null; error: { message: string } | null }): T {
  if (res.error) throw new Error(res.error.message);
  return res.data as T;
}

Deno.serve((req: Request) => {
  const authHeader = req.headers.get('Authorization') ?? '';
  // Runs as the signed-in user: row-level security applies to everything read through this client.
  const asUser = createClient(URL, PUBLISHABLE, { ...plain, global: { headers: { Authorization: authHeader } } });
  // Service role: only for the signed-in check, the organization switch and the usage log.
  const admin = createClient(URL, SECRET, plain);

  const deps: Deps = {
    now: () => new Date(),
    allowedOrigins: ORIGINS,

    async getUser(header) {
      const token = header.replace(/^Bearer\s+/i, '').trim();
      if (!token) return null;
      const { data, error } = await admin.auth.getUser(token);
      return error || !data.user ? null : { id: data.user.id };
    },
    async getMembership(userId) {
      const row = ok(await admin.from('organization_members').select('organization_id').eq('user_id', userId).eq('is_active', true)
        .order('created_at').limit(1).maybeSingle());
      return row ? { organizationId: (row as { organization_id: string }).organization_id } : null;
    },
    async aiEnabled(orgId) {
      const row = ok(await admin.from('organization_settings').select('ai_reports_enabled').eq('organization_id', orgId).maybeSingle());
      return (row as { ai_reports_enabled?: boolean } | null)?.ai_reports_enabled === true;
    },
    async usage(orgId, userId, since24h, since30d) {
      const count = async (q: PromiseLike<{ count: number | null; error: { message: string } | null }>) => {
        const r = await q; if (r.error) throw new Error(r.error.message); return r.count ?? 0;
      };
      const [userToday, orgMonth] = await Promise.all([
        count(admin.from('ai_report_usage').select('id', { count: 'exact', head: true }).eq('user_id', userId).eq('status', 'ok').gte('created_at', since24h)),
        count(admin.from('ai_report_usage').select('id', { count: 'exact', head: true }).eq('organization_id', orgId).eq('status', 'ok').gte('created_at', since30d)),
      ]);
      return { userToday, orgMonth };
    },
    async logUsage(row) {
      const { error } = await admin.from('ai_report_usage').insert(row);
      if (error) console.error('could not log AI usage:', error.message);
    },

    async canViewReport(orgId, scope, teamId, userId) {
      const { data, error } = await asUser.rpc('can_view_report', { p_org: orgId, p_scope: scope, p_team: teamId, p_user: userId });
      if (error) throw new Error(error.message);
      return data === true;
    },
    async reportSummary(scope, teamId, userId, from, to) {
      return ok(await asUser.rpc('report_summary', { p_scope: scope, p_team: teamId, p_user: userId, p_from: from, p_to: to })) as ReportData;
    },
    async taskDetails(ids) {
      const out: TaskDetail[] = [];
      for (let i = 0; i < ids.length; i += 100) {
        const rows = ok(await asUser.from('tasks').select('id, description, category:pipeline_categories(name)').in('id', ids.slice(i, i + 100))) as unknown as
          { id: string; description: string | null; category: { name: string } | { name: string }[] | null }[];
        for (const r of rows) {
          const c = Array.isArray(r.category) ? r.category[0] : r.category;
          out.push({ id: r.id, description: r.description, category: c?.name ?? null });
        }
      }
      return out;
    },
    async teamNames(ids) {
      const rows = ok(await asUser.from('teams').select('id, name').in('id', ids)) as { id: string; name: string }[];
      return Object.fromEntries(rows.map((r) => [r.id, r.name]));
    },
    async personName(userId) {
      const row = ok(await asUser.from('profiles').select('full_name, email').eq('id', userId).maybeSingle()) as { full_name: string; email: string } | null;
      return row?.full_name || row?.email || '';
    },

    generate: (system, user) => callGemini({ apiKey: Deno.env.get('GEMINI_API_KEY'), model: Deno.env.get('GEMINI_MODEL'), system, user }),
  };
  return handle(req, deps);
});
