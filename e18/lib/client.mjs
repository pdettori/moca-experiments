/** One turn against the supervisor. Never throws: failures come back as ok:false. */
export async function turn(baseUrl, prompt, sessionId, { timeoutMs = 5000 } = {}) {
  const t0 = performance.now();
  try {
    const res = await fetch(`${baseUrl}/turn`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(sessionId ? { prompt, sessionId } : { prompt }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const text = await res.text();
    const ms = performance.now() - t0;
    if (!res.ok) return { ok: false, ms, status: res.status, error: text.slice(0, 200) };
    let j = {};
    try {
      j = JSON.parse(text);
    } catch {
      return { ok: false, ms, status: res.status, error: 'non-JSON body' };
    }
    return { ok: true, ms, sessionId: j.sessionId, status: res.status };
  } catch (e) {
    return { ok: false, ms: performance.now() - t0, error: String(e?.cause?.code ?? e?.name ?? e) };
  }
}

/** Resends the same turn until one succeeds; times are from this call's start (the kill instant). */
export async function retryUntilOk(baseUrl, prompt, sessionId, { intervalMs = 200, capMs = 120000, timeoutMs = 5000 } = {}) {
  const t0 = performance.now();
  let firstErrorMs = null;
  let attempts = 0;
  while (performance.now() - t0 < capMs) {
    attempts += 1;
    const r = await turn(baseUrl, prompt, sessionId, { timeoutMs });
    if (r.ok) return { firstErrorMs, recoverMs: performance.now() - t0, censored: false, attempts };
    if (firstErrorMs === null) firstErrorMs = performance.now() - t0;
    await new Promise((res) => setTimeout(res, intervalMs));
  }
  return { firstErrorMs, recoverMs: capMs, censored: true, attempts };
}
