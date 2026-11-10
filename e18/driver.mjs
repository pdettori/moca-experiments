// E18 driver: plays a user, injects a crash, times the recovery. See docs/specs/E18-crash-recovery-latency-design.md.
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { turn, retryUntilOk } from './lib/client.mjs';
import { userRetryTime, percentile } from './lib/stats.mjs';
import * as injector from './lib/injector.mjs';

export const CASES = ['W-I', 'W-M', 'S-I', 'S-M'];
const FACTS = ['APPLE', 'BANANA'];
const PROMPT = 'Reply only with OK.';
const MAX_REDOS = 3;

/** Default injector bound to a real compose project. */
export function composeInjector(ctx = injector.makeCtx()) {
  return {
    waitSteady: () => injector.waitSteady(ctx),
    killWorker: (o) => injector.killWorker(ctx, o),
    killSupervisor: () => injector.killSupervisor(ctx),
    ensureSupervisorUp: () => injector.ensureSupervisorUp(ctx),
    restarts: async () => (await injector.readMetrics(ctx)).counters.restarts,
  };
}

/** Reads the session's stored history from Redis; the stub cannot recall facts, so the model's answer is not used. */
export function redisHistory(ctx = injector.makeCtx()) {
  return async (sid) => (await ctx.run(['exec', '-T', 'redis', 'valkey-cli', 'XRANGE', `session:${sid}`, '-', '+'])).stdout;
}

/** One recorded run. Retries internally (up to MAX_REDOS) when a mid-turn kill finds no busy worker. */
export async function runOne({ case: kase, run, baseUrl, inj, readHistory, delayMs = 200, intervalMs = 200 }) {
  const midTurn = kase.endsWith('-M');
  const worker = kase.startsWith('W');
  for (let attempt = 0; attempt <= MAX_REDOS; attempt++) {
    await inj.waitSteady();
    const restartsBefore = await inj.restarts();
    const first = await turn(baseUrl, `Fact 1 is ${FACTS[0]}. ${PROMPT}`);
    const sid = first.sessionId;
    await turn(baseUrl, `Fact 2 is ${FACTS[1]}. ${PROMPT}`, sid);
    const base = [];
    for (let i = 0; i < 3; i++) base.push((await turn(baseUrl, PROMPT, sid)).ms);
    const tBase = percentile(base, 50);

    let killedAt;
    let fraction = null;
    let manualStartMs = null;
    let inflight = null;
    try {
      if (midTurn) {
        fraction = 0.1 + Math.random() * 0.8;
        inflight = turn(baseUrl, PROMPT, sid);
        await new Promise((r) => setTimeout(r, fraction * (delayMs + tBase)));
      }
      ({ killedAt } = worker ? await inj.killWorker({ busy: midTurn }) : await inj.killSupervisor());
    } catch (e) {
      if (e instanceof injector.NoBusyWorker && attempt < MAX_REDOS) continue;
      throw e;
    }
    const inflightResult = inflight ? await inflight : null;
    if (!worker) ({ manualStartMs } = await inj.ensureSupervisorUp());
    const r = await retryUntilOk(baseUrl, PROMPT, sid, { intervalMs });
    const tRecover = performance.now() - killedAt - (manualStartMs ?? 0);
    const tErr = r.firstErrorMs === null ? null : r.firstErrorMs;
    const hist = await readHistory(sid);
    const restartsAfter = await inj.restarts().catch(() => null);
    return {
      case: kase,
      run,
      tBase,
      tErr,
      tRecover,
      tRecoverUser: userRetryTime(tErr, tRecover),
      censored: r.censored,
      contextOk: FACTS.every((f) => hist.includes(f)),
      resendNeeded: midTurn ? !(inflightResult && inflightResult.ok) : false,
      fraction,
      manualStartMs,
      restartsBefore,
      restartsAfter,
    };
  }
  throw new Error(`no usable run for ${kase}`);
}

async function main() {
  const arg = (n, d) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : d; };
  const runs = Number(arg('runs', 10));
  const out = arg('out', 'results/runs.jsonl');
  const cases = arg('cases', CASES.join(',')).split(',');
  const baseUrl = arg('url', 'http://127.0.0.1:8080');
  const delayMs = Number(process.env.STUB_DELAY_MS ?? 200);
  mkdirSync(dirname(out), { recursive: true });
  const ctx = injector.makeCtx();
  const inj = composeInjector(ctx);
  const readHistory = redisHistory(ctx);
  for (let i = 0; i < 5; i++) await turn(baseUrl, PROMPT); // warm-up
  for (const kase of cases) {
    for (let run = 1; run <= runs; run++) {
      const rec = await runOne({ case: kase, run, baseUrl, inj, readHistory, delayMs });
      appendFileSync(out, JSON.stringify(rec) + '\n');
      console.log(`${kase} #${run}: recover ${Math.round(rec.tRecover)} ms${rec.censored ? ' CENSORED' : ''} ctx=${rec.contextOk}`);
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) main();
