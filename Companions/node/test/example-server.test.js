'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const path = require('node:path');
const { createExampleServer, parseArgs } = require('../example-server');

const TOKEN = 'example-local-token-0123456789';
const AUTH = { Authorization: `Bearer ${TOKEN}` };

async function start(t, options = {}) {
  const example = createExampleServer({ token: TOKEN, quiet: true, ...options });
  const port = await example.listen(0);
  t.after(() => example.close());
  const base = `http://127.0.0.1:${port}`;
  const get = async (p) => {
    const res = await fetch(`${base}${p}`, { headers: AUTH });
    return { status: res.status, body: await res.json() };
  };
  const post = async (p) => {
    const res = await fetch(`${base}${p}`, { method: 'POST' });
    return { status: res.status, body: await res.json() };
  };
  return { example, base, get, post };
}

test('example server starts with leads=12 and signups=9 for the 24h window', async (t) => {
  const { get } = await start(t);
  const metrics = await get('/_forgedeck/v1/metrics?window=24h');
  assert.equal(metrics.status, 200);
  assert.deepEqual(metrics.body.metrics, { leads: 12, signups: 9 });
  assert.equal(metrics.body.window, '24h');
  const status = await get('/_forgedeck/v1/status');
  assert.deepEqual(status.body.metrics, { leads_24h: 12, signups_24h: 9 });
  assert.equal(status.body.health.state, 'healthy');
  const week = await get('/_forgedeck/v1/metrics?window=7d');
  assert.deepEqual(week.body.metrics, { leads: 17, signups: 12 });
});

test('example server binds to 127.0.0.1 only', async (t) => {
  const { example } = await start(t);
  assert.equal(example.server.address().address, '127.0.0.1');
});

test('example server requires the bearer token', async (t) => {
  const { base } = await start(t);
  assert.equal((await fetch(`${base}/_forgedeck/v1/status`)).status, 401);
  assert.equal((await fetch(`${base}/_forgedeck/v1/status`, { headers: { Authorization: 'Bearer nope-nope-nope-nope' } })).status, 401);
});

test('test controls are disabled unless --test-controls is given', async (t) => {
  const { post, get } = await start(t);
  assert.equal((await post('/__test/add-lead')).status, 404);
  assert.equal((await post('/__test/health?state=unhealthy')).status, 404);
  assert.deepEqual((await get('/_forgedeck/v1/metrics')).body.metrics, { leads: 12, signups: 9 });
});

test('add-lead appends exactly one lead; ids stay stable so clients can dedupe', async (t) => {
  const { get, post } = await start(t, { testControls: true });
  const before = await get('/_forgedeck/v1/leads?limit=100');
  const beforeIds = before.body.items.map((i) => i.id);
  assert.equal(new Set(beforeIds).size, beforeIds.length);

  const added = await post('/__test/add-lead');
  assert.equal(added.status, 200);
  assert.equal(added.body.test_control, true);
  assert.deepEqual(added.body.totals, { leads_24h: 13, signups_24h: 9 });

  assert.deepEqual((await get('/_forgedeck/v1/metrics?window=24h')).body.metrics, { leads: 13, signups: 9 });
  assert.deepEqual((await get('/_forgedeck/v1/status')).body.metrics, { leads_24h: 13, signups_24h: 9 });

  const after = await get('/_forgedeck/v1/leads?limit=100');
  const afterIds = after.body.items.map((i) => i.id);
  assert.equal(afterIds.length, beforeIds.length + 1);
  assert.deepEqual(afterIds.slice(0, beforeIds.length), beforeIds, 'existing ids and order are unchanged');
  assert.equal(afterIds[afterIds.length - 1], added.body.added.id);
  assert.equal(new Set(afterIds).size, afterIds.length);
  assert.ok(!JSON.stringify(after.body).includes('@'), 'no contact fields');

  // Re-reading yields the same ids again: a client merging by id sees one new lead, not duplicates.
  const again = await get('/_forgedeck/v1/leads?limit=100');
  assert.deepEqual(
    again.body.items.map((i) => i.id),
    afterIds,
  );
  const events = await get('/_forgedeck/v1/events?limit=100');
  assert.ok(events.body.items.some((i) => i.id === added.body.added.id));
});

test('paging through leads with a cursor after add-lead yields each id once', async (t) => {
  const { get, post } = await start(t, { testControls: true });
  await post('/__test/add-lead');
  const ids = [];
  let cursor = null;
  for (let page = 0; page < 10; page++) {
    const r = await get(`/_forgedeck/v1/leads?limit=10${cursor ? `&cursor=${cursor}` : ''}`);
    ids.push(...r.body.items.map((i) => i.id));
    cursor = r.body.next_cursor;
    if (!cursor) break;
  }
  assert.equal(ids.length, 5 + 3 + 12 + 9 + 1);
  assert.equal(new Set(ids).size, ids.length);
});

