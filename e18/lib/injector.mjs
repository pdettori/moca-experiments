import { spawn } from 'node:child_process';

export class NoBusyWorker extends Error {}

const sleepReal = (ms) => new Promise((r) => setTimeout(r, ms));

/** Default runner: `docker compose` for the e18 project; E18_COMPOSE_FILES is a space-separated -f list. */
export function dockerRunner({ project = 'e18', files = process.env.E18_COMPOSE_FILES ?? '', dir = process.env.E18_PROJECT_DIR } = {}) {
  const f = files.split(/\s+/).filter(Boolean).flatMap((x) => ['-f', x]);
  const d = dir ? ['--project-directory', dir, '--env-file', `${dir}/.env`] : [];
  return (cmd) =>
    new Promise((resolve) => {
      const p = spawn('docker', ['compose', '-p', project, ...d, ...f, ...cmd]);
      let stdout = '';
      p.stdout.on('data', (d) => (stdout += d));
      p.on('close', (code) => resolve({ code, stdout }));
      p.on('error', () => resolve({ code: -1, stdout: '' }));
    });
}

export function makeCtx(run = dockerRunner()) {
  return { run, sleep: sleepReal };
}

const FETCH_METRICS = ['exec', '-T', 'supervisor', 'node', '-e',
  "fetch('http://127.0.0.1:8081/metrics').then(r=>r.text()).then(t=>process.stdout.write(t))"];

export async function readMetrics(ctx) {
  const r = await ctx.run(FETCH_METRICS);
  if (r.code !== 0) throw new Error(`metrics unavailable (exit ${r.code})`);
  return JSON.parse(r.stdout);
}

export async function waitSteady(ctx, { timeoutMs = 60000 } = {}) {
  const deadline = performance.now() + timeoutMs;
  for (;;) {
    try {
      const m = await readMetrics(ctx);
      if (m.workers.length > 0 && m.workers.every((w) => w.healthy && w.inFlight === 0)) return;
    } catch {}
    if (performance.now() > deadline) throw new Error('pool never reached steady state');
    await ctx.sleep(250);
  }
}

export async function killWorker(ctx, { busy }) {
  const m = await readMetrics(ctx);
  const w = busy ? m.workers.find((x) => x.inFlight > 0) : m.workers.find((x) => x.healthy);
  if (!w) throw busy ? new NoBusyWorker('no worker has a turn in flight') : new Error('no healthy worker');
  const killedAt = performance.now();
  await ctx.run(['exec', '-T', 'supervisor', 'kill', '-9', String(w.pid)]);
  return { pid: w.pid, killedAt };
}

export async function killSupervisor(ctx) {
  const killedAt = performance.now();
  await ctx.run(['kill', 'supervisor']);
  return { killedAt };
}

/** Waits for Compose's restart policy; if the container is still down after waitMs, starts it. */
export async function ensureSupervisorUp(ctx, { waitMs = 30000 } = {}) {
  const deadline = performance.now() + waitMs;
  const up = async () => /running|supervisor/.test((await ctx.run(['ps', '--status', 'running', '--services', 'supervisor'])).stdout);
  while (performance.now() < deadline) {
    if (await up()) return { manualStartMs: null };
    await ctx.sleep(250);
  }
  const t0 = performance.now();
  await ctx.run(['up', '-d', 'supervisor']);
  while (!(await up())) await ctx.sleep(250);
  return { manualStartMs: performance.now() - t0 };
}
