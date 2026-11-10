import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildReport } from '../report.mjs';

const run = (c, r, tRecover, extra = {}) => ({ case: c, run: r, tRecover, tRecoverUser: tRecover + 2000, censored: false, contextOk: true, fraction: null, ...extra });

test('per-case table shows n, the censored count and the share of the real median', () => {
  const md = buildReport(
    [run('W-I', 1, 400), run('W-I', 2, 600), run('W-I', 3, 0, { censored: true })],
    { medianMs: 4000, p95Ms: 6000 },
  );
  assert.match(md, /W-I/);
  assert.match(md, /\| W-I \| 3 \| 1 \|/);
  assert.match(md, /\d+\.\d%/);
});

test('mid-turn cases carry the computed-not-measured row', () => {
  const md = buildReport([run('W-M', 1, 500, { fraction: 0.5 })], { medianMs: 4000, p95Ms: 6000 });
  assert.match(md, /computed, not measured/);
});

test('idle cases do not carry the computed row', () => {
  const md = buildReport([run('S-I', 1, 5000)], { medianMs: 4000, p95Ms: 6000 });
  assert.doesNotMatch(md, /computed, not measured/);
});
