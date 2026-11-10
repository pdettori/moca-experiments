// E18 report: per-case table from results/runs.jsonl and results/baseline.json.
import { readFileSync, writeFileSync } from 'node:fs';
import { summarize, percentile, realModelMix, midTurnWait } from './lib/stats.mjs';

const CASE_ORDER = ['W-I', 'W-M', 'S-I', 'S-M'];
const s = (ms) => (ms / 1000).toFixed(2);

export function buildReport(runs, baseline) {
  const T = baseline.medianMs;
  const rows = [];
  const computed = [];
  for (const c of CASE_ORDER) {
    const rs = runs.filter((r) => r.case === c);
    if (rs.length === 0) continue;
    const sm = summarize(rs);
    const overhead = percentile(rs.map((r) => (r.censored ? 120000 : r.tRecover) - (r.tBase ?? 0)), 50);
    const mix = realModelMix(overhead, T);
    const user = percentile(rs.map((r) => r.tRecoverUser ?? r.tRecover), 50);
    const ctx = rs.filter((r) => r.contextOk).length;
    rows.push(`| ${c} | ${sm.n} | ${sm.censored} | ${s(sm.median)} | ${s(sm.p95)} | ${s(sm.max)} | ${mix.seconds.toFixed(2)} s, ${(mix.share * 100).toFixed(1)}% | ${s(user)} | ${ctx}/${sm.n} |`);
    if (c.endsWith('-M')) {
      const f = percentile(rs.map((r) => r.fraction ?? 0.5), 50);
      const typical = midTurnWait(f * T, sm.median, T);
      const worst = midTurnWait(0.9 * T, sm.median, T);
      computed.push(`| ${c} | ${s(typical)} | ${s(worst)} |`);
    }
  }
  const out = [
    '# E18 results: crash recovery latency',
    '',
    `Real-model baseline: median T = ${s(T)} s, p95 = ${s(baseline.p95Ms)} s.`,
    '',
    '| case | n | censored | recover median (s) | p95 (s) | max (s) | overhead vs T | user-retry median (s) | context ok |',
    '| ---- | - | -------- | ------------------ | ------- | ------- | ------------- | --------------------- | ---------- |',
    ...rows,
  ];
  if (computed.length) {
    out.push(
      '',
      'Mid-turn wait for a real-model user who must resend: `elapsed_at_kill + t_recover + T` (computed, not measured). The kill fraction is the median f for typical and 0.9 for worst case.',
      '',
      '| case | typical (s) | worst (s) |',
      '| ---- | ----------- | --------- |',
      ...computed,
    );
  }
  return out.join('\n') + '\n';
}

function main() {
  const arg = (n) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : undefined; };
  const runs = readFileSync(arg('runs') ?? 'results/runs.jsonl', 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  const baseline = JSON.parse(readFileSync(arg('baseline') ?? 'results/baseline.json', 'utf8'));
  writeFileSync(arg('out') ?? 'RESULTS.md', buildReport(runs, baseline));
}

if (import.meta.url === `file://${process.argv[1]}`) main();
