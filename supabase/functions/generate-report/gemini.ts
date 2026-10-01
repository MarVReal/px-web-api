// Calls the Gemini API (generateContent). The API key is passed in by the caller and never logged or returned.

export const DEFAULT_MODEL = 'gemini-3.5-flash-lite';

export class AiError extends Error {
  code: string;
  status: number;
  constructor(code: string, message: string, status = 502) {
    super(message);
    this.name = 'AiError';
    this.code = code;
    this.status = status;
  }
}

export interface GeminiResult { text: string; inputTokens: number | null; outputTokens: number | null; model: string; }

interface GeminiOptions {
  apiKey: string | undefined;
  model: string | undefined;
  system: string;
  user: string;
  fetchFn?: typeof fetch;
  timeoutMs?: number;
}

/** Google's error text, shortened and with the key (if it ever appears) removed. */
function scrub(text: string, key: string): string {
  return text.split(key).join('[hidden]').replace(/\s+/g, ' ').trim().slice(0, 300);
}

export async function callGemini(o: GeminiOptions): Promise<GeminiResult> {
  const key = o.apiKey?.trim();
  if (!key) throw new AiError('not_configured', 'AI report writing is not set up yet: the GEMINI_API_KEY secret is missing.', 503);
  const model = (o.model?.trim() || DEFAULT_MODEL).replace(/^models\//, '');
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`;

  let res: Response;
  try {
    res = await (o.fetchFn ?? fetch)(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: o.system }] },
        contents: [{ role: 'user', parts: [{ text: o.user }] }],
        generationConfig: { temperature: 0.3, maxOutputTokens: 4096 },
      }),
      signal: AbortSignal.timeout(o.timeoutMs ?? 50_000),
    });
  } catch (e) {
    const timedOut = e instanceof Error && (e.name === 'TimeoutError' || e.name === 'AbortError');
    throw timedOut
      ? new AiError('timeout', 'The AI service took too long to answer. Try again.', 504)
      : new AiError('unreachable', 'Could not reach the AI service. Try again in a moment.', 502);
  }

  const raw = await res.text();
  let data: any = null; // eslint-disable-line @typescript-eslint/no-explicit-any
  try { data = JSON.parse(raw); } catch { /* not JSON */ }

  if (!res.ok) {
    const detail = scrub(String(data?.error?.message ?? raw), key);
    if (res.status === 429) throw new AiError('rate_limited', 'The AI service is busy right now. Wait a minute and try again.', 429);
    if (res.status === 404) throw new AiError('model_not_found', `The AI model "${model}" was not found. Check the GEMINI_MODEL secret. ${detail}`, 502);
    if (res.status >= 500) throw new AiError('unavailable', 'The AI service is temporarily unavailable. Try again shortly.', 503);
    throw new AiError('rejected', `The AI service rejected the request (${res.status}). ${detail}`, 502);
  }

  const parts: { text?: string; thought?: boolean }[] = data?.candidates?.[0]?.content?.parts ?? [];
  const text = parts.filter((p) => !p.thought && typeof p.text === 'string').map((p) => p.text).join('');
  if (!text.trim()) {
    const blocked = data?.promptFeedback?.blockReason;
    throw blocked
      ? new AiError('blocked', `The AI service declined to write this report (${blocked}).`, 502)
      : new AiError('empty', 'The AI service returned no text. Try again.', 502);
  }
  return {
    text,
    inputTokens: data?.usageMetadata?.promptTokenCount ?? null,
    outputTokens: data?.usageMetadata?.candidatesTokenCount ?? null,
    model,
  };
}
