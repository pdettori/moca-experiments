import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { turn, retryUntilOk } from '../lib/client.mjs';

function serve(handler) {
  const s = http.createServer(handler);
  return new Promise((res) => s.listen(0, '127.0.0.1', () => res({ s, url: `http://127.0.0.1:${s.address().port}` })));
}

test('turn returns ok:false with the status on a 503 and does not throw', async () => {
  const { s, url } = await serve((q, r) => r.writeHead(503).end('busy'));
  const r = await turn(url, 'hi');
  s.close();
  assert.equal(r.ok, false);
  assert.equal(r.status, 503);
});

test('turn returns ok:false with an error on connection refused', async () => {
  const r = await turn('http://127.0.0.1:1', 'hi');
  assert.equal(r.ok, false);
  assert.ok(r.error);
});

test('turn returns the sessionId on success', async () => {
  const { s, url } = await serve((q, r) => r.writeHead(200, { 'content-type': 'application/json' }).end('{"sessionId":"abc","response":"OK"}'));
  const r = await turn(url, 'hi');
  s.close();
  assert.equal(r.ok, true);
  assert.equal(r.sessionId, 'abc');
});

test('retryUntilOk reports the first error and the recovery time', async () => {
  const t0 = performance.now();
  const { s, url } = await serve((q, r) => {
    if (performance.now() - t0 < 600) r.writeHead(503).end('x');
    else r.writeHead(200, { 'content-type': 'application/json' }).end('{"sessionId":"abc"}');
  });
  const r = await retryUntilOk(url, 'hi', 'abc', { intervalMs: 50, capMs: 5000 });
  s.close();
  assert.equal(r.censored, false);
  assert.ok(r.recoverMs >= 550, `recoverMs ${r.recoverMs}`);
  assert.ok(r.firstErrorMs !== null && r.firstErrorMs < 200);
});

test('retryUntilOk is censored when the server never recovers', async () => {
  const { s, url } = await serve((q, r) => r.writeHead(503).end('x'));
  const r = await retryUntilOk(url, 'hi', 'abc', { intervalMs: 50, capMs: 400 });
  s.close();
  assert.equal(r.censored, true);
});
