import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readMetrics, waitSteady, killWorker, killSupervisor, ensureSupervisorUp, NoBusyWorker } from '../lib/injector.mjs';

const metrics = (workers, restarts = 0) => JSON.stringify({ workers, counters: { restarts } });

function fakeRun(handler) {
  const calls = [];
  const run = async (cmd) => {
    calls.push(cmd.join(' '));
    return handler(cmd.join(' '), calls.length);
  };
  return { ctx: { run, sleep: async () => {} }, calls };
}

test('readMetrics parses the supervisor admin body', async () => {
  const { ctx } = fakeRun(() => ({ code: 0, stdout: metrics([{ id: 0, pid: 11, inFlight: 0, healthy: true }], 2) }));
  const m = await readMetrics(ctx);
  assert.equal(m.workers[0].pid, 11);
  assert.equal(m.counters.restarts, 2);
});

test('waitSteady rejects when a worker stays unhealthy', async () => {
  const { ctx } = fakeRun(() => ({ code: 0, stdout: metrics([{ id: 0, pid: 1, inFlight: 0, healthy: false }]) }));
  await assert.rejects(waitSteady(ctx, { timeoutMs: 20 }), /steady/);
});

test('waitSteady resolves when all workers are healthy and idle', async () => {
  const { ctx } = fakeRun(() => ({ code: 0, stdout: metrics([{ id: 0, pid: 1, inFlight: 0, healthy: true }]) }));
  await waitSteady(ctx, { timeoutMs: 1000 });
});

test('killWorker busy throws NoBusyWorker when every worker is idle', async () => {
  const { ctx } = fakeRun(() => ({ code: 0, stdout: metrics([{ id: 0, pid: 1, inFlight: 0, healthy: true }]) }));
  await assert.rejects(killWorker(ctx, { busy: true }), NoBusyWorker);
});

test('killWorker busy kills the pid that has inFlight > 0', async () => {
  const { ctx, calls } = fakeRun((c) =>
    c.includes('kill -9') ? { code: 0, stdout: '' } : { code: 0, stdout: metrics([{ id: 0, pid: 1, inFlight: 0, healthy: true }, { id: 1, pid: 22, inFlight: 1, healthy: true }]) },
  );
  const r = await killWorker(ctx, { busy: true });
  assert.equal(r.pid, 22);
  assert.ok(calls.some((c) => c.includes('kill -9 22')));
});

test('killSupervisor issues docker kill on the supervisor service', async () => {
  const { ctx, calls } = fakeRun(() => ({ code: 0, stdout: '' }));
  await killSupervisor(ctx);
  assert.ok(calls.some((c) => /kill .*supervisor/.test(c)));
});

test('ensureSupervisorUp returns null when Compose restarts it by itself', async () => {
  const { ctx } = fakeRun((c) => (c.includes('ps') ? { code: 0, stdout: 'running' } : { code: 0, stdout: '' }));
  const r = await ensureSupervisorUp(ctx, { waitMs: 50 });
  assert.equal(r.manualStartMs, null);
});

test('ensureSupervisorUp starts it and reports the delay when it stays down', async () => {
  let started = false;
  const { ctx } = fakeRun((c) => {
    if (c.includes('up -d')) { started = true; return { code: 0, stdout: '' }; }
    if (c.includes('ps')) return { code: 0, stdout: started ? 'running' : 'exited' };
    return { code: 0, stdout: '' };
  });
  const r = await ensureSupervisorUp(ctx, { waitMs: 20 });
  assert.equal(typeof r.manualStartMs, 'number');
});
