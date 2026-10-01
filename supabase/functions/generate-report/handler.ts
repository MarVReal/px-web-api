// Request handling for generate-report. Everything outside (database, Gemini, clock) is injected through
// `Deps`, so the rules below can be tested with fakes and no network.
import { AiError } from './gemini.ts';
import {
  buildPrompt, fallbackNarrative, fallbackOverview, groupByCategory, parseModelText,
} from './prompt.ts';
import type { Facts, Grouping, Scope, Section, TaskInfo } from './prompt.ts';

export const USAGE_LIMITS = { perUserPerDay: 30, perOrgPerMonth: 500 };

export interface SummaryTask {
  id: string; title: string; assignees: string | null; status: string; stage?: string | null;
  completed_on: string | null; due_date: string | null; delayed: boolean; carried_over: boolean;
}
export interface ReportData {
  total: number; completed: number; in_progress: number; pending: number; carried_over: number; delayed: number;
  completion_rate: number; tasks: SummaryTask[];
}
export interface TaskDetail { id: string; description: string | null; category: string | null; }
export interface UsageRow {
  organization_id: string; user_id: string; model: string; status: 'ok' | 'error';
  task_count: number; input_tokens: number | null; output_tokens: number | null; error: string | null;
}

export interface Deps {
  now(): Date;
  allowedOrigins: string[];
  /** Verifies the caller's token against Supabase Auth. */
  getUser(authHeader: string): Promise<{ id: string } | null>;
  getMembership(userId: string): Promise<{ organizationId: string } | null>;
  aiEnabled(organizationId: string): Promise<boolean>;
  usage(organizationId: string, userId: string, since24h: string, since30d: string): Promise<{ userToday: number; orgMonth: number }>;
  logUsage(row: UsageRow): Promise<void>;
  // The next calls run as the signed-in user, so row-level security limits what they can read.
  canViewReport(organizationId: string, scope: Scope, teamId: string | null, userId: string | null): Promise<boolean>;
  reportSummary(scope: Scope, teamId: string | null, userId: string | null, from: string, to: string): Promise<ReportData>;
  taskDetails(ids: string[]): Promise<TaskDetail[]>;
  teamNames(ids: string[]): Promise<Record<string, string>>;
  personName(userId: string): Promise<string>;
  generate(system: string, user: string): Promise<{ text: string; inputTokens: number | null; outputTokens: number | null; model: string }>;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

interface Body {
  scope: Scope; from: string; to: string; teamId: string | null; teamIds: string[]; userId: string | null;
  groupBy: 'category' | 'none'; categories: string[] | null;
}

function parseBody(raw: unknown): { ok: true; value: Body } | { ok: false; message: string } {
  if (!raw || typeof raw !== 'object') return { ok: false, message: 'Send a JSON body.' };
  const b = raw as Record<string, unknown>;
  const scope = b.scope;
  if (scope !== 'individual' && scope !== 'team' && scope !== 'organization') return { ok: false, message: 'scope must be individual, team or organization.' };
  const from = String(b.from ?? ''), to = String(b.to ?? '');
  if (!DATE.test(from) || !DATE.test(to) || Number.isNaN(Date.parse(from)) || Number.isNaN(Date.parse(to))) return { ok: false, message: 'from and to must be dates like 2026-10-31.' };
  if (to < from) return { ok: false, message: '"to" must be on or after "from".' };
  if ((Date.parse(to) - Date.parse(from)) / 864e5 > 366) return { ok: false, message: 'The date range is limited to one year.' };
  const teamId = typeof b.team_id === 'string' && UUID.test(b.team_id) ? b.team_id : null;
  const userId = typeof b.user_id === 'string' && UUID.test(b.user_id) ? b.user_id : null;
  const teamIds = Array.isArray(b.team_ids) ? b.team_ids.filter((x): x is string => typeof x === 'string' && UUID.test(x)).slice(0, 20) : [];
  if (scope === 'team' && !teamId) return { ok: false, message: 'team_id is required for a team report.' };
  if (scope === 'individual' && !userId) return { ok: false, message: 'user_id is required for an individual report.' };
  if (scope === 'organization' && !teamIds.length) return { ok: false, message: 'team_ids is required for an organization report.' };
  const categories = Array.isArray(b.categories)
    ? b.categories.filter((x): x is string => typeof x === 'string' && !!x.trim()).map((x) => x.trim().slice(0, 60)).slice(0, 20) : null;
  return { ok: true, value: { scope, from, to, teamId, teamIds, userId, groupBy: b.group_by === 'none' ? 'none' : 'category', categories } };
}

const fmtDate = (iso: string) => new Date(iso + 'T00:00:00Z').toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' });

function sumFacts(list: ReportData[]): Facts {
  const total = list.reduce((n, r) => n + r.total, 0), completed = list.reduce((n, r) => n + r.completed, 0);
  return {
    total, completed, inProgress: list.reduce((n, r) => n + r.in_progress, 0), pending: list.reduce((n, r) => n + r.pending, 0),
    carriedOver: list.reduce((n, r) => n + r.carried_over, 0), delayed: list.reduce((n, r) => n + r.delayed, 0),
    completionRate: total ? Math.round((1000 * completed) / total) / 10 : 0,
  };
}

function corsHeaders(origin: string | null, allowed: string[]): Record<string, string> {
  const h: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  };
  if (origin && allowed.includes(origin)) h['Access-Control-Allow-Origin'] = origin;
  return h;
}

