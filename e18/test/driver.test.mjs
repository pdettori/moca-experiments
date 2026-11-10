import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { runOne } from '../driver.mjs';

// A fake supervisor: fails for `downMs` after `kill()`, then serves turns.
function fakeWorld(downMs) {
  let downUntil = 0;
  const s = http.createServer((q, r) => {
    if (performance.now() < downUntil) return r.writeHead(503).end('down');
    r.writeHead(200, { 'content-type': 'application/json' }).end('{"sessionId":"sid-1"}');
  });
  return new Promise((res) =>
    s.listen(0, '127.0.0.1', () =>
      res({ s, url: `http://127.0.0.1:${s.address().port}`, kill: () => { downUntil = performance.now() + downMs; return { killedAt: performance.now(), pid: 7 }; } }),
    ),
  );
}

const noRedis = async () => 'APPLE BANANA';

test('W-I: records tRecover near the outage and context_ok', async () => {
  const w = await fakeWorld(500);
  const inj = { waitSteady: async () => {}, killWorker: async () => w.kill(), killSupervisor: async () => w.kill(), ensureSupervisorUp: async () => ({ manualStartMs: null }), restarts: async () => 0 };
  const rec = await runOne({ case: 'W-I', run: 1, baseUrl: w.url, inj, readHistory: noRedis, delayMs: 0, intervalMs: 50 });
  w.s.close();
  assert.equal(rec.case, 'W-I');
  assert.equal(rec.censored, false);
  assert.ok(rec.tRecover >= 450 && rec.tRecover < 2000, `tRecover ${rec.tRecover}`);
  assert.equal(rec.contextOk, true);
  assert.equal(rec.resendNeeded, false);
  assert.ok(rec.tRecoverUser >= rec.tRecover);
});

test('context_ok is false when the history lacks a fact', async () => {
  const w = await fakeWorld(0);
  const inj = { waitSteady: async () => {}, killWorker: async () => w.kill(), killSupervisor: async () => w.kill(), ensureSupervisorUp: async () => ({ manualStartMs: null }), restarts: async () => 0 };
  const rec = await runOne({ case: 'W-I', run: 1, baseUrl: w.url, inj, readHistory: async () => 'APPLE only', delayMs: 0, intervalMs: 50 });
  w.s.close();
  assert.equal(rec.contextOk, false);
});

test('a mid-turn run whose kill finds no busy worker is retried, not recorded as an idle run', async () => {
  const w = await fakeWorld(100);
  let calls = 0;
  const { NoBusyWorker } = await import('../lib/injector.mjs');
  const inj = {
    waitSteady: async () => {},
    killWorker: async () => { calls += 1; if (calls === 1) throw new NoBusyWorker('idle'); return w.kill(); },
    killSupervisor: async () => w.kill(), ensureSupervisorUp: async () => ({ manualStartMs: null }), restarts: async () => 0,
  };
  const rec = await runOne({ case: 'W-M', run: 1, baseUrl: w.url, inj, readHistory: noRedis, delayMs: 0, intervalMs: 50 });
  w.s.close();
  assert.equal(calls, 2);
  assert.equal(rec.case, 'W-M');
});

test('S-I: a manual supervisor start is excluded from tRecover and reported separately', async () => {
  const w = await fakeWorld(0);
  const inj = {
    waitSteady: async () => {}, killWorker: async () => w.kill(), killSupervisor: async () => w.kill(),
    ensureSupervisorUp: async () => { await new Promise((r) => setTimeout(r, 400)); return { manualStartMs: 400 }; },
    restarts: async () => 0,
  };
  const rec = await runOne({ case: 'S-I', run: 1, baseUrl: w.url, inj, readHistory: noRedis, delayMs: 0, intervalMs: 50 });
  w.s.close();
  assert.equal(rec.manualStartMs, 400);
  assert.ok(rec.tRecover < 300, `tRecover ${rec.tRecover}`);
});