test('health toggle: three failing checks then recovery', async (t) => {
  const { get, post } = await start(t, { testControls: true });
  assert.equal((await get('/_forgedeck/v1/status')).body.health.state, 'healthy');
  assert.equal((await post('/__test/health?state=unhealthy')).status, 200);
  for (let i = 0; i < 3; i++) {
    const s = await get('/_forgedeck/v1/status');
    assert.equal(s.status, 200);
    assert.equal(s.body.health.state, 'unhealthy');
    assert.deepEqual(s.body.health.checks, [
      { id: 'database', state: 'unhealthy' },
      { id: 'queue', state: 'healthy' },
    ]);
  }
  assert.equal((await post('/__test/health?state=healthy')).body.health, 'healthy');
  assert.equal((await get('/_forgedeck/v1/status')).body.health.state, 'healthy');
  const incidents = (await get('/_forgedeck/v1/events?limit=100')).body.items.filter((i) => i.kind === 'incident');
  assert.equal(incidents.length, 2);
  assert.equal((await post('/__test/health?state=broken')).status, 400);
  assert.equal((await post('/__test/health?state=degraded')).status, 200);
  assert.equal((await get('/_forgedeck/v1/status')).body.health.state, 'degraded');
});

test('test controls refuse GET and browser-originated requests', async (t) => {
  const { base } = await start(t, { testControls: true });
  assert.equal((await fetch(`${base}/__test/add-lead`)).status, 405);
  assert.equal((await fetch(`${base}/__test/add-lead`, { method: 'POST', headers: { Origin: 'https://evil.example' } })).status, 403);
  assert.equal((await fetch(`${base}/__test/nope`, { method: 'POST' })).status, 404);
});

test('--sha sets the reported commit; --fail-health starts unhealthy', async (t) => {
  const sha = 'abcdef0123456789abcdef0123456789abcdef01';
  const { get } = await start(t, { sha, failHealth: true });
  const s = await get('/_forgedeck/v1/status');
  assert.equal(s.body.release.commit_sha, sha);
  assert.equal(s.body.health.state, 'unhealthy');
});

test('--masked-labels adds masked labels only', async (t) => {
  const { get } = await start(t, { maskedLabels: true });
  const r = await get('/_forgedeck/v1/leads?limit=100');
  assert.match(r.body.items[0].label, /^s\*\*\*@e\*\*\*\.com$/);
  assert.ok(!JSON.stringify(r.body).includes('sample'));
});

test('parseArgs', () => {
  const o = parseArgs(['--port', '9000', '--token', 'abcdefghijklmnopqrst', '--sha', 'abc1234', '--test-controls']);
  assert.equal(o.port, 9000);
  assert.equal(o.sha, 'abc1234');
  assert.equal(o.testControls, true);
  assert.equal(o.failHealth, false);
  assert.throws(() => parseArgs(['--sha', 'not-hex']), /--sha/);
  assert.throws(() => parseArgs(['--wat']), /Unknown argument/);
  assert.throws(() => parseArgs(['--port']), /needs a value/);
});

test('CLI: starts, serves, never prints the token, exits on SIGTERM', async () => {
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'example-server.js'), '--port', '0', '--token', TOKEN, '--test-controls'], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  child.stdout.on('data', (d) => (out += d));
  child.stderr.on('data', (d) => (out += d));
  try {
    const deadline = Date.now() + 5000;
    while (!/base URL:\s+http:\/\/127\.0\.0\.1:\d+/.test(out) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 25));
    const m = /base URL:\s+(http:\/\/127\.0\.0\.1:\d+)/.exec(out);
    assert.ok(m, `server did not start: ${out}`);
    const res = await fetch(`${m[1]}/_forgedeck/v1/metrics?window=24h`, { headers: AUTH });
    assert.equal(res.status, 200);
    assert.deepEqual((await res.json()).metrics, { leads: 12, signups: 9 });
    await new Promise((r) => setTimeout(r, 50));
    assert.ok(!out.includes(TOKEN), 'token must not be printed or logged');
    assert.match(out, /TEST CONTROLS ENABLED/);
  } finally {
    const exited = new Promise((resolve) => child.once('exit', resolve));
    child.kill('SIGTERM');
    await exited;
  }
});

test('CLI: refuses to start without a token', async () => {
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'example-server.js'), '--port', '0'], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, FORGEDECK_TOKEN: '' } });
  let err = '';
  child.stderr.on('data', (d) => (err += d));
  const code = await new Promise((resolve) => child.once('exit', resolve));
  assert.equal(code, 2);
  assert.match(err, /token/i);
});