export async function handle(req: Request, d: Deps): Promise<Response> {
  const cors = corsHeaders(req.headers.get('Origin'), d.allowedOrigins);
  const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
  const fail = (status: number, error: string, message: string) => reply(status, { error, message });

  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (req.method !== 'POST') return fail(405, 'method_not_allowed', 'Use POST.');

  let orgId = '', userId = '', model = 'unknown', taskCount = 0;
  try {
    const user = await d.getUser(req.headers.get('Authorization') ?? '');
    if (!user) return fail(401, 'not_signed_in', 'Please sign in again.');
    userId = user.id;

    let raw: unknown = null;
    try { const text = await req.text(); raw = text.length <= 20_000 ? JSON.parse(text) : null; } catch { raw = null; }
    const parsed = parseBody(raw);
    if (!parsed.ok) return fail(400, 'bad_request', parsed.message);
    const body = parsed.value;

    const member = await d.getMembership(user.id);
    if (!member) return fail(403, 'no_organization', 'Your account is not part of an organization.');
    orgId = member.organizationId;

    if (!(await d.aiEnabled(orgId))) {
      return fail(403, 'ai_disabled', 'AI report writing is turned off for your organization. An admin can turn it on in Organization Settings.');
    }

    // Who may report on what: same rule the Reports page uses (can_view_report), checked again here.
    if (body.scope === 'organization') {
      if (!(await d.canViewReport(orgId, 'organization', null, null))) return fail(403, 'not_allowed', 'Only admins can write organization reports.');
    } else if (body.scope === 'team') {
      if (!(await d.canViewReport(orgId, 'team', body.teamId, null))) return fail(403, 'not_allowed', 'You cannot write a report for this team.');
    } else if (!(await d.canViewReport(orgId, 'individual', null, body.userId))) {
      return fail(403, 'not_allowed', 'You cannot write a report for this person.');
    }

    const now = d.now();
    const since24h = new Date(now.getTime() - 24 * 3600e3).toISOString(), since30d = new Date(now.getTime() - 30 * 24 * 3600e3).toISOString();
    const used = await d.usage(orgId, user.id, since24h, since30d);
    if (used.userToday >= USAGE_LIMITS.perUserPerDay) return fail(429, 'limit_user', `You have reached the limit of ${USAGE_LIMITS.perUserPerDay} AI reports in 24 hours. Try again later.`);
    if (used.orgMonth >= USAGE_LIMITS.perOrgPerMonth) return fail(429, 'limit_org', `Your organization has reached its limit of ${USAGE_LIMITS.perOrgPerMonth} AI reports for this month.`);

    // Collect the tasks the report is made of (the same ones the numbers on screen are based on).
    const period = `${fmtDate(body.from)} to ${fmtDate(body.to)}`;
    const infos: TaskInfo[] = [];
    const datas: ReportData[] = [];
    let subject = '';
    let sections: Section[] = [];
    let grouping: Grouping = 'none';
    let names: Record<string, string> = {};
    // `team` holds the team id for organization reports, so teams with the same name never merge.
    const toInfo = (t: SummaryTask, team: string): TaskInfo => ({
      id: t.id, title: t.title, description: '', status: t.status, completedOn: t.completed_on, dueDate: t.due_date,
      delayed: !!t.delayed, carriedOver: !!t.carried_over, assignees: t.assignees ?? '', category: '', team,
    });

    if (body.scope === 'organization') {
      names = await d.teamNames(body.teamIds);
      subject = 'the organization';
      for (const id of body.teamIds) {
        const data = await d.reportSummary('team', id, null, body.from, body.to);
        datas.push(data);
        infos.push(...data.tasks.map((t) => toInfo(t, id)));
      }
      grouping = 'team';
    } else if (body.scope === 'team') {
      const data = await d.reportSummary('team', body.teamId, null, body.from, body.to);
      datas.push(data);
      subject = (await d.teamNames([body.teamId!]))[body.teamId!] ?? 'the team';
      infos.push(...data.tasks.map((t) => toInfo(t, subject)));
    } else {
      const data = await d.reportSummary('individual', null, body.userId, body.from, body.to);
      datas.push(data);
      subject = (await d.personName(body.userId!)) || 'the employee';
      infos.push(...data.tasks.map((t) => toInfo(t, '')));
    }

    if (!infos.length) {
      return reply(200, { empty: true, overview: '', sections: [], task_count: 0, omitted: 0, model: null, message: 'There are no tasks in this period, so there is nothing to summarize.' });
    }

    // Add descriptions and categories (read as the signed-in user, so row-level security still applies).
    const details = new Map((await d.taskDetails(infos.map((t) => t.id))).map((x) => [x.id, x]));
    for (const t of infos) {
      const x = details.get(t.id);
      t.description = x?.description ?? '';
      t.category = x?.category ?? '';
    }
    taskCount = infos.length;
    const facts = sumFacts(datas);

    if (body.scope === 'organization') {
      const seen = new Map<string, number>();
      sections = body.teamIds.map((id) => ({ key: id, title: names[id] ?? 'Team', tasks: infos.filter((t) => t.team === id) })).filter((s) => s.tasks.length)
        .map((s) => { const n = (seen.get(s.title.toLowerCase()) ?? 0) + 1; seen.set(s.title.toLowerCase(), n); return n > 1 ? { ...s, title: `${s.title} (${n})` } : s; });
    } else if (body.groupBy === 'category') {
      sections = groupByCategory(infos, body.categories);
      grouping = 'category';
    } else {
      sections = [{ key: 'all', title: 'All tasks', tasks: infos }];
      grouping = 'none';
    }

    const prompt = buildPrompt({ scope: body.scope, subject, period, facts, sections, grouping });
    const out = await d.generate(prompt.system, prompt.user);
    model = out.model;
    const expected = grouping === 'none' ? [] : prompt.sections.map((s) => s.title);
    const parsedText = parseModelText(out.text, expected);

    const result = {
      empty: false,
      overview: parsedText.overview || fallbackOverview(subject, period, facts),
      sections: grouping === 'none' ? [] : prompt.sections.map((s) => ({
        key: s.key, title: s.title,
        narrative: parsedText.sections.find((p) => p.title === s.title)?.narrative || fallbackNarrative(s),
      })),
      task_count: infos.length, omitted: prompt.omitted, model: out.model,
    };
    await d.logUsage({ organization_id: orgId, user_id: userId, model: out.model, status: 'ok', task_count: infos.length, input_tokens: out.inputTokens, output_tokens: out.outputTokens, error: null });
    return reply(200, result);
  } catch (e) {
    if (e instanceof AiError) {
      if (orgId && userId) await d.logUsage({ organization_id: orgId, user_id: userId, model, status: 'error', task_count: taskCount, input_tokens: null, output_tokens: null, error: `${e.code}: ${e.message}`.slice(0, 300) }).catch(() => {});
      return fail(e.status, e.code, e.message);
    }
    console.error('generate-report failed:', e instanceof Error ? e.message : 'unknown error');
    return fail(500, 'server_error', 'Something went wrong while preparing the report. Try again.');
  }
}
